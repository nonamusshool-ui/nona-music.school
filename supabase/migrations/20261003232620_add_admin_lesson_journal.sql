-- Read-only, month-scoped journal. The lesson remains the sole source of truth.
create index lessons_journal_scheduled_idx on public.lessons(scheduled_at desc, id desc);

create function public.admin_lesson_journal(
  month_start date,
  teacher_filter uuid default null,
  student_filter uuid default null,
  status_filter text default null,
  name_query text default null,
  page_size integer default 100,
  page_offset integer default 0
)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
      l.scheduled_at, l.duration_minutes, l.status, l.consumes_lesson,
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
$$;

revoke all on function public.admin_lesson_journal(date, uuid, uuid, text, text, integer, integer)
from public, anon, authenticated, service_role;
grant execute on function public.admin_lesson_journal(date, uuid, uuid, text, text, integer, integer)
to authenticated;
