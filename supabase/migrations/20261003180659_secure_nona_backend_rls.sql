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
