-- Isolated Supabase/PostgreSQL test database only. Random fixtures; no real data.
begin;
set local plpgsql.check_asserts=on;
do $test$
declare
  adm uuid:=gen_random_uuid(); t uuid:=gen_random_uuid(); other_t uuid:=gen_random_uuid();
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); d uuid:=gen_random_uuid();
  outsider uuid:=gen_random_uuid(); pending_user uuid:=gen_random_uuid();
  pa uuid:=gen_random_uuid(); pb uuid:=gen_random_uuid(); pc uuid:=gen_random_uuid(); pd uuid:=gen_random_uuid();
  base_day date:=current_date+28;
  r jsonb; series_a uuid; series_b uuid; series_c uuid; series_d uuid;
  first_id uuid; old_id uuid; new_id uuid; free_id uuid; new_pkg uuid; rejected boolean;
  planned integer; balance integer; preserved jsonb;
begin
  insert into auth.users(id) values(adm),(t),(other_t),(a),(b),(c),(d),(outsider),(pending_user);
  insert into public.profiles(id,role,status,can_teach,admin_level) values
    (adm,'admin','active',true,'senior'),(t,'teacher','active',false,null),
    (other_t,'teacher','active',false,null),(a,'student','active',false,null),
    (b,'student','active',false,null),(c,'student','active',false,null),
    (d,'student','active',false,null),(outsider,'student','active',false,null)
    on conflict(id) do update set role=excluded.role,status=excluded.status,
      can_teach=excluded.can_teach,admin_level=excluded.admin_level;
  insert into public.teacher_students(teacher_id,student_id) values(t,a),(t,b),(t,c),(t,d);
  insert into public.lesson_packages(id,student_id,lessons_purchased,status,valid_from,valid_until) values
    (pa,a,8,'active',null,null),(pb,b,1,'active',null,null),
    (pc,c,8,'active',null,null),(pd,d,8,'active',base_day,base_day+14);
  insert into public.lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson)
    values(b,t,pb,now()-interval '3 days','completed',true);
  -- Four of eight purchased lessons already consumed: exactly four remain.
  insert into public.lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson)
    select a,t,pa,now()-n*interval '7 days','completed',true from generate_series(1,4) n;
  perform set_config('request.jwt.claim.sub',t::text,true);
  execute 'set local role authenticated';
  r:=public.teacher_schedule_lesson_series(a,base_day,'10:00',60,'online','https://meet.google.com/test',null,pa,true,8);
  series_a:=(r->>'series_id')::uuid;
  assert r->>'count'='8' and r->>'covered'='4' and r->>'pending'='4';
  assert (select count(*)=8 from public.lessons where series_id=series_a);
  assert (select bool_and(billing_status='covered' and consumes_lesson and package_id=pa)
    from public.lessons where series_id=series_a and series_occurrence<=4);
  assert (select bool_and(billing_status='pending' and not consumes_lesson and package_id is null)
    from public.lessons where series_id=series_a and series_occurrence>4);
  assert (select lessons_remaining=4 from public.package_balances where package_id=pa);
  r:=public.teacher_schedule_lesson_series(b,base_day,'12:00',60,'online','https://meet.google.com/test',null,pb,true,8);
  series_b:=(r->>'series_id')::uuid;
  assert r->>'covered'='0' and r->>'pending'='8';
  r:=public.teacher_schedule_lesson_series(c,base_day,'14:00',60,'online','https://meet.google.com/test',null,pc,true,8);
  series_c:=(r->>'series_id')::uuid;
  assert r->>'covered'='8' and r->>'pending'='0';
  assert (select lessons_remaining=8 from public.package_balances where package_id=pc);
  r:=public.teacher_schedule_lesson_series(d,base_day,'16:00',60,'online','https://meet.google.com/test',null,pd,true,8);
  series_d:=(r->>'series_id')::uuid;
  assert r->>'covered'='3' and r->>'pending'='5';
  r:=public.teacher_schedule_lesson(a,base_day+1,'10:00',60,'online','https://meet.google.com/test',null,null,false);
  free_id:=(r->>'id')::uuid;
  assert r->>'billing_status'='free';
  assert (select billing_status='free' and package_id is null and not consumes_lesson from public.lessons where id=free_id);

  -- Covered occurrence reschedule keeps one reservation and preserves history.
  select id into old_id from public.lessons where series_id=series_a and series_occurrence=1;
  r:=public.teacher_reschedule_lesson(old_id,base_day+2,'10:00',60,'online','https://meet.google.com/test',null,pa,true);
  new_id:=(r->>'new_id')::uuid;
  assert (select billing_status='covered' and package_id=pa and consumes_lesson from public.lessons where id=new_id);
  assert (select status='rescheduled' and package_id=pa and not consumes_lesson from public.lessons where id=old_id);
  assert r=public.teacher_reschedule_lesson(old_id,base_day+2,'10:00',60,'online','https://meet.google.com/test',null,pa,true);
  -- Pending reschedule and no-op guard work with paid intent + no package.
  select id into old_id from public.lessons where series_id=series_b and series_occurrence=1;
  rejected:=false;
  begin perform public.teacher_reschedule_lesson(old_id,base_day,'12:00',60,'online','https://meet.google.com/test',null,null,true);
  exception when invalid_parameter_value then rejected:=true; end;
  assert rejected;
  r:=public.teacher_reschedule_lesson(old_id,base_day+2,'12:00',60,'online','https://meet.google.com/test',null,null,true);
  assert (select billing_status='pending' and not consumes_lesson from public.lessons where id=(r->>'new_id')::uuid);
  -- Bulk edits preserve mixed coverage and a finite series.
  select id into first_id from public.lessons where series_id=series_a and series_occurrence=2 and status='scheduled';
  r:=public.teacher_update_lesson_series_from(first_id,base_day+8,'10:00',60,'online','https://meet.google.com/test',null,pa,true);
  assert r->>'count'='7';
  assert (select count(*)=4 from public.lessons where series_id=series_a and billing_status='covered' and status='scheduled');
  assert (select count(*)=4 from public.lessons where series_id=series_a and billing_status='pending' and status='scheduled');

  perform set_config('request.jwt.claim.sub',adm::text,true);
  r:=public.admin_create_lesson_package(a,4);
  new_pkg:=(r->>'package_id')::uuid;
  assert (select count(*)=4 from public.lessons where package_id=new_pkg and billing_status='covered');
  assert (select min(series_occurrence)=5 and max(series_occurrence)=8 from public.lessons where package_id=new_pkg);
  assert (select lessons_remaining=4 from public.package_balances where package_id=new_pkg);
  assert (select billing_status='free' and package_id is null from public.lessons where id=free_id);
  -- Admin emergency flow can plan a paid lesson without any available package.
  r:=public.admin_schedule_lesson(b,t,base_day+3,'12:00',60,null,'https://meet.google.com/test',true);
  assert r->>'billing_status'='pending';
  -- Direct activation runs the same deferred allocator, not a frontend-only hook.
  execute 'reset role';
  insert into public.lesson_packages(student_id,lessons_purchased,status) values(b,4,'expired') returning id into new_pkg;
  update public.lesson_packages set status='active' where id=new_pkg;
  set constraints all immediate;
  set constraints all deferred;
  assert (select count(*)=4 from public.lessons where package_id=new_pkg and consumes_lesson);
  assert (select bool_and(student_id=b) from public.lessons where package_id=new_pkg);
  assert (select min(scheduled_at) from public.lessons where package_id=new_pkg)
    < (select min(scheduled_at) from public.lessons where student_id=b and billing_status='pending'
      and status in ('scheduled','in_progress','completed'));

  -- Pending completed lessons can be paid later; pending cancellations/no_show
  -- are not retroactively charged. Free lessons remain free after finalization.
  insert into public.lessons(student_id,teacher_id,scheduled_at,status,consumes_lesson,billing_status)
    values(d,t,now()-interval '2 days','scheduled',false,'pending') returning id into old_id;
  insert into public.lessons(student_id,teacher_id,scheduled_at,status,consumes_lesson,billing_status)
    values(d,t,now()-interval '3 days','scheduled',false,'free') returning id into free_id;
  perform private.finalize_due_lessons();
  assert (select status='completed' and billing_status='pending' and not consumes_lesson from public.lessons where id=old_id);
  assert (select status='completed' and billing_status='free' and not consumes_lesson from public.lessons where id=free_id);
  select sum(lessons_remaining) into balance from public.package_balances where student_id=d and status='active';
  perform set_config('request.jwt.claim.sub',adm::text,true);
  r:=public.admin_create_lesson_package(d,1);
  assert (select billing_status='covered' and consumes_lesson and package_id=(r->>'package_id')::uuid from public.lessons where id=old_id);
  assert (select lessons_remaining=0 from public.package_balances where package_id=(r->>'package_id')::uuid);
  assert (select billing_status='free' and package_id is null from public.lessons where id=free_id);

  -- Existing lifecycle: completed, charged/uncharged cancellation, no_show.
  perform set_config('request.jwt.claim.sub',t::text,true);
  select id into old_id from public.lessons where series_id=series_c and series_occurrence=1;
  perform public.teacher_start_lesson(old_id);
  perform public.teacher_resolve_lesson(old_id,'completed');
  assert private.package_lessons_used(pc)=1;
  select id into old_id from public.lessons where series_id=series_c and series_occurrence=2;
  perform public.teacher_resolve_lesson(old_id,'cancelled','student_no_show',null,true);
  assert private.package_lessons_used(pc)=2;
  select id into old_id from public.lessons where series_id=series_c and series_occurrence=3;
  perform public.teacher_resolve_lesson(old_id,'cancelled','cancelled_in_advance',null,false);
  assert private.package_lessons_used(pc)=2;
  update public.lessons set status='no_show',resolved_at=now() where series_id=series_c and series_occurrence=4;
  assert private.package_lessons_used(pc)=2;

  -- Ownership/auth/RLS and protected comments are unchanged.
  execute 'set local role authenticated';
  rejected:=false;
  begin perform public.teacher_schedule_lesson(a,base_day+4,'10:00',60,'online','https://meet.google.com/test',null,pc,true);
  exception when invalid_parameter_value then rejected:=true; end;
  assert rejected;
  perform set_config('request.jwt.claim.sub',other_t::text,true);
  rejected:=false;
  begin perform public.teacher_schedule_lesson_series(a,base_day+5,'10:00',60,'online','https://meet.google.com/test',null,null,true,8);
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected;
  perform set_config('request.jwt.claim.sub',a::text,true);
  assert (select count(*)>0 from public.lessons where student_id=a);
  assert not exists(select 1 from public.lessons where student_id=b);
  perform set_config('request.jwt.claim.sub',b::text,true);
  assert (select count(*)>0 from public.lessons where billing_status='pending' and status='scheduled');
  perform set_config('request.jwt.claim.sub',a::text,true);
  rejected:=false;
  begin perform public.teacher_schedule_lesson_series(a,base_day+5,'10:00',60,'online','https://meet.google.com/test',null,null,true,8);
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected;
  rejected:=false;
  begin perform outcome_note from public.lessons limit 1;
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected;
  rejected:=false;
  begin perform * from public.staff_lesson_records();
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected;
  assert not has_function_privilege('authenticated','private.allocate_pending_lessons(uuid,uuid)','execute');
  assert not has_function_privilege('anon','public.teacher_schedule_lesson_series(uuid,date,time,integer,text,text,text,uuid,boolean,integer)','execute');
  execute 'reset role';
end;
$test$;
rollback;
