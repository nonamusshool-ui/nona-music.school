// Deterministic browser fixtures. Install Playwright outside this static repo,
// then set PLAYWRIGHT_MODULE to its absolute module path. No real API calls.
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const http=require('node:http');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo=path.resolve(__dirname,'../..');
const client=`
const s=globalThis.__billingTest;
export const supabase={from(name){return query(s.tables[name]||[]);},rpc(name,args){
 if(name==='staff_lesson_records')return query(s.lessons);
 if(name==='student_lesson_teacher_names')return Promise.resolve({data:[{teacher_id:'ta',full_name:'Тестовий викладач'}],error:null});
 s.calls.push({name,args});
 if(name==='admin_lesson_statement')return Promise.resolve({data:s.statement,error:null});
 if(name==='admin_lesson_journal')return Promise.resolve({data:s.journal,error:null});
 return Promise.resolve({data:{id:'new',new_id:'new',count:args.occurrence_count||3,covered:4,pending:4,free:0},error:null});}};
function query(rows){let data=[...rows];return {select(){return this;},eq(k,v){data=data.filter(x=>x[k]===v);return this;},in(k,v){data=data.filter(x=>v.includes(x[k]));return this;},gte(k,v){data=data.filter(x=>x[k]>=v);return this;},lt(k,v){data=data.filter(x=>x[k]<v);return this;},neq(k,v){data=data.filter(x=>x[k]!==v);return this;},order(){return this;},limit(){return this;},then(fn){return Promise.resolve({data,error:null}).then(fn);}};}
`;
const harness=`
document.getElementById('private-content').hidden=false;document.getElementById('cabinet-loading').hidden=true;
if(location.pathname.startsWith('/teacher')){const {initTeacher}=await import('./teacher.js?v=13');const {initSchedule}=await import('./schedule.js?v=3');window.openWeek=()=>initSchedule('teacher','ta');initTeacher('ta');}
else if(location.pathname.startsWith('/cabinet')){const {initStudent}=await import('./student.js?v=9');const {initSchedule}=await import('./schedule.js?v=3');initStudent('sa');window.openWeek=()=>initSchedule('student','sa');}
else {const {initAdminJournal}=await import('./admin-journal.js?v=4');initAdminJournal();}
`;
const server=http.createServer((req,res)=>{
 let file=path.join(repo,decodeURIComponent(req.url.split('?')[0]));
 if(!file.startsWith(repo+path.sep)){res.writeHead(403).end();return;}
 if(file.endsWith('supabase-client.js')){res.writeHead(200,{'Content-Type':'application/javascript'}).end(client);return;}
 // Chat transport/auth is outside these deterministic scheduling fixtures.
 if(file.endsWith('chat.js')){res.writeHead(200,{'Content-Type':'application/javascript'}).end('export function initChat() {}');return;}
 if(file.endsWith('dashboard.js')){res.writeHead(200,{'Content-Type':'application/javascript'}).end(harness);return;}
 if(fs.existsSync(file)&&fs.statSync(file).isDirectory())file=path.join(file,'index.html');
 try{res.writeHead(200,{'Content-Type':{'.html':'text/html; charset=utf-8','.js':'application/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png'}[path.extname(file)]||'application/octet-stream'}).end(fs.readFileSync(file));}catch{res.writeHead(404).end();}
});
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const browser=await chromium.launch({channel:process.env.BROWSER_CHANNEL||'msedge',headless:true});
 try{for(const width of [1440,390]){
  const context=await browser.newContext({viewport:{width,height:900}});
  const now=new Date().toISOString();
  const base={student_id:'sa',teacher_id:'ta',scheduled_at:now,duration_minutes:60,status:'scheduled',lesson_format:'online',lesson_url:'https://meet.google.com/test',series_id:null};
  const covered={...base,id:'covered',lesson_id:'covered',package_id:'pkg',consumes_lesson:true,billing_status:'covered'};
  const pending={...base,id:'pending',lesson_id:'pending',package_id:null,consumes_lesson:false,billing_status:'pending'};
  const free={...base,id:'free',lesson_id:'free',package_id:null,consumes_lesson:false,billing_status:'free'};
  const rows=[covered,pending,free].map(x=>({...x,student_name:'Тестовий учень',teacher_name:'Тестовий викладач'}));
  await context.addInitScript(state=>{globalThis.__billingTest=state;},{calls:[],lessons:rows,tables:{
   teacher_students:[{student_id:'sa',teacher_id:'ta',active:true}],profiles:[{id:'sa',full_name:'Тестовий учень',status:'active'},{id:'ta',full_name:'Тестовий викладач',status:'active'}],
   package_balances:[{package_id:'pkg',student_id:'sa',lessons_remaining:4,lessons_purchased:4,status:'active',valid_from:null,valid_until:null}],lessons:rows},
   statement:{days_in_month:31,rows:[],teachers:[],students:[]},journal:{rows,total:3,summary:{scheduled:3},teachers:[],students:[]}});
  const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});page.setDefaultTimeout(10000);
  const root=`http://127.0.0.1:${server.address().port}`;
  await page.goto(root+'/teacher/');
  await page.waitForFunction(()=>document.getElementById('cabinet-status').textContent==='');
  const open=async()=>{await page.locator('#teacher-students').getByRole('button',{name:'Запланувати урок'}).click();await page.waitForFunction(()=>!document.getElementById('teacher-schedule-save').disabled);};
  const fill=async()=>{await page.locator('#teacher-lesson-date').fill('2030-10-22');await page.locator('#teacher-lesson-time').fill('15:00');await page.locator('#teacher-lesson-url').fill('https://meet.google.com/test');await page.locator('#teacher-lesson-weekly').check();await page.locator('#teacher-series-count').fill('8');};
  const save=async()=>{await page.locator('#teacher-schedule-save').click();await page.waitForFunction(()=>!document.getElementById('teacher-schedule-dialog').open);};
  await open();await fill();assert.equal(await page.locator('#teacher-lesson-consumes').isChecked(),true);assert.match(await page.locator('#teacher-package-warning').textContent(),/залишилось 4/);await save();
  assert.equal((await page.evaluate(()=>__billingTest.calls.at(-1))).name,'teacher_schedule_lesson_series');assert.match(await page.locator('#cabinet-status').textContent(),/Покрито пакетом: 4; очікує оплати: 4/);
  await page.evaluate(()=>{__billingTest.tables.package_balances=[];});await open();await fill();assert.equal(await page.locator('#teacher-lesson-consumes').isChecked(),true);await save();let call=await page.evaluate(()=>__billingTest.calls.at(-1));assert.equal(call.args.target_package_id,null);assert.equal(call.args.takes_package_lesson,true);
  await open();await fill();await page.locator('#teacher-lesson-consumes').uncheck();assert.match(await page.locator('#teacher-package-warning').textContent(),/Безкоштовне заняття/);await save();assert.equal((await page.evaluate(()=>__billingTest.calls.at(-1))).args.takes_package_lesson,false);
  await page.evaluate(()=>{__billingTest.tables.package_balances=[{package_id:'pkg',student_id:'sa',lessons_remaining:0,lessons_purchased:4,status:'active',valid_until:'2028-01-01'}];});await open();await fill();await save();assert.equal((await page.evaluate(()=>__billingTest.calls.at(-1))).args.takes_package_lesson,true);
  await page.evaluate(()=>window.openWeek());await page.locator('.schedule-lesson').first().waitFor();
  for(const [index,label] of ['Пакет · буде списано після проведення','Очікує оплати','Безкоштовне заняття'].entries()){
   await page.locator('.schedule-lesson').nth(index).click();assert.match(await page.locator('#schedule-details').textContent(),new RegExp(label));await page.locator('#schedule-details-close').click();
  }
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  await page.goto(root+'/cabinet/');await page.waitForFunction(()=>typeof window.openWeek==='function');await page.evaluate(()=>window.openWeek());await page.locator('.schedule-lesson').first().waitFor();assert.equal(await page.locator('.schedule-lesson').count(),3);await page.locator('.schedule-lesson').nth(1).click();assert.match(await page.locator('#schedule-details').textContent(),/Очікує оплати/);await page.locator('#schedule-details-close').click();
  await page.goto(root+'/admin/');await page.waitForFunction(()=>__billingTest.calls.some(x=>x.name==='admin_lesson_statement'));await page.locator('#journal-tab-records').click();await page.locator('#journal-body tr').first().waitFor();assert.match(await page.locator('#journal-body').textContent(),/Очікує оплати/);assert.match(await page.locator('#journal-body').textContent(),/Безкоштовне заняття/);
  assert.deepEqual(errors,[]);console.log(`PASS ${width}px: 4/8, zero balance, expired dates, explicit free, persisted billing labels, student pending visibility, journal and no runtime errors.`);await context.close();
 }}finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);server.close();process.exitCode=1;});
