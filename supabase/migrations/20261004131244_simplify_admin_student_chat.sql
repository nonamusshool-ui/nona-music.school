-- Keep historic student/teacher messages, but disable that product entirely.
-- New rows have exactly one student and one explicitly participating admin.
alter table public.conversations add column admin_id uuid references public.profiles(id);
alter table public.conversations alter column teacher_id drop not null;
alter table public.conversations add constraint conversations_one_staff_participant
  check ((teacher_id is null) <> (admin_id is null));
alter table public.conversations add constraint conversations_admin_distinct
  check (admin_id is null or student_id <> admin_id);
create unique index conversations_student_admin_unique
  on public.conversations (student_id, admin_id) where admin_id is not null;

-- One school contact is configured explicitly. Seed only when production has
-- exactly one active admin; otherwise an admin must claim the contact in UI.
create table private.chat_contact_config (
  singleton boolean primary key default true check (singleton),
  admin_id uuid not null references public.profiles(id),
  updated_at timestamptz not null default now()
);
revoke all on private.chat_contact_config from public, anon, authenticated, service_role;
alter table private.chat_contact_config enable row level security;
insert into private.chat_contact_config (singleton, admin_id)
select true, id from (
  select id, count(*) over () as admin_count from public.profiles
  where role = 'admin' and status = 'active'
) active_admins where admin_count = 1;

-- Preserve the existing validation of lesson teacher/student assignments.
-- Inactive historic teacher chats may remain as audit records, but cannot be
-- reactivated or used for messaging.
create or replace function private.validate_teacher_student_pair()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_table_name = 'teacher_students' then
    if not exists (
      select 1 from public.profiles t join public.profiles s on s.id = new.student_id
      where t.id = new.teacher_id and t.role = 'teacher' and s.role = 'student'
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
drop trigger conversations_valid_pair on public.conversations;
create trigger conversations_valid_pair before insert or update of teacher_id, admin_id, student_id, active
on public.conversations for each row execute function private.validate_teacher_student_pair();

drop trigger teacher_students_sync_conversation on public.teacher_students;
drop function private.sync_conversation_assignment();
update public.conversations set active = false where admin_id is null and active;

create or replace function private.validate_message_sender()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.conversations c
    where c.id = new.conversation_id and c.admin_id is not null
      and new.sender_id in (c.student_id, c.admin_id)) then
    raise exception 'Message sender must belong to the admin/student conversation' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function private.is_conversation_participant(conversation_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.conversations c where c.id = conversation_uuid
      and c.admin_id is not null
      and ((c.student_id = (select auth.uid()) and private.current_role() = 'student')
        or (c.admin_id = (select auth.uid()) and private.current_role() = 'admin'))
  );
$$;

drop policy conversations_read on public.conversations;
create policy conversations_read on public.conversations for select to authenticated
  using (private.is_conversation_participant(id));
create function private.can_send_admin_chat(conversation_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_conversation_participant(conversation_uuid) and exists (
    select 1 from public.conversations c
    join private.chat_contact_config cfg on cfg.singleton and cfg.admin_id = c.admin_id
    join public.profiles s on s.id = c.student_id and s.role = 'student' and s.status = 'active'
    join public.profiles a on a.id = c.admin_id and a.role = 'admin' and a.status = 'active'
    where c.id = conversation_uuid and c.active
  );
$$;
revoke all on function private.can_send_admin_chat(uuid) from public, anon, authenticated, service_role;
grant execute on function private.can_send_admin_chat(uuid) to authenticated;
drop policy messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated with check (
  sender_id = (select auth.uid())
  and private.can_send_admin_chat(conversation_id)
);

-- Old teacher RPC is removed so no stale client can open another teacher chat.
drop function public.open_assigned_conversation(uuid);

create function public.open_admin_conversation(target_student_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  actor_role text := private.current_role();
  student_uuid uuid;
  admin_uuid uuid;
  chat public.conversations%rowtype;
begin
  select cfg.admin_id into admin_uuid from private.chat_contact_config cfg
  join public.profiles p on p.id = cfg.admin_id and p.role = 'admin' and p.status = 'active'
  where cfg.singleton;
  if admin_uuid is null then
    raise exception 'Chat unavailable' using errcode = '42501';
  end if;
  if actor_role = 'student' then
    if target_student_id is not null and target_student_id <> actor_id then
      raise exception 'Chat unavailable' using errcode = '42501';
    end if;
    student_uuid := actor_id;
  elsif actor_role = 'admin' and actor_id = admin_uuid then
    student_uuid := target_student_id;
  else
    raise exception 'Chat unavailable' using errcode = '42501';
  end if;
  if student_uuid is null or not exists (
    select 1 from public.profiles p where p.id = student_uuid
      and p.role = 'student' and p.status = 'active'
  ) then
    raise exception 'Active student required' using errcode = '42501';
  end if;
  insert into public.conversations as c (student_id, admin_id, active)
  values (student_uuid, admin_uuid, true)
  on conflict (student_id, admin_id) where admin_id is not null
  do update set active = true returning * into chat;
  return pg_catalog.jsonb_build_object('conversation_id', chat.id,
    'student_id', chat.student_id, 'admin_id', chat.admin_id, 'active', chat.active);
end;
$$;
revoke all on function public.open_admin_conversation(uuid) from public, anon, authenticated, service_role;
grant execute on function public.open_admin_conversation(uuid) to authenticated;

create function public.my_chat_contacts()
returns table (peer_id uuid, peer_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  actor_role text := private.current_role();
  contact_id uuid;
begin
  select cfg.admin_id into contact_id from private.chat_contact_config cfg
  join public.profiles a on a.id = cfg.admin_id and a.role = 'admin' and a.status = 'active'
  where cfg.singleton;
  if actor_role = 'student' then
    return query select a.id, coalesce(a.full_name, 'Адміністрація НОНА')
      from public.profiles a where a.id = contact_id;
  elsif actor_role = 'admin' and auth.uid() = contact_id then
    return query select s.id, coalesce(s.full_name, 'Учень НОНА')
      from public.profiles s where s.role = 'student' and s.status = 'active'
      order by s.full_name nulls last, s.id;
  elsif actor_role is distinct from 'admin' then
    raise exception 'Chat unavailable' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.my_chat_contacts() from public, anon, authenticated, service_role;
grant execute on function public.my_chat_contacts() to authenticated;

create or replace function public.my_conversation_summaries()
returns table (conversation_id uuid, other_user_id uuid, other_name text,
  last_message_body text, last_message_at timestamptz, unread_count bigint)
language plpgsql stable security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  actor_role text := private.current_role();
  contact_id uuid;
begin
  if actor_role not in ('student', 'admin') or actor_role is null then
    raise exception 'Chat unavailable' using errcode = '42501';
  end if;
  select cfg.admin_id into contact_id from private.chat_contact_config cfg
  join public.profiles a on a.id = cfg.admin_id and a.role = 'admin' and a.status = 'active'
  where cfg.singleton;
  return query
    select c.id,
      case when actor_role = 'student' then c.admin_id else c.student_id end,
      coalesce(p.full_name, case when actor_role = 'student' then 'Адміністрація НОНА' else 'Учень НОНА' end),
      pg_catalog.left(last_message.body, 160), last_message.created_at,
      (select count(*) from public.messages unread
        where unread.conversation_id = c.id and unread.sender_id <> actor_id
          and unread.read_at is null)
    from public.conversations c
    join public.profiles s on s.id = c.student_id and s.role = 'student' and s.status = 'active'
    join public.profiles p on p.id = case when actor_role = 'student' then c.admin_id else c.student_id end
    left join lateral (select m.body, m.created_at from public.messages m
      where m.conversation_id = c.id order by m.created_at desc, m.id desc limit 1) last_message on true
    where c.admin_id = contact_id and c.active
      and ((actor_role = 'student' and c.student_id = actor_id)
        or (actor_role = 'admin' and c.admin_id = actor_id))
    order by last_message.created_at desc nulls last, p.full_name;
end;
$$;

-- Any active admin may explicitly take over as the school's chat contact.
-- Previously sent messages remain stored and visible only to their old pair.
create function public.admin_claim_chat_contact()
returns boolean language plpgsql security definer set search_path = '' as $$
declare actor_id uuid := auth.uid();
begin
  if private.current_role() is distinct from 'admin' then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  insert into private.chat_contact_config (singleton, admin_id)
  values (true, actor_id)
  on conflict (singleton) do update set admin_id = excluded.admin_id, updated_at = now();
  update public.conversations c set active = (c.admin_id = actor_id and exists (
    select 1 from public.profiles s where s.id = c.student_id
      and s.role = 'student' and s.status = 'active'
  )) where c.admin_id is not null
    and c.active is distinct from (c.admin_id = actor_id and exists (
      select 1 from public.profiles s where s.id = c.student_id
        and s.role = 'student' and s.status = 'active'
    ));
  return true;
end;
$$;
revoke all on function public.admin_claim_chat_contact() from public, anon, authenticated, service_role;
grant execute on function public.admin_claim_chat_contact() to authenticated;

create function public.my_chat_contact_status()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.current_role() = 'admin' and exists (
    select 1 from private.chat_contact_config cfg where cfg.singleton
      and cfg.admin_id = (select auth.uid())
  );
$$;
revoke all on function public.my_chat_contact_status() from public, anon, authenticated, service_role;
grant execute on function public.my_chat_contact_status() to authenticated;
