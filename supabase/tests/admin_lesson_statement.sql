-- Run after migrations in an isolated database with the current schema.
-- No real accounts/lessons: random fixtures and a final ROLLBACK.
begin;
set local plpgsql.check_asserts = on;
do $test$
declare
  admin_id uuid := gen_random_uuid(); ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); pending_id uuid := gen_random_uuid();
  pkg uuid := gen_random_uuid(); extra_pkg uuid := gen_random_uuid(); used_pkg uuid := gen_random_uuid();
  pkg_b uuid := gen_random_uuid(); series_uuid uuid := gen_random_uuid(); old_id uuid := gen_random_uuid();
  report jsonb; row_a jsonb; row_b jsonb; yearly jsonb; item jsonb;
  rejected boolean; actor uuid; expected_balance integer;
begin
  insert into auth.users(id) values (admin_id),(ta),(tb),(sa),(sb),(pending_id);
  insert into public.profiles(id,full_name,role,status,can_teach,admin_level) values
    (admin_id,'Test admin','admin','active',true,'senior'),
    (ta,'Teacher A','teacher','active',false,null),(tb,'Teacher B','teacher','active',false,null),
    (sa,'Student A','student','active',false,null),(sb,'Student B','student','active',false,null)
    on conflict(id) do update set full_name=excluded.full_name,role=excluded.role,status=excluded.status,
      can_teach=excluded.can_teach,admin_level=excluded.admin_level;
  insert into public.teacher_students(teacher_id,student_id) values (ta,sa),(tb,sa),(ta,sb);
  insert into public.lesson_packages(id,student_id,lessons_purchased,status) values
    (pkg,sa,20,'active'),(extra_pkg,sa,5,'active'),(used_pkg,sa,10,'used'),(pkg_b,sb,7,'active');
  insert into public.lesson_series(id,student_id,teacher_id,start_date,weekday,local_time,duration_minutes,
    lesson_format,package_id,consumes_lesson,occurrence_count,created_by)
    values (series_uuid,sa,ta,'2026-10-13',2,'15:00',60,'online',pkg,true,2,admin_id);

  insert into public.lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson,
    resolved_at,outcome_reason,outcome_note) values
    (sa,ta,pkg,'2026-10-05 12:00Z','completed',true,null,null,null),
    (sa,ta,pkg,'2026-10-06 12:00Z','scheduled',true,null,null,null),
    (sa,ta,pkg,'2026-10-07 12:00Z','in_progress',true,null,null,null),
    (sa,ta,pkg,'2026-10-08 12:00Z','cancelled',true,'2026-10-08 12:00Z','student_cancelled','Internal fixture note'),
    (sa,ta,pkg,'2026-10-09 12:00Z','cancelled',true,null,null,null),
    (sa,ta,pkg,'2026-10-10 12:00Z','no_show',true,'2026-10-10 12:00Z','student_no_show',null);
  insert into public.lessons(id,student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson)
    values (old_id,sa,ta,pkg,'2026-10-11 12:00Z','rescheduled',false);
  insert into public.lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson,rescheduled_from)
    values (sa,ta,pkg,'2026-10-12 12:00Z','completed',true,old_id);
  insert into public.lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson,series_id,series_occurrence)
    values (sa,ta,pkg,'2026-10-13 12:00Z','completed',true,series_uuid,1),
      (sa,ta,pkg,'2026-10-20 12:00Z','completed',true,series_uuid,2);
  -- Two teachers/lessons on one student's day: one visual row, no lost lesson.
  insert into public.lessons(student_id,teacher_id,scheduled_at,status,consumes_lesson) values
    (sa,tb,'2026-10-05 15:00Z','completed',false);
  insert into public.lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson) values
    (sb,ta,pkg_b,'2026-10-15 12:00Z','completed',true),
    (sb,ta,null,'2026-10-16 12:00Z','scheduled',false),
    (sb,ta,null,'2026-10-17 12:00Z','cancelled',false);
  -- Kyiv month boundaries span the DST change: UTC+3 start, UTC+2 end.
  insert into public.lessons(student_id,teacher_id,scheduled_at,status,consumes_lesson) values
    (sa,ta,'2026-09-30 20:59:59Z','completed',false),
    (sa,ta,'2026-09-30 21:00Z','completed',false),
    (sa,ta,'2026-10-31 21:59:59Z','completed',false),
    (sa,ta,'2026-10-31 22:00Z','completed',false),
    (sa,ta,'2025-12-31 21:59:59Z','completed',false),
    (sa,ta,'2026-12-31 21:59:59Z','completed',false),
    (sa,ta,'2026-12-31 22:00Z','completed',false);
  -- Charge outside October still affects CURRENT balance; used package excluded.
  insert into public.lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson) values
    (sa,ta,pkg,'2025-12-31 22:00Z','completed',true),
    (sa,ta,used_pkg,'2025-08-01 12:00Z','completed',true);
  insert into public.lessons(student_id,teacher_id,scheduled_at,status,consumes_lesson) values
    (sb,ta,'2024-02-29 21:59:59Z','completed',false),
    (sb,ta,'2024-02-29 22:00Z','scheduled',false),
    (sb,ta,'2025-02-28 21:59:59Z','scheduled',false),
    (sb,ta,'2026-04-30 20:59:59Z','completed',false),
    (sb,ta,'2026-04-30 21:00Z','completed',false);
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  execute 'set local role authenticated';
  report := public.admin_lesson_statement('month','2026-10-01');
  assert (report->>'days_in_month')::integer=31;
  assert jsonb_array_length(report->'rows')=2;
  select r into row_a from jsonb_array_elements(report->'rows') r where r->>'student_id'=sa::text;
  select r into row_b from jsonb_array_elements(report->'rows') r where r->>'student_id'=sb::text;
  assert jsonb_array_length(row_a->'teachers')=2;
  assert jsonb_array_length(row_a->'days'->'5')=2;
  assert row_a->'days'->'5'->0->>'status'='completed';
  assert row_a->'days'->'6'->0->>'status'='scheduled';
  assert row_a->'days'->'7'->0->>'status'='in_progress';
  assert row_a->'days'->'8'->0->>'status'='cancelled';
  assert row_a->'days'->'10'->0->>'status'='no_show';
  assert row_a->'days'->'11'->0->>'status'='rescheduled';
  assert row_a->'days'->'12'->0->>'status'='completed';
  assert row_a->'days'->'13'->0->>'series_id'=series_uuid::text;
  assert (row_a->'days'->'20'->0->>'series_occurrence')::integer=2;
  assert row_a->'days'->'1'->0->>'scheduled_at' is not null;
  assert row_a->'days'->'31'->0->>'status'='completed';
  assert not (row_a->'days'->'8'->0 ? 'outcome_note');
  assert (row_a->'totals'->>'completed')::integer=7;
  assert (row_a->'totals'->>'scheduled')::integer=1;
  assert (row_a->'totals'->>'in_progress')::integer=1;
  assert (row_a->'totals'->>'cancelled')::integer=3;
  assert (row_a->'totals'->>'rescheduled')::integer=1;
  assert (row_a->'totals'->>'charged')::integer=5;
  select sum(lessons_remaining)::integer into expected_balance
    from public.package_balances where student_id=sa and status='active';
  assert expected_balance=19;
  assert (row_a->'totals'->>'remaining_now')::integer=expected_balance;
  assert (row_b->'totals'->>'remaining_now')::integer=6;
  assert not (report ? 'remaining_total'); -- Never sum duplicate teacher balances.

  yearly := public.admin_lesson_statement('year','2026-01-01');
  select r into row_a from jsonb_array_elements(yearly->'rows') r where r->>'student_id'=sa::text;
  assert (select count(*)=12 from jsonb_object_keys(row_a->'months'));
  assert row_a->'months'->>'1'='1';
  assert row_a->'months'->>'9'='1';
  assert row_a->'months'->>'10'='7';
  assert row_a->'months'->>'11'='1';
  assert row_a->'months'->>'12'='1';
  assert row_a->'months'->>'2'='0';
  assert (row_a->'totals'->>'completed')::integer=11;
  assert (select sum(value::integer)=11 from jsonb_each_text(row_a->'months'));
  assert (row_a->'totals'->>'remaining_now')::integer=19;
  assert row_a->'days'='{}'::jsonb;

  report := public.admin_lesson_statement('month','2026-10-01',tb);
  assert jsonb_array_length(report->'rows')=1;
  assert report->'rows'->0->'totals'->>'completed'='1';
  assert jsonb_array_length(report->'rows'->0->'teachers')=1;
  assert jsonb_array_length(report->'rows'->0->'days'->'5')=1;
  assert report->'rows'->0->'totals'->>'remaining_now'='19';
  report := public.admin_lesson_statement('year','2026-01-01',tb,sa);
  assert report->'rows'->0->'months'->>'10'='1';
  report := public.admin_lesson_statement('month','2026-10-01',null,sb);
  assert jsonb_array_length(report->'rows')=1;
  assert report->'rows'->0->>'student_id'=sb::text;
  report := public.admin_lesson_statement('month','2026-10-01',null,null,'Teacher B');
  assert report->'rows'->0->'totals'->>'completed'='1';
  report := public.admin_lesson_statement('month','2026-10-01',null,null,'student a');
  assert jsonb_array_length(report->'rows')=1;
  assert report->'rows'->0->'totals'->>'completed'='7';
  report := public.admin_lesson_statement('month','2026-10-01',tb,sb);
  assert report->'rows'='[]'::jsonb;
  assert public.admin_lesson_statement('month','2024-02-01')->>'days_in_month'='29';
  assert public.admin_lesson_statement('month','2025-02-01')->>'days_in_month'='28';
  assert public.admin_lesson_statement('month','2026-04-01')->>'days_in_month'='30';
  assert public.admin_lesson_statement('month','2026-01-01')->>'days_in_month'='31';
  report := public.admin_lesson_statement('month','2024-02-01');
  assert report->'rows'->0->'days'->'29'->0->>'status'='completed';
  assert report->'rows'->0->'totals'->>'scheduled'='0';
  report := public.admin_lesson_statement('month','2025-02-01');
  assert report->'rows'->0->'days'->'28'->0->>'status'='scheduled';
  assert not (report->'rows'->0->'days' ? '29');
  report := public.admin_lesson_statement('month','2026-04-01');
  assert report->'rows'->0->'days'->'30'->0->>'status'='completed';
  assert report->'rows'->0->'totals'->>'completed'='1';
  foreach actor in array array[ta,sa,pending_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);
    rejected := false;
    begin perform public.admin_lesson_statement('month','2026-10-01');
    exception when insufficient_privilege then rejected := true; end;
    assert rejected;
  end loop;
  perform set_config('request.jwt.claim.sub','',true);
  rejected := false;
  begin perform public.admin_lesson_statement('month','2026-10-01');
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
  assert not has_function_privilege('anon','public.admin_lesson_statement(text,date,uuid,uuid,text)','execute');
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  rejected := false;
  begin perform public.admin_lesson_statement('year','2026-10-01');
  exception when invalid_parameter_value then rejected := true; end;
  assert rejected;
  rejected := false;
  begin perform public.admin_lesson_statement('month','2026-10-02');
  exception when invalid_parameter_value then rejected := true; end;
  assert rejected;
  rejected := false;
  begin perform public.admin_lesson_statement('month','2026-10-01',null,null,repeat('x',101));
  exception when invalid_parameter_value then rejected := true; end;
  assert rejected;
  -- The existing detailed journal still paginates and returns internal notes.
  item := public.admin_lesson_journal('2026-10-01',null,sa,'cancelled',null,1,0);
  assert item->>'total'='3' and jsonb_array_length(item->'rows')=1;
  item := public.admin_lesson_journal('2026-10-01',null,sa,'cancelled',null,100,0);
  assert exists(select 1 from jsonb_array_elements(item->'rows') r where r->>'outcome_note'='Internal fixture note');
  execute 'reset role';
  update public.profiles set status='suspended' where id=admin_id;
  rejected := false;
  begin perform public.admin_lesson_statement('month','2026-10-01');
  exception when insufficient_privilege then rejected := true; end;
  assert rejected;
end;
$test$;
rollback;
