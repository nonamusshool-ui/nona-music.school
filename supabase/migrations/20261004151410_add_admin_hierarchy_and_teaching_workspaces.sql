-- Existing administrators remain standard. The first senior is appointed
-- through a separate trusted, one-time SQL action after deployment.
alter table public.profiles
  add column can_teach boolean not null default false,
  add column admin_level text;

update public.profiles set admin_level = 'standard' where role = 'admin';

alter table public.profiles add constraint profiles_admin_level_check
  check (admin_level is null or admin_level in ('standard', 'senior'));
alter table public.profiles add constraint profiles_capability_shape_check check (
  (role is null and not can_teach and admin_level is null)
  or (role in ('student', 'teacher') and not can_teach and admin_level is null)
  or (role = 'admin' and admin_level in ('standard', 'senior')
      and (admin_level = 'standard' or can_teach))
);

-- No user metadata, email, or browser-provided value grants a capability.
create function private.can_teach(user_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select user_uuid is not null and exists (
    select 1 from public.profiles p where p.id = user_uuid and p.status = 'active'
      and (p.role = 'teacher' or (p.role = 'admin' and p.can_teach))
  );
$$;
create function private.is_senior_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.profiles p where p.id = (select auth.uid())
      and p.role = 'admin' and p.status = 'active' and p.admin_level = 'senior'
  );
$$;
revoke all on function private.can_teach(uuid), private.is_senior_admin()
  from public, anon, authenticated, service_role;
grant execute on function private.can_teach(uuid) to authenticated;

create or replace function private.is_teacher_of(student_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and private.can_teach((select auth.uid()))
    and exists (select 1 from public.teacher_students ts
      where ts.teacher_id = (select auth.uid()) and ts.student_id = student_uuid and ts.active);
$$;

drop policy teacher_students_read on public.teacher_students;
create policy teacher_students_read on public.teacher_students for select to authenticated using (
  (select private.is_admin())
  or (teacher_id = (select auth.uid()) and private.can_teach((select auth.uid())))
  or (student_id = (select auth.uid()) and (select private.current_role()) = 'student')
);
drop policy lessons_read on public.lessons;
create policy lessons_read on public.lessons for select to authenticated using (
  (select private.is_admin())
  or (student_id = (select auth.uid()) and (select private.current_role()) = 'student')
  or (teacher_id = (select auth.uid()) and private.can_teach((select auth.uid())))
);

-- The legacy mutation endpoint must not bypass the new hierarchy.
revoke all on function public.admin_update_user_access(uuid, text, text)
  from public, anon, authenticated, service_role;

create function public.admin_list_users_v2()
returns table (id uuid, full_name text, email text, phone text, role text,
  status text, admin_level text, can_teach boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  return query select p.id, p.full_name, u.email::text, p.phone, p.role,
    p.status, p.admin_level, p.can_teach, p.created_at
  from public.profiles p join auth.users u on u.id = p.id
  order by p.created_at desc, p.id;
end;
$$;

create function public.admin_update_user_access_v2(
  target_user_id uuid, new_role text, new_status text,
  new_admin_level text default null, new_can_teach boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  target_record public.profiles%rowtype;
  senior_caller boolean;
  teacher_capability_after boolean;
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if target_user_id is null or target_user_id = (select auth.uid()) then
    raise exception 'Cannot change own access' using errcode = '42501';
  end if;
  if new_role is not null and new_role not in ('student', 'teacher', 'admin') then
    raise exception 'Invalid role' using errcode = '22023';
  end if;
  if new_status is null or new_status not in ('pending', 'active', 'suspended')
    or (new_status = 'active' and new_role is null) then
    raise exception 'Invalid status' using errcode = '22023';
  end if;
  if new_can_teach is null or (
    new_role = 'admin' and (new_admin_level not in ('standard', 'senior') or new_admin_level is null
      or (new_admin_level = 'senior' and not new_can_teach))
    ) or (new_role is distinct from 'admin' and (new_admin_level is not null or new_can_teach)) then
    raise exception 'Invalid admin capability' using errcode = '22023';
  end if;

  -- Serialize senior removal even when two different senior rows are edited.
  perform pg_catalog.pg_advisory_xact_lock(774419, 1);
  senior_caller := private.is_senior_admin();
  select * into target_record from public.profiles where id = target_user_id for update;
  if target_record.id is null then
    raise exception 'Profile not found' using errcode = 'P0002';
  end if;
  if (target_record.role = 'admin' or new_role = 'admin') and not senior_caller then
    raise exception 'Senior admin required' using errcode = '42501';
  end if;
  if target_record.role = 'admin' and target_record.admin_level = 'senior'
    and target_record.status = 'active'
    and (new_role is distinct from 'admin' or new_admin_level is distinct from 'senior'
      or new_status is distinct from 'active')
    and (select count(*) from public.profiles p where p.role = 'admin'
      and p.admin_level = 'senior' and p.status = 'active') <= 1 then
    raise exception 'Cannot disable the last senior admin' using errcode = 'P0001';
  end if;

  teacher_capability_after := coalesce(new_role = 'teacher'
    or (new_role = 'admin' and new_can_teach), false);
  if target_record.role is distinct from new_role then
    if target_record.role = 'student' and (
      exists (select 1 from public.teacher_students ts where ts.student_id = target_user_id)
      or exists (select 1 from public.lesson_packages p where p.student_id = target_user_id)
      or exists (select 1 from public.lessons l where l.student_id = target_user_id)
      or exists (select 1 from public.conversations c where c.student_id = target_user_id)
    ) then
      raise exception 'Student has linked records' using errcode = '23514';
    end if;
    if target_record.role = 'teacher' and not teacher_capability_after and (
      exists (select 1 from public.teacher_students ts where ts.teacher_id = target_user_id)
      or exists (select 1 from public.lessons l where l.teacher_id = target_user_id)
      or exists (select 1 from public.conversations c where c.teacher_id = target_user_id)
    ) then
      raise exception 'Teacher has linked records' using errcode = '23514';
    end if;
  end if;
  if not teacher_capability_after and (
    exists (select 1 from public.teacher_students ts where ts.teacher_id = target_user_id and ts.active)
    or exists (select 1 from public.lessons l where l.teacher_id = target_user_id
      and l.status in ('scheduled', 'in_progress'))
  ) then
    raise exception 'Reassign active students and lessons first' using errcode = '23514';
  end if;

  update public.profiles set role = new_role, status = new_status,
    admin_level = new_admin_level, can_teach = new_can_teach
  where id = target_user_id;
  return (select pg_catalog.jsonb_build_object(
    'id', p.id, 'full_name', p.full_name, 'email', u.email,
    'phone', p.phone, 'role', p.role, 'status', p.status,
    'admin_level', p.admin_level, 'can_teach', p.can_teach,
    'created_at', p.created_at)
    from public.profiles p join auth.users u on u.id = p.id where p.id = target_user_id);
end;
$$;
revoke all on function public.admin_list_users_v2(),
  public.admin_update_user_access_v2(uuid, text, text, text, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.admin_list_users_v2(),
  public.admin_update_user_access_v2(uuid, text, text, text, boolean)
  to authenticated;

-- Preserve all existing RPC signatures and behavior; extend only the teacher eligibility checks.
create or replace function private.validate_teacher_student_pair()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_table_name = 'teacher_students' then
    if not exists (
      select 1 from public.profiles t join public.profiles s on s.id = new.student_id
      where t.id = new.teacher_id and (t.role = 'teacher' or (t.role = 'admin' and t.can_teach)) and s.role = 'student'
        and (not new.active or (t.status = 'active' and s.status = 'active'))
    ) then
      raise exception 'Teacher and student must have matching roles and be active for active links' using errcode = '23514';
    end if;
  elsif new.admin_id is not null then
    if new.teacher_id is not null then
      raise exception 'Chat has too many participants' using errcode = '23514';
    end if;
    if new.active and not exists (
      select 1 from public.profiles s join public.profiles a on a.id = new.admin_id
      join private.chat_contact_config cfg on cfg.singleton and cfg.admin_id = a.id
      where s.id = new.student_id and s.role = 'student' and s.status = 'active'
        and a.role = 'admin' and a.status = 'active'
    ) then
      raise exception 'Active chat requires the configured admin and active student' using errcode = '23514';
    end if;
  elsif new.active then
    raise exception 'Teacher chat is retired' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.validate_lesson_relationship()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (
    select 1 from public.profiles t join public.profiles s on s.id = new.student_id
    where t.id = new.teacher_id and (t.role = 'teacher' or (t.role = 'admin' and t.can_teach)) and t.status = 'active'
      and s.role = 'student' and s.status = 'active'
  ) or not exists (
    select 1 from public.teacher_students ts
    where ts.teacher_id = new.teacher_id and ts.student_id = new.student_id and ts.active
  ) then
    raise exception 'Lesson requires an active teacher/student assignment' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function public.admin_assign_teacher(target_student_id uuid, target_teacher_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  assignment public.teacher_students%rowtype;
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  select * into student_record from public.profiles where id = target_student_id for update;
  select * into teacher_record from public.profiles where id = target_teacher_id for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or not (teacher_record.role = 'teacher' or (teacher_record.role = 'admin' and teacher_record.can_teach)) or teacher_record.status <> 'active' then
    raise exception 'Active student and teacher required' using errcode = '22023';
  end if;
  if exists (select 1 from public.lessons l
    where l.student_id = target_student_id and l.teacher_id <> target_teacher_id
      and l.status = 'scheduled' and l.scheduled_at >= now()) then
    raise exception 'Resolve future lessons with the previous teacher before reassigning'
      using errcode = '22023';
  end if;

  -- Preserve history; the student row lock serializes concurrent replacements.
  update public.teacher_students
  set active = false
  where student_id = target_student_id and teacher_id <> target_teacher_id and active;
  insert into public.teacher_students as ts (student_id, teacher_id)
  values (target_student_id, target_teacher_id)
  on conflict (teacher_id, student_id) do update
    set active = true, assigned_at = case when ts.active then ts.assigned_at else now() end
  returning * into assignment;
  return pg_catalog.jsonb_build_object(
    'student_id', assignment.student_id,
    'teacher_id', assignment.teacher_id,
    'teacher_name', teacher_record.full_name,
    'active', assignment.active,
    'assigned_at', assignment.assigned_at
  );
end;
$$;

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
    or teacher_record.id is null or not (teacher_record.role = 'teacher' or (teacher_record.role = 'admin' and teacher_record.can_teach)) or teacher_record.status <> 'active'
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

create or replace function public.teacher_schedule_lesson(
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
  if private.can_teach(auth.uid()) is distinct from true then
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
    or teacher_record.id is null or not (teacher_record.role = 'teacher' or (teacher_record.role = 'admin' and teacher_record.can_teach)) or teacher_record.status <> 'active'
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
  if private.can_teach(auth.uid()) is distinct from true then
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

create or replace function public.teacher_reschedule_lesson(
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
  old_url text;
  old_location text;
  old_format text;
begin
  if private.can_teach(auth.uid()) is distinct from true then
    raise exception 'Active teacher required' using errcode = '42501';
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
    location_text, created_by, rescheduled_from)
  values (old_lesson.student_id, auth.uid(), target_package_id, start_at,
    lesson_duration, 'scheduled', takes_package_lesson, selected_format,
    clean_url, clean_location, auth.uid(), old_lesson.id) returning * into new_lesson;
  return pg_catalog.jsonb_build_object('old_id', old_lesson.id,
    'old_status', 'rescheduled', 'new_id', new_lesson.id,
    'new_status', new_lesson.status);
end;
$$;

create or replace function public.teacher_start_lesson(target_lesson_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  lesson_record public.lessons%rowtype;
begin
  if private.can_teach(auth.uid()) is distinct from true then
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

create or replace function public.admin_dashboard_metrics()
returns table (
  students bigint,
  teachers bigint,
  lessons_today bigint,
  active_packages bigint
)
language plpgsql stable security definer set search_path = '' as $$
declare
  local_day date;
begin
  if (select private.is_admin()) is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  local_day := (now() at time zone 'Europe/Kyiv')::date;
  return query
  select
    (select count(*) from public.profiles p
      where p.role = 'student' and p.status = 'active'),
    (select count(*) from public.profiles p
      where (p.role = 'teacher' or (p.role = 'admin' and p.can_teach)) and p.status = 'active'),
    (select count(*) from public.lessons l
      where l.scheduled_at >= (local_day::timestamp at time zone 'Europe/Kyiv')
        and l.scheduled_at < ((local_day + 1)::timestamp at time zone 'Europe/Kyiv')),
    (select count(*) from public.lesson_packages p where p.status = 'active');
end;
$$;
