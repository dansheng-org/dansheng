// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { schedule, tick, stop, reconcile, visibleLogin, cancelAppointment, DEFAULT_OPTIONS } from '../main.mjs';
import { validatePlan, classify } from '../policy.mjs';
import { request, launchFields, PATHS } from '../api.mjs';

const RELEASE = Date.parse('2031-01-02T07:00:01+08:00');
const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url), 'utf8'));
function plan(extra = {}) { return { task_id: 'fixture-task', account_id: 'fixture-a', venue_id: 900,
  target_date: '2031-01-04', release_at: '2031-01-02T07:00:01+08:00',
  plans: [{ time: '10:00-11:00', period_id: 70, courts: [901, 902] }], ...extra }; }
function mock() {
  const store = new Map(), calls = [], jobs = [];
  const m = { store, calls, jobs, now: RELEASE - 70000, writes: [], history: [], reply: { e: 1, m: '容量不足' }, calendarFails: false,
    grants: new Set(manifest.capabilities), persistedJobs: new Map() };
  m.ctx = {
    storage: { get: async ({key}) => store.has(key) ? structuredClone(store.get(key)) : null,
      set: async ({key,value}) => { store.set(key, structuredClone(value)); }, delete: async ({key}) => store.delete(key) },
    browser: {
      evaluate: async p => { calls.push(p); if (m.desktop) throw Object.assign(new Error('missing'), {code:'CapabilityUnavailable'});
        return { account_id: p.account_id, authenticated: !m.noAuth, session_handle: 'opaque-fixture-session' }; },
      request: async p => {
        if (!m.grants.has('browser.request') || (p.method === 'POST' && !m.grants.has('browser.write'))) throw Object.assign(new Error('denied'), {code:'PermissionDenied'});
        calls.push(p);
        if (p.method === 'POST') { m.writes.push(p); if (m.writeError) throw Object.assign(new Error('masked'), { code: m.writeError }); }
        let body = p.method === 'POST' ? m.reply : {e:0,d:{time:[{id:71,str_time:'10:00-11:00'}],resource:[]}};
        if (p.url.includes('calendar') && m.calendarFails) throw Object.assign(new Error('calendar unavailable'), {code:'Http503'});
        if (p.url.includes('appointment-list') || p.url.includes('appointmentList')) body = {e:0,d:{data:m.history}};
        if (m.onRequest) await m.onRequest(p);
        return { status: 200, url:p.url, body:JSON.stringify(body) };
      }
    },
    jobs: { schedule: async p => {
      jobs.push(structuredClone(p));
      const key=JSON.stringify([p.plugin_id,p.action,p.input,p.interval_seconds]);
      if(!m.persistedJobs.has(key))m.persistedJobs.set(key,'job-'+(m.persistedJobs.size+1));
      if(m.scheduleErrorOnce){m.scheduleErrorOnce=false;throw Object.assign(new Error('synthetic lost enqueue response'),{code:'LocalTimeout'})}
      if(m.onSchedule)await m.onSchedule(structuredClone(p));
      return {job_id:m.persistedJobs.get(key)};
    }, cancel: async p => { calls.push(p); } },
    ui: { publish: async p => { calls.push(p); } }, sources: { upsert: async () => {} },
  };
  return m;
}
async function time(m, f) { const old = Date.now; Date.now = () => m.now; try { return await f(); } finally { Date.now = old; } }
const state = m => m.store.get('task:fixture-a:fixture-task');
const step = m => tick(m.ctx,structuredClone(m.jobs.at(-1).input));

test('retains all original timing defaults, explicit Shanghai epoch and no raw passwords', async () => {
  const m=mock(); const result=await time(m,()=>schedule(m.ctx,plan({password:'never-forward'})));
  assert.equal(DEFAULT_OPTIONS.nativePrewarmMs,300000); assert.equal(DEFAULT_OPTIONS.browserPreloadMs,60000);
  assert.equal(DEFAULT_OPTIONS.firstShotDelayMs,300); assert.equal(DEFAULT_OPTIONS.windowMs,300000);
  assert.equal(Date.parse(result.native_wake_at),RELEASE-300000);
  assert.equal(Date.parse(m.jobs[0].run_at),RELEASE-60000);
  assert.equal(JSON.stringify([...m.store.values(),m.calls]).includes('never-forward'),false);
});
test('desktop missing capability and unauthenticated sessions never issue HTTP or writes', async () => {
  const m=mock(); m.desktop=true;
  await assert.rejects(time(m,()=>schedule(m.ctx,plan())), {code:'CapabilityUnavailable'});
  m.desktop=false;m.noAuth=true;
  await assert.rejects(time(m,()=>schedule(m.ctx,plan())), {code:'AuthenticationRequired'});
  assert.equal(m.writes.length,0);
  await visibleLogin(m.ctx,{account_id:'fixture-a'});
  assert.equal(m.calls.at(-1).operation,'session.requireLogin');
});
test('preload, 300ms first shot, latest period ID, XHR FormData and sign-key', async () => {
  const m=mock(); await time(m,()=>schedule(m.ctx,plan()));
  m.now=RELEASE-60000; await time(m,()=>step(m)); assert.equal(m.writes.length,0);
  assert.equal(Date.parse(m.jobs.at(-1).run_at),RELEASE+300);
  m.now=RELEASE+299; await time(m,()=>step(m)); assert.equal(m.writes.length,0);
  m.now=RELEASE+300; await time(m,()=>step(m));
  const w=m.writes[0]; assert.equal(w.transport,'xhr'); assert.equal(w.headers['sign-key'],PATHS.launch+'post');
  assert.equal(w.session_handle,'opaque-fixture-session'); assert.ok(w.mutation_key);
  const data=JSON.parse(w.form_fields.data)[0]; assert.deepEqual(data.resource_ids,[901]); assert.equal(data.period[0].period_id,71);
});
test('ordered courts, 1200ms round pause and 800ms throttle delay', async () => {
  const m=mock();m.now=RELEASE+300;await time(m,()=>schedule(m.ctx,plan()));
  await time(m,()=>step(m));await time(m,()=>step(m));
  assert.deepEqual(m.writes.map(w=>JSON.parse(w.form_fields.data)[0].resource_ids[0]),[901,902]);
  assert.equal(Date.parse(m.jobs.at(-1).run_at),m.now+1200);
  m.reply={e:1,m:'请求频繁'};await time(m,()=>step(m));
  assert.equal(Date.parse(m.jobs.at(-1).run_at),m.now+800);
});
test('not-open advances period but remains retryable; existing reservation is terminal', async () => {
  const m=mock();m.now=RELEASE+300;m.reply={e:1,m:'未开放'};await time(m,()=>schedule(m.ctx,plan()));
  await time(m,()=>step(m));assert.equal(state(m).round,2);assert.equal(state(m).status,'running');
  m.reply={e:1,m:'已有未结束的预约'};await time(m,()=>step(m));assert.equal(state(m).status,'existingReservation');
  const n=m.writes.length;await time(m,()=>step(m));assert.equal(m.writes.length,n);
});
test('success removes the time slot and partial successes survive subsequent ticks', async () => {
  const m=mock();m.now=RELEASE+300;m.reply={e:0};await time(m,()=>schedule(m.ctx,plan()));
  await time(m,()=>step(m));assert.equal(state(m).status,'completed');assert.equal(state(m).successes.length,1);
  await time(m,()=>step(m));assert.equal(m.writes.length,1);
});
test('saved period remains usable if calendar unavailable; strict deadline blocks writes', async () => {
  const m=mock();m.calendarFails=true;m.now=RELEASE+300;await time(m,()=>schedule(m.ctx,plan()));
  await time(m,()=>step(m));assert.equal(JSON.parse(m.writes[0].form_fields.data)[0].period[0].period_id,70);
  m.now=RELEASE+300000;await time(m,()=>step(m));assert.equal(m.writes.length,1);assert.equal(state(m).status,'expired');
});
test('write timeout journals uncertainty; retry/restart cannot issue another write', async () => {
  const m=mock();m.now=RELEASE+300;await time(m,()=>schedule(m.ctx,plan()));m.writeError='BrowserRequestFailed';
  await assert.rejects(time(m,()=>step(m)), {code:'NeedsReconciliation'});
  assert.ok(m.calls.some(c => c.url && c.url.includes('appointment-list')));
  assert.ok(state(m).pending);assert.equal(state(m).status,'needs_reconciliation');
  await assert.rejects(time(m,()=>step(m)),{code:'NeedsReconciliation'});assert.equal(m.writes.length,1);
  await assert.rejects(time(m,()=>reconcile(m.ctx,plan())),{code:'NeedsReconciliation'});assert.equal(m.writes.length,1);
  m.history=[{id:30,status:1,slots:[{date:'2031-01-04',str_time:'10:00-11:00',resource_id:901,status:1}]}];
  const r=await time(m,()=>reconcile(m.ctx,plan()));assert.equal(r.status,'reconciled_requires_user_resume');assert.equal(m.writes.length,1);
  assert.equal((await time(m,()=>step(m))).status,'reconciled_requires_user_resume');assert.equal(m.writes.length,1);
});
test('local stop and stop during in-flight write never enqueue another retry', async () => {
  const m=mock();m.now=RELEASE+300;await time(m,()=>schedule(m.ctx,plan()));
  m.onRequest=async p=>{if(p.method==='POST')await stop(m.ctx,plan());};
  const n=m.jobs.length;await time(m,()=>step(m));assert.equal(state(m).status,'stopped');assert.equal(m.jobs.length,n);
});
test('account-scoped records, conflict limits, malformed plans and offset-less time rejected', async () => {
  const m=mock();await time(m,()=>schedule(m.ctx,plan()));
  await assert.rejects(time(m,()=>schedule(m.ctx,plan({task_id:'conflict'}))),{code:'TimeConflict'});
  await assert.rejects(time(m,()=>tick(m.ctx,{account_id:'fixture-b',task_id:'fixture-task'})),{code:'TaskNotFound'});
  assert.throws(()=>validatePlan(plan({release_at:'2031-01-02T07:00:01'})),{code:'InvalidReleaseTime'});
  assert.throws(()=>validatePlan(plan({target_date:'2031-02-30'})));
  assert.throws(()=>validatePlan(plan({plans:[{time:'x',courts:[]}]})),{code:'InvalidPlan'});
  assert.throws(()=>validatePlan(plan({options:{firstShotDelayMs:300000}})),{code:'InvalidOptions'});
});
test('write 412/HTML is uncertain; GET WAF response requires visible recovery', async () => {
  const m=mock();m.ctx.browser.request=async()=>({status:412,body:'WAF',url:'https://booking.fudan.edu.cn/'});
  await assert.rejects(request(m.ctx,plan(),PATHS.launch,launchFields(plan(),70,901)),{code:'NeedsReconciliation'});
  await assert.rejects(request(m.ctx,plan(),PATHS.venues),{code:'WafChallengeRequired'});
  assert.equal(classify({e:1,m:'已满'}),'gone');assert.equal(classify({e:0}),'success');
});
test('cancellation re-reads flags; third-party uses dedicated endpoint and uncertainty blocks resend', async () => {
  const m=mock();m.history=[{id:30,type:7,slots:[]}];m.reply={e:0};
  await time(m,()=>cancelAppointment(m.ctx,{account_id:'fixture-a',appointment_id:30}));
  assert.ok(m.writes[0].url.endsWith(PATHS.thirdPartyCancel));
  await assert.rejects(cancelAppointment(m.ctx,{account_id:'fixture-a',appointment_id:30}),{code:'NeedsReconciliation'});
});
test('host uncertainty is preserved when core immediately closes the job lease', async () => {
  const m=mock();m.now=RELEASE+300;await time(m,()=>schedule(m.ctx,plan()));
  const original=Object.assign(new Error('generic host message'),{code:'NeedsReconciliation'});
  let closed=false;
  const get=m.ctx.storage.get, set=m.ctx.storage.set;
  m.ctx.storage.get=async p=>{if(closed)throw Object.assign(new Error('closed'),{code:'Cancelled'});return get(p)};
  m.ctx.storage.set=async p=>{if(closed)throw Object.assign(new Error('closed'),{code:'Cancelled'});return set(p)};
  const browserRequest=m.ctx.browser.request;
  m.ctx.browser.request=async p=>{if(p.method==='POST'){m.writes.push(p);closed=true;throw original}return browserRequest(p)};
  await assert.rejects(time(m,()=>step(m)), e=>e===original && e.code==='NeedsReconciliation');
  assert.ok(state(m).pending);assert.equal(m.writes.length,1);
  closed=false;
  await assert.rejects(time(m,()=>reconcile(m.ctx,plan())),{code:'NeedsReconciliation'});
  assert.ok(m.calls.some(c=>c.url&&c.url.includes('appointment-list')));assert.equal(m.writes.length,1);
});
test('manifest declares separate browser.write and read-only grant cannot submit POST', async () => {
  assert.ok(manifest.capabilities.includes('browser.write'));
  const m=mock();m.grants.delete('browser.write');
  await request(m.ctx,plan(),PATHS.venues);
  await assert.rejects(request(m.ctx,plan(),PATHS.launch,launchFields(plan(),70,901)),{code:'PermissionDenied'});
  assert.equal(m.writes.length,0);
});
test('monotonic tick inputs distinguish transitions and stale sequences cannot run', async () => {
  const m=mock();await time(m,()=>schedule(m.ctx,plan()));
  const first=structuredClone(m.jobs[0].input);assert.equal(first.sequence,1);
  m.now=RELEASE-60000;await time(m,()=>tick(m.ctx,first));
  assert.equal(m.jobs.at(-1).input.sequence,2);assert.equal(state(m).sequence,2);
  assert.equal(m.persistedJobs.size,2);
  const count=m.jobs.length;
  assert.equal((await time(m,()=>tick(m.ctx,first))).status,'stale_sequence');
  assert.equal((await time(m,()=>tick(m.ctx,{...first,sequence:3}))).status,'stale_sequence');
  await assert.rejects(time(m,()=>tick(m.ctx,{...first,sequence:'2'})),{code:'InvalidSequence'});
  assert.equal(m.jobs.length,count);assert.equal(m.writes.length,0);
});
test('lost local enqueue response retries the persisted transition without advancing identity', async () => {
  const m=mock();m.scheduleErrorOnce=true;
  await assert.rejects(time(m,()=>schedule(m.ctx,plan())),{code:'LocalTimeout'});
  assert.equal(state(m).transition.phase,'pending_schedule');assert.equal(state(m).sequence,1);
  const first=structuredClone(m.jobs[0]);
  m.now+=1000;const retry=await time(m,()=>schedule(m.ctx,plan()));
  assert.equal(retry.sequence,1);assert.equal(retry.job_id,'job-1');
  assert.equal(m.persistedJobs.size,1);assert.deepEqual(m.jobs.at(-1),first);
  assert.equal(state(m).transition.phase,'scheduled');
});
test('late enqueue acknowledgement cannot roll back a child that already advanced', async () => {
  const m=mock();m.now=RELEASE-60000;
  m.onSchedule=async p=>{m.onSchedule=null;await tick(m.ctx,p.input)};
  const result=await time(m,()=>schedule(m.ctx,plan()));
  assert.equal(state(m).sequence,2);assert.equal(state(m).last_consumed_sequence,1);
  assert.equal(state(m).transition.sequence,2);assert.equal(state(m).transition.phase,'scheduled');
  assert.equal(state(m).job_id,'job-2');assert.equal(result.job_id,'job-2');
  assert.equal(result.sequence,2);assert.equal(m.writes.length,0);
});
