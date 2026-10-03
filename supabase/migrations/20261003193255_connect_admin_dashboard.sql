-- Only the database profile grants admin access. These RPCs intentionally
-- bypass row policies after checking private.is_admin(); no table grants change.
create function public.admin_dashboard_metrics()
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
      where p.role = 'teacher' and p.status = 'active'),
    (select count(*) from public.lessons l
      where l.scheduled_at >= (local_day::timestamp at time zone 'Europe/Kyiv')
        and l.scheduled_at < ((local_day + 1)::timestamp at time zone 'Europe/Kyiv')),
    (select count(*) from public.lesson_packages p where p.status = 'active');
end;
$$;

create function public.admin_list_users()
returns table (
  id uuid,
  full_name text,
  email text,
  phone text,
  role text,
  status text,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select private.is_admin()) is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  return query
  select p.id, p.full_name, u.email::text, p.phone, p.role, p.status, p.created_at
  from public.profiles p
  join auth.users u on u.id = p.id
  order by p.created_at desc, p.id;
end;
$$;

create function public.admin_update_user_access(
  target_user_id uuid,
  new_role text,
  new_status text
)
returns table (
  id uuid,
  full_name text,
  email text,
  phone text,
  role text,
  status text,
  created_at timestamptz
)
language plpgsql security definer set search_path = '' as $$
declare
  existing_id uuid;
  previous_role text;
begin
  if (select private.is_admin()) is distinct from true then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if target_user_id is null or target_user_id = (select auth.uid()) then
    raise exception 'Cannot change own access' using errcode = '42501';
  end if;
  if new_role is not null and new_role not in ('student', 'teacher', 'admin') then
    raise exception 'Invalid role' using errcode = '22023';
  end if;
  if new_status is null or new_status not in ('pending', 'active', 'suspended') then
    raise exception 'Invalid status' using errcode = '22023';
  end if;
  if new_status = 'active' and new_role is null then
    raise exception 'An active account needs a role' using errcode = '22023';
  end if;

  select p.id, p.role into existing_id, previous_role
  from public.profiles p
  where p.id = target_user_id
  for update;
  if existing_id is null then
    raise exception 'Profile not found' using errcode = 'P0002';
  end if;
  -- Existing assignments and records must keep their teacher/student meaning.
  if previous_role is distinct from new_role then
    if previous_role = 'teacher' and (
      exists (select 1 from public.teacher_students ts where ts.teacher_id = target_user_id)
      or exists (select 1 from public.lessons l where l.teacher_id = target_user_id)
      or exists (select 1 from public.conversations c where c.teacher_id = target_user_id)
    ) then
      raise exception 'Teacher has linked records' using errcode = '23514';
    end if;
    if previous_role = 'student' and (
      exists (select 1 from public.teacher_students ts where ts.student_id = target_user_id)
      or exists (select 1 from public.lesson_packages p where p.student_id = target_user_id)
      or exists (select 1 from public.lessons l where l.student_id = target_user_id)
      or exists (select 1 from public.conversations c where c.student_id = target_user_id)
    ) then
      raise exception 'Student has linked records' using errcode = '23514';
    end if;
  end if;

  update public.profiles p
  set role = new_role, status = new_status
  where p.id = target_user_id;

  return query
  select p.id, p.full_name, u.email::text, p.phone, p.role, p.status, p.created_at
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.id = target_user_id;
end;
$$;

revoke all on function public.admin_dashboard_metrics() from public, anon, authenticated, service_role;
revoke all on function public.admin_list_users() from public, anon, authenticated, service_role;
revoke all on function public.admin_update_user_access(uuid, text, text) from public, anon, authenticated, service_role;

grant execute on function public.admin_dashboard_metrics() to authenticated;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_update_user_access(uuid, text, text) to authenticated;
