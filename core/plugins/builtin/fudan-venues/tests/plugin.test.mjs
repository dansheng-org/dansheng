// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import {
  visibleLogin,
  venues,
  calendar,
  appointments,
  detail,
  prepareManual,
  reserve,
  reconcile,
  journal,
  prepareCancel,
  cancel,
  reconcileCancel,
} from '../main.mjs';

import {
  parseSlotState,
  normalizeManualInput,
  mutationKey,
  cancelMutationKey,
  classify,
} from '../policy.mjs';

import {
  FIXTURE_ACCOUNT,
  FIXTURE_VENUE_ID,
  FIXTURE_DATE,
  DANXI_CALENDAR_RESPONSE,
  DANXI_CALENDAR_RESPONSE_OCCUPIED,
  DANXI_VENUES_RESPONSE,
  DANXI_APPOINTMENTS_RESPONSE,
  DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  DANXI_APPOINTMENTS_CANCELLED,
  DANXI_DETAIL_RESPONSE,
  LAUNCH_SUCCESS_RESPONSE,
  LAUNCH_GONE_RESPONSE,
  LAUNCH_EXISTING_RESPONSE,
  LAUNCH_NOT_OPEN_RESPONSE,
  CANCEL_SUCCESS_RESPONSE,
  CANCEL_REJECT_RESPONSE,
} from './fixtures.mjs';

const manifest = JSON.parse(
  readFileSync(new URL('../manifest.json', import.meta.url), 'utf8')
);

function createMock(overrides = {}) {
  const store = new Map();
  const calls = [];
  const writes = [];

  const m = {
    store,
    calls,
    writes,
    authenticated: true,
    writeError: null,
    calendarResponse: DANXI_CALENDAR_RESPONSE,
    launchResponse: LAUNCH_SUCCESS_RESPONSE,
    appointmentsResponse: DANXI_APPOINTMENTS_RESPONSE,
    detailResponse: DANXI_DETAIL_RESPONSE,
    grants: new Set(manifest.capabilities),
    ...overrides,
  };

  m.ctx = {
    storage: {
      get: async ({ key }) => (store.has(key) ? structuredClone(store.get(key)) : null),
      set: async ({ key, value }) => {
        store.set(key, structuredClone(value));
      },
      delete: async ({ key }) => {
        store.delete(key);
      },
    },
    browser: {
      evaluate: async p => {
        calls.push({ type: 'evaluate', payload: p });
        if (!m.authenticated) {
          return { account_id: p.account_id, authenticated: false };
        }
        return {
          account_id: p.account_id,
          authenticated: true,
          session_handle: 'mock-session-handle-1234',
        };
      },
      login: async p => {
        calls.push({ type: 'login', payload: p });
        return { success: true, operation: p.operation };
      },
      request: async p => {
        calls.push({ type: 'request', payload: p });
        if (!m.grants.has('browser.request')) {
          throw Object.assign(new Error('Permission denied'), { code: 'PermissionDenied' });
        }
        if (p.method === 'POST') {
          if (!m.grants.has('browser.write')) {
            throw Object.assign(new Error('Write permission denied'), { code: 'PermissionDenied' });
          }
          writes.push(structuredClone(p));
          if (m.writeError) {
            throw Object.assign(new Error('Write failure'), { code: m.writeError });
          }
        }

        let body = {};
        if (p.url.includes('/api/topic/resource-list')) {
          body = DANXI_VENUES_RESPONSE;
        } else if (p.url.includes('/site/resource/calendar')) {
          body = m.calendarResponse;
        } else if (p.url.includes('appointment-list') || p.url.includes('appointmentList')) {
          body = m.appointmentsResponse;
        } else if (p.url.includes('/site/appointment/appointment-detail')) {
          body = m.detailResponse;
        } else if (p.url.includes('/site/resource/launch')) {
          body = m.launchResponse;
        } else if (p.url.includes('/site/appointment/appointment-cancel') || p.url.includes('/site/third-party/cancel-appointment')) {
          body = m.cancelResponse || CANCEL_SUCCESS_RESPONSE;
        }

        return {
          status: 200,
          url: p.url,
          body: JSON.stringify(body),
        };
      },
    },
  };

  return m;
}

test('manifest: declares trusted official baked capability without jobs or timers', () => {
  assert.equal(manifest.id, 'official.fudan-venues');
  assert.equal(manifest.api_version, 1);
  assert.equal(manifest.version, '0.1.0');
  assert.equal(manifest.entry, 'main.mjs');

  // Verify NO jobs capabilities
  const jobCaps = manifest.capabilities.filter(c => c.startsWith('jobs.'));
  assert.equal(jobCaps.length, 0, 'No jobs capabilities should be declared');

  // Verify required actions
  const requiredActions = [
    'visibleLogin',
    'venues',
    'calendar',
    'appointments',
    'detail',
    'prepareManual',
    'reserve',
    'reconcile',
    'prepareCancel',
    'cancel',
    'reconcileCancel',
    'journal',
  ];
  for (const act of requiredActions) {
    assert.ok(manifest.actions[act], `Action ${act} must be declared in manifest`);
  }

  // Mutating action flag checks
  assert.equal(manifest.actions.reserve.mutating, true);
  assert.equal(manifest.actions.cancel.mutating, true);
  assert.equal(manifest.actions.prepareCancel.mutating, false);
  assert.equal(manifest.actions.reconcileCancel.mutating, false);
  assert.equal(manifest.actions.prepareManual.mutating, false);
  assert.equal(manifest.actions.calendar.mutating, false);
  assert.equal(manifest.actions.venues.mutating, false);
});

test('visibleLogin: hands off to trusted visible login without accepting credentials', async () => {
  const m = createMock();
  const res = await visibleLogin(m.ctx, { account_id: FIXTURE_ACCOUNT });
  assert.ok(res.success || res.operation);
  const loginCall = m.calls.find(c => c.type === 'login' || c.payload?.operation === 'session.requireLogin');
  assert.ok(loginCall, 'visibleLogin must trigger session.requireLogin');
  assert.equal(loginCall.payload.account_id, FIXTURE_ACCOUNT);
  assert.equal(JSON.stringify(m.calls).includes('password'), false);
});

test('venues: returns [{id, name}] format from DanXi topic response', async () => {
  const m = createMock();
  const res = await venues(m.ctx, { account_id: FIXTURE_ACCOUNT });
  assert.ok(Array.isArray(res));
  assert.equal(res.length, 3);
  assert.deepEqual(res[0], {
    id: 900,
    name: '正大体育馆-羽毛球馆',
    type: 1,
    building: '正大体育馆',
    sport: '羽毛球馆',
  });
  assert.equal(res[1].id, 905);
  assert.equal(res[1].name, '南区体育馆-乒乓球馆');
});

test('calendar: preserves real DanXi shape with time periods and per-court capacity (not all free)', async () => {
  const m = createMock();
  const res = await calendar(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    venue_id: FIXTURE_VENUE_ID,
    target_date: FIXTURE_DATE,
  });

  assert.equal(res.venue_id, FIXTURE_VENUE_ID);
  assert.equal(res.target_date, FIXTURE_DATE);
  assert.equal(res.periods.length, 2);
  assert.equal(res.courts.length, 3);

  // Total slots = 2 periods * 3 courts = 6
  assert.equal(res.slots.length, 6);

  // Court 901, Period 70: occupy: false, num: 1, status: 0 -> available: true
  const c901p70 = res.slots.find(s => s.court_id === 901 && s.period_id === 70);
  assert.ok(c901p70);
  assert.equal(c901p70.available, true);
  assert.equal(c901p70.occupied, false);
  assert.equal(c901p70.remaining, 1);
  assert.equal(c901p70.time, '10:00-11:00');

  // Court 901, Period 71: occupy: true, num: 0, status: 1 -> available: false
  const c901p71 = res.slots.find(s => s.court_id === 901 && s.period_id === 71);
  assert.ok(c901p71);
  assert.equal(c901p71.available, false);
  assert.equal(c901p71.occupied, true);

  // Court 902, Period 70: num: 0 -> available: false
  const c902p70 = res.slots.find(s => s.court_id === 902 && s.period_id === 70);
  assert.ok(c902p70);
  assert.equal(c902p70.available, false);
  assert.equal(c902p70.occupied, true);
  assert.equal(c902p70.remaining, 0);

  // Court 902, Period 71: read_only: true -> available: false
  const c902p71 = res.slots.find(s => s.court_id === 902 && s.period_id === 71);
  assert.ok(c902p71);
  assert.equal(c902p71.available, false);
  assert.equal(c902p71.read_only, true);

  // Court 903, Period 70: num: 2 -> available: true, remaining: 2
  const c903p70 = res.slots.find(s => s.court_id === 903 && s.period_id === 70);
  assert.ok(c903p70);
  assert.equal(c903p70.available, true);
  assert.equal(c903p70.remaining, 2);

  // Court 903, Period 71: status: 2 -> available: false
  const c903p71 = res.slots.find(s => s.court_id === 903 && s.period_id === 71);
  assert.ok(c903p71);
  assert.equal(c903p71.available, false);
});

test('appointments and detail: parses appointment history and voucher info', async () => {
  const m = createMock();
  const list = await appointments(m.ctx, { account_id: FIXTURE_ACCOUNT });
  assert.equal(list.length, 1);
  assert.equal(list[0].id, 5501);
  assert.equal(list[0].status_name, '已预约');
  assert.equal(list[0].slots.length, 1);
  assert.equal(list[0].slots[0].date, '2026-11-09');
  assert.equal(list[0].slots[0].time, '10:00-11:00');

  const vDetail = await detail(m.ctx, { account_id: FIXTURE_ACCOUNT, appointment_id: 5501 });
  assert.equal(vDetail.id, 5501);
  assert.equal(vDetail.qrcode, 'DATA:QRCODE-FIXTURE-12345');
  assert.equal(vDetail.show_code, true);
  assert.equal(vDetail.refresh_seconds, 15);
});

test('prepareManual: normalizes string/number conversions and computes deterministic mutation_key', async () => {
  const m = createMock();
  // Pass strings for venue_id, period_id, court_id
  const rawInput = {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-1001',
    venue_id: '900',
    target_date: '2026-11-09',
    period_id: '70',
    court_id: '901',
    time: '10:00-11:00',
    venue_name: '正大体育馆-羽毛球馆',
    court_name: '羽毛球 1 号场',
  };

  const prep = await prepareManual(m.ctx, rawInput);
  assert.ok(prep.canonical_input);
  assert.ok(prep.summary);

  const c = prep.canonical_input;
  assert.equal(typeof c.venue_id, 'number');
  assert.equal(c.venue_id, 900);
  assert.equal(typeof c.period_id, 'number');
  assert.equal(c.period_id, 70);
  assert.equal(typeof c.court_id, 'number');
  assert.equal(c.court_id, 901);
  assert.equal(c.account_id, FIXTURE_ACCOUNT);
  assert.equal(c.task_id, 'task-1001');
  assert.equal(c.target_date, '2026-11-09');
  assert.equal(c.time, '10:00-11:00');

  const expectedKey = `manual:${FIXTURE_ACCOUNT}:task-1001:2026-11-09:900:70:901`;
  assert.equal(c.mutation_key, expectedKey);

  assert.ok(prep.summary.includes(FIXTURE_ACCOUNT));
  assert.ok(prep.summary.includes('task-1001'));
  assert.ok(prep.summary.includes('900'));
  assert.ok(prep.summary.includes('70'));
  assert.ok(prep.summary.includes('901'));
});

test('prepareManual: rejects malformed dates, invalid accounts, and negative numbers', async () => {
  const m = createMock();
  await assert.rejects(
    prepareManual(m.ctx, { account_id: 'bad acc!!', venue_id: 900, target_date: '2026-11-09', period_id: 70, court_id: 901, time: '10:00-11:00' }),
    { code: 'InvalidAccount' }
  );

  await assert.rejects(
    prepareManual(m.ctx, { account_id: FIXTURE_ACCOUNT, venue_id: 900, target_date: '2026-02-31', period_id: 70, court_id: 901, time: '10:00-11:00' }),
    { code: 'InvalidDate' }
  );

  await assert.rejects(
    prepareManual(m.ctx, { account_id: FIXTURE_ACCOUNT, venue_id: -5, target_date: '2026-11-09', period_id: 70, court_id: 901, time: '10:00-11:00' }),
    { code: 'InvalidId' }
  );
});

test('reserve: confirmed execution rechecks availability and submits single POST with sign-key', async () => {
  const m = createMock();
  const prep = await prepareManual(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-success',
    venue_id: 900,
    target_date: '2026-11-09',
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  const res = await reserve(m.ctx, prep.canonical_input);
  assert.equal(res.status, 'success');
  assert.equal(res.message, '预约成功');

  // Exactly 1 write POST was dispatched
  assert.equal(m.writes.length, 1);
  const write = m.writes[0];

  assert.equal(write.method, 'POST');
  assert.equal(write.transport, 'xhr');
  assert.equal(write.url, 'https://booking.fudan.edu.cn/reservation/site/resource/launch');
  assert.equal(write.headers['sign-key'], '/reservation/site/resource/launchpost');
  assert.equal(write.mutation_key, prep.canonical_input.mutation_key);

  const orderData = JSON.parse(write.form_fields.data);
  assert.equal(orderData.length, 1);
  assert.deepEqual(orderData[0].resource_ids, [901]);
  assert.equal(orderData[0].group_id, 900);
  assert.equal(orderData[0].number, 1);
  assert.equal(orderData[0].period[0].date, '2026-11-09');
  assert.equal(orderData[0].period[0].period_id, 70);

  // Journal in storage was marked completed
  const j = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-success' });
  assert.equal(j.entry.status, 'success');
});

test('reserve: recheck fails when court is no longer available and prevents ANY write', async () => {
  const m = createMock({
    calendarResponse: DANXI_CALENDAR_RESPONSE_OCCUPIED,
  });

  const prep = await prepareManual(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-occupied',
    venue_id: 900,
    target_date: '2026-11-09',
    period_id: 70,
    court_id: 901, // In OCCUPIED fixture, court 901 period 70 has occupy: true, num: 0
    time: '10:00-11:00',
  });

  await assert.rejects(
    reserve(m.ctx, prep.canonical_input),
    { code: 'CourtOccupied' }
  );

  // Crucial check: NO POST write was attempted!
  assert.equal(m.writes.length, 0);
});

test('reserve: write timeout preserves uncertain journal and prevents retry without reconciliation', async () => {
  const m = createMock({
    writeError: 'WriteTimeout',
  });

  const prep = await prepareManual(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-timeout',
    venue_id: 900,
    target_date: '2026-11-09',
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  // Write times out
  await assert.rejects(
    reserve(m.ctx, prep.canonical_input),
    { code: 'NeedsReconciliation' }
  );

  // Journal in storage MUST record uncertain state
  const j = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-timeout' });
  assert.ok(j.entry);
  assert.equal(j.entry.status, 'uncertain');

  // Subsequent call without reconciliation is strictly blocked: NO RETRY!
  await assert.rejects(
    reserve(m.ctx, prep.canonical_input),
    { code: 'NeedsReconciliation' }
  );
  assert.equal(m.writes.length, 1, 'Retry must never issue another POST');
});

test('reconcile: successfully reconciles uncertain task against appointment history', async () => {
  const m = createMock();
  // Pre-populate journal with an uncertain outcome
  await m.ctx.storage.set({
    key: `journal:manual:${FIXTURE_ACCOUNT}:task-reconcile`,
    value: {
      account_id: FIXTURE_ACCOUNT,
      task_id: 'task-reconcile',
      venue_id: 900,
      target_date: '2026-11-09',
      period_id: 70,
      court_id: 901,
      time: '10:00-11:00',
      status: 'uncertain',
    },
  });

  const rec = await reconcile(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-reconcile',
  });

  assert.equal(rec.status, 'reconciled_success');
  assert.equal(rec.appointment_id, 5501);

  const j = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-reconcile' });
  assert.equal(j.entry.status, 'reconciled_success');
  assert.equal(j.entry.appointment_id, 5501);
});

test('reconcile: returns needs_reconciliation without marking failed when absent from history; preserves uncertain status', async () => {
  const m = createMock({
    appointmentsResponse: { e: 'OK', d: { data: [] } },
  });

  await m.ctx.storage.set({
    key: `journal:manual:${FIXTURE_ACCOUNT}:task-reconcile-empty`,
    value: {
      account_id: FIXTURE_ACCOUNT,
      task_id: 'task-reconcile-empty',
      venue_id: 900,
      target_date: '2026-11-09',
      period_id: 70,
      court_id: 901,
      time: '10:00-11:00',
      status: 'uncertain',
    },
  });

  const rec = await reconcile(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-reconcile-empty',
  });

  assert.equal(rec.status, 'needs_reconciliation');
  assert.equal(rec.task_id, 'task-reconcile-empty');

  // Verify journal was NOT marked failed; status remains uncertain and is NOT freed
  const j = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-reconcile-empty' });
  assert.equal(j.entry.status, 'uncertain');
});

test('reconcile: recovers in_flight task across restart upon proven match', async () => {
  const m = createMock();
  // Simulate task left in_flight due to lease closure or process restart
  await m.ctx.storage.set({
    key: `journal:manual:${FIXTURE_ACCOUNT}:task-in-flight-restart`,
    value: {
      account_id: FIXTURE_ACCOUNT,
      task_id: 'task-in-flight-restart',
      venue_id: 900,
      target_date: '2026-11-09',
      period_id: 70,
      court_id: 901,
      time: '10:00-11:00',
      status: 'in_flight',
      started_at: Date.now() - 30000,
    },
  });

  const rec = await reconcile(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-in-flight-restart',
  });

  assert.equal(rec.status, 'reconciled_success');
  assert.equal(rec.appointment_id, 5501);

  const j = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-in-flight-restart' });
  assert.equal(j.entry.status, 'reconciled_success');
  assert.equal(j.entry.appointment_id, 5501);
});

test('reconcile: repeat reconcile on already proven record returns same positive id for host reconciliation', async () => {
  const m = createMock();
  await m.ctx.storage.set({
    key: `journal:manual:${FIXTURE_ACCOUNT}:task-proven`,
    value: {
      account_id: FIXTURE_ACCOUNT,
      task_id: 'task-proven',
      venue_id: 900,
      target_date: '2026-11-09',
      period_id: 70,
      court_id: 901,
      time: '10:00-11:00',
      status: 'reconciled_success',
      appointment_id: 5501,
      reconciled_at: Date.now(),
    },
  });

  // Call reconcile repeatedly
  const rec1 = await reconcile(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-proven' });
  assert.equal(rec1.status, 'reconciled_success');
  assert.equal(rec1.appointment_id, 5501);
  assert.equal(rec1.already_reconciled, true);

  const rec2 = await reconcile(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-proven' });
  assert.equal(rec2.status, 'reconciled_success');
  assert.equal(rec2.appointment_id, 5501);
  assert.equal(rec2.already_reconciled, true);
});

test('reserve: cannot re-submit same task if prior state is in_flight or reconciled_success', async () => {
  const m = createMock();
  const prep = await prepareManual(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-locked',
    venue_id: 900,
    target_date: '2026-11-09',
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  // Prior state: in_flight -> must block reserve immediately
  await m.ctx.storage.set({
    key: `journal:manual:${FIXTURE_ACCOUNT}:task-locked`,
    value: { ...prep.canonical_input, status: 'in_flight', started_at: Date.now() },
  });

  await assert.rejects(
    reserve(m.ctx, prep.canonical_input),
    { code: 'NeedsReconciliation' }
  );
  assert.equal(m.writes.length, 0, 'No write may be dispatched when in_flight');

  // Prior state: reconciled_success -> must return already completed without write
  await m.ctx.storage.set({
    key: `journal:manual:${FIXTURE_ACCOUNT}:task-locked`,
    value: { ...prep.canonical_input, status: 'reconciled_success', appointment_id: 5501 },
  });

  const res = await reserve(m.ctx, prep.canonical_input);
  assert.equal(res.status, 'success');
  assert.equal(res.already_completed, true);
  assert.equal(m.writes.length, 0, 'No write may be dispatched when reconciled_success');
});

test('reserve: thrown host error durably preserves uncertain state in journal', async () => {
  const m = createMock({
    writeError: 'HostLeaseClosed',
  });

  const prep = await prepareManual(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-host-err',
    venue_id: 900,
    target_date: '2026-11-09',
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  await assert.rejects(
    reserve(m.ctx, prep.canonical_input),
    { code: 'NeedsReconciliation' }
  );

  const j = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-host-err' });
  assert.ok(j.entry);
  assert.equal(j.entry.status, 'uncertain');
  assert.equal(j.entry.error, 'HostLeaseClosed');
});

test('journal: exposes accurate journal retrieval for same task', async () => {
  const m = createMock();
  const prep = await prepareManual(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-journal-view',
    venue_id: 900,
    target_date: '2026-11-09',
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  const emptyJournal = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-journal-view' });
  assert.equal(emptyJournal.task_id, 'task-journal-view');
  assert.equal(emptyJournal.entry, null);

  await reserve(m.ctx, prep.canonical_input);

  const populatedJournal = await journal(m.ctx, { account_id: FIXTURE_ACCOUNT, task_id: 'task-journal-view' });
  assert.equal(populatedJournal.task_id, 'task-journal-view');
  assert.ok(populatedJournal.entry);
  assert.equal(populatedJournal.entry.status, 'success');
  assert.equal(populatedJournal.entry.mutation_key, prep.canonical_input.mutation_key);
});

test('denial: permission denial and unauthenticated sessions fail closed without write', async () => {
  const mNoAuth = createMock({ authenticated: false });
  const prep = await prepareManual(mNoAuth.ctx, {
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-denial',
    venue_id: 900,
    target_date: '2026-11-09',
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  await assert.rejects(
    reserve(mNoAuth.ctx, prep.canonical_input),
    { code: 'AuthenticationRequired' }
  );
  assert.equal(mNoAuth.writes.length, 0);

  const mNoWriteGrant = createMock();
  mNoWriteGrant.grants.delete('browser.write');
  await assert.rejects(
    reserve(mNoWriteGrant.ctx, prep.canonical_input),
    { code: 'PermissionDenied' }
  );
  assert.equal(mNoWriteGrant.writes.length, 0);
});

test('prepareCancel: prepares standard appointment with exact eligible detail_ids and data_ids', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  });

  const prep = await prepareCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
  });

  assert.ok(prep.canonical_input);
  assert.equal(prep.appointment_id, 5501);
  assert.equal(prep.is_third_party, false);
  assert.deepEqual(prep.appointment_detail_id, [8801]);
  assert.deepEqual(prep.appointment_data_ids, []);
  assert.equal(prep.canonical_input.mutation_key, `cancel:${FIXTURE_ACCOUNT}:5501`);
  assert.ok(prep.summary.includes(FIXTURE_ACCOUNT));
  assert.ok(prep.summary.includes('5501'));
  assert.ok(prep.summary.includes('羽毛球'));
});

test('prepareCancel: prepares third-party appointment with type 7 dedicated endpoint', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  });

  const prep = await prepareCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5502,
  });

  assert.ok(prep.canonical_input);
  assert.equal(prep.appointment_id, 5502);
  assert.equal(prep.is_third_party, true);
  assert.equal(prep.endpoint, '/reservation/site/third-party/cancel-appointment');
  assert.equal(prep.canonical_input.mutation_key, `cancel:${FIXTURE_ACCOUNT}:5502`);
  assert.ok(prep.summary.includes('第三方系统预约'));
});

test('prepareCancel: rejects non-cancellable appointment', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  });

  await assert.rejects(
    prepareCancel(m.ctx, { account_id: FIXTURE_ACCOUNT, appointment_id: 5503 }),
    { code: 'CancellationNotAllowed' }
  );
});

test('cancel: executes single POST with exact sign-key and cancel mutation_key', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  });

  const prep = await prepareCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
  });

  const res = await cancel(m.ctx, prep.canonical_input);
  assert.equal(res.status, 'cancelled');
  assert.equal(res.appointment_id, 5501);

  assert.equal(m.writes.length, 1);
  const write = m.writes[0];
  assert.equal(write.method, 'POST');
  assert.equal(write.transport, 'xhr');
  assert.equal(write.url, 'https://booking.fudan.edu.cn/reservation/site/appointment/appointment-cancel');
  assert.equal(write.headers['sign-key'], '/reservation/site/appointment/appointment-cancelpost');
  assert.equal(write.mutation_key, `cancel:${FIXTURE_ACCOUNT}:5501`);
  assert.equal(write.form_fields.appointment_id, '5501');
  assert.equal(write.form_fields.appointment_detail_id, JSON.stringify([8801]));
  assert.equal(write.form_fields.appointment_data_ids, JSON.stringify([]));

  const stored = await m.ctx.storage.get({ key: `journal:cancel:${FIXTURE_ACCOUNT}:5501` });
  assert.equal(stored.status, 'confirmed');
});

test('cancel: executes third-party cancel to dedicated endpoint', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  });

  const prep = await prepareCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5502,
  });

  const res = await cancel(m.ctx, prep.canonical_input);
  assert.equal(res.status, 'cancelled');
  assert.equal(res.appointment_id, 5502);

  assert.equal(m.writes.length, 1);
  const write = m.writes[0];
  assert.equal(write.url, 'https://booking.fudan.edu.cn/reservation/site/third-party/cancel-appointment');
  assert.equal(write.headers['sign-key'], '/reservation/site/third-party/cancel-appointmentpost');
  assert.equal(write.form_fields.appointment_id, '5502');
});

test('cancel: prevents broadening or mismatched slot selection on fresh comparison', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  });

  // Client attempts to cancel broader selection (e.g. detail_ids=[8801, 8899])
  const broadenedInput = {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
    appointment_detail_id: [8801, 8899],
    appointment_data_ids: [],
  };

  await assert.rejects(
    cancel(m.ctx, broadenedInput),
    { code: 'CancellationNotAllowed' }
  );

  assert.equal(m.writes.length, 0, 'No cancel write may be issued when slot IDs mismatch');
});

test('cancel: write timeout preserves uncertain state and prevents retry', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
    writeError: 'WriteTimeout',
  });

  const prep = await prepareCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
  });

  await assert.rejects(
    cancel(m.ctx, prep.canonical_input),
    { code: 'NeedsReconciliation' }
  );

  const stored = await m.ctx.storage.get({ key: `journal:cancel:${FIXTURE_ACCOUNT}:5501` });
  assert.ok(stored);
  assert.equal(stored.status, 'uncertain');

  // Second attempt is strictly blocked without retry
  await assert.rejects(
    cancel(m.ctx, prep.canonical_input),
    { code: 'NeedsReconciliation' }
  );
  assert.equal(m.writes.length, 1, 'Retry must never issue another POST');
});

test('reconcileCancel: positive match confirms cancellation when record shows cancelled or inactive', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_CANCELLED,
  });

  await m.ctx.storage.set({
    key: `journal:cancel:${FIXTURE_ACCOUNT}:5501`,
    value: {
      account_id: FIXTURE_ACCOUNT,
      appointment_id: 5501,
      status: 'uncertain',
    },
  });

  const rec = await reconcileCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
  });

  assert.equal(rec.status, 'reconciled_cancelled');
  assert.equal(rec.appointment_id, 5501);

  // Repeated call returns same positive appointment_id
  const recRepeat = await reconcileCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
  });
  assert.equal(recRepeat.status, 'reconciled_cancelled');
  assert.equal(recRepeat.appointment_id, 5501);
  assert.equal(recRepeat.already_reconciled, true);
});

test('reconcileCancel: returns needs_reconciliation when absent from history; does NOT mark failed', async () => {
  const m = createMock({
    appointmentsResponse: { e: 'OK', d: { data: [] } },
  });

  await m.ctx.storage.set({
    key: `journal:cancel:${FIXTURE_ACCOUNT}:5501`,
    value: {
      account_id: FIXTURE_ACCOUNT,
      appointment_id: 5501,
      status: 'uncertain',
    },
  });

  const rec = await reconcileCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
  });

  assert.equal(rec.status, 'needs_reconciliation');
  assert.equal(rec.appointment_id, 5501);

  const stored = await m.ctx.storage.get({ key: `journal:cancel:${FIXTURE_ACCOUNT}:5501` });
  assert.equal(stored.status, 'uncertain');
});

test('reconcileCancel: returns still_active when appointment still has active slots', async () => {
  const m = createMock({
    appointmentsResponse: DANXI_APPOINTMENTS_WITH_THIRD_PARTY,
  });

  await m.ctx.storage.set({
    key: `journal:cancel:${FIXTURE_ACCOUNT}:5501`,
    value: {
      account_id: FIXTURE_ACCOUNT,
      appointment_id: 5501,
      status: 'uncertain',
    },
  });

  const rec = await reconcileCancel(m.ctx, {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
  });

  assert.equal(rec.status, 'still_active');
  assert.equal(rec.appointment_id, 5501);
});
