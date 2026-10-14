-- Run against an isolated PostgreSQL/Supabase test database after migrations.
-- Random fixture IDs, no real accounts or lessons; the whole fixture rolls back.
begin;
set local plpgsql.check_asserts = on;
do $test$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); admin_id uuid := gen_random_uuid();
  pkg uuid := gen_random_uuid(); small_pkg uuid := gen_random_uuid(); expired_pkg uuid := gen_random_uuid();
  base_day date := current_date + 28;
  dst_day date;
  gap_day date;
  single_result jsonb; result jsonb; again jsonb; saved jsonb;
  series_uuid uuid; other_series uuid; other_lesson uuid; lesson_id uuid; replacement uuid;
  before_lessons integer; before_series integer; rejected boolean; expected_time timestamptz;
  protected_rows jsonb; series_before jsonb; n integer;
begin
  base_day := base_day + ((2 - extract(isodow from base_day)::integer + 7) % 7);
  dst_day := make_date(extract(year from now())::integer + 1, 10, 1);
  dst_day := dst_day + ((2 - extract(isodow from dst_day)::integer + 7) % 7);
  insert into auth.users(id) values (ta),(tb),(sa),(sb),(sc),(admin_id);
  insert into public.profiles(id,role,status,can_teach,admin_level) values
    (ta,'teacher','active',false,null),(tb,'teacher','active',false,null),
    (sa,'student','active',false,null),(sb,'student','active',false,null),(sc,'student','active',false,null),
    (admin_id,'admin','active',true,'senior')
    on conflict(id) do update set role=excluded.role,status=excluded.status,
      can_teach=excluded.can_teach,admin_level=excluded.admin_level;
  insert into public.teacher_students(teacher_id,student_id) values (ta,sa),(ta,sb),(tb,sc),(admin_id,sa);
  insert into public.lesson_packages(id,student_id,lessons_purchased,status,valid_from,valid_until)
    values (pkg,sa,8,'active',dst_day,dst_day+70),
      (small_pkg,sa,5,'active',null,null),(expired_pkg,sa,8,'active',base_day,base_day+14);
  perform set_config('request.jwt.claim.sub',ta::text,true);

  -- A/K: unchanged single creation, no-op guard, history, idempotent retry,
  -- cancellation, manual start and completion.
  single_result := public.teacher_schedule_lesson(sa,base_day,'15:00',60,'online','https://meet.google.com/test',null,null,false);
  lesson_id := (single_result->>'id')::uuid;
  assert (select series_id is null from public.lessons where id=lesson_id);
  rejected := false;
  begin
    perform public.teacher_reschedule_lesson(lesson_id,base_day,'15:00',60,'online','https://meet.google.com/test',null,null,false);
  exception when sqlstate '22023' then rejected := sqlerrm = 'Reschedule must change lesson details'; end;
  assert rejected;
  result := public.teacher_reschedule_lesson(lesson_id,base_day+1,'16:00',45,'offline',null,'Test studio',null,false);
  again := public.teacher_reschedule_lesson(lesson_id,base_day+1,'16:00',45,'offline',null,'Test studio',null,false);
  assert result=again;
  replacement := (result->>'new_id')::uuid;
  assert (select status='rescheduled' and not consumes_lesson from public.lessons where id=lesson_id);
  assert (select series_id is null and not series_exception from public.lessons where id=replacement);
  perform public.teacher_resolve_lesson(replacement,'cancelled','student_cancelled',null,false);
  single_result := public.teacher_schedule_lesson(sa,base_day+3,'15:00',60,'online','https://meet.google.com/test',null,null,false);
  lesson_id := (single_result->>'id')::uuid;
  perform public.teacher_start_lesson(lesson_id);
  perform public.teacher_resolve_lesson(lesson_id,'completed');
  assert (select status='completed' and completion_source='teacher' from public.lessons where id=lesson_id);

  -- B/C: exactly eight normal rows, bounded numbering, Kyiv 15:00 across DST.
  result := public.teacher_schedule_lesson_series(sa,dst_day,'15:00',60,'online','https://meet.google.com/test',null,pkg,true,8);
  series_uuid := (result->>'series_id')::uuid;
  assert (select count(*)=8 and min(series_occurrence)=1 and max(series_occurrence)=8
    from public.lessons where series_id=series_uuid and status='scheduled');
  assert (select bool_and((scheduled_at at time zone 'Europe/Kyiv')::time='15:00'::time)
    from public.lessons where series_id=series_uuid);
  assert (select count(distinct extract(hour from scheduled_at at time zone 'UTC'))=2 from public.lessons where series_id=series_uuid);
  assert private.package_committed_slots(pkg)=8;

  -- D: third occurrence conflicts with another student of the same teacher.
  perform public.teacher_schedule_lesson(sb,base_day+84,'15:00',60,'online','https://meet.google.com/test',null,null,false);
  select count(*) into before_lessons from public.lessons;
  select count(*) into before_series from public.lesson_series;
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sa,base_day+70,'15:00',60,'online','https://meet.google.com/test',null,null,false,8);
  exception when sqlstate '22023' then rejected := sqlerrm='Series slot conflict'; end;
  assert rejected;
  assert (select count(*)=before_lessons from public.lessons);
  assert (select count(*)=before_series from public.lesson_series);

  -- E: insufficient capacity and per-date validity reject the entire series.
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sa,base_day+210,'14:00',60,'online','https://meet.google.com/test',null,small_pkg,true,8);
  exception when sqlstate '22023' then rejected := sqlerrm='Series package insufficient'; end;
  assert rejected;
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sa,base_day,'14:00',60,'online','https://meet.google.com/test',null,expired_pkg,true,8);
  exception when sqlstate '22023' then rejected := sqlerrm='Series package invalid on lesson dates'; end;
  assert rejected;
  assert (select count(*)=before_lessons from public.lessons);
  assert (select count(*)=before_series from public.lesson_series);
  for n in select unnest(array[1,53]) loop
    rejected := false;
    begin
      perform public.teacher_schedule_lesson_series(sa,base_day+210,'14:00',60,'online','https://meet.google.com/test',null,null,false,n);
    exception when sqlstate '22023' then rejected := sqlerrm='Series count must be between 2 and 52'; end;
    assert rejected;
  end loop;
  -- A nonexistent Kyiv spring wall-clock minute cannot create a partial series.
  gap_day := make_date(extract(year from now())::integer+1,4,1)-1;
  gap_day := gap_day - extract(dow from gap_day)::integer;
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sa,gap_day,'03:30',60,'online','https://meet.google.com/test',null,null,false,2);
  exception when sqlstate '22023' then rejected := true; end;
  assert rejected;
  assert (select count(*)=before_lessons from public.lessons);
  assert (select count(*)=before_series from public.lesson_series);

  -- F: one occurrence becomes an exception, preserves series identity/history.
  select id into lesson_id from public.lessons where series_id=series_uuid and series_occurrence=3;
  saved := (select to_jsonb(s) from public.lesson_series s where id=series_uuid);
  result := public.teacher_reschedule_lesson(lesson_id,dst_day+15,'17:00',60,'online','https://meet.google.com/test',null,pkg,true);
  replacement := (result->>'new_id')::uuid;
  assert (select series_id=series_uuid and series_occurrence=3 and series_exception from public.lessons where id=replacement);
  assert (select (scheduled_at at time zone 'Europe/Kyiv')::time='15:00'::time from public.lessons where series_id=series_uuid and series_occurrence=4);
  assert saved=(select to_jsonb(s) from public.lesson_series s where id=series_uuid);
  assert private.package_committed_slots(pkg)=8;

  -- G/H/I: past, exception, completed, cancelled and in-progress rows survive.
  update public.lessons set scheduled_at=now()-interval '7 days' where series_id=series_uuid and series_occurrence=1;
  select id into lesson_id from public.lessons where series_id=series_uuid and series_occurrence=4;
  perform public.teacher_start_lesson(lesson_id); perform public.teacher_resolve_lesson(lesson_id,'completed');
  select id into lesson_id from public.lessons where series_id=series_uuid and series_occurrence=5;
  perform public.teacher_resolve_lesson(lesson_id,'cancelled','cancelled_in_advance',null,false);
  select id into lesson_id from public.lessons where series_id=series_uuid and series_occurrence=6;
  perform public.teacher_start_lesson(lesson_id);
  protected_rows := (select jsonb_agg(to_jsonb(l) order by l.id) from public.lessons l
    where series_id=series_uuid and series_occurrence in (1,3,4,5,6));
  select id into lesson_id from public.lessons where series_id=series_uuid and series_occurrence=2;
  result := public.teacher_update_lesson_series_from(lesson_id,dst_day+8,'16:00',45,'offline',null,'Test studio',pkg,true);
  assert (result->>'count')::integer=3;
  assert protected_rows=(select jsonb_agg(to_jsonb(l) order by l.id) from public.lessons l
    where series_id=series_uuid and series_occurrence in (1,3,4,5,6));
  assert (select bool_and((scheduled_at at time zone 'Europe/Kyiv')::time='16:00'::time
    and extract(isodow from scheduled_at at time zone 'Europe/Kyiv')=3 and not series_exception)
    from public.lessons where series_id=series_uuid and series_occurrence in(2,7,8) and status='scheduled');
  assert (select weekday=3 and local_time='16:00'::time from public.lesson_series where id=series_uuid);
  assert private.package_committed_slots(pkg)=7;
  select id into lesson_id from public.lessons where series_id=series_uuid and series_occurrence=4;
  rejected := false;
  begin
    perform public.teacher_update_lesson_series_from(lesson_id,dst_day+22,'16:00',45,'offline',null,'Test studio',pkg,true);
  exception when sqlstate '22023' then rejected := true; end;
  assert rejected;

  -- Bulk conflict and capacity failures leave both rule and history untouched.
  perform public.teacher_schedule_lesson(sb,dst_day+44,'16:00',45,'offline',null,'Test studio',null,false);
  saved := (select jsonb_agg(to_jsonb(l) order by l.id) from public.lessons l where series_id=series_uuid);
  series_before := (select to_jsonb(s) from public.lesson_series s where id=series_uuid);
  select id into lesson_id from public.lessons where series_id=series_uuid and series_occurrence=2 and status='scheduled';
  rejected := false;
  begin
    perform public.teacher_update_lesson_series_from(lesson_id,dst_day+9,'16:00',45,'offline',null,'Test studio',pkg,true);
  exception when sqlstate '22023' then rejected := sqlerrm='Series slot conflict'; end;
  assert rejected;
  assert saved=(select jsonb_agg(to_jsonb(l) order by l.id) from public.lessons l where series_id=series_uuid);
  assert series_before=(select to_jsonb(s) from public.lesson_series s where id=series_uuid);
  -- Switching the future subset to a two-slot package cannot reserve three.
  insert into public.lesson_packages(student_id,lessons_purchased,status) values(sa,2,'active') returning id into small_pkg;
  rejected := false;
  begin
    perform public.teacher_update_lesson_series_from(lesson_id,dst_day+8,'16:00',45,'online','https://meet.google.com/test',null,small_pkg,true);
  exception when sqlstate '22023' then rejected := sqlerrm='Series package insufficient'; end;
  assert rejected;
  rejected := false;
  begin
    perform public.teacher_update_lesson_series_from(lesson_id,dst_day+8,'16:00',45,'online','https://meet.google.com/test',null,expired_pkg,true);
  exception when sqlstate '22023' then rejected := sqlerrm='Series package invalid on lesson dates'; end;
  assert rejected;
  assert saved=(select jsonb_agg(to_jsonb(l) order by l.id) from public.lessons l where series_id=series_uuid);
  assert series_before=(select to_jsonb(s) from public.lesson_series s where id=series_uuid);
  -- Protect exceptions even when they are selected as a bulk anchor.
  rejected := false;
  begin
    perform public.teacher_update_lesson_series_from(replacement,dst_day+15,'18:00',45,'offline',null,'Test studio',pkg,true);
  exception when sqlstate '22023' then rejected := true; end;
  assert rejected;

  -- J/security: other teacher, unassigned/inactive accounts, student, direct writes.
  perform set_config('request.jwt.claim.sub',tb::text,true);
  result := public.teacher_schedule_lesson_series(sc,base_day+400,'11:00',60,'online','https://meet.google.com/test',null,null,false,2);
  other_series := (result->>'series_id')::uuid;
  select id into other_lesson from public.lessons where series_id=other_series and series_occurrence=1;
  perform set_config('request.jwt.claim.sub',ta::text,true);
  rejected := false;
  begin
    perform public.teacher_update_lesson_series_from(other_lesson,base_day+400,'12:00',60,'online','https://meet.google.com/test',null,null,false);
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  rejected := false;
  begin
    perform public.teacher_reschedule_lesson(other_lesson,base_day+400,'12:00',60,'online','https://meet.google.com/test',null,null,false);
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sc,base_day+400,'12:00',60,'online','https://meet.google.com/test',null,null,false,2);
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  update public.profiles set status='suspended' where id=sa;
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sa,base_day+500,'12:00',60,'online','https://meet.google.com/test',null,null,false,2);
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  update public.profiles set status='active' where id=sa;
  update public.profiles set status='suspended' where id=ta;
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sa,base_day+500,'12:00',60,'online','https://meet.google.com/test',null,null,false,2);
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  update public.profiles set status='active' where id=ta;
  perform set_config('request.jwt.claim.sub',sa::text,true);
  execute 'set local role authenticated';
  assert (select count(*)=1 from public.lesson_series);
  assert not has_column_privilege('authenticated','public.lessons','outcome_note','SELECT');
  assert has_column_privilege('authenticated','public.lessons','series_id','SELECT');
  rejected := false;
  begin perform count(*) from public.staff_lesson_records(); exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  rejected := false;
  begin
    perform public.teacher_schedule_lesson_series(sa,base_day+500,'12:00',60,'online','https://meet.google.com/test',null,null,false,2);
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  rejected := false;
  begin update public.lesson_series set local_time='20:00' where id=series_uuid;
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',tb::text,true);
  execute 'set local role authenticated'; assert (select count(*)=1 from public.lesson_series); execute 'reset role';
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  execute 'set local role authenticated'; assert (select count(*)=2 from public.lesson_series); execute 'reset role';
  execute 'set local role anon';
  assert not has_function_privilege('anon','public.teacher_schedule_lesson_series(uuid,date,time,integer,text,text,text,uuid,boolean,integer)','EXECUTE');
  rejected := false;
  begin perform count(*) from public.lesson_series; exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  execute 'reset role';
end;
$test$;
rollback;
