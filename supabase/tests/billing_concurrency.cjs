// Node built-ins + psql, no npm dependencies. Isolated LOCAL test database only.
// PSQL_BINARY=/path/psql NONA_TEST_DATABASE_URL=postgresql://.../nona_test node ...
const { execFileSync, spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const assert = require('node:assert/strict');
const url = process.env.NONA_TEST_DATABASE_URL;
if (!url) throw new Error('Set NONA_TEST_DATABASE_URL to an isolated local *_test database');
const target = new URL(url);
if (!['127.0.0.1', 'localhost', '[::1]'].includes(target.hostname) || !target.pathname.endsWith('_test')) {
  throw new Error('This test refuses non-local/non-test databases');
}
const psql = process.env.PSQL_BINARY || 'psql';
const args = ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', url];
const sql = (query) => execFileSync(psql, args, { input: query, encoding: 'utf8', windowsHide: true }).trim();
const run = (query) => new Promise((resolve, reject) => {
  const child = spawn(psql, args, { windowsHide: true });
  let error = '';
  child.stderr.on('data', (chunk) => { error += chunk; });
  child.on('error', reject);
  child.on('close', (code) => code ? reject(new Error(error)) : resolve());
  child.stdin.end(query);
});
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const [admin, teacher, student, pack] = Array.from({ length: 4 }, randomUUID);
const ids = [admin, teacher, student].map((id) => `'${id}'`).join(',');
const setup = `begin;
insert into auth.users(id) values('${admin}'),('${teacher}'),('${student}');
update profiles set role='admin',status='active',can_teach=true,admin_level='senior' where id='${admin}';
update profiles set role='teacher',status='active' where id='${teacher}';
update profiles set role='student',status='active' where id='${student}';
insert into teacher_students(teacher_id,student_id) values('${teacher}','${student}');
insert into lessons(student_id,teacher_id,scheduled_at,status,billing_status,consumes_lesson)
 select '${student}','${teacher}',now()+n*interval '7 days','scheduled','pending',false from generate_series(1,8) n;
insert into lesson_packages(id,student_id,lessons_purchased,status) values('${pack}','${student}',4,'expired');
commit;`;
(async () => {
  try {
    sql(setup);
    // A activation holds the ordering gate before any package tuple lock. B is
    // a simultaneous allocation attempt against that SAME package/student.
    const a = run(`begin; set local application_name='nona-billing-test-a'; set local statement_timeout='5s';
      update lesson_packages set status='active' where id='${pack}'; select pg_sleep(1.5); commit;`);
    let sleeping = false;
    for (let i = 0; i < 50; i++) {
      if (sql("select exists(select 1 from pg_stat_activity where application_name='nona-billing-test-a' and wait_event='PgSleep')") === 't') { sleeping = true; break; }
      await wait(20);
    }
    assert.ok(sleeping, 'Concurrent session A did not reach its synchronization point');
    const b = run(`begin; set local application_name='nona-billing-test-b'; set local statement_timeout='5s';
      select private.allocate_pending_lessons('${student}','${pack}'); commit;`);
    let blocked = false;
    for (let i = 0; i < 20; i++) {
      if (sql("select exists(select 1 from pg_stat_activity where application_name='nona-billing-test-b' and wait_event='advisory')") === 't') { blocked = true; break; }
      await wait(20);
    }
    await Promise.all([a, b]);
    assert.ok(blocked, 'Test must observe actual overlapping transactions/lock wait');
    assert.equal(sql(`select count(*) from lessons where student_id='${student}' and billing_status='covered'`), '4');
    assert.equal(sql(`select count(*) from lessons where student_id='${student}' and billing_status='pending'`), '4');
    assert.equal(sql(`select bool_and(covered) from (select billing_status='covered' covered from lessons where student_id='${student}' order by scheduled_at,id limit 4) s`), 't');
    console.log('PASS: two overlapping allocation transactions, real advisory wait, exactly oldest 4 covered / 4 pending.');
    await Promise.all(Array.from({ length: 8 }, () => run(`select private.allocate_pending_lessons('${student}','${pack}');`)));
    assert.equal(sql(`select private.package_committed_slots('${pack}')`), '4');
    // Two supported admin purchase RPCs also serialize; no shared lesson can
    // be allocated twice. Remaining capacity is real and not future usage.
    await Promise.all([1, 2].map(() => run(`begin; set local statement_timeout='5s';
      select set_config('request.jwt.claim.sub','${admin}',true); set local role authenticated;
      select public.admin_create_lesson_package('${student}',2); commit;`)));
    assert.equal(sql(`select count(*) from lessons where student_id='${student}' and billing_status='covered'`), '8');
    assert.equal(sql(`select bool_and(private.package_committed_slots(id)<=lessons_purchased) from lesson_packages where student_id='${student}'`), 't');
    assert.equal(sql(`select sum(lessons_purchased) from lesson_packages where student_id='${student}'`), '8');
    assert.equal(sql(`select count(*) from lessons where student_id='${student}' and status='completed'`), '0');
    console.log('PASS: 8 racing retries + 2 concurrent admin purchases, no over-allocation/deadlock or schedule consumption.');
  } finally {
    sql(`begin; delete from lessons where student_id='${student}'; delete from lesson_series where student_id='${student}';
      delete from lesson_packages where student_id='${student}'; delete from teacher_students where student_id='${student}';
      delete from profiles where id in (${ids}); delete from auth.users where id in (${ids}); commit;`);
  }
})().catch((error) => { console.error(error.message); process.exitCode = 1; });
