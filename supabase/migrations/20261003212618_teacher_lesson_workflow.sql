-- Existing lessons and Meet URLs remain intact. A null format means a legacy
-- lesson whose location was not explicitly recorded.
alter table public.lessons
  add column lesson_format text check (lesson_format in ('online', 'offline')),
  add column lesson_url text,
  add column location_text text,
  add column outcome_reason text check (outcome_reason in (
    'student_no_show', 'teacher_unavailable', 'student_cancelled',
    'technical_issue', 'cancelled_in_advance', 'other')),
  add column outcome_note text check (outcome_note is null or char_length(outcome_note) <= 2000),
  add column resolved_at timestamptz,
  add column resolved_by uuid references public.profiles(id),
  add column rescheduled_from uuid references public.lessons(id);

alter table public.lessons drop constraint lessons_status_check;
alter table public.lessons add constraint lessons_status_check
  check (status in ('scheduled', 'completed', 'cancelled', 'no_show', 'rescheduled'));

create unique index lessons_rescheduled_from_unique
  on public.lessons(rescheduled_from) where rescheduled_from is not null;

-- Legacy cancelled/no_show rows had no charge regardless of consumes_lesson.
-- New cancellations count only after an explicit, recorded resolution.
create or replace function private.package_lessons_used(package_uuid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select count(l.id)::integer from public.lesson_packages p
  join public.lessons l on l.package_id = p.id
  where p.id = package_uuid and l.consumes_lesson
    and (l.status = 'completed' or (l.status = 'cancelled' and l.resolved_at is not null))
    and ((p.student_id = (select auth.uid()) and private.current_role() = 'student')
      or private.is_teacher_of(p.student_id) or private.is_admin());
$$;

-- This helper is callable only from owner-checked SECURITY DEFINER RPCs.
create function private.package_committed_slots(package_uuid uuid, except_lesson_id uuid default null)
returns integer language sql stable set search_path = '' as $$
  select count(*)::integer from public.lessons l
  where l.package_id = package_uuid and l.id is distinct from except_lesson_id
    and l.consumes_lesson and (
      l.status in ('scheduled', 'completed')
      or (l.status = 'cancelled' and l.resolved_at is not null));
$$;
revoke all on function private.package_committed_slots(uuid, uuid) from public, anon, authenticated;

create function private.lesson_start_kyiv(lesson_date date, lesson_time time without time zone)
returns timestamptz language plpgsql stable set search_path = '' as $$
declare
  local_time timestamp without time zone;
  start_at timestamptz;
begin
  if lesson_date is null or lesson_time is null then
    raise exception 'Date and time required' using errcode = '22023';
  end if;
  local_time := lesson_date::timestamp + lesson_time;
  start_at := local_time at time zone 'Europe/Kyiv';
  if start_at <= now() or (start_at at time zone 'Europe/Kyiv') <> local_time then
    raise exception 'Choose a valid future Kyiv time' using errcode = '22023';
  end if;
  return start_at;
end;
$$;
revoke all on function private.lesson_start_kyiv(date, time without time zone) from public, anon, authenticated;

create function private.assert_lesson_destination(
  selected_format text, selected_url text, selected_location text
)
returns void language plpgsql set search_path = '' as $$
begin
  if selected_format = 'online' then
    if selected_url is null or pg_catalog.length(selected_url) > 2048
      or selected_url !~ '^https://[^/@[:space:]]+(/[^[:space:]]*)?$'
      or selected_location is not null then
      raise exception 'An online lesson needs an HTTPS link only' using errcode = '22023';
    end if;
  elsif selected_format = 'offline' then
    if selected_location is null or pg_catalog.length(selected_location) > 500
      or selected_url is not null then
      raise exception 'An offline lesson needs a location only' using errcode = '22023';
    end if;
  else
    raise exception 'Invalid lesson format' using errcode = '22023';
  end if;
end;
$$;
revoke all on function private.assert_lesson_destination(text, text, text) from public, anon, authenticated;

create function private.assert_lesson_package(
  target_student_id uuid, target_package_id uuid, lesson_date date,
  takes_package_lesson boolean, except_lesson_id uuid default null
)
returns void language plpgsql set search_path = '' as $$
declare
  selected_package public.lesson_packages%rowtype;
begin
  if takes_package_lesson is null or (takes_package_lesson and target_package_id is null) then
    raise exception 'A consuming lesson requires a package' using errcode = '22023';
  end if;
  if target_package_id is null then return; end if;
  select * into selected_package from public.lesson_packages where id = target_package_id for update;
  if selected_package.id is null or selected_package.student_id <> target_student_id
    or selected_package.status <> 'active'
    or (selected_package.valid_from is not null and lesson_date < selected_package.valid_from)
    or (selected_package.valid_until is not null and lesson_date > selected_package.valid_until) then
    raise exception 'An active student package valid on lesson day is required' using errcode = '22023';
  end if;
  if takes_package_lesson and
    private.package_committed_slots(target_package_id, except_lesson_id) >= selected_package.lessons_purchased then
    raise exception 'Package has no unreserved lessons' using errcode = '22023';
  end if;
end;
$$;
revoke all on function private.assert_lesson_package(uuid, uuid, date, boolean, uuid)
  from public, anon, authenticated;

create function private.assert_lesson_slot(
  target_student_id uuid, target_teacher_id uuid, start_at timestamptz,
  target_duration_minutes integer, except_lesson_id uuid default null
)
returns void language plpgsql stable set search_path = '' as $$
begin
  if exists (select 1 from public.lessons l
    where l.status = 'scheduled' and l.id is distinct from except_lesson_id
      and (l.teacher_id = target_teacher_id or l.student_id = target_student_id)
      and pg_catalog.tstzrange(l.scheduled_at,
        l.scheduled_at + l.duration_minutes * interval '1 minute', '[)')
        && pg_catalog.tstzrange(start_at,
          start_at + target_duration_minutes * interval '1 minute', '[)')) then
    raise exception 'Teacher or student already has a lesson at this time' using errcode = '22023';
  end if;
end;
$$;
revoke all on function private.assert_lesson_slot(uuid, uuid, timestamptz, integer, uuid)
  from public, anon, authenticated;

create function public.teacher_schedule_lesson(
  target_student_id uuid, lesson_date date, lesson_time time without time zone,
  lesson_duration integer, selected_format text, selected_url text,
  selected_location text, target_package_id uuid, takes_package_lesson boolean
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  created_lesson public.lessons%rowtype;
  start_at timestamptz;
  clean_url text := nullif(pg_catalog.btrim(selected_url), '');
  clean_location text := nullif(pg_catalog.btrim(selected_location), '');
begin
  if private.current_role() is distinct from 'teacher' then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  if lesson_duration is null or lesson_duration not between 15 and 180 then
    raise exception 'Invalid duration' using errcode = '22023';
  end if;
  start_at := private.lesson_start_kyiv(lesson_date, lesson_time);
  perform private.assert_lesson_destination(selected_format, clean_url, clean_location);
  select * into student_record from public.profiles where id = target_student_id for update;
  select * into teacher_record from public.profiles where id = auth.uid() for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or teacher_record.role <> 'teacher' or teacher_record.status <> 'active'
    or not exists (select 1 from public.teacher_students ts
      where ts.student_id = target_student_id and ts.teacher_id = auth.uid() and ts.active) then
    raise exception 'Active assigned student required' using errcode = '42501';
  end if;
  perform private.assert_lesson_package(target_student_id, target_package_id,
    lesson_date, takes_package_lesson);
  perform private.assert_lesson_slot(target_student_id, auth.uid(), start_at, lesson_duration);
  insert into public.lessons (student_id, teacher_id, package_id, scheduled_at,
    duration_minutes, status, consumes_lesson, lesson_format, lesson_url,
    location_text, created_by)
  values (target_student_id, auth.uid(), target_package_id, start_at,
    lesson_duration, 'scheduled', takes_package_lesson, selected_format,
    clean_url, clean_location, auth.uid()) returning * into created_lesson;
  return pg_catalog.jsonb_build_object('id', created_lesson.id,
    'scheduled_at', created_lesson.scheduled_at, 'status', created_lesson.status);
end;
$$;

create function public.teacher_resolve_lesson(
  target_lesson_id uuid, outcome text, reason text default null,
  note text default null, charge_package boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  lesson_record public.lessons%rowtype;
  selected_package public.lesson_packages%rowtype;
  clean_note text := nullif(pg_catalog.btrim(note), '');
  committed_count integer;
begin
  if private.current_role() is distinct from 'teacher' then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  select * into lesson_record from public.lessons where id = target_lesson_id for update;
  if lesson_record.id is null or lesson_record.teacher_id <> auth.uid() then
    raise exception 'Lesson not found for this teacher' using errcode = '42501';
  end if;
  if outcome not in ('completed', 'cancelled') or outcome is null then
    raise exception 'Invalid outcome' using errcode = '22023';
  end if;
  if lesson_record.status = outcome then
    if outcome = 'cancelled' and (lesson_record.outcome_reason is distinct from reason
      or lesson_record.outcome_note is distinct from clean_note
      or lesson_record.consumes_lesson is distinct from charge_package) then
      raise exception 'Lesson already resolved with a different decision' using errcode = '22023';
    end if;
    return pg_catalog.jsonb_build_object('id', lesson_record.id,
      'status', lesson_record.status, 'consumes_lesson', lesson_record.consumes_lesson,
      'resolved_at', lesson_record.resolved_at);
  end if;
  if lesson_record.status <> 'scheduled' or
    lesson_record.scheduled_at + lesson_record.duration_minutes * interval '1 minute' > now() then
    raise exception 'Only a finished scheduled lesson can be resolved' using errcode = '22023';
  end if;
  if outcome = 'completed' then
    if reason is not null or clean_note is not null or charge_package then
      raise exception 'Completed lessons do not accept cancellation details' using errcode = '22023';
    end if;
  else
    if reason is null or reason not in ('student_no_show', 'teacher_unavailable',
      'student_cancelled', 'technical_issue', 'cancelled_in_advance', 'other')
      or (reason = 'other' and clean_note is null) or charge_package is null then
      raise exception 'Valid cancellation reason and charge decision required' using errcode = '22023';
    end if;
  end if;
  if clean_note is not null and pg_catalog.length(clean_note) > 2000 then
    raise exception 'Note is too long' using errcode = '22023';
  end if;
  if (outcome = 'completed' and lesson_record.consumes_lesson)
    or (outcome = 'cancelled' and charge_package) then
    if lesson_record.package_id is null then
      raise exception 'A charged lesson requires a package' using errcode = '22023';
    end if;
    select * into selected_package from public.lesson_packages
    where id = lesson_record.package_id for update;
    committed_count := private.package_committed_slots(lesson_record.package_id, lesson_record.id);
    if committed_count >= selected_package.lessons_purchased then
      raise exception 'Package has no unreserved lessons' using errcode = '22023';
    end if;
  end if;
  update public.lessons set status = outcome,
    consumes_lesson = case when outcome = 'cancelled' then charge_package else consumes_lesson end,
    outcome_reason = case when outcome = 'cancelled' then reason else null end,
    outcome_note = case when outcome = 'cancelled' then clean_note else null end,
    completed_at = case when outcome = 'completed' then now() else null end,
    resolved_at = now(), resolved_by = auth.uid()
  where id = lesson_record.id returning * into lesson_record;
  return pg_catalog.jsonb_build_object('id', lesson_record.id,
    'status', lesson_record.status, 'consumes_lesson', lesson_record.consumes_lesson,
    'resolved_at', lesson_record.resolved_at);
end;
$$;

-- Keep the existing public API working for already-deployed clients.
create or replace function public.teacher_complete_lesson(target_lesson_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return public.teacher_resolve_lesson(target_lesson_id, 'completed', null, null, false);
end;
$$;

create function public.teacher_reschedule_lesson(
  target_lesson_id uuid, lesson_date date, lesson_time time without time zone,
  lesson_duration integer, selected_format text, selected_url text,
  selected_location text, target_package_id uuid, takes_package_lesson boolean
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  old_lesson public.lessons%rowtype;
  new_lesson public.lessons%rowtype;
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  start_at timestamptz;
  clean_url text := nullif(pg_catalog.btrim(selected_url), '');
  clean_location text := nullif(pg_catalog.btrim(selected_location), '');
begin
  if private.current_role() is distinct from 'teacher' then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  select * into old_lesson from public.lessons where id = target_lesson_id for update;
  if old_lesson.id is null or old_lesson.teacher_id <> auth.uid() then
    raise exception 'Lesson not found for this teacher' using errcode = '42501';
  end if;
  if old_lesson.status = 'rescheduled' then
    select * into new_lesson from public.lessons where rescheduled_from = old_lesson.id;
    return pg_catalog.jsonb_build_object('old_id', old_lesson.id,
      'old_status', old_lesson.status, 'new_id', new_lesson.id,
      'new_status', new_lesson.status);
  end if;
  if old_lesson.status <> 'scheduled' or lesson_duration is null
    or lesson_duration not between 15 and 180 then
    raise exception 'Only a scheduled lesson can be rescheduled' using errcode = '22023';
  end if;
  start_at := private.lesson_start_kyiv(lesson_date, lesson_time);
  perform private.assert_lesson_destination(selected_format, clean_url, clean_location);
  select * into student_record from public.profiles where id = old_lesson.student_id for update;
  select * into teacher_record from public.profiles where id = auth.uid() for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or teacher_record.role <> 'teacher' or teacher_record.status <> 'active'
    or not exists (select 1 from public.teacher_students ts
      where ts.student_id = old_lesson.student_id and ts.teacher_id = auth.uid() and ts.active) then
    raise exception 'Active assigned student required' using errcode = '42501';
  end if;
  perform private.assert_lesson_package(old_lesson.student_id, target_package_id,
    lesson_date, takes_package_lesson, old_lesson.id);
  perform private.assert_lesson_slot(old_lesson.student_id, auth.uid(), start_at,
    lesson_duration, old_lesson.id);
  update public.lessons set status = 'rescheduled', consumes_lesson = false,
    resolved_at = now(), resolved_by = auth.uid()
  where id = old_lesson.id;
  insert into public.lessons (student_id, teacher_id, package_id, scheduled_at,
    duration_minutes, status, consumes_lesson, lesson_format, lesson_url,
    location_text, created_by, rescheduled_from)
  values (old_lesson.student_id, auth.uid(), target_package_id, start_at,
    lesson_duration, 'scheduled', takes_package_lesson, selected_format,
    clean_url, clean_location, auth.uid(), old_lesson.id) returning * into new_lesson;
  return pg_catalog.jsonb_build_object('old_id', old_lesson.id,
    'old_status', 'rescheduled', 'new_id', new_lesson.id,
    'new_status', new_lesson.status);
end;
$$;

revoke all on function public.teacher_schedule_lesson(uuid, date, time without time zone, integer, text, text, text, uuid, boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.teacher_resolve_lesson(uuid, text, text, text, boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.teacher_reschedule_lesson(uuid, date, time without time zone, integer, text, text, text, uuid, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.teacher_schedule_lesson(uuid, date, time without time zone, integer, text, text, text, uuid, boolean)
  to authenticated;
grant execute on function public.teacher_resolve_lesson(uuid, text, text, text, boolean)
  to authenticated;
grant execute on function public.teacher_reschedule_lesson(uuid, date, time without time zone, integer, text, text, text, uuid, boolean)
  to authenticated;

-- Preserve admin emergency scheduling, including its existing signature.
-- It now observes explicitly charged cancellations when reserving capacity.
create or replace function public.admin_schedule_lesson(
  target_student_id uuid, target_teacher_id uuid, lesson_date date, lesson_time time without time zone,
  lesson_duration integer default 60, target_package_id uuid default null,
  meeting_url text default null, takes_package_lesson boolean default true
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  selected_package public.lesson_packages%rowtype;
  created_lesson public.lessons%rowtype;
  local_time timestamp without time zone;
  lesson_start timestamptz;
  reserved_count integer;
  clean_url text;
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if lesson_date is null or lesson_time is null or lesson_duration is null
    or lesson_duration not between 15 and 180 or takes_package_lesson is null then
    raise exception 'Invalid lesson date or duration' using errcode = '22023';
  end if;
  local_time := lesson_date::timestamp + lesson_time;
  lesson_start := local_time at time zone 'Europe/Kyiv';
  if lesson_start <= now()
    or (lesson_start at time zone 'Europe/Kyiv') <> local_time then
    raise exception 'Choose a valid future Kyiv time' using errcode = '22023';
  end if;
  clean_url := nullif(pg_catalog.btrim(meeting_url), '');
  if clean_url is not null and (pg_catalog.length(clean_url) > 2048
    or clean_url !~ '^https://meet[.]google[.]com/[^[:space:]]+$') then
    raise exception 'Invalid Google Meet URL' using errcode = '22023';
  end if;
  if takes_package_lesson and target_package_id is null then
    raise exception 'A consuming lesson requires a package' using errcode = '22023';
  end if;

  select * into student_record from public.profiles where id = target_student_id for update;
  select * into teacher_record from public.profiles where id = target_teacher_id for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or teacher_record.role <> 'teacher' or teacher_record.status <> 'active' then
    raise exception 'Active student and teacher required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.teacher_students ts
    where ts.student_id = target_student_id and ts.teacher_id = target_teacher_id and ts.active) then
    raise exception 'Teacher is not assigned to student' using errcode = '22023';
  end if;
  if target_package_id is not null then
    select * into selected_package from public.lesson_packages
    where id = target_package_id for update;
    if selected_package.id is null or selected_package.student_id <> target_student_id
      or selected_package.status <> 'active'
      or (selected_package.valid_from is not null and lesson_date < selected_package.valid_from)
      or (selected_package.valid_until is not null and lesson_date > selected_package.valid_until) then
      raise exception 'An active student package valid on lesson day is required' using errcode = '22023';
    end if;
    if takes_package_lesson then
      select count(*) into reserved_count from public.lessons l
      where l.package_id = target_package_id and l.consumes_lesson
        and (l.status in ('scheduled', 'completed')
          or (l.status = 'cancelled' and l.resolved_at is not null));
      if reserved_count >= selected_package.lessons_purchased then
        raise exception 'Package has no unreserved lessons' using errcode = '22023';
      end if;
    end if;
  end if;
  if exists (select 1 from public.lessons l where l.status = 'scheduled'
    and (l.teacher_id = target_teacher_id or l.student_id = target_student_id)
    and pg_catalog.tstzrange(l.scheduled_at,
      l.scheduled_at + l.duration_minutes * interval '1 minute', '[)')
      && pg_catalog.tstzrange(lesson_start,
        lesson_start + lesson_duration * interval '1 minute', '[)')) then
    raise exception 'Teacher or student already has a lesson at this time' using errcode = '22023';
  end if;
  insert into public.lessons
    (package_id, student_id, teacher_id, scheduled_at, duration_minutes,
      status, consumes_lesson, meet_url, lesson_format, lesson_url, created_by)
  values (target_package_id, target_student_id, target_teacher_id, lesson_start,
    lesson_duration, 'scheduled', takes_package_lesson, clean_url,
    case when clean_url is null then null else 'online' end, clean_url, auth.uid())
  returning * into created_lesson;
  return pg_catalog.jsonb_build_object(
    'id', created_lesson.id, 'student_id', created_lesson.student_id,
    'teacher_id', created_lesson.teacher_id, 'package_id', created_lesson.package_id,
    'scheduled_at', created_lesson.scheduled_at,
    'duration_minutes', created_lesson.duration_minutes,
    'status', created_lesson.status, 'consumes_lesson', created_lesson.consumes_lesson,
    'meet_url', created_lesson.meet_url
  );
end;
$$;
