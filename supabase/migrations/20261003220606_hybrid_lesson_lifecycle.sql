-- Keep historical lesson rows intact. NULL completion_source means legacy data.
alter table public.lessons
  add column started_at timestamptz,
  add column completion_source text check (completion_source in ('automatic', 'teacher'));

alter table public.lessons drop constraint lessons_status_check;
alter table public.lessons add constraint lessons_status_check
  check (status in ('scheduled', 'in_progress', 'completed', 'cancelled', 'no_show', 'rescheduled'));

-- One central grace period for both scheduled and manually started lessons.
create function private.lesson_completion_grace()
returns interval language sql immutable set search_path = '' as $$
  select interval '10 minutes';
$$;
revoke all on function private.lesson_completion_grace() from public, anon, authenticated, service_role;

create or replace function private.package_committed_slots(package_uuid uuid, except_lesson_id uuid default null)
returns integer language sql stable set search_path = '' as $$
  select count(*)::integer from public.lessons l
  where l.package_id = package_uuid and l.id is distinct from except_lesson_id
    and l.consumes_lesson and (
      l.status in ('scheduled', 'in_progress', 'completed')
      or (l.status = 'cancelled' and l.resolved_at is not null));
$$;

create or replace function private.assert_lesson_slot(
  target_student_id uuid, target_teacher_id uuid, start_at timestamptz,
  target_duration_minutes integer, except_lesson_id uuid default null
)
returns void language plpgsql stable set search_path = '' as $$
begin
  if exists (select 1 from public.lessons l
    where l.status in ('scheduled', 'in_progress') and l.id is distinct from except_lesson_id
      and (l.teacher_id = target_teacher_id or l.student_id = target_student_id)
      and pg_catalog.tstzrange(coalesce(l.started_at, l.scheduled_at),
        coalesce(l.started_at, l.scheduled_at) + l.duration_minutes * interval '1 minute', '[)')
        && pg_catalog.tstzrange(start_at,
          start_at + target_duration_minutes * interval '1 minute', '[)')) then
    raise exception 'Teacher or student already has a lesson at this time' using errcode = '22023';
  end if;
end;
$$;

create function public.teacher_start_lesson(target_lesson_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  lesson_record public.lessons%rowtype;
begin
  if private.current_role() is distinct from 'teacher' then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  select * into lesson_record from public.lessons where id = target_lesson_id for update;
  if lesson_record.id is null or lesson_record.teacher_id <> auth.uid() then
    raise exception 'Lesson not found for this teacher' using errcode = '42501';
  end if;
  if lesson_record.status = 'in_progress' then
    return pg_catalog.jsonb_build_object('id', lesson_record.id,
      'status', lesson_record.status, 'started_at', lesson_record.started_at);
  end if;
  if lesson_record.status <> 'scheduled' then
    raise exception 'Only a scheduled lesson can be started' using errcode = '22023';
  end if;
  update public.lessons set status = 'in_progress', started_at = now()
  where id = lesson_record.id returning * into lesson_record;
  return pg_catalog.jsonb_build_object('id', lesson_record.id,
    'status', lesson_record.status, 'started_at', lesson_record.started_at);
end;
$$;
revoke all on function public.teacher_start_lesson(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.teacher_start_lesson(uuid) to authenticated;

-- Keep the existing RPC signature; the extra state is a server-side concern.
create or replace function public.teacher_resolve_lesson(
  target_lesson_id uuid, outcome text, reason text default null,
  note text default null, charge_package boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  lesson_record public.lessons%rowtype;
  selected_package public.lesson_packages%rowtype;
  clean_note text := nullif(pg_catalog.btrim(note), '');
begin
  if private.current_role() is distinct from 'teacher' then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  select * into lesson_record from public.lessons where id = target_lesson_id for update;
  if lesson_record.id is null or lesson_record.teacher_id <> auth.uid() then
    raise exception 'Lesson not found for this teacher' using errcode = '42501';
  end if;
  if outcome is null or outcome not in ('completed', 'cancelled') then
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
      'completion_source', lesson_record.completion_source);
  end if;
  if lesson_record.status not in ('scheduled', 'in_progress') then
    raise exception 'Only an open lesson can be resolved' using errcode = '22023';
  end if;
  if outcome = 'completed' then
    if reason is not null or clean_note is not null or charge_package then
      raise exception 'Completed lessons do not accept cancellation details' using errcode = '22023';
    end if;
    -- Legacy clients may still complete a scheduled lesson after its planned end.
    if lesson_record.status = 'scheduled' and
      lesson_record.scheduled_at + lesson_record.duration_minutes * interval '1 minute' > now() then
      raise exception 'Start the lesson before finishing it early' using errcode = '22023';
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
    if private.package_committed_slots(lesson_record.package_id, lesson_record.id)
      >= selected_package.lessons_purchased then
      raise exception 'Package has no unreserved lessons' using errcode = '22023';
    end if;
  end if;
  update public.lessons set status = outcome,
    consumes_lesson = case when outcome = 'cancelled' then charge_package else consumes_lesson end,
    outcome_reason = case when outcome = 'cancelled' then reason else null end,
    outcome_note = case when outcome = 'cancelled' then clean_note else null end,
    completed_at = case when outcome = 'completed' then now() else null end,
    completion_source = case when outcome = 'completed' then 'teacher' else null end,
    resolved_at = now(), resolved_by = auth.uid()
  where id = lesson_record.id returning * into lesson_record;
  return pg_catalog.jsonb_build_object('id', lesson_record.id,
    'status', lesson_record.status, 'consumes_lesson', lesson_record.consumes_lesson,
    'completion_source', lesson_record.completion_source);
end;
$$;

-- Cron runs as postgres; signed-in and anonymous clients cannot call this.
create function private.finalize_due_lessons(batch_limit integer default 500)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  due_lesson record;
  finalized_count integer := 0;
begin
  if batch_limit is null or batch_limit not between 1 and 1000 then
    raise exception 'Invalid batch limit' using errcode = '22023';
  end if;
  for due_lesson in
    select l.id from public.lessons l
    where l.status in ('scheduled', 'in_progress')
      and coalesce(l.started_at, l.scheduled_at)
        + l.duration_minutes * interval '1 minute'
        + private.lesson_completion_grace() <= now()
    order by coalesce(l.started_at, l.scheduled_at), l.id
    for update of l skip locked
    limit batch_limit
  loop
    update public.lessons set status = 'completed', completed_at = now(),
      resolved_at = now(), resolved_by = null, completion_source = 'automatic',
      consumes_lesson = consumes_lesson and package_id is not null
    where id = due_lesson.id and status in ('scheduled', 'in_progress');
    if found then finalized_count := finalized_count + 1; end if;
  end loop;
  return finalized_count;
end;
$$;
revoke all on function private.finalize_due_lessons(integer)
  from public, anon, authenticated, service_role;

-- Preserve admin emergency scheduling while counting active lessons as reserved.
create or replace function public.admin_schedule_lesson(
  target_student_id uuid, target_teacher_id uuid, lesson_date date, lesson_time time without time zone,
  lesson_duration integer default 60, target_package_id uuid default null,
  meeting_url text default null, takes_package_lesson boolean default true
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  created_lesson public.lessons%rowtype;
  lesson_start timestamptz;
  clean_url text := nullif(pg_catalog.btrim(meeting_url), '');
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if lesson_duration is null or lesson_duration not between 15 and 180 then
    raise exception 'Invalid duration' using errcode = '22023';
  end if;
  lesson_start := private.lesson_start_kyiv(lesson_date, lesson_time);
  if clean_url is not null and (pg_catalog.length(clean_url) > 2048
    or clean_url !~ '^https://meet[.]google[.]com/[^[:space:]]+$') then
    raise exception 'Invalid Google Meet URL' using errcode = '22023';
  end if;
  select * into student_record from public.profiles where id = target_student_id for update;
  select * into teacher_record from public.profiles where id = target_teacher_id for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or teacher_record.role <> 'teacher' or teacher_record.status <> 'active'
    or not exists (select 1 from public.teacher_students ts
      where ts.student_id = target_student_id and ts.teacher_id = target_teacher_id and ts.active) then
    raise exception 'Active assigned student and teacher required' using errcode = '42501';
  end if;
  perform private.assert_lesson_package(target_student_id, target_package_id,
    lesson_date, takes_package_lesson);
  perform private.assert_lesson_slot(target_student_id, target_teacher_id, lesson_start, lesson_duration);
  insert into public.lessons (package_id, student_id, teacher_id, scheduled_at,
    duration_minutes, status, consumes_lesson, meet_url, lesson_format, lesson_url, created_by)
  values (target_package_id, target_student_id, target_teacher_id, lesson_start,
    lesson_duration, 'scheduled', takes_package_lesson, clean_url,
    case when clean_url is null then null else 'online' end, clean_url, auth.uid())
  returning * into created_lesson;
  return pg_catalog.jsonb_build_object('id', created_lesson.id,
    'student_id', created_lesson.student_id, 'teacher_id', created_lesson.teacher_id,
    'package_id', created_lesson.package_id, 'scheduled_at', created_lesson.scheduled_at,
    'duration_minutes', created_lesson.duration_minutes, 'status', created_lesson.status,
    'consumes_lesson', created_lesson.consumes_lesson, 'meet_url', created_lesson.meet_url);
end;
$$;
