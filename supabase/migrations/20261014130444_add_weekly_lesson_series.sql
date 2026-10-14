-- Finite weekly rules; concrete lessons remain the source of scheduling/billing.
set local lock_timeout = '5s';
create table public.lesson_series (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id),
  teacher_id uuid not null references public.profiles(id),
  start_date date not null,
  weekday smallint not null check (weekday between 1 and 7),
  local_time time not null check (local_time < time '24:00'),
  duration_minutes integer not null check (duration_minutes between 15 and 180),
  lesson_format text not null check (lesson_format in ('online', 'offline')),
  lesson_url text,
  location_text text,
  package_id uuid,
  consumes_lesson boolean not null,
  occurrence_count integer not null check (occurrence_count between 2 and 52),
  status text not null default 'active' check (status in ('active', 'ended')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, student_id, teacher_id),
  foreign key (package_id, student_id) references public.lesson_packages(id, student_id),
  check (teacher_id <> student_id),
  check (weekday = extract(isodow from start_date)),
  check (not consumes_lesson or package_id is not null)
);
create index lesson_series_student_idx on public.lesson_series(student_id);
create index lesson_series_teacher_idx on public.lesson_series(teacher_id);
create index lesson_series_package_student_idx on public.lesson_series(package_id, student_id) where package_id is not null;
create index lesson_series_created_by_idx on public.lesson_series(created_by);
create trigger lesson_series_updated_at before update on public.lesson_series
for each row execute function private.set_updated_at();

alter table public.lesson_series enable row level security;
revoke all on public.lesson_series from public, anon, authenticated, service_role;
grant select on public.lesson_series to authenticated;
create policy lesson_series_read on public.lesson_series for select to authenticated using (
  (select private.is_admin())
  or (teacher_id = (select auth.uid()) and private.can_teach((select auth.uid())))
  or (student_id = (select auth.uid()) and (select private.current_role()) = 'student')
);

alter table public.lessons
  add column series_id uuid,
  add column series_occurrence smallint,
  add column series_exception boolean not null default false,
  add constraint lessons_series_owner_fk foreign key (series_id, student_id, teacher_id)
    references public.lesson_series(id, student_id, teacher_id),
  add constraint lessons_series_occurrence_check check (
    (series_id is null and series_occurrence is null and not series_exception)
    or (series_id is not null and series_occurrence between 1 and 52 and series_occurrence is not null)
  );
create index lessons_series_idx on public.lessons(series_id, series_occurrence) where series_id is not null;
create index lessons_series_owner_idx on public.lessons(series_id, student_id, teacher_id) where series_id is not null;
create unique index lessons_series_current_occurrence_idx on public.lessons(series_id, series_occurrence)
  where series_id is not null and status <> 'rescheduled';
-- Preserve column-level protection of outcome_note; never grant table SELECT.
grant select (series_id, series_occurrence, series_exception) on public.lessons to authenticated;

create function private.assert_series_actor(target_student_id uuid)
returns void language plpgsql set search_path = '' as $$
declare
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  -- Same student/teacher lock order as existing single-lesson scheduling.
  select * into student_record from public.profiles where id = target_student_id for update;
  select * into teacher_record from public.profiles where id = auth.uid() for update;
  if student_record.id is null or student_record.role is distinct from 'student'
    or student_record.status is distinct from 'active'
    or teacher_record.id is null or teacher_record.status is distinct from 'active'
    or not (teacher_record.role = 'teacher' or (teacher_record.role = 'admin' and teacher_record.can_teach)) then
    raise exception 'Active assigned student required' using errcode = '42501';
  end if;
  perform 1 from public.teacher_students ts where ts.student_id = target_student_id
    and ts.teacher_id = auth.uid() and ts.active for share;
  if not found then
    raise exception 'Active assigned student required' using errcode = '42501';
  end if;
end;
$$;

-- Generalize assert_lesson_slot's identical overlap rule to a replacement set.
-- Individual exceptions and non-scheduled records are never in the exclusions.
create function private.assert_series_slot(target_student_id uuid, start_at timestamptz,
  lesson_duration integer, replaced_ids uuid[])
returns void language plpgsql stable set search_path = '' as $$
begin
  if exists (select 1 from public.lessons l
    where l.status in ('scheduled', 'in_progress') and not (l.id = any(replaced_ids))
      and (l.teacher_id = auth.uid() or l.student_id = target_student_id)
      and pg_catalog.tstzrange(coalesce(l.started_at, l.scheduled_at),
        coalesce(l.started_at, l.scheduled_at) + l.duration_minutes * interval '1 minute', '[)')
        && pg_catalog.tstzrange(start_at, start_at + lesson_duration * interval '1 minute', '[)')) then
    raise exception 'Series slot conflict' using errcode = '22023',
      detail = jsonb_build_object('scheduled_at', start_at)::text;
  end if;
end;
$$;

create function private.assert_series_package(target_student_id uuid, target_package_id uuid,
  lesson_dates date[], takes_package_lesson boolean, replaced_ids uuid[])
returns void language plpgsql set search_path = '' as $$
declare
  selected_package public.lesson_packages%rowtype;
  committed integer;
begin
  if takes_package_lesson is null or (takes_package_lesson and target_package_id is null) then
    raise exception 'A consuming lesson requires a package' using errcode = '22023';
  end if;
  if target_package_id is null then return; end if;
  select * into selected_package from public.lesson_packages where id = target_package_id for update;
  if selected_package.id is null or selected_package.student_id <> target_student_id
    or selected_package.status <> 'active'
    or exists (select 1 from unnest(lesson_dates) d where
      (selected_package.valid_from is not null and d < selected_package.valid_from)
      or (selected_package.valid_until is not null and d > selected_package.valid_until)) then
    raise exception 'Series package invalid on lesson dates' using errcode = '22023';
  end if;
  -- Exact committed-slot statuses used by private.package_committed_slots.
  select count(*) into committed from public.lessons l
    where l.package_id = target_package_id and not (l.id = any(replaced_ids))
      and l.consumes_lesson and (l.status in ('scheduled', 'in_progress', 'completed')
        or (l.status = 'cancelled' and l.resolved_at is not null));
  if takes_package_lesson and committed + cardinality(lesson_dates) > selected_package.lessons_purchased then
    raise exception 'Series package insufficient' using errcode = '22023',
      detail = jsonb_build_object('count', cardinality(lesson_dates))::text;
  end if;
end;
$$;

create function public.teacher_schedule_lesson_series(target_student_id uuid,
  lesson_date date, lesson_time time, lesson_duration integer, selected_format text,
  selected_url text, selected_location text, target_package_id uuid,
  takes_package_lesson boolean, occurrence_count integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  lesson_dates date[];
  starts_at timestamptz[] := '{}';
  series_uuid uuid;
  created jsonb;
  instant timestamptz;
  clean_url text := nullif(btrim(selected_url), '');
  clean_location text := nullif(btrim(selected_location), '');
  i integer;
begin
  perform private.assert_series_actor(target_student_id);
  if occurrence_count is null or occurrence_count not between 2 and 52 then
    raise exception 'Series count must be between 2 and 52' using errcode = '22023';
  end if;
  if lesson_duration is null or lesson_duration not between 15 and 180 then
    raise exception 'Invalid duration' using errcode = '22023';
  end if;
  perform private.assert_lesson_destination(selected_format, clean_url, clean_location);
  select array_agg(lesson_date + n * 7 order by n) into lesson_dates
    from generate_series(0, occurrence_count - 1) n;
  for i in 1..occurrence_count loop
    -- Civil dates + Kyiv wall time, not seven UTC days: preserves DST.
    instant := private.lesson_start_kyiv(lesson_dates[i], lesson_time);
    starts_at := array_append(starts_at, instant);
    begin
      perform private.assert_lesson_slot(target_student_id, auth.uid(), instant, lesson_duration);
    exception when sqlstate '22023' then
      raise exception 'Series slot conflict' using errcode = '22023',
        detail = jsonb_build_object('scheduled_at', instant)::text;
    end;
  end loop;
  perform private.assert_series_package(target_student_id, target_package_id,
    lesson_dates, takes_package_lesson, '{}'::uuid[]);
  insert into public.lesson_series (student_id, teacher_id, start_date, weekday, local_time,
    duration_minutes, lesson_format, lesson_url, location_text, package_id,
    consumes_lesson, occurrence_count, created_by)
  values (target_student_id, auth.uid(), lesson_date, extract(isodow from lesson_date), lesson_time,
    lesson_duration, selected_format, clean_url, clean_location, target_package_id,
    takes_package_lesson, occurrence_count, auth.uid()) returning id into series_uuid;
  for i in 1..occurrence_count loop
    -- Reuse every existing single-lesson package/slot/assignment validation.
    created := public.teacher_schedule_lesson(target_student_id, lesson_dates[i], lesson_time,
      lesson_duration, selected_format, clean_url, clean_location, target_package_id, takes_package_lesson);
    update public.lessons set series_id = series_uuid, series_occurrence = i where id = (created ->> 'id')::uuid;
  end loop;
  return jsonb_build_object('series_id', series_uuid, 'count', occurrence_count,
    'first_scheduled_at', starts_at[1]);
end;
$$;

create function public.teacher_update_lesson_series_from(target_lesson_id uuid,
  lesson_date date, lesson_time time, lesson_duration integer, selected_format text,
  selected_url text, selected_location text, target_package_id uuid, takes_package_lesson boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  anchor public.lessons%rowtype;
  series_record public.lesson_series%rowtype;
  old_lesson public.lessons%rowtype;
  old_id uuid;
  replaced_ids uuid[];
  lesson_dates date[] := '{}';
  starts_at timestamptz[] := '{}';
  new_day date;
  new_start timestamptz;
  clean_url text := nullif(btrim(selected_url), '');
  clean_location text := nullif(btrim(selected_location), '');
  i integer := 0;
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  select * into anchor from public.lessons where id = target_lesson_id;
  if anchor.id is null or anchor.teacher_id <> auth.uid() or anchor.series_id is null then
    raise exception 'Series lesson not found for this teacher' using errcode = '42501';
  end if;
  -- All series edits serialize on this rule before locking concrete lessons.
  select * into series_record from public.lesson_series where id = anchor.series_id
    and teacher_id = auth.uid() for update;
  if series_record.id is null then
    raise exception 'Series not found for this teacher' using errcode = '42501';
  end if;
  perform 1 from public.lessons l where l.id = target_lesson_id or (
    l.series_id = series_record.id and l.teacher_id = auth.uid()
    and l.series_occurrence >= anchor.series_occurrence and l.scheduled_at >= anchor.scheduled_at
    and l.scheduled_at > now() and l.status = 'scheduled' and not l.series_exception
  ) order by l.id for update;
  select * into anchor from public.lessons where id = target_lesson_id;
  if anchor.status <> 'scheduled' or anchor.scheduled_at <= now() or anchor.series_exception then
    raise exception 'Regular future scheduled series lesson required' using errcode = '22023';
  end if;
  perform private.assert_series_actor(anchor.student_id);
  if lesson_duration is null or lesson_duration not between 15 and 180 then
    raise exception 'Invalid duration' using errcode = '22023';
  end if;
  perform private.assert_lesson_destination(selected_format, clean_url, clean_location);
  if private.lesson_start_kyiv(lesson_date, lesson_time) = anchor.scheduled_at
    and lesson_duration = anchor.duration_minutes
    and selected_format is not distinct from coalesce(anchor.lesson_format, case when coalesce(anchor.lesson_url, anchor.meet_url) is not null then 'online' else 'offline' end)
    and clean_url is not distinct from coalesce(nullif(btrim(anchor.lesson_url), ''), nullif(btrim(anchor.meet_url), ''))
    and clean_location is not distinct from nullif(btrim(anchor.location_text), '')
    and target_package_id is not distinct from anchor.package_id
    and takes_package_lesson is not distinct from anchor.consumes_lesson then
    raise exception 'Reschedule must change lesson details' using errcode = '22023';
  end if;
  select array_agg(l.id order by l.series_occurrence) into replaced_ids from public.lessons l
    where l.series_id = series_record.id and l.teacher_id = auth.uid()
      and l.series_occurrence >= anchor.series_occurrence and l.scheduled_at >= anchor.scheduled_at
      and l.scheduled_at > now() and l.status = 'scheduled' and not l.series_exception;
  -- Lock every released/selected package in a deterministic order as well.
  perform 1 from public.lesson_packages p where p.id = target_package_id
    or p.id in (select package_id from public.lessons where id = any(replaced_ids)) order by p.id for update;
  foreach old_id in array replaced_ids loop
    select * into old_lesson from public.lessons where id = old_id;
    new_day := lesson_date + (old_lesson.series_occurrence - anchor.series_occurrence) * 7;
    new_start := private.lesson_start_kyiv(new_day, lesson_time);
    perform private.assert_series_slot(anchor.student_id, new_start, lesson_duration, replaced_ids);
    lesson_dates := array_append(lesson_dates, new_day);
    starts_at := array_append(starts_at, new_start);
  end loop;
  perform private.assert_series_package(anchor.student_id, target_package_id,
    lesson_dates, takes_package_lesson, replaced_ids);
  -- All checks precede writes; any later trigger error still rolls back everything.
  update public.lessons set status = 'rescheduled', consumes_lesson = false,
    resolved_at = now(), resolved_by = auth.uid() where id = any(replaced_ids);
  foreach old_id in array replaced_ids loop
    select * into old_lesson from public.lessons where id = old_id;
    i := i + 1;
    insert into public.lessons (student_id, teacher_id, package_id, scheduled_at, duration_minutes,
      status, consumes_lesson, lesson_format, lesson_url, location_text, created_by,
      rescheduled_from, series_id, series_occurrence, series_exception)
    values (anchor.student_id, auth.uid(), target_package_id, starts_at[i], lesson_duration,
      'scheduled', takes_package_lesson, selected_format, clean_url, clean_location, auth.uid(),
      old_lesson.id, series_record.id, old_lesson.series_occurrence, false);
  end loop;
  update public.lesson_series set start_date = lesson_date - (anchor.series_occurrence - 1) * 7,
    weekday = extract(isodow from lesson_date), local_time = lesson_time,
    duration_minutes = lesson_duration, lesson_format = selected_format, lesson_url = clean_url,
    location_text = clean_location, package_id = target_package_id, consumes_lesson = takes_package_lesson
    where id = series_record.id;
  return jsonb_build_object('series_id', series_record.id, 'count', cardinality(replaced_ids),
    'first_scheduled_at', starts_at[1]);
end;
$$;

revoke all on function private.assert_series_actor(uuid),
  private.assert_series_slot(uuid, timestamptz, integer, uuid[]),
  private.assert_series_package(uuid, uuid, date[], boolean, uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.teacher_schedule_lesson_series(uuid, date, time, integer, text, text, text, uuid, boolean, integer),
  public.teacher_update_lesson_series_from(uuid, date, time, integer, text, text, text, uuid, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.teacher_schedule_lesson_series(uuid, date, time, integer, text, text, text, uuid, boolean, integer),
  public.teacher_update_lesson_series_from(uuid, date, time, integer, text, text, text, uuid, boolean) to authenticated;

-- Preserve the existing single-occurrence history and idempotency contract.
CREATE OR REPLACE FUNCTION public.teacher_reschedule_lesson(target_lesson_id uuid, lesson_date date, lesson_time time without time zone, lesson_duration integer, selected_format text, selected_url text, selected_location text, target_package_id uuid, takes_package_lesson boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  old_lesson public.lessons%rowtype;
  new_lesson public.lessons%rowtype;
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  start_at timestamptz;
  clean_url text := nullif(pg_catalog.btrim(selected_url), '');
  clean_location text := nullif(pg_catalog.btrim(selected_location), '');
  old_url text;
  old_location text;
  old_format text;
  original_series uuid;
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  select series_id into original_series from public.lessons where id = target_lesson_id and teacher_id = auth.uid();
  if original_series is not null then
    perform 1 from public.lesson_series where id = original_series and teacher_id = auth.uid() for update;
    if not found then raise exception 'Series not found for this teacher' using errcode = '42501'; end if;
  end if;
  -- Serializes repeated/concurrent calls for this exact lesson ID.
  select * into old_lesson from public.lessons where id = target_lesson_id for update;
  if old_lesson.id is null or old_lesson.teacher_id <> auth.uid() then
    raise exception 'Lesson not found for this teacher' using errcode = '42501';
  end if;
  if old_lesson.status = 'rescheduled' then
    select * into new_lesson from public.lessons where rescheduled_from = old_lesson.id;
    if new_lesson.id is null then
      raise exception 'Replacement lesson missing' using errcode = '22023';
    end if;
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

  -- Compare effective, normalized values. Older online lessons may store the
  -- link only in meet_url and have no explicit lesson_format.
  old_url := coalesce(nullif(pg_catalog.btrim(old_lesson.lesson_url), ''),
    nullif(pg_catalog.btrim(old_lesson.meet_url), ''));
  old_location := nullif(pg_catalog.btrim(old_lesson.location_text), '');
  old_format := coalesce(old_lesson.lesson_format,
    case when old_url is not null then 'online'
      when old_location is not null then 'offline' end);
  if start_at = old_lesson.scheduled_at
    and lesson_duration = old_lesson.duration_minutes
    and selected_format is not distinct from old_format
    and clean_url is not distinct from old_url
    and clean_location is not distinct from old_location
    and target_package_id is not distinct from old_lesson.package_id
    and takes_package_lesson is not distinct from old_lesson.consumes_lesson then
    raise exception 'Reschedule must change lesson details' using errcode = '22023';
  end if;

  select * into student_record from public.profiles where id = old_lesson.student_id for update;
  select * into teacher_record from public.profiles where id = auth.uid() for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or not (teacher_record.role = 'teacher' or (teacher_record.role = 'admin' and teacher_record.can_teach)) or teacher_record.status <> 'active'
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
    location_text, created_by, rescheduled_from, series_id, series_occurrence, series_exception)
  values (old_lesson.student_id, auth.uid(), target_package_id, start_at,
    lesson_duration, 'scheduled', takes_package_lesson, selected_format,
    clean_url, clean_location, auth.uid(), old_lesson.id,
    old_lesson.series_id, old_lesson.series_occurrence, old_lesson.series_id is not null) returning * into new_lesson;
  return pg_catalog.jsonb_build_object('old_id', old_lesson.id,
    'old_status', 'rescheduled', 'new_id', new_lesson.id,
    'new_status', new_lesson.status);
end;
$function$;

notify pgrst, 'reload schema';
