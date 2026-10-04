-- Historic conversations remain readable by their two participants after an
-- assignment ends. Sending still requires an active assignment and chat.
create or replace function private.is_conversation_participant(conversation_uuid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.conversations c where c.id = conversation_uuid
      and ((c.student_id = (select auth.uid()) and private.current_role() = 'student')
        or (c.teacher_id = (select auth.uid()) and private.current_role() = 'teacher'))
  );
$$;

drop policy messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated with check (
  sender_id = (select auth.uid())
  and private.is_conversation_participant(conversation_id)
  and exists (select 1 from public.conversations c
    join public.teacher_students ts on ts.student_id = c.student_id
      and ts.teacher_id = c.teacher_id and ts.active
    where c.id = conversation_id and c.active)
);

-- Assignments are the source of truth for whether an old chat can be used.
create function private.sync_conversation_assignment()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.conversations c set active = new.active
  where c.student_id = new.student_id and c.teacher_id = new.teacher_id
    and c.active is distinct from new.active;
  return new;
end;
$$;
revoke all on function private.sync_conversation_assignment() from public, anon, authenticated, service_role;
create trigger teacher_students_sync_conversation
after insert or update of active on public.teacher_students
for each row execute function private.sync_conversation_assignment();

-- Align any existing conversations with the current assignment without
-- deleting or altering message history.
update public.conversations c set active = exists (
  select 1 from public.teacher_students ts where ts.student_id = c.student_id
    and ts.teacher_id = c.teacher_id and ts.active
)
where c.active is distinct from exists (
  select 1 from public.teacher_students ts where ts.student_id = c.student_id
    and ts.teacher_id = c.teacher_id and ts.active
);

create function public.open_assigned_conversation(target_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  actor_role text := private.current_role();
  student_uuid uuid;
  teacher_uuid uuid;
  chat public.conversations%rowtype;
begin
  if actor_role = 'student' then
    student_uuid := actor_id;
    teacher_uuid := target_user_id;
  elsif actor_role = 'teacher' then
    student_uuid := target_user_id;
    teacher_uuid := actor_id;
  else
    raise exception 'Chat unavailable' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles s join public.profiles t on t.id = teacher_uuid
    where s.id = student_uuid and s.role = 'student' and s.status = 'active'
      and t.role = 'teacher' and t.status = 'active')
    or not exists (select 1 from public.teacher_students ts
      where ts.student_id = student_uuid and ts.teacher_id = teacher_uuid and ts.active) then
    raise exception 'Active assigned pair required' using errcode = '42501';
  end if;
  insert into public.conversations as c (student_id, teacher_id, active)
  values (student_uuid, teacher_uuid, true)
  on conflict (student_id, teacher_id) do update set active = true
  returning * into chat;
  return pg_catalog.jsonb_build_object('conversation_id', chat.id,
    'student_id', chat.student_id, 'teacher_id', chat.teacher_id, 'active', chat.active);
end;
$$;
revoke all on function public.open_assigned_conversation(uuid) from public, anon, authenticated, service_role;
grant execute on function public.open_assigned_conversation(uuid) to authenticated;

create function public.mark_conversation_read(target_conversation_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  affected integer;
begin
  if private.is_conversation_participant(target_conversation_id) is distinct from true then
    raise exception 'Chat unavailable' using errcode = '42501';
  end if;
  update public.messages m set read_at = now()
  where m.conversation_id = target_conversation_id
    and m.sender_id <> auth.uid() and m.read_at is null;
  get diagnostics affected = row_count;
  return affected;
end;
$$;
revoke all on function public.mark_conversation_read(uuid) from public, anon, authenticated, service_role;
grant execute on function public.mark_conversation_read(uuid) to authenticated;

create function public.my_conversation_summaries()
returns table (conversation_id uuid, other_user_id uuid, other_name text,
  last_message_body text, last_message_at timestamptz, unread_count bigint)
language plpgsql stable security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  actor_role text := private.current_role();
begin
  if actor_role not in ('student', 'teacher') or actor_role is null then
    raise exception 'Chat unavailable' using errcode = '42501';
  end if;
  return query
    select c.id,
      case when actor_role = 'student' then c.teacher_id else c.student_id end,
      coalesce(p.full_name, case when actor_role = 'student' then 'Викладач НОНА' else 'Учень НОНА' end),
      pg_catalog.left(last_message.body, 160), last_message.created_at,
      (select count(*) from public.messages unread
        where unread.conversation_id = c.id and unread.sender_id <> actor_id
          and unread.read_at is null)
    from public.conversations c
    join public.teacher_students ts on ts.student_id = c.student_id
      and ts.teacher_id = c.teacher_id and ts.active
    join public.profiles p on p.id = case when actor_role = 'student' then c.teacher_id else c.student_id end
    left join lateral (select m.body, m.created_at from public.messages m
      where m.conversation_id = c.id order by m.created_at desc, m.id desc limit 1) last_message on true
    where c.active and ((actor_role = 'student' and c.student_id = actor_id)
      or (actor_role = 'teacher' and c.teacher_id = actor_id))
    order by last_message.created_at desc nulls last, p.full_name;
end;
$$;
revoke all on function public.my_conversation_summaries() from public, anon, authenticated, service_role;
grant execute on function public.my_conversation_summaries() to authenticated;

create index messages_unread_conversation_idx
  on public.messages (conversation_id, sender_id) where read_at is null;
