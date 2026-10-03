-- NONA Music School cabinet schema. Apply once to the linked project.
-- Authorization comes from profiles.role + profiles.status, never user metadata.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  avatar_url text,
  role text check (role in ('student', 'teacher', 'admin')),
  status text not null default 'pending' check (status in ('pending', 'active', 'suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.teacher_students (
  teacher_id uuid not null references public.profiles(id),
  student_id uuid not null references public.profiles(id),
  active boolean not null default true,
  assigned_at timestamptz not null default now(),
  primary key (teacher_id, student_id),
  constraint teacher_students_distinct_people check (teacher_id <> student_id)
);

create table public.lesson_packages (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id),
  lessons_purchased integer not null check (lessons_purchased > 0),
  status text not null default 'active' check (status in ('active', 'used', 'expired', 'cancelled')),
  valid_from date,
  valid_until date,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lesson_packages_dates check (valid_until is null or valid_from is null or valid_until >= valid_from),
  constraint lesson_packages_id_student_unique unique (id, student_id)
);

create table public.lessons (
  id uuid primary key default gen_random_uuid(),
  package_id uuid,
  student_id uuid not null references public.profiles(id),
  teacher_id uuid not null references public.profiles(id),
  scheduled_at timestamptz not null,
  duration_minutes integer not null default 60 check (duration_minutes between 1 and 480),
  status text not null default 'scheduled' check (status in ('scheduled', 'completed', 'cancelled', 'no_show')),
  consumes_lesson boolean not null default true,
  meet_url text,
  homework text,
  completed_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lessons_distinct_people check (student_id <> teacher_id),
  constraint lessons_package_student_fk foreign key (package_id, student_id)
    references public.lesson_packages(id, student_id)
);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id),
  teacher_id uuid not null references public.profiles(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint conversations_distinct_people check (student_id <> teacher_id),
  constraint conversations_pair_unique unique (student_id, teacher_id)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id),
  sender_id uuid not null references public.profiles(id),
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  read_at timestamptz,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  type text not null check (char_length(btrim(type)) between 1 and 100),
  title text,
  body text,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

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

alter table public.profiles enable row level security;
alter table public.teacher_students enable row level security;
alter table public.lesson_packages enable row level security;
alter table public.lessons enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.notifications enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (
  id = (select auth.uid()) or (select private.is_admin())
  or private.is_teacher_of(id) or private.is_student_of(id)
);
create policy profiles_edit_self on public.profiles for update to authenticated
using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy teacher_students_read on public.teacher_students for select to authenticated using (
  (select private.is_admin())
  or (teacher_id = (select auth.uid()) and (select private.current_role()) = 'teacher')
  or (student_id = (select auth.uid()) and (select private.current_role()) = 'student')
);
create policy lesson_packages_read on public.lesson_packages for select to authenticated using (
  (select private.is_admin())
  or (student_id = (select auth.uid()) and (select private.current_role()) = 'student')
  or private.is_teacher_of(student_id)
);
create policy lessons_read on public.lessons for select to authenticated using (
  (select private.is_admin())
  or (student_id = (select auth.uid()) and (select private.current_role()) = 'student')
  or (teacher_id = (select auth.uid()) and (select private.current_role()) = 'teacher')
);
create policy conversations_read on public.conversations for select to authenticated using (
  (select private.is_admin()) or private.is_conversation_participant(id)
);
create policy messages_read on public.messages for select to authenticated using (
  private.is_conversation_participant(conversation_id)
);
create policy messages_send on public.messages for insert to authenticated with check (
  sender_id = (select auth.uid()) and private.is_conversation_participant(conversation_id)
  and exists (select 1 from public.conversations c
    where c.id = conversation_id and c.active)
);
create policy notifications_read on public.notifications for select to authenticated using (
  user_id = (select auth.uid())
);
create policy notifications_mark_read on public.notifications for update to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Column-level updates prevent self-assignment of role/status or reassignment
-- of a notification. Admin writes are reserved for a future trusted process.
revoke all on public.profiles, public.teacher_students, public.lesson_packages,
  public.lessons, public.conversations, public.messages, public.notifications,
  public.package_balances from public, anon, authenticated;
grant select on public.profiles, public.teacher_students, public.lesson_packages,
  public.lessons, public.conversations, public.messages, public.notifications,
  public.package_balances to authenticated;
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;
grant insert (conversation_id, sender_id, body) on public.messages to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- teacher_students primary key already indexes teacher_id as its first column.
create index teacher_students_student_idx on public.teacher_students (student_id);
create index lesson_packages_student_idx on public.lesson_packages (student_id);
create index lessons_student_scheduled_idx on public.lessons (student_id, scheduled_at);
create index lessons_teacher_scheduled_idx on public.lessons (teacher_id, scheduled_at);
create index lessons_package_idx on public.lessons (package_id);
-- conversations_pair_unique already indexes student_id as its first column.
create index conversations_teacher_idx on public.conversations (teacher_id);
create index messages_conversation_created_idx on public.messages (conversation_id, created_at);
create index messages_sender_idx on public.messages (sender_id);
create index notifications_user_created_idx on public.notifications (user_id, created_at);
create index notifications_unread_idx on public.notifications (user_id, created_at)
where read_at is null;

-- Supabase Postgres Changes publication; no duplicate entries on rerun.
do $$
declare table_name text;
begin
  if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    execute 'create publication supabase_realtime';
  end if;
  for table_name in select unnest(array['messages', 'notifications', 'lessons']) loop
    if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime' and puballtables)
      and not exists (select 1 from pg_catalog.pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = table_name) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    end if;
  end loop;
end;
$$;
