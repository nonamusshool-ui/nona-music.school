-- Keep the existing RPC signature and row lock. The unique child index remains
-- the final backstop against concurrent replacements of the same lesson.
create or replace function public.teacher_reschedule_lesson(
  target_lesson_id uuid, lesson_date date, lesson_time time without time zone,
  lesson_duration integer, selected_format text, selected_url text,
  selected_location text, target_package_id uuid, takes_package_lesson boolean
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  old_lesson public.lessons%rowtype;
  new_lesson public.lessons%rowtype;
  student_record public.profiles%rowtype;
  teacher_record public.profiles%rowtype;
  start_at timestamptz;
  clean_url text := nullif(pg_catalog.btrim(selected_url), '');
  clean_location text := nullif(pg_catalog.btrim(selected_location), '');
  old_url text;
  old_location text;
  old_format text;
begin
  if private.current_role() is distinct from 'teacher' then
    raise exception 'Active teacher required' using errcode = '42501';
  end if;
  -- Serializes repeated/concurrent calls for this exact lesson ID.
  select * into old_lesson from public.lessons where id = target_lesson_id for update;
  if old_lesson.id is null or old_lesson.teacher_id <> auth.uid() then
    raise exception 'Lesson not found for this teacher' using errcode = '42501';
  end if;
  if old_lesson.status = 'rescheduled' then
    select * into new_lesson from public.lessons where rescheduled_from = old_lesson.id;
    if new_lesson.id is null then
      raise exception 'Replacement lesson missing' using errcode = '22023';
    end if;
    return pg_catalog.jsonb_build_object('old_id', old_lesson.id,
      'old_status', old_lesson.status, 'new_id', new_lesson.id,
      'new_status', new_lesson.status);
  end if;
  if old_lesson.status <> 'scheduled' or lesson_duration is null
    or lesson_duration not between 15 and 180 then
    raise exception 'Only a scheduled lesson can be rescheduled' using errcode = '22023';
  end if;
  start_at := private.lesson_start_kyiv(lesson_date, lesson_time);
  perform private.assert_lesson_destination(selected_format, clean_url, clean_location);

  -- Compare effective, normalized values. Older online lessons may store the
  -- link only in meet_url and have no explicit lesson_format.
  old_url := coalesce(nullif(pg_catalog.btrim(old_lesson.lesson_url), ''),
    nullif(pg_catalog.btrim(old_lesson.meet_url), ''));
  old_location := nullif(pg_catalog.btrim(old_lesson.location_text), '');
  old_format := coalesce(old_lesson.lesson_format,
    case when old_url is not null then 'online'
      when old_location is not null then 'offline' end);
  if start_at = old_lesson.scheduled_at
    and lesson_duration = old_lesson.duration_minutes
    and selected_format is not distinct from old_format
    and clean_url is not distinct from old_url
    and clean_location is not distinct from old_location
    and target_package_id is not distinct from old_lesson.package_id
    and takes_package_lesson is not distinct from old_lesson.consumes_lesson then
    raise exception 'Reschedule must change lesson details' using errcode = '22023';
  end if;

  select * into student_record from public.profiles where id = old_lesson.student_id for update;
  select * into teacher_record from public.profiles where id = auth.uid() for update;
  if student_record.id is null or student_record.role <> 'student' or student_record.status <> 'active'
    or teacher_record.id is null or teacher_record.role <> 'teacher' or teacher_record.status <> 'active'
    or not exists (select 1 from public.teacher_students ts
      where ts.student_id = old_lesson.student_id and ts.teacher_id = auth.uid() and ts.active) then
    raise exception 'Active assigned student required' using errcode = '42501';
  end if;
  perform private.assert_lesson_package(old_lesson.student_id, target_package_id,
    lesson_date, takes_package_lesson, old_lesson.id);
  perform private.assert_lesson_slot(old_lesson.student_id, auth.uid(), start_at,
    lesson_duration, old_lesson.id);
  update public.lessons set status = 'rescheduled', consumes_lesson = false,
    resolved_at = now(), resolved_by = auth.uid()
  where id = old_lesson.id;
  insert into public.lessons (student_id, teacher_id, package_id, scheduled_at,
    duration_minutes, status, consumes_lesson, lesson_format, lesson_url,
    location_text, created_by, rescheduled_from)
  values (old_lesson.student_id, auth.uid(), target_package_id, start_at,
    lesson_duration, 'scheduled', takes_package_lesson, selected_format,
    clean_url, clean_location, auth.uid(), old_lesson.id) returning * into new_lesson;
  return pg_catalog.jsonb_build_object('old_id', old_lesson.id,
    'old_status', 'rescheduled', 'new_id', new_lesson.id,
    'new_status', new_lesson.status);
end;
$$;

revoke all on function public.teacher_reschedule_lesson(uuid, date, time without time zone, integer, text, text, text, uuid, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.teacher_reschedule_lesson(uuid, date, time without time zone, integer, text, text, text, uuid, boolean)
  to authenticated;
