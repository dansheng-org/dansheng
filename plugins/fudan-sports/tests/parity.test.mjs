// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  schedule, tick, stop, reconcile, listTasks, prepareSchedule, DEFAULT_OPTIONS,
} from '../main.mjs';
import { validatePlan } from '../policy.mjs';
import { PATHS } from '../api.mjs';

const RELEASE = Date.parse('2031-01-02T07:00:01+08:00');
const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url), 'utf8'));

function plan(extra = {}) {
  return {
    task_id: 'fixture-parity-task',
    account_id: 'fixture-a',
    venue_id: 900,
    target_date: '2031-01-04',
    release_at: '2031-01-02T07:00:01+08:00',
    plans: [
      { time: '10:00-11:00', period_id: 70, courts: [901, 902] },
    ],
    ...extra,
  };
}

function multiSlotPlan(extra = {}) {
  return {
    task_id: 'fixture-multi-task',
    account_id: 'fixture-a',
    venue_id: 900,
    target_date: '2031-01-04',
    release_at: '2031-01-02T07:00:01+08:00',
    plans: [
      { time: '10:00-11:00', period_id: 70, courts: [901, 902] },
      { time: '14:00-15:00', period_id: 71, courts: [903, 904] },
    ],
    ...extra,
  };
}

function mock() {
  const store = new Map(), calls = [], jobs = [];
  const m = {
    store,
    calls,
    jobs,
    now: RELEASE - 70000,
    writes: [],
    history: [],
    reply: { e: 0 },
    repliesByCourt: new Map(),
    calendarFails: false,
    calendarPeriods: [{ id: 70, str_time: '10:00-11:00' }, { id: 71, str_time: '14:00-15:00' }],
    grants: new Set(manifest.capabilities),
    persistedJobs: new Map(),
  };
  m.ctx = {
    storage: {
      get: async ({ key }) => store.has(key) ? structuredClone(store.get(key)) : null,
      set: async ({ key, value }) => { store.set(key, structuredClone(value)); },
      delete: async ({ key }) => store.delete(key),
    },
    browser: {
      evaluate: async p => {
        calls.push(p);
        if (m.desktop) throw Object.assign(new Error('missing'), { code: 'CapabilityUnavailable' });
        return { account_id: p.account_id, authenticated: !m.noAuth, session_handle: 'opaque-fixture-session' };
      },
      request: async p => {
        if (!m.grants.has('browser.request') || (p.method === 'POST' && !m.grants.has('browser.write'))) {
          throw Object.assign(new Error('denied'), { code: 'PermissionDenied' });
        }
        calls.push(p);
        if (p.method === 'POST') {
          m.writes.push(p);
          if (m.writeError) throw Object.assign(new Error('masked'), { code: m.writeError });
          if (m.writeErrorCourt && p.form_fields?.data?.includes(String(m.writeErrorCourt))) {
            throw Object.assign(new Error('court error'), { code: 'NeedsReconciliation' });
          }
        }
        let body = p.method === 'POST' ? m.reply : { e: 0, d: { time: m.calendarPeriods, resource: [] } };
        if (p.method === 'POST' && m.repliesByCourt.size > 0) {
          for (const [cid, rep] of m.repliesByCourt.entries()) {
            if (p.form_fields?.data?.includes(String(cid))) {
              body = rep;
              break;
            }
          }
        }
        if (p.url.includes('calendar') && m.calendarFails) {
          throw Object.assign(new Error('calendar unavailable'), { code: 'Http503' });
        }
        if (p.url.includes('appointment-list') || p.url.includes('appointmentList')) {
          body = { e: 0, d: { data: m.history } };
        }
        if (m.onRequest) await m.onRequest(p);
        return { status: 200, url: p.url, body: JSON.stringify(body) };
      },
    },
    jobs: {
      schedule: async p => {
        jobs.push(structuredClone(p));
        const key = JSON.stringify([p.plugin_id, p.action, p.input, p.interval_seconds]);
        if (!m.persistedJobs.has(key)) m.persistedJobs.set(key, 'job-' + (m.persistedJobs.size + 1));
        return {
          job_id: m.persistedJobs.get(key),
          run_at: p.run_at,
          state: 'scheduled',
          wake_up: { state: 'armed', wake_at: p.prepare_at || p.run_at },
        };
      },
      cancel: async p => { calls.push(p); },
      status: async p => ({ id: p.job_id, state: 'scheduled', run_at: '2031-01-02T06:59:01.000Z' }),
    },
    ui: { publish: async p => { calls.push(p); } },
    sources: { upsert: async () => {} },
  };
  return m;
}

async function time(m, f) {
  const old = Date.now;
  Date.now = () => m.now;
  try {
    return await f();
  } finally {
    Date.now = old;
  }
}

const state = (m, taskId = 'fixture-parity-task') => m.store.get(`task:fixture-a:${taskId}`);
const step = (m, taskId) => {
  const matching = taskId
    ? m.jobs.filter(j => j.input?.task_id === taskId).at(-1)
    : m.jobs.at(-1);
  return tick(m.ctx, structuredClone(matching.input));
};

test('timing parity: 60s preload, release+300ms first shot, 5min window deadline', async () => {
  const m = mock();
  const res = await time(m, () => schedule(m.ctx, plan()));
  assert.equal(res.status, 'scheduled');
  assert.equal(Date.parse(res.native_wake_at), RELEASE - 300000); // 5 min native alarm
  assert.equal(Date.parse(res.deadline_at), RELEASE + 300000); // 5 min deadline

  // 1. Tick before preload window returns waiting_preload
  m.now = RELEASE - 70000;
  const waitingPreload = await time(m, () => step(m));
  assert.equal(waitingPreload.status, 'waiting_preload');
  assert.equal(Date.parse(m.jobs.at(-1).run_at), RELEASE - 60000);

  // 2. Preload at RELEASE - 60s prewarms session and loads calendar
  m.now = RELEASE - 60000;
  const preloaded = await time(m, () => step(m));
  assert.equal(preloaded.status, 'preloaded');
  assert.equal(m.writes.length, 0);
  assert.equal(Date.parse(m.jobs.at(-1).run_at), RELEASE + 300); // Enqueued at release+300ms

  // 3. Tick before first shot returns preloaded
  m.now = RELEASE + 200;
  const waitingFirstShot = await time(m, () => step(m));
  assert.equal(waitingFirstShot.status, 'preloaded');
  assert.equal(m.writes.length, 0);

  // 4. First shot at RELEASE + 300ms dispatches POST write
  m.now = RELEASE + 300;
  const firstShot = await time(m, () => step(m));
  assert.equal(firstShot.status, 'completed');
  assert.equal(m.writes.length, 1);

  // 5. Execution at or after deadline expires
  const m2 = mock();
  await time(m2, () => schedule(m2.ctx, plan({ task_id: 'expired-task' })));
  m2.now = RELEASE + 300000;
  const expiredStep = await time(m2, () => step(m2));
  assert.equal(expiredStep.status, 'expired');
  assert.equal(m2.writes.length, 0);
});

test('refreshed period IDs parity: latest calendar replaces null or stale period IDs', async () => {
  const m = mock();
  m.calendarPeriods = [{ id: 85, str_time: '10:00-11:00' }]; // Server assigned period ID 85
  // Plan scheduled with period_id: null (e.g. before schedule opened)
  const p = plan({
    task_id: 'refresh-task',
    plans: [{ time: '10:00-11:00', period_id: null, courts: [901, 902] }],
  });

  await time(m, () => schedule(m.ctx, p));

  // At preload, calendar is fetched and period ID 85 is loaded
  m.now = RELEASE - 60000;
  await time(m, () => step(m));
  assert.equal(state(m, 'refresh-task').periods[0].id, 85);

  // At release+300ms, booking write uses refreshed period ID 85
  m.now = RELEASE + 300;
  await time(m, () => step(m));
  assert.equal(m.writes.length, 1);
  const writeData = JSON.parse(m.writes[0].form_fields.data)[0];
  assert.equal(writeData.period[0].period_id, 85);
  assert.ok(m.writes[0].mutation_key.includes(':85:901'));
});

test('sequential execution: per-slot priority and fallback courts progression', async () => {
  const m = mock();
  m.now = RELEASE + 300;
  // Plan with 2 disjoint slots, each having 2 courts in priority order
  const p = multiSlotPlan({ task_id: 'normal-seq-task' });
  await time(m, () => schedule(m.ctx, p));

  // Court 901 fails with explicit rejection (gone)
  m.repliesByCourt.set(901, { e: 1, m: '容量不足' });
  // Fallback Court 902 succeeds
  m.repliesByCourt.set(902, { e: 0 });
  // Court 903 fails with explicit rejection (gone)
  m.repliesByCourt.set(903, { e: 1, m: '已满' });
  // Fallback Court 904 succeeds
  m.repliesByCourt.set(904, { e: 0 });

  // Tick 1: Slot 1 Court 901 -> rejected
  const t1 = await time(m, () => step(m));
  assert.equal(t1.status, 'running');
  assert.equal(m.writes.length, 1);
  assert.ok(m.writes[0].mutation_key.includes(':70:901'));

  // Tick 2: Slot 1 Court 902 fallback -> success (Slot 1 completed)
  const t2 = await time(m, () => step(m));
  assert.equal(t2.status, 'running');
  assert.equal(m.writes.length, 2);
  assert.ok(m.writes[1].mutation_key.includes(':70:902'));
  assert.equal(state(m, 'normal-seq-task').successes.length, 1);

  // Tick 3: Slot 2 Court 903 -> rejected
  const t3 = await time(m, () => step(m));
  assert.equal(t3.status, 'running');
  assert.equal(m.writes.length, 3);
  assert.ok(m.writes[2].mutation_key.includes(':71:903'));

  // Tick 4: Slot 2 Court 904 fallback -> success (Slot 2 completed)
  const t4 = await time(m, () => step(m));
  assert.equal(t4.status, 'completed');
  assert.equal(m.writes.length, 4);
  assert.ok(m.writes[3].mutation_key.includes(':71:904'));
  assert.equal(state(m, 'normal-seq-task').successes.length, 2);
});

test('concurrent execution of independent tasks (parity with sports_sniper_background.dart Future.wait)', async () => {
  const m = mock();
  m.now = RELEASE + 300;

  // Two independent tasks for different dates/venues
  const p1 = plan({ task_id: 'task-concurrent-1', target_date: '2031-01-04' });
  const p2 = plan({ task_id: 'task-concurrent-2', target_date: '2031-01-05' });

  await time(m, () => schedule(m.ctx, p1));
  await time(m, () => schedule(m.ctx, p2));

  // In DanXi sports_sniper_background.dart, Future.wait executes multiple eligible tasks concurrently.
  // In dansheng, each task runs its own scheduled ticks independently without collision.
  m.reply = { e: 0 };
  const [res1, res2] = await Promise.all([
    time(m, () => step(m, 'task-concurrent-1')),
    time(m, () => step(m, 'task-concurrent-2')),
  ]);

  assert.equal(res1.status, 'completed');
  assert.equal(res2.status, 'completed');
  assert.equal(m.writes.length, 2);

  const keys = m.writes.map(w => w.mutation_key);
  assert.ok(keys.some(k => k.includes('task:fixture-a:task-concurrent-1')));
  assert.ok(keys.some(k => k.includes('task:fixture-a:task-concurrent-2')));
});

test('delays: throttle backoff (800ms) and round pause (1200ms) delay progression', async () => {
  const m = mock();
  m.now = RELEASE + 300;
  const p = plan({ task_id: 'throttle-task', plans: [{ time: '10:00-11:00', period_id: 70, courts: [901, 902] }] });
  await time(m, () => schedule(m.ctx, p));

  // 1. Throttled on court 901 -> backs off 800ms before fallback court 902
  m.repliesByCourt.set(901, { e: 1, m: '操作过于频繁，请稍候' });
  m.repliesByCourt.set(902, { e: 1, m: '容量不足' });

  await time(m, () => step(m));
  const jobAfterThrottle = m.jobs.at(-1);
  assert.equal(Date.parse(jobAfterThrottle.run_at), m.now + 800);

  // Advance time by 800ms to run fallback court 902
  m.now += 800;
  await time(m, () => step(m));
  // All courts in Round 1 exhausted -> advances to Round 2 with 1200ms round pause
  const jobAfterRound = m.jobs.at(-1);
  assert.equal(Date.parse(jobAfterRound.run_at), m.now + 1200);
  assert.equal(state(m, 'throttle-task').round, 2);
});

test('uncertainty preservation in sequential execution: timeout halts subsequent ticks, history reconciles', async () => {
  const m = mock();
  m.now = RELEASE + 300;
  const p = plan({ task_id: 'uncertain-seq-task' });
  await time(m, () => schedule(m.ctx, p));

  m.writeError = 'BrowserRequestFailed';

  // Tick encounters network timeout / ambiguous write
  await assert.rejects(time(m, () => step(m)), { code: 'NeedsReconciliation' });

  const st = state(m, 'uncertain-seq-task');
  assert.equal(st.status, 'needs_reconciliation');
  assert.ok(st.pending);
  assert.equal(st.pending.court_id, 901);

  // Subsequent tick attempts are strictly blocked to prevent duplicate writes
  await assert.rejects(time(m, () => step(m)), { code: 'NeedsReconciliation' });
  assert.equal(m.writes.length, 1); // No new writes dispatched

  // History confirms reservation in remote appointment list
  m.history = [{
    id: 99,
    slots: [{ active: true, date: '2031-01-04', time: '10:00-11:00', resource_id: 901, can_cancel: true }],
  }];

  const reconciled = await time(m, () => reconcile(m.ctx, p));
  assert.equal(reconciled.status, 'reconciled_requires_user_resume');
  assert.equal(reconciled.appointment_id, 99);
  assert.equal(state(m, 'uncertain-seq-task').pending, null);
  assert.equal(state(m, 'uncertain-seq-task').successes.length, 1);
});

test('backward reconciliation compatibility: handles prior 0.1 tasks with array or single pending', async () => {
  const m = mock();
  m.history = [{
    id: 101,
    slots: [{ active: true, date: '2031-01-04', time: '10:00-11:00', resource_id: 901, can_cancel: true }],
  }];

  // Prior task state with array pending
  const pArray = plan({ task_id: 'legacy-array-task' });
  m.store.set('task:fixture-a:legacy-array-task', {
    plan: pArray,
    status: 'needs_reconciliation',
    successes: [],
    pending: [{ time: '10:00-11:00', court_id: 901, period_id: 70, round: 1 }],
  });

  const resArray = await reconcile(m.ctx, pArray);
  assert.equal(resArray.status, 'reconciled_requires_user_resume');
  assert.equal(resArray.appointment_id, 101);
  assert.equal(state(m, 'legacy-array-task').pending, null);

  // Prior task state with single object pending
  const pSingle = plan({ task_id: 'legacy-single-task' });
  m.store.set('task:fixture-a:legacy-single-task', {
    plan: pSingle,
    status: 'needs_reconciliation',
    successes: [],
    pending: { time: '10:00-11:00', court_id: 901, period_id: 70, round: 1 },
  });

  const resSingle = await reconcile(m.ctx, pSingle);
  assert.equal(resSingle.status, 'reconciled_requires_user_resume');
  assert.equal(resSingle.appointment_id, 101);
  assert.equal(state(m, 'legacy-single-task').pending, null);
});

test('retries on explicit rejection only: not-open advances, existing reservation terminates', async () => {
  const m = mock();
  m.now = RELEASE + 300;
  const p = plan({ task_id: 'rejection-task' });

  // 1. notOpen advances without terminal stop and remains retryable in next round
  m.reply = { e: 1, m: '未开放预约' };
  await time(m, () => schedule(m.ctx, p));
  const tNotOpen = await time(m, () => step(m));
  assert.equal(tNotOpen.status, 'running');
  assert.equal(state(m, 'rejection-task').round, 2);

  // 2. existingReservation is immediately terminal
  m.reply = { e: 1, m: '已有未结束的预约' };
  const tExisting = await time(m, () => step(m));
  assert.equal(tExisting.status, 'existingReservation');

  // No further writes after terminal existing reservation
  const writesCount = m.writes.length;
  await time(m, () => step(m));
  assert.equal(m.writes.length, writesCount);
});

test('prepareSchedule normalizes UI inputs into canonical plan without strategy option', async () => {
  const m = mock();
  const prep = await prepareSchedule(m.ctx, {
    account_id: 'fixture-a',
    venue_id: 900,
    target_date: '2031-01-04',
    release_at: '2031-01-02T07:00:01+08:00',
    selected_slots: [
      { time: '10:00-11:00', period_id: 70, court_id: 901 },
    ],
  });

  assert.equal(prep.account_id, 'fixture-a');
  assert.equal(prep.venue_id, 900);
  assert.equal(prep.target_date, '2031-01-04');
  assert.equal(prep.plans.length, 1);
  assert.equal(prep.plans[0].courts[0], 901);
  assert.ok(!prep.strategy);
  assert.ok(prep.summary.includes('预约计划: 账号 fixture-a'));

  // Negative options reject invalid bounds
  assert.throws(() => validatePlan(plan({ options: { maxReservationSlots: 5 } })), { code: 'InvalidOptions' });

  // listTasks reflects task cleanly without strategy
  await time(m, () => schedule(m.ctx, prep));
  const tasks = await listTasks(m.ctx, { account_id: 'fixture-a' });
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].task_id, prep.task_id);
  assert.ok(!tasks[0].strategy);
});
