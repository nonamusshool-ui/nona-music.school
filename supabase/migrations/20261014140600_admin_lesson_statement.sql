-- Read-only spreadsheet statement. Authorization is checked before any data read.
create function public.admin_lesson_statement(
  period_type text, period_start date,
  teacher_filter uuid default null, student_filter uuid default null,
  name_query text default null
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  start_at timestamptz;
  end_at timestamptz;
  clean_query text := nullif(btrim(name_query), '');
  result jsonb;
begin
  if private.is_admin() is distinct from true then
    raise exception 'Active admin access required' using errcode = '42501';
  end if;
  if period_type is null or period_type not in ('month', 'year')
    or period_start is null or not isfinite(period_start)
    or extract(day from period_start) <> 1
    or (period_type = 'year' and extract(month from period_start) <> 1)
    or char_length(clean_query) > 100 then
    raise exception 'Invalid statement period or filters' using errcode = '22023';
  end if;
  start_at := period_start::timestamp at time zone 'Europe/Kyiv';
  end_at := (period_start + case when period_type = 'year' then interval '1 year'
    else interval '1 month' end)::timestamp at time zone 'Europe/Kyiv';

  with period_rows as materialized (
    select l.id as lesson_id, l.student_id, l.teacher_id,
      coalesce(nullif(s.full_name, ''), 'Ім’я не вказано') as student_name,
      coalesce(nullif(t.full_name, ''), 'Ім’я не вказано') as teacher_name,
      l.scheduled_at, l.duration_minutes, l.status, l.package_id,
      p.lessons_purchased, l.series_id, l.series_occurrence, l.series_exception,
      extract(day from l.scheduled_at at time zone 'Europe/Kyiv')::integer as day_number,
      extract(month from l.scheduled_at at time zone 'Europe/Kyiv')::integer as month_number,
      -- Match private.package_lessons_used; reservations are not charges.
      (l.package_id is not null and l.consumes_lesson and
        (l.status = 'completed' or (l.status = 'cancelled' and l.resolved_at is not null))) as charged
    from public.lessons l
    join public.profiles s on s.id = l.student_id
    join public.profiles t on t.id = l.teacher_id
    left join public.lesson_packages p on p.id = l.package_id
    where l.scheduled_at >= start_at and l.scheduled_at < end_at
  ), filtered as materialized (
    select * from period_rows r
    where (teacher_filter is null or r.teacher_id = teacher_filter)
      and (student_filter is null or r.student_id = student_filter)
      and (clean_query is null or r.student_name ilike '%' || clean_query || '%'
        or r.teacher_name ilike '%' || clean_query || '%')
  ), student_totals as (
    select student_id, student_name,
      count(*) filter (where status = 'completed') as completed,
      count(*) filter (where status in ('cancelled', 'no_show')) as cancelled,
      count(*) filter (where status = 'rescheduled') as rescheduled,
      count(*) filter (where status = 'scheduled') as scheduled,
      count(*) filter (where status = 'in_progress') as in_progress,
      count(*) filter (where charged) as charged
    from filtered group by student_id, student_name
  ), balances as (
    select b.student_id, sum(b.lessons_remaining) as remaining_now
    from public.package_balances b
    where b.status = 'active' and b.student_id in (select student_id from student_totals)
    group by b.student_id
  ), student_teachers as (
    select student_id, jsonb_agg(jsonb_build_object('id', teacher_id, 'name', teacher_name)
      order by teacher_name, teacher_id) as teachers
    from (select distinct student_id, teacher_id, teacher_name from filtered) t
    group by student_id
  ), daily as (
    select student_id, day_number,
      jsonb_agg(jsonb_build_object(
        'lesson_id', lesson_id, 'student_id', student_id, 'student_name', student_name,
        'teacher_id', teacher_id, 'teacher_name', teacher_name,
        'scheduled_at', scheduled_at, 'duration_minutes', duration_minutes,
        'status', status, 'charged', charged, 'package_id', package_id,
        'lessons_purchased', lessons_purchased, 'series_id', series_id,
        'series_occurrence', series_occurrence, 'series_exception', series_exception
      ) order by scheduled_at, lesson_id) as lessons
    from filtered where period_type = 'month' group by student_id, day_number
  ), student_days as (
    select student_id, jsonb_object_agg(day_number::text, lessons) as days
    from daily group by student_id
  ), completed_months as (
    select student_id, month_number, count(*) as completed
    from filtered where period_type = 'year' and status = 'completed'
    group by student_id, month_number
  ), student_months as (
    select s.student_id, jsonb_object_agg(n::text, coalesce(m.completed, 0)) as months
    from student_totals s cross join generate_series(1, 12) n
    left join completed_months m on m.student_id = s.student_id and m.month_number = n
    where period_type = 'year' group by s.student_id
  )
  select jsonb_build_object(
    'period_type', period_type, 'period_start', period_start,
    'days_in_month', case when period_type = 'month' then
      extract(day from period_start + interval '1 month' - interval '1 day')::integer else 0 end,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'student_id', s.student_id, 'student_name', s.student_name, 'teachers', t.teachers,
      'days', coalesce(d.days, '{}'::jsonb), 'months', coalesce(m.months, '{}'::jsonb),
      'totals', jsonb_build_object('completed', s.completed, 'cancelled', s.cancelled,
        'rescheduled', s.rescheduled, 'scheduled', s.scheduled, 'in_progress', s.in_progress,
        'charged', s.charged, 'remaining_now', coalesce(b.remaining_now, 0))
      ) order by s.student_name, s.student_id)
      from student_totals s join student_teachers t using (student_id)
      left join balances b using (student_id) left join student_days d using (student_id)
      left join student_months m using (student_id)), '[]'::jsonb),
    'teachers', coalesce((select jsonb_agg(jsonb_build_object('id', teacher_id, 'name', teacher_name)
      order by teacher_name, teacher_id) from
      (select distinct teacher_id, teacher_name from period_rows) t), '[]'::jsonb),
    'students', coalesce((select jsonb_agg(jsonb_build_object('id', student_id, 'name', student_name)
      order by student_name, student_id) from
      (select distinct student_id, student_name from period_rows) s), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;
revoke all on function public.admin_lesson_statement(text, date, uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.admin_lesson_statement(text, date, uuid, uuid, text) to authenticated;
