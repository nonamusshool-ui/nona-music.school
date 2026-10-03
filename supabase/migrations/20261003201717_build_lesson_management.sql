-- Phase 2 writes stay behind narrow, profile-authorized RPCs. Existing table
-- grants, RLS policies, triggers, and package_balances remain unchanged.
create function public.admin_assign_teacher(target_student_id uuid, target_teacher_id uuid)
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
    or teacher_record.id is null or teacher_record.role <> 'teacher' or teacher_record.status <> 'active' then
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

-- Historic lesson teacher names remain visible to their student after a teacher
-- reassignment, without broadening the profiles RLS policy.
create function public.student_lesson_teacher_names()
returns table (teacher_id uuid, full_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if private.current_role() is distinct from 'student' then
    raise exception 'Active student required' using errcode = '42501';
  end if;
  return query
    select distinct p.id, p.full_name from public.profiles p
    join public.lessons l on l.teacher_id = p.id
    where l.student_id = auth.uid();
end;
$$;

create function public.admin_create_lesson_package(
  target_student_id uuid, lessons_count integer, starts_on date default null, ends_on date default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  student_record public.profiles%rowtype;
  created_package public.lesson_packages%rowtype;
begin
  if private.is_admin() is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
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
  return pg_catalog.jsonb_build_object(
    'package_id', created_package.id,
    'student_id', created_package.student_id,
    'lessons_purchased', created_package.lessons_purchased,
    'status', created_package.status,
    'valid_from', created_package.valid_from,
    'valid_until', created_package.valid_until
  );
end;
$$;

create function public.admin_schedule_lesson(
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
        and l.status in ('scheduled', 'completed');
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
      status, consumes_lesson, meet_url, created_by)
  values (target_package_id, target_student_id, target_teacher_id, lesson_start,
    lesson_duration, 'scheduled', takes_package_lesson, clean_url, auth.uid())
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

create function public.teacher_complete_lesson(target_lesson_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  lesson_record public.lessons%rowtype;
  selected_package public.lesson_packages%rowtype;
  used_count integer;
begin
  if private.current_role() is distinct from 'teacher' then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  select * into lesson_record from public.lessons where id = target_lesson_id for update;
  if lesson_record.id is null or lesson_record.teacher_id <> auth.uid() then
    raise exception 'Lesson not found for this teacher' using errcode = '42501';
  end if;
  if lesson_record.status = 'completed' then
    return pg_catalog.jsonb_build_object('id', lesson_record.id, 'status', lesson_record.status,
      'completed_at', lesson_record.completed_at);
  end if;
  if lesson_record.status <> 'scheduled'
    or lesson_record.scheduled_at + lesson_record.duration_minutes * interval '1 minute' > now() then
    raise exception 'Only a finished scheduled lesson can be completed' using errcode = '22023';
  end if;
  if lesson_record.consumes_lesson and lesson_record.package_id is not null then
    select * into selected_package from public.lesson_packages
    where id = lesson_record.package_id for update;
    select count(*) into used_count from public.lessons l
    where l.package_id = lesson_record.package_id and l.status = 'completed' and l.consumes_lesson;
    if used_count >= selected_package.lessons_purchased then
      raise exception 'Package has no remaining lessons' using errcode = '22023';
    end if;
  end if;
  update public.lessons set status = 'completed', completed_at = now()
  where id = lesson_record.id returning * into lesson_record;
  return pg_catalog.jsonb_build_object('id', lesson_record.id, 'status', lesson_record.status,
    'completed_at', lesson_record.completed_at);
end;
$$;

revoke all on function public.admin_assign_teacher(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.admin_create_lesson_package(uuid, integer, date, date) from public, anon, authenticated, service_role;
revoke all on function public.admin_schedule_lesson(uuid, uuid, date, time without time zone, integer, uuid, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.teacher_complete_lesson(uuid) from public, anon, authenticated, service_role;
revoke all on function public.student_lesson_teacher_names() from public, anon, authenticated, service_role;
grant execute on function public.admin_assign_teacher(uuid, uuid) to authenticated;
grant execute on function public.admin_create_lesson_package(uuid, integer, date, date) to authenticated;
grant execute on function public.admin_schedule_lesson(uuid, uuid, date, time without time zone, integer, uuid, text, boolean) to authenticated;
grant execute on function public.teacher_complete_lesson(uuid) to authenticated;
grant execute on function public.student_lesson_teacher_names() to authenticated;
