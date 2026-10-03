-- This trigger deliberately ignores raw_user_meta_data.role and status.
create function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (
    new.id,
    nullif(left(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', ''), 120), ''),
    nullif(left(coalesce(new.raw_user_meta_data ->> 'avatar_url', ''), 2048), '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;
create trigger nona_create_profile_after_signup
after insert on auth.users for each row execute function private.handle_new_user();

-- Existing Auth users, if any, also begin pending with no assigned role.
insert into public.profiles (id, full_name, avatar_url)
select id,
  nullif(left(coalesce(raw_user_meta_data ->> 'full_name', raw_user_meta_data ->> 'name', ''), 120), ''),
  nullif(left(coalesce(raw_user_meta_data ->> 'avatar_url', ''), 2048), '')
from auth.users
on conflict (id) do nothing;

create function private.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_updated_at before update on public.profiles
for each row execute function private.set_updated_at();
create trigger lesson_packages_updated_at before update on public.lesson_packages
for each row execute function private.set_updated_at();
create trigger lessons_updated_at before update on public.lessons
for each row execute function private.set_updated_at();
create trigger conversations_updated_at before update on public.conversations
for each row execute function private.set_updated_at();

-- Guard trusted writes too: foreign keys alone cannot validate profile roles.
create function private.validate_teacher_student_pair()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (
    select 1 from public.profiles t join public.profiles s on s.id = new.student_id
    where t.id = new.teacher_id and t.role = 'teacher'
      and s.role = 'student'
      and (not new.active or (t.status = 'active' and s.status = 'active'))
  ) then
    raise exception 'Teacher and student must have matching roles and be active for active links' using errcode = '23514';
  end if;
  if tg_table_name = 'conversations' and new.active and not exists (
    select 1 from public.teacher_students ts
    where ts.teacher_id = new.teacher_id and ts.student_id = new.student_id and ts.active
  ) then
    raise exception 'Conversation requires an active teacher assignment' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger teacher_students_valid_pair before insert or update of teacher_id, student_id, active
on public.teacher_students for each row execute function private.validate_teacher_student_pair();
create trigger conversations_valid_pair before insert or update of teacher_id, student_id, active
on public.conversations for each row execute function private.validate_teacher_student_pair();

create function private.validate_package_student()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.profiles p
    where p.id = new.student_id and p.role = 'student' and p.status = 'active') then
    raise exception 'Package requires an active student' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger lesson_packages_valid_student before insert or update of student_id
on public.lesson_packages for each row execute function private.validate_package_student();

create function private.validate_lesson_relationship()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (
    select 1 from public.profiles t join public.profiles s on s.id = new.student_id
    where t.id = new.teacher_id and t.role = 'teacher' and t.status = 'active'
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
create trigger lessons_valid_relationship before insert or update of student_id, teacher_id
on public.lessons for each row execute function private.validate_lesson_relationship();

create function private.validate_message_sender()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.conversations c
    where c.id = new.conversation_id
      and new.sender_id in (c.student_id, c.teacher_id)) then
    raise exception 'Message sender must belong to the conversation' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger messages_valid_sender before insert or update of conversation_id, sender_id
on public.messages for each row execute function private.validate_message_sender();

-- Private authorization lookups intentionally bypass recursive table policies.
-- Each definer helper checks the current authenticated user and uses an empty search path.
create function private.current_role()
returns text language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p
  where p.id = (select auth.uid()) and p.status = 'active';
$$;

create function private.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and private.current_role() = 'admin';
$$;

create function private.is_teacher_of(student_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and private.current_role() = 'teacher'
    and exists (select 1 from public.teacher_students ts
      where ts.teacher_id = (select auth.uid()) and ts.student_id = student_uuid and ts.active);
$$;

create function private.is_student_of(teacher_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and private.current_role() = 'student'
    and exists (select 1 from public.teacher_students ts
      where ts.student_id = (select auth.uid()) and ts.teacher_id = teacher_uuid and ts.active);
$$;

create function private.is_conversation_participant(conversation_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.conversations c where c.id = conversation_uuid
      and exists (select 1 from public.teacher_students ts
        where ts.teacher_id = c.teacher_id and ts.student_id = c.student_id and ts.active)
      and ((c.student_id = (select auth.uid()) and private.current_role() = 'student')
        or (c.teacher_id = (select auth.uid()) and private.current_role() = 'teacher'))
  );
$$;

-- The lesson RLS intentionally limits teachers to their own lessons. This
-- checked helper counts all completed lessons so their package balance is exact.
create function private.package_lessons_used(package_uuid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select count(l.id)::integer from public.lesson_packages p
  join public.lessons l on l.package_id = p.id
  where p.id = package_uuid and l.status = 'completed' and l.consumes_lesson
    and ((p.student_id = (select auth.uid()) and private.current_role() = 'student')
      or private.is_teacher_of(p.student_id) or private.is_admin());
$$;

revoke all on function private.set_updated_at() from public, anon, authenticated;
revoke all on function private.validate_teacher_student_pair() from public, anon, authenticated;
revoke all on function private.validate_package_student() from public, anon, authenticated;
revoke all on function private.validate_lesson_relationship() from public, anon, authenticated;
revoke all on function private.validate_message_sender() from public, anon, authenticated;
revoke all on function private.current_role() from public, anon, authenticated;
revoke all on function private.is_admin() from public, anon, authenticated;
revoke all on function private.is_teacher_of(uuid) from public, anon, authenticated;
revoke all on function private.is_student_of(uuid) from public, anon, authenticated;
revoke all on function private.is_conversation_participant(uuid) from public, anon, authenticated;
revoke all on function private.package_lessons_used(uuid) from public, anon, authenticated;
grant execute on function private.current_role(), private.is_admin(),
  private.is_teacher_of(uuid), private.is_student_of(uuid),
  private.is_conversation_participant(uuid), private.package_lessons_used(uuid)
to authenticated;

create view public.package_balances with (security_invoker = true) as
select p.id as package_id, p.student_id, p.lessons_purchased,
  used.lessons_used,
  greatest(p.lessons_purchased - used.lessons_used, 0) as lessons_remaining,
  p.status, p.valid_from, p.valid_until
from public.lesson_packages p
cross join lateral (select private.package_lessons_used(p.id) as lessons_used) used;
