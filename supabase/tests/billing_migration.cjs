// Replay repository migrations in a throwaway LOCAL database and verify backfill.
// Uses Node built-ins + psql. Requires a local superuser/test server (CREATE DB).
const fs=require('node:fs');const path=require('node:path');const cp=require('node:child_process');
const assert=require('node:assert/strict');const {randomUUID}=require('node:crypto');
const url=new URL(process.env.NONA_TEST_DATABASE_URL || 'invalid:');
if(!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||!url.pathname.endsWith('_test')){
  throw new Error('Set NONA_TEST_DATABASE_URL to an isolated LOCAL *_test database');
}
const psql=process.env.PSQL_BINARY || 'psql';const root=path.resolve(__dirname,'../..');
const dbName=`nona_upgrade_${randomUUID().replaceAll('-','')}_test`;
const run=(query,database=dbName)=>{
  const connection=new URL(url);connection.pathname='/'+database;
  return cp.execFileSync(psql,['-X','-qAt','-v','ON_ERROR_STOP=1','-d',connection.href],{
    input:query,encoding:'utf8',windowsHide:true,env:{...process.env,PGCLIENTENCODING:'UTF8'},
  }).trim();
};
let created=false;
try{
  run('create database '+dbName,'postgres');created=true;
  run(`create schema auth;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}',raw_app_meta_data jsonb default '{}',created_at timestamptz default now(),last_sign_in_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create function public.rls_auto_enable() returns event_trigger language plpgsql as $$begin return;end;$$;
    grant usage on schema auth,public to anon,authenticated,service_role;
    grant execute on function auth.uid() to anon,authenticated,service_role;`);
  const directory=path.join(root,'supabase/migrations');const files=fs.readdirSync(directory).filter(x=>x.endsWith('.sql')).sort();
  const target=files.find(x=>x.endsWith('_separate_schedule_from_billing.sql'));assert.ok(target);
  for(const file of files.filter(x=>x<target&&!x.includes('schedule_due_lesson_finalization'))){
    run('begin;'+fs.readFileSync(path.join(directory,file),'utf8')+';commit;');
  }
  run(`do $$ declare t uuid:=gen_random_uuid();s uuid:=gen_random_uuid();p uuid:=gen_random_uuid();begin
    insert into auth.users(id) values(t),(s);update profiles set role='teacher',status='active' where id=t;
    update profiles set role='student',status='active' where id=s;
    insert into teacher_students(teacher_id,student_id) values(t,s);
    insert into lesson_packages(id,student_id,lessons_purchased) values(p,s,50);
    insert into lessons(student_id,teacher_id,package_id,scheduled_at,status,consumes_lesson,resolved_at)
    select s,t,case when has_package then p else null end,now()-interval '100 days'+n*interval '1 day',st,takes,now()-interval '99 days'
    from unnest(array['scheduled','in_progress','completed','cancelled','no_show','rescheduled']) with ordinality x(st,n)
    cross join unnest(array[true,false]) y(takes) cross join unnest(array[true,false]) z(has_package);
    end;$$;`);
  const teacher=run("select id from profiles where role='teacher'");
  const snapshot=()=>JSON.parse(run(`set request.jwt.claim.sub='${teacher}';
    select jsonb_build_object(
      'lessons',(select jsonb_agg(to_jsonb(l)-'billing_status' order by id) from lessons l),
      'balances',(select jsonb_agg(to_jsonb(b) order by package_id) from package_balances b),
      'policies',(select jsonb_agg(to_jsonb(p) order by schemaname,tablename,policyname) from pg_policies p),
      'acl',(select jsonb_agg(jsonb_build_object('name',p.proname,'acl',p.proacl::text) order by p.proname)
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='private' and p.proname in ('current_role','is_admin','is_teacher_of','package_lessons_used')))::text;`));
  const before=snapshot();assert.equal(before.lessons.length,24);assert.equal(before.balances[0].lessons_used,2);
  run('begin;'+fs.readFileSync(path.join(directory,target),'utf8')+';commit;');
  assert.deepEqual(snapshot(),before);
  assert.equal(run("select bool_and(billing_status=case when package_id is null then 'free' else 'covered' end) from lessons"),'t');
  console.log('PASS: upgrade preserves all 24 historical combinations, timestamps, actual balances, RLS policies and policy-helper ACLs.');
}finally{if(created)run('drop database '+dbName,'postgres');}
