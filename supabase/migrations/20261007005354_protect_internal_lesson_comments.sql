-- Internal cancellation notes are staff-only, even through direct REST/GraphQL.
-- All other lesson columns keep their existing RLS-controlled access.
revoke select on public.lessons from public, anon, authenticated;
revoke select (outcome_note) on public.lessons from public, anon, authenticated;
grant select (
  id, package_id, student_id, teacher_id, scheduled_at, duration_minutes,
  status, consumes_lesson, meet_url, homework, completed_at, created_by,
  created_at, updated_at, lesson_format, lesson_url, location_text,
  outcome_reason, resolved_at, resolved_by, rescheduled_from, started_at,
  completion_source
) on public.lessons to authenticated;

-- Deliberate privileged read: explicit active-role and ownership checks replace
-- RLS here because authenticated cannot read outcome_note directly.
create function public.staff_lesson_records()
returns setof public.lessons
language plpgsql stable security definer set search_path = '' as $$
declare
  actor_id uuid := auth.uid();
  admin_access boolean := private.is_admin();
begin
  if actor_id is null or (
    admin_access is distinct from true
    and private.can_teach(actor_id) is distinct from true
  ) then
    raise exception 'Active staff access required' using errcode = '42501';
  end if;
  return query select l.* from public.lessons l
    where admin_access is true or l.teacher_id = actor_id;
end;
$$;
revoke all on function public.staff_lesson_records()
  from public, anon, authenticated, service_role;
grant execute on function public.staff_lesson_records() to authenticated;
