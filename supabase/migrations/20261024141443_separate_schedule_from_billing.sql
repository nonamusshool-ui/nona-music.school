-- Scheduling is independent of package coverage. Preserve all existing history.
set local lock_timeout = '5s';
alter table public.lessons add column billing_status text;
-- Adding classification must not rewrite historical updated_at timestamps.
alter table public.lessons disable trigger lessons_updated_at;
update public.lessons set billing_status = case when package_id is null then 'free' else 'covered' end;
alter table public.lessons enable trigger lessons_updated_at;
alter table public.lessons alter column billing_status set not null;
alter table public.lessons add constraint lessons_billing_status_check check (
  (billing_status = 'covered' and package_id is not null)
  or (billing_status in ('pending', 'free') and package_id is null)
);
comment on column public.lessons.billing_status is
  'Concrete billing truth: covered by a package, pending payment, or intentionally free. Legacy flags/history are preserved.';
-- A series stores billing preferences only; occurrences can have mixed coverage.
alter table public.lesson_series drop constraint lesson_series_check2;
comment on column public.lesson_series.package_id is 'Preferred package; concrete lessons determine actual coverage.';
grant select (billing_status) on public.lessons to authenticated;
create index lessons_pending_billing_idx on public.lessons(student_id, scheduled_at, id)
  where billing_status = 'pending' and status in ('scheduled', 'in_progress', 'completed');

-- One transaction-level ordering gate precedes ALL lesson/package row locks,
-- including supported direct package activation. Row locks below protect capacity.
-- Conservative serialization is deliberate for this small school; no SKIP LOCKED
-- allocation can skip the oldest debt or deadlock with completion/rescheduling.
create function private.lock_lesson_billing() returns void
language sql set search_path = '' as $$
  select pg_catalog.pg_advisory_xact_lock(20261024, 1);
$$;
create function private.lesson_billing_write_gate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lock_lesson_billing();
  return null;
end;
$$;
create trigger lessons_billing_write_gate before insert or update or delete on public.lessons
  for each statement execute function private.lesson_billing_write_gate();
create trigger lesson_packages_billing_write_gate before insert or update or delete on public.lesson_packages
  for each statement execute function private.lesson_billing_write_gate();

create function private.validate_lesson_billing() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  needs_capacity boolean;
  capacity integer;
begin
  -- Compatibility for existing SQL imports: no package never silently means debt.
  if new.billing_status is null then
    new.billing_status := case when new.package_id is null then 'free' else 'covered' end;
  end if;
  if new.billing_status in ('pending', 'free') then
    new.consumes_lesson := false;
  end if;
  if new.billing_status = 'covered' and new.consumes_lesson
    and (new.status in ('scheduled','in_progress','completed')
      or (new.status='cancelled' and new.resolved_at is not null)) then
    needs_capacity := tg_op='INSERT';
    if tg_op='UPDATE' then
      needs_capacity := old.package_id is distinct from new.package_id
        or not old.consumes_lesson or old.billing_status <> 'covered'
        or not (old.status in ('scheduled','in_progress','completed')
          or (old.status='cancelled' and old.resolved_at is not null));
    end if;
    if needs_capacity then
      select p.lessons_purchased into capacity from public.lesson_packages p
        where p.id=new.package_id and p.student_id=new.student_id for update;
      if capacity is null then
        raise exception 'Student package required' using errcode='22023';
      end if;
      if private.package_committed_slots(new.package_id, new.id) >= capacity then
        raise exception 'Package coverage capacity exceeded' using errcode='22023';
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger lessons_validate_billing before insert or update on public.lessons
  for each row execute function private.validate_lesson_billing();

create function private.allocate_pending_lessons(target_student_id uuid, preferred_package uuid default null)
returns integer language plpgsql set search_path = '' as $$
declare
  pending public.lessons%rowtype;
  chosen uuid;
  allocated integer := 0;
begin
  perform private.lock_lesson_billing();
  perform 1 from public.lesson_packages p where p.student_id=target_student_id order by p.id for update;
  for pending in select l.* from public.lessons l
    where l.student_id=target_student_id and l.billing_status='pending'
      and l.status in ('scheduled','in_progress','completed')
    order by l.scheduled_at,l.id for update of l
  loop
    select p.id into chosen from public.lesson_packages p
      where p.student_id=target_student_id and p.status='active'
        and (p.valid_from is null or (pending.scheduled_at at time zone 'Europe/Kyiv')::date>=p.valid_from)
        and (p.valid_until is null or (pending.scheduled_at at time zone 'Europe/Kyiv')::date<=p.valid_until)
        and private.package_committed_slots(p.id) < p.lessons_purchased
      order by (p.id=preferred_package) desc nulls last, p.valid_until nulls last, p.created_at,p.id limit 1;
    if chosen is not null then
      update public.lessons set billing_status='covered', package_id=chosen, consumes_lesson=true
        where id=pending.id;
      allocated := allocated+1;
    end if;
  end loop;
  return allocated;
end;
$$;
create function private.allocate_lesson_billing_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Allocation updates are already validated and must not recursively allocate.
  if new.billing_status='covered' and new.consumes_lesson
    and (new.status in ('scheduled','in_progress','completed')
      or (new.status='cancelled' and new.resolved_at is not null)) then return null; end if;
  perform private.allocate_pending_lessons(new.student_id);
  return null;
end;
$$;
create function private.allocate_package_billing_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.allocate_pending_lessons(new.student_id);
  return null;
end;
$$;
-- Deferred fallback runs after a whole reschedule, never between old/replacement
-- rows. RPCs also allocate before returning so clients receive committed truth.
create constraint trigger lessons_allocate_billing after insert or update on public.lessons
  deferrable initially deferred for each row execute function private.allocate_lesson_billing_after_write();
create constraint trigger lesson_packages_allocate_billing after insert or update on public.lesson_packages
  deferrable initially deferred for each row execute function private.allocate_package_billing_after_write();
revoke all on function private.lock_lesson_billing(), private.lesson_billing_write_gate(),
  private.validate_lesson_billing(), private.allocate_pending_lessons(uuid,uuid),
  private.allocate_lesson_billing_after_write(), private.allocate_package_billing_after_write()
  from public,anon,authenticated,service_role;

-- Existing authorization, RLS helpers and RPC ACLs are preserved by CREATE OR REPLACE.
CREATE OR REPLACE FUNCTION private.assert_series_actor(target_student_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  perform private.lock_lesson_billing();
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
$function$;

CREATE OR REPLACE FUNCTION private.package_lessons_used(package_uuid uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select count(l.id)::integer from public.lesson_packages p
  join public.lessons l on l.package_id = p.id
  where p.id = package_uuid and l.billing_status = 'covered' and l.consumes_lesson
    and (l.status = 'completed' or (l.status = 'cancelled' and l.resolved_at is not null))
    and ((p.student_id = (select auth.uid()) and private.current_role() = 'student')
      or private.is_teacher_of(p.student_id) or private.is_admin());
$function$;

CREATE OR REPLACE FUNCTION private.package_committed_slots(package_uuid uuid, except_lesson_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select count(*)::integer from public.lessons l
  where l.package_id = package_uuid and l.id is distinct from except_lesson_id
    and l.billing_status = 'covered' and l.consumes_lesson and (
      l.status in ('scheduled', 'in_progress', 'completed')
      or (l.status = 'cancelled' and l.resolved_at is not null));
$function$;

create or replace function private.assert_lesson_package(target_student_id uuid,target_package_id uuid,lesson_date date,takes_package_lesson boolean,except_lesson_id uuid default null)
returns void language plpgsql set search_path='' as $$
begin
 if takes_package_lesson is null then raise exception 'Billing intent required' using errcode='22023'; end if;
 if target_package_id is not null and not exists(select 1 from public.lesson_packages where id=target_package_id and student_id=target_student_id) then
   raise exception 'Student package required' using errcode='22023';
 end if;
end; $$;
create or replace function private.assert_series_package(target_student_id uuid,target_package_id uuid,lesson_dates date[],takes_package_lesson boolean,replaced_ids uuid[])
returns void language plpgsql set search_path='' as $$
begin
 perform private.assert_lesson_package(target_student_id,target_package_id,lesson_dates[1],takes_package_lesson);
end; $$;

CREATE OR REPLACE FUNCTION public.teacher_schedule_lesson(target_student_id uuid, lesson_date date, lesson_time time without time zone, lesson_duration integer, selected_format text, selected_url text, selected_location text, target_package_id uuid, takes_package_lesson boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  created_lesson public.lessons%rowtype;
  start_at timestamptz;
  clean_url text := nullif(pg_catalog.btrim(selected_url), '');
  clean_location text := nullif(pg_catalog.btrim(selected_location), '');
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  perform private.lock_lesson_billing();
  if lesson_duration is null or lesson_duration not between 15 and 180 then
    raise exception 'Invalid duration' using errcode = '22023';
  end if;
  start_at := private.lesson_start_kyiv(lesson_date, lesson_time);
  perform private.assert_lesson_destination(selected_format, clean_url, clean_location);
  select * into student_record from public.profiles where id = target_student_id for update;
  select * into teacher_record from public.profiles where id = auth.uid() for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or not (teacher_record.role = 'teacher' or (teacher_record.role = 'admin' and teacher_record.can_teach)) or teacher_record.status <> 'active'
    or not exists (select 1 from public.teacher_students ts
      where ts.student_id = target_student_id and ts.teacher_id = auth.uid() and ts.active) then
    raise exception 'Active assigned student required' using errcode = '42501';
  end if;
  perform private.assert_lesson_package(target_student_id, target_package_id,
    lesson_date, takes_package_lesson);
  perform private.assert_lesson_slot(target_student_id, auth.uid(), start_at, lesson_duration);
  insert into public.lessons (billing_status, student_id, teacher_id, package_id, scheduled_at,
    duration_minutes, status, consumes_lesson, lesson_format, lesson_url,
    location_text, created_by)
  values (case when takes_package_lesson then 'pending' else 'free' end, target_student_id, auth.uid(), null, start_at,
    lesson_duration, 'scheduled', false, selected_format,
    clean_url, clean_location, auth.uid()) returning * into created_lesson;
  perform private.allocate_pending_lessons(target_student_id, target_package_id);
  select * into created_lesson from public.lessons where id=created_lesson.id;
  return pg_catalog.jsonb_build_object('id', created_lesson.id, 'billing_status', created_lesson.billing_status,
    'scheduled_at', created_lesson.scheduled_at, 'status', created_lesson.status);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_schedule_lesson(target_student_id uuid, target_teacher_id uuid, lesson_date date, lesson_time time without time zone, lesson_duration integer DEFAULT 60, target_package_id uuid DEFAULT NULL::uuid, meeting_url text DEFAULT NULL::text, takes_package_lesson boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.lock_lesson_billing();
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
    or teacher_record.id is null or not (teacher_record.role = 'teacher' or (teacher_record.role = 'admin' and teacher_record.can_teach)) or teacher_record.status <> 'active'
    or not exists (select 1 from public.teacher_students ts
      where ts.student_id = target_student_id and ts.teacher_id = target_teacher_id and ts.active) then
    raise exception 'Active assigned student and teacher required' using errcode = '42501';
  end if;
  perform private.assert_lesson_package(target_student_id, target_package_id,
    lesson_date, takes_package_lesson);
  perform private.assert_lesson_slot(target_student_id, target_teacher_id, lesson_start, lesson_duration);
  insert into public.lessons (billing_status, package_id, student_id, teacher_id, scheduled_at,
    duration_minutes, status, consumes_lesson, meet_url, lesson_format, lesson_url, created_by)
  values (case when takes_package_lesson then 'pending' else 'free' end, null, target_student_id, target_teacher_id, lesson_start,
    lesson_duration, 'scheduled', false, clean_url,
    case when clean_url is null then null else 'online' end, clean_url, auth.uid())
  returning * into created_lesson;
  perform private.allocate_pending_lessons(target_student_id, target_package_id);
  select * into created_lesson from public.lessons where id=created_lesson.id;
  return pg_catalog.jsonb_build_object('id', created_lesson.id, 'billing_status', created_lesson.billing_status,
    'student_id', created_lesson.student_id, 'teacher_id', created_lesson.teacher_id,
    'package_id', created_lesson.package_id, 'scheduled_at', created_lesson.scheduled_at,
    'duration_minutes', created_lesson.duration_minutes, 'status', created_lesson.status,
    'consumes_lesson', created_lesson.consumes_lesson, 'meet_url', created_lesson.meet_url);
end;
$function$;

CREATE OR REPLACE FUNCTION public.teacher_schedule_lesson_series(target_student_id uuid, lesson_date date, lesson_time time without time zone, lesson_duration integer, selected_format text, selected_url text, selected_location text, target_package_id uuid, takes_package_lesson boolean, occurrence_count integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  return (select jsonb_build_object('covered',count(*) filter(where billing_status='covered'),
    'pending',count(*) filter(where billing_status='pending'),'free',count(*) filter(where billing_status='free'))
    from public.lessons where series_id=series_uuid and status<>'rescheduled') || jsonb_build_object('series_id', series_uuid, 'count', occurrence_count,
    'first_scheduled_at', starts_at[1]);
end;
$function$;

CREATE OR REPLACE FUNCTION public.teacher_update_lesson_series_from(target_lesson_id uuid, lesson_date date, lesson_time time without time zone, lesson_duration integer, selected_format text, selected_url text, selected_location text, target_package_id uuid, takes_package_lesson boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.lock_lesson_billing();
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
    and takes_package_lesson is not distinct from (anchor.billing_status='pending' or anchor.consumes_lesson) then
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
    insert into public.lessons (billing_status, student_id, teacher_id, package_id, scheduled_at, duration_minutes,
      status, consumes_lesson, lesson_format, lesson_url, location_text, created_by,
      rescheduled_from, series_id, series_occurrence, series_exception)
    values (case when takes_package_lesson then 'pending' else 'free' end, anchor.student_id, auth.uid(), null, starts_at[i], lesson_duration,
      'scheduled', false, selected_format, clean_url, clean_location, auth.uid(),
      old_lesson.id, series_record.id, old_lesson.series_occurrence, false);
  end loop;
  update public.lesson_series set start_date = lesson_date - (anchor.series_occurrence - 1) * 7,
    weekday = extract(isodow from lesson_date), local_time = lesson_time,
    duration_minutes = lesson_duration, lesson_format = selected_format, lesson_url = clean_url,
    location_text = clean_location, package_id = target_package_id, consumes_lesson = takes_package_lesson
    where id = series_record.id;
  perform private.allocate_pending_lessons(anchor.student_id, target_package_id);
  return jsonb_build_object('series_id', series_record.id, 'count', cardinality(replaced_ids),
    'first_scheduled_at', starts_at[1]);
end;
$function$;

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
  perform private.lock_lesson_billing();
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
    and takes_package_lesson is not distinct from (old_lesson.billing_status='pending' or old_lesson.consumes_lesson) then
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
  insert into public.lessons (billing_status, student_id, teacher_id, package_id, scheduled_at,
    duration_minutes, status, consumes_lesson, lesson_format, lesson_url,
    location_text, created_by, rescheduled_from, series_id, series_occurrence, series_exception)
  values (case when takes_package_lesson then 'pending' else 'free' end, old_lesson.student_id, auth.uid(), null, start_at,
    lesson_duration, 'scheduled', false, selected_format,
    clean_url, clean_location, auth.uid(), old_lesson.id,
    old_lesson.series_id, old_lesson.series_occurrence, old_lesson.series_id is not null) returning * into new_lesson;
  perform private.allocate_pending_lessons(old_lesson.student_id, target_package_id);
  return pg_catalog.jsonb_build_object('old_id', old_lesson.id,
    'old_status', 'rescheduled', 'new_id', new_lesson.id,
    'new_status', new_lesson.status);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_create_lesson_package(target_student_id uuid, lessons_count integer, starts_on date DEFAULT NULL::date, ends_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  student_record public.profiles%rowtype;
  created_package public.lesson_packages%rowtype;
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  perform private.lock_lesson_billing();
  if lessons_count is null or lessons_count <= 0
    or (starts_on is not null and ends_on is not null and ends_on < starts_on) then
    raise exception 'Invalid package size or dates' using errcode = '22023';
  end if;
  select * into student_record from public.profiles where id = target_student_id for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active' then
    raise exception 'Active student required' using errcode = '22023';
  end if;
  insert into public.lesson_packages
    (student_id, lessons_purchased, status, valid_from, valid_until, created_by)
  values (target_student_id, lessons_count, 'active', starts_on, ends_on, auth.uid())
  returning * into created_package;
  perform private.allocate_pending_lessons(target_student_id, created_package.id);
  return pg_catalog.jsonb_build_object(
    'package_id', created_package.id,
    'student_id', created_package.student_id,
    'lessons_purchased', created_package.lessons_purchased,
    'status', created_package.status,
    'valid_from', created_package.valid_from,
    'valid_until', created_package.valid_until
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.teacher_resolve_lesson(target_lesson_id uuid, outcome text, reason text DEFAULT NULL::text, note text DEFAULT NULL::text, charge_package boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  lesson_record public.lessons%rowtype;
  selected_package public.lesson_packages%rowtype;
  clean_note text := nullif(pg_catalog.btrim(note), '');
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  perform private.lock_lesson_billing();
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
  perform private.allocate_pending_lessons(lesson_record.student_id);
  return pg_catalog.jsonb_build_object('id', lesson_record.id,
    'status', lesson_record.status, 'consumes_lesson', lesson_record.consumes_lesson,
    'completion_source', lesson_record.completion_source);
end;
$function$;

CREATE OR REPLACE FUNCTION public.teacher_start_lesson(target_lesson_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  lesson_record public.lessons%rowtype;
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  perform private.lock_lesson_billing();
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
$function$;

CREATE OR REPLACE FUNCTION private.finalize_due_lessons(batch_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  due_lesson record;
  finalized_count integer := 0;
begin
  if batch_limit is null or batch_limit not between 1 and 1000 then
    raise exception 'Invalid batch limit' using errcode = '22023';
  end if;
  perform private.lock_lesson_billing();
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
      consumes_lesson = billing_status='covered' and consumes_lesson and package_id is not null
    where id = due_lesson.id and status in ('scheduled', 'in_progress');
    if found then finalized_count := finalized_count + 1; end if;
  end loop;
  return finalized_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_lesson_journal(month_start date, teacher_filter uuid DEFAULT NULL::uuid, student_filter uuid DEFAULT NULL::uuid, status_filter text DEFAULT NULL::text, name_query text DEFAULT NULL::text, page_size integer DEFAULT 100, page_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  result jsonb;
  from_utc timestamptz;
  until_utc timestamptz;
  clean_query text := nullif(pg_catalog.btrim(name_query), '');
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if month_start is null or extract(day from month_start) <> 1
    or page_size is null or page_size not between 1 and 200
    or page_offset is null or page_offset < 0
    or (status_filter is not null and status_filter not in
      ('scheduled', 'in_progress', 'completed', 'cancelled', 'rescheduled'))
    or pg_catalog.char_length(coalesce(clean_query, '')) > 100 then
    raise exception 'Invalid journal parameters' using errcode = '22023';
  end if;

  from_utc := month_start::timestamp at time zone 'Europe/Kyiv';
  until_utc := (month_start + interval '1 month')::timestamp at time zone 'Europe/Kyiv';

  with month_rows as materialized (
    select l.id as lesson_id, l.student_id, coalesce(s.full_name, 'Ім’я не вказано') as student_name,
      l.teacher_id, coalesce(t.full_name, 'Ім’я не вказано') as teacher_name,
      l.scheduled_at, l.duration_minutes, l.status, l.billing_status, l.consumes_lesson,
      l.package_id, p.lessons_purchased, p.status as package_status,
      l.lesson_format, l.location_text, l.lesson_url, l.meet_url,
      l.outcome_reason, l.outcome_note, l.started_at, l.completed_at,
      l.resolved_at, l.completion_source,
      (l.package_id is not null and l.consumes_lesson and
        (l.status = 'completed' or (l.status = 'cancelled' and l.resolved_at is not null))) as charged
    from public.lessons l
    join public.profiles s on s.id = l.student_id
    join public.profiles t on t.id = l.teacher_id
    left join public.lesson_packages p on p.id = l.package_id
    where l.scheduled_at >= from_utc and l.scheduled_at < until_utc
  ), filtered as materialized (
    select * from month_rows r
    where (teacher_filter is null or r.teacher_id = teacher_filter)
      and (student_filter is null or r.student_id = student_filter)
      and (status_filter is null or r.status = status_filter
        or (status_filter = 'cancelled' and r.status = 'no_show'))
      and (clean_query is null or r.student_name ilike '%' || clean_query || '%'
        or r.teacher_name ilike '%' || clean_query || '%')
  ), page as (
    select * from filtered order by scheduled_at desc, lesson_id desc
    limit page_size offset page_offset
  )
  select jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(to_jsonb(page) order by scheduled_at desc, lesson_id desc), '[]'::jsonb) from page),
    'total', (select count(*) from filtered),
    'summary', (select jsonb_build_object(
      'total', count(*),
      'completed', count(*) filter (where status = 'completed'),
      'cancelled', count(*) filter (where status in ('cancelled', 'no_show')),
      'rescheduled', count(*) filter (where status = 'rescheduled'),
      'scheduled', count(*) filter (where status = 'scheduled'),
      'in_progress', count(*) filter (where status = 'in_progress'),
      'charged', count(*) filter (where charged)
    ) from filtered),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('id', teacher_id, 'name', teacher_name) order by teacher_name), '[]'::jsonb)
      from (select distinct teacher_id, teacher_name from month_rows) teacher_names),
    'students', (select coalesce(jsonb_agg(jsonb_build_object('id', student_id, 'name', student_name) order by student_name), '[]'::jsonb)
      from (select distinct student_id, student_name from month_rows) student_names)
  ) into result;
  return result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_lesson_statement(period_type text, period_start date, teacher_filter uuid DEFAULT NULL::uuid, student_filter uuid DEFAULT NULL::uuid, name_query text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  start_at timestamptz;
  end_at timestamptz;
  clean_query text := nullif(btrim(name_query), '');
  result jsonb;
begin
  if private.is_admin() is distinct from true then
    raise exception 'Active admin access required' using errcode = '42501';
  end if;
  if period_type is null or period_type not in ('month', 'year')
    or period_start is null or not isfinite(period_start)
    or extract(day from period_start) <> 1
    or (period_type = 'year' and extract(month from period_start) <> 1)
    or char_length(clean_query) > 100 then
    raise exception 'Invalid statement period or filters' using errcode = '22023';
  end if;
  start_at := period_start::timestamp at time zone 'Europe/Kyiv';
  end_at := (period_start + case when period_type = 'year' then interval '1 year'
    else interval '1 month' end)::timestamp at time zone 'Europe/Kyiv';

  with period_rows as materialized (
    select l.id as lesson_id, l.student_id, l.teacher_id,
      coalesce(nullif(s.full_name, ''), 'Ім’я не вказано') as student_name,
      coalesce(nullif(t.full_name, ''), 'Ім’я не вказано') as teacher_name,
      l.scheduled_at, l.duration_minutes, l.status, l.billing_status, l.package_id,
      p.lessons_purchased, l.series_id, l.series_occurrence, l.series_exception,
      extract(day from l.scheduled_at at time zone 'Europe/Kyiv')::integer as day_number,
      extract(month from l.scheduled_at at time zone 'Europe/Kyiv')::integer as month_number,
      -- Match private.package_lessons_used; reservations are not charges.
      (l.package_id is not null and l.consumes_lesson and
        (l.status = 'completed' or (l.status = 'cancelled' and l.resolved_at is not null))) as charged
    from public.lessons l
    join public.profiles s on s.id = l.student_id
    join public.profiles t on t.id = l.teacher_id
    left join public.lesson_packages p on p.id = l.package_id
    where l.scheduled_at >= start_at and l.scheduled_at < end_at
  ), filtered as materialized (
    select * from period_rows r
    where (teacher_filter is null or r.teacher_id = teacher_filter)
      and (student_filter is null or r.student_id = student_filter)
      and (clean_query is null or r.student_name ilike '%' || clean_query || '%'
        or r.teacher_name ilike '%' || clean_query || '%')
  ), student_totals as (
    select student_id, student_name,
      count(*) filter (where status = 'completed') as completed,
      count(*) filter (where status in ('cancelled', 'no_show')) as cancelled,
      count(*) filter (where status = 'rescheduled') as rescheduled,
      count(*) filter (where status = 'scheduled') as scheduled,
      count(*) filter (where status = 'in_progress') as in_progress,
      count(*) filter (where charged) as charged
    from filtered group by student_id, student_name
  ), balances as (
    select b.student_id, sum(b.lessons_remaining) as remaining_now
    from public.package_balances b
    where b.status = 'active' and b.student_id in (select student_id from student_totals)
    group by b.student_id
  ), student_teachers as (
    select student_id, jsonb_agg(jsonb_build_object('id', teacher_id, 'name', teacher_name)
      order by teacher_name, teacher_id) as teachers
    from (select distinct student_id, teacher_id, teacher_name from filtered) t
    group by student_id
  ), daily as (
    select student_id, day_number,
      jsonb_agg(jsonb_build_object(
        'lesson_id', lesson_id, 'student_id', student_id, 'student_name', student_name,
        'teacher_id', teacher_id, 'teacher_name', teacher_name,
        'scheduled_at', scheduled_at, 'duration_minutes', duration_minutes,
        'status', status, 'billing_status', billing_status, 'charged', charged, 'package_id', package_id,
        'lessons_purchased', lessons_purchased, 'series_id', series_id,
        'series_occurrence', series_occurrence, 'series_exception', series_exception
      ) order by scheduled_at, lesson_id) as lessons
    from filtered where period_type = 'month' group by student_id, day_number
  ), student_days as (
    select student_id, jsonb_object_agg(day_number::text, lessons) as days
    from daily group by student_id
  ), completed_months as (
    select student_id, month_number, count(*) as completed
    from filtered where period_type = 'year' and status = 'completed'
    group by student_id, month_number
  ), student_months as (
    select s.student_id, jsonb_object_agg(n::text, coalesce(m.completed, 0)) as months
    from student_totals s cross join generate_series(1, 12) n
    left join completed_months m on m.student_id = s.student_id and m.month_number = n
    where period_type = 'year' group by s.student_id
  )
  select jsonb_build_object(
    'period_type', period_type, 'period_start', period_start,
    'days_in_month', case when period_type = 'month' then
      extract(day from period_start + interval '1 month' - interval '1 day')::integer else 0 end,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'student_id', s.student_id, 'student_name', s.student_name, 'teachers', t.teachers,
      'days', coalesce(d.days, '{}'::jsonb), 'months', coalesce(m.months, '{}'::jsonb),
      'totals', jsonb_build_object('completed', s.completed, 'cancelled', s.cancelled,
        'rescheduled', s.rescheduled, 'scheduled', s.scheduled, 'in_progress', s.in_progress,
        'charged', s.charged, 'remaining_now', coalesce(b.remaining_now, 0))
      ) order by s.student_name, s.student_id)
      from student_totals s join student_teachers t using (student_id)
      left join balances b using (student_id) left join student_days d using (student_id)
      left join student_months m using (student_id)), '[]'::jsonb),
    'teachers', coalesce((select jsonb_agg(jsonb_build_object('id', teacher_id, 'name', teacher_name)
      order by teacher_name, teacher_id) from
      (select distinct teacher_id, teacher_name from period_rows) t), '[]'::jsonb),
    'students', coalesce((select jsonb_agg(jsonb_build_object('id', student_id, 'name', student_name)
      order by student_name, student_id) from
      (select distinct student_id, student_name from period_rows) s), '[]'::jsonb)
  ) into result;
  return result;
end;
$function$;
