// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, rmSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  schedule, tick, stop, reconcile, listTasks,
  venues, venueOptions, slotOptions, prepareSchedule,
  appointments, appointmentDetail, prepareCancelAppointment, cancelAppointment,
  taskOptions, appointmentOptions, cancellableAppointmentOptions,
  DEFAULT_OPTIONS,
} from '../main.mjs';
import {
  HOST_POLICY, verifyIdentityProbe, matchBindingRule, isWritePermitted, evaluateWriteOutcome,
  evaluateKey, evaluateForm, resolveJsonPointer,
} from './host-policy-fixture.mjs';
import { pack } from '../pack.mjs';

const RELEASE = Date.parse('2031-01-02T07:00:01+08:00');
const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url), 'utf8'));

function plan(extra = {}) {
  return {
    task_id: 'fixture-task',
    account_id: 'fixture-a',
    venue_id: 900,
    target_date: '2031-01-04',
    release_at: '2031-01-02T07:00:01+08:00',
    plans: [{ time: '10:00-11:00', period_id: 70, courts: [901, 902] }],
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
    calendarFails: false,
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
        }
        let body = p.method === 'POST'
          ? m.reply
          : { e: 0, d: { time: [{ id: 70, str_time: '10:00-11:00' }, { id: 71, str_time: '14:00-15:00' }], resource: [{ id: 901, name: '1号场' }, { id: 902, name: '2号场' }] } };
        if (p.url.includes('calendar') && m.calendarFails) {
          throw Object.assign(new Error('calendar unavailable'), { code: 'Http503' });
        }
        if (p.url.includes('resource-list')) {
          body = { e: 0, d: { data: [{ base: { id: 900, name: '江湾羽毛球馆', type: 1 } }, { base: { id: 901, name: '正大体育馆', type: 1 } }] } };
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
        if (!m.grants.has('jobs.schedule')) throw Object.assign(new Error('denied'), { code: 'PermissionDenied' });
        jobs.push(structuredClone(p));
        const key = JSON.stringify([p.plugin_id, p.action, p.input, p.interval_seconds]);
        if (!m.persistedJobs.has(key)) m.persistedJobs.set(key, 'job-' + (m.persistedJobs.size + 1));
        if (m.scheduleErrorOnce) {
          m.scheduleErrorOnce = false;
          throw Object.assign(new Error('synthetic timeout'), { code: 'LocalTimeout' });
        }
        if (m.onSchedule) await m.onSchedule(structuredClone(p));
        const jobId = m.persistedJobs.get(key);
        return {
          job_id: jobId,
          run_at: p.run_at,
          state: 'scheduled',
          wake_up: { state: 'armed', wake_at: p.prepare_at || p.run_at },
        };
      },
      cancel: async p => { calls.push(p); },
      status: async p => {
        if (!m.grants.has('jobs.status')) throw Object.assign(new Error('denied'), { code: 'PermissionDenied' });
        return { id: p.job_id, state: 'scheduled', run_at: '2031-01-02T06:59:01.000Z' };
      },
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

test('manifest declares generic UI v1 schema and required actions', () => {
  assert.equal(manifest.api_version, 1);
  assert.ok(manifest.capabilities.includes('jobs.status'));
  assert.ok(manifest.actions.listTasks);
  assert.equal(manifest.actions.listTasks.mutating, false);
  assert.ok(manifest.actions.venueOptions);
  assert.ok(manifest.actions.slotOptions);
  assert.ok(manifest.actions.prepareSchedule);

  const formEntry = manifest.ui.find(u => u.id === 'sports_schedule');
  assert.ok(formEntry, 'form entry must exist');
  assert.equal(formEntry.ui_version, 1);
  assert.equal(formEntry.time_zone, 'Asia/Shanghai');
  assert.ok(Array.isArray(formEntry.fields));
  assert.ok(Array.isArray(formEntry.buttons));

  // Verify field types
  const fieldTypes = formEntry.fields.map(f => f.type);
  assert.ok(fieldTypes.includes('identifier'));
  assert.ok(fieldTypes.includes('select'));
  assert.ok(fieldTypes.includes('date'));
  assert.ok(fieldTypes.includes('datetime'));
  assert.ok(fieldTypes.includes('multiselect'));

  // Verify source with action and dependsOn
  const slotField = formEntry.fields.find(f => f.id === 'selected_slots');
  assert.deepEqual(slotField.source.dependsOn, ['venue_id', 'target_date']);

  // Verify button prepare action
  const button = formEntry.buttons[0];
  assert.equal(button.action, 'schedule');
  assert.equal(button.prepare, 'prepareSchedule');
  assert.equal(button.confirm, true);
});

test('venueOptions and slotOptions provide [{label, value}] dynamic sources', async () => {
  const m = mock();
  const vOptions = await venueOptions(m.ctx, { account_id: 'fixture-a' });
  assert.ok(Array.isArray(vOptions));
  assert.equal(vOptions.length, 2);
  assert.deepEqual(vOptions[0], { label: '江湾羽毛球馆', value: 900 });

  // Missing dependencies returns empty array safely
  assert.deepEqual(await slotOptions(m.ctx, { account_id: 'fixture-a' }), []);
  assert.deepEqual(await slotOptions(m.ctx, { account_id: 'fixture-a', venue_id: 900 }), []);

  // With venue_id and target_date returns slot options
  const sOptions = await slotOptions(m.ctx, {
    account_id: 'fixture-a',
    venue_id: 900,
    target_date: '2031-01-04',
  });
  assert.ok(sOptions.length > 0);
  assert.ok(sOptions[0].label.includes('10:00-11:00'));
  assert.equal(sOptions[0].value.time, '10:00-11:00');
  assert.equal(sOptions[0].value.period_id, 70);
});

test('prepareSchedule normalizes UI form selection into canonical SportsPlan', async () => {
  const m = mock();
  const input = {
    account_id: 'fixture-a',
    venue_id: { value: 900 },
    target_date: '2031-01-04',
    // Dart datetime format with Shanghai offset
    release_at: '2031-01-02T07:00:01+08:00',
    selected_slots: [
      { time: '10:00-11:00', period_id: 70, court_id: 901 },
      { time: '10:00-11:00', period_id: 70, court_id: 902 },
      { time: '14:00-15:00', period_id: 71, court_id: 901 },
    ],
  };

  const prepared = await prepareSchedule(m.ctx, input);
  assert.ok(prepared.canonical_input);
  assert.ok(prepared.summary);
  assert.ok(prepared.task_id);
  assert.equal(prepared.account_id, 'fixture-a');
  assert.equal(prepared.venue_id, 900);
  assert.equal(prepared.plans.length, 2);
  // Grouped courts for 10:00-11:00
  assert.deepEqual(prepared.plans[0], { time: '10:00-11:00', period_id: 70, courts: [901, 902] });
  assert.deepEqual(prepared.plans[1], { time: '14:00-15:00', period_id: 71, courts: [901] });

  // Schedule accepts canonical input directly or wrapped in canonical_input
  const schedResult = await time(m, () => schedule(m.ctx, prepared));
  assert.equal(schedResult.task_id, prepared.task_id);
  assert.ok(schedResult.job_id);
  assert.ok(schedResult.wake_up);
});

test('listTasks is scoped strictly to owner/account and returns safe summaries', async () => {
  const m = mock();
  await time(m, () => schedule(m.ctx, plan({ task_id: 'task-1' })));

  // Account fixture-a sees task-1
  const listA = await listTasks(m.ctx, { account_id: 'fixture-a' });
  assert.equal(listA.length, 1);
  assert.equal(listA[0].task_id, 'task-1');
  assert.equal(listA[0].account_id, 'fixture-a');
  assert.equal(listA[0].status, 'scheduled');
  assert.equal(listA[0].display_status, 'waiting_wake');
  assert.equal(listA[0].job_id, 'job-1');
  assert.ok(listA[0].wake_up);
  assert.equal(listA[0].wake_up.state, 'armed');
  assert.ok(listA[0].subtask);
  assert.equal(listA[0].subtask.id, 'job-1');

  // Account fixture-b sees nothing
  const listB = await listTasks(m.ctx, { account_id: 'fixture-b' });
  assert.equal(listB.length, 0);

  // Invalid account is rejected
  await assert.rejects(listTasks(m.ctx, {}), { code: 'InvalidAccount' });

  // Safe summary verification: no credentials, passwords or session handles leaked
  const serialized = JSON.stringify(listA);
  assert.equal(serialized.includes('opaque-fixture-session'), false);
  assert.equal(serialized.includes('password'), false);
});

test('late enqueue acknowledgement never overwrites a user stop arriving in-flight', async () => {
  const m = mock();
  m.now = RELEASE - 60000;
  // User issues stop while schedule's enqueue is in-flight awaiting ACK
  m.onSchedule = async () => {
    m.onSchedule = null;
    await stop(m.ctx, plan());
  };

  const result = await time(m, () => schedule(m.ctx, plan()));
  const tasks = await listTasks(m.ctx, { account_id: 'fixture-a' });
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].status, 'stopped');
  assert.equal(result.status, 'stopped');
});

test('late enqueue acknowledgement never rolls back sequence or overwrites wake_up of advanced child', async () => {
  const m = mock();
  m.now = RELEASE - 60000;
  m.onSchedule = async p => {
    m.onSchedule = null;
    await tick(m.ctx, p.input);
  };

  const result = await time(m, () => schedule(m.ctx, plan()));
  assert.equal(result.sequence, 2);
  const tasks = await listTasks(m.ctx, { account_id: 'fixture-a' });
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].sequence, 2);
  assert.equal(tasks[0].job_id, 'job-2');
});

test('enable and disable lifecycle: disabled plugin cannot mutate and re-enabling resumes cleanly', async () => {
  const m = mock();
  await time(m, () => schedule(m.ctx, plan()));

  // Simulate disabling plugin: write and schedule capabilities revoked
  m.grants.delete('browser.write');
  m.grants.delete('jobs.schedule');

  // Direct write request is immediately rejected with PermissionDenied
  await assert.rejects(m.ctx.browser.request({
    method: 'POST',
    url: 'https://booking.fudan.edu.cn/reservation/site/resource/launch',
    account_id: 'fixture-a',
    session_handle: 'h',
    headers: {},
  }), { code: 'PermissionDenied' });
  assert.equal(m.writes.length, 0);

  // Scheduling another task while disabled fails with PermissionDenied
  await assert.rejects(time(m, () => schedule(m.ctx, plan({ task_id: 'disabled-task', target_date: '2031-01-05' }))), {
    code: 'PermissionDenied',
  });

  // Read-only listTasks continues to work while disabled
  const tasksWhileDisabled = await listTasks(m.ctx, { account_id: 'fixture-a' });
  assert.equal(tasksWhileDisabled.length, 2);
  assert.ok(tasksWhileDisabled.some(t => t.task_id === 'fixture-task'));

  // Simulate re-enabling plugin: capabilities restored
  m.grants.add('browser.write');
  m.grants.add('jobs.schedule');

  // Continuation proceeds cleanly when re-enabled
  m.now = RELEASE + 300;
  const tickResult = await time(m, () => tick(m.ctx, { account_id: 'fixture-a', task_id: 'fixture-task', sequence: 1 }));
  assert.equal(tickResult.status, 'completed');
  assert.equal(m.writes.length, 1);

  const finalTasks = await listTasks(m.ctx, { account_id: 'fixture-a' });
  assert.equal(finalTasks[0].status, 'completed');
});

test('manifest exposes all 8 required generic UI entries omitting tick with valid schema', () => {
  const uiIds = manifest.ui.map(u => u.id);
  assert.ok(uiIds.includes('visible_login'));
  assert.ok(uiIds.includes('venue_calendar'));
  assert.ok(uiIds.includes('sports_schedule'));
  assert.ok(uiIds.includes('task_list'));
  assert.ok(uiIds.includes('task_management'));
  assert.ok(uiIds.includes('appointment_history'));
  assert.ok(uiIds.includes('appointment_detail'));
  assert.ok(uiIds.includes('cancel_appointment'));

  // tick MUST NOT be exposed in UI entries
  assert.equal(uiIds.includes('tick'), false);
  for (const entry of manifest.ui) {
    if (entry.buttons) {
      assert.equal(entry.buttons.some(b => b.action === 'tick'), false, `Entry ${entry.id} must not expose tick action`);
    }
  }

  // Check cancellation UI entry
  const cancelEntry = manifest.ui.find(u => u.id === 'cancel_appointment');
  assert.ok(cancelEntry);
  assert.equal(cancelEntry.ui_version, 1);
  assert.equal(cancelEntry.fields[0].id, 'appointment_id');
  assert.equal(cancelEntry.fields[0].type, 'select');
  assert.equal(cancelEntry.fields[0].source.action, 'cancellableAppointmentOptions');
  assert.equal(cancelEntry.buttons[0].action, 'cancelAppointment');
  assert.equal(cancelEntry.buttons[0].prepare, 'prepareCancelAppointment');
  assert.equal(cancelEntry.buttons[0].confirm, true);
});

test('UI option selectors normalize options into label and value pairs', async () => {
  const m = mock();
  m.history = [
    {
      id: 5566,
      resource_name: '江湾羽毛球馆 1号场',
      status: 1,
      type: 1,
      is_cancel: true,
      slots: [{ date: '2031-01-04', time: '10:00-11:00', resource_name: '1号场', active: true, can_cancel: true }],
    },
    {
      id: 7788,
      resource_name: '正大健身房',
      status: 1,
      type: 7,
      is_cancel: false,
      slots: [{ date: '2031-01-05', time: '15:00-16:00', resource_name: '健身房', active: true, can_cancel: true }],
    },
  ];

  await time(m, () => schedule(m.ctx, plan({ task_id: 'task-opt' })));

  const tOptions = await taskOptions(m.ctx, { account_id: 'fixture-a' });
  assert.ok(Array.isArray(tOptions));
  assert.equal(tOptions.length, 1);
  assert.equal(tOptions[0].value, 'task-opt');
  assert.ok(tOptions[0].label.includes('task-opt'));

  const aOptions = await appointmentOptions(m.ctx, { account_id: 'fixture-a' });
  assert.equal(aOptions.length, 2);
  assert.equal(aOptions[0].value, 5566);
  assert.equal(aOptions[1].value, 7788);

  const cOptions = await cancellableAppointmentOptions(m.ctx, { account_id: 'fixture-a' });
  assert.equal(cOptions.length, 2); // 5566 is_cancel: true, 7788 type: 7 (third party)
  assert.equal(cOptions[0].value, 5566);
  assert.equal(cOptions[1].value, 7788);
});

test('cancellation preparation and execution: normal and 3rd-party with fresh re-read and broadening rejection', async () => {
  const m = mock();
  m.history = [
    {
      id: 5566,
      resource_name: '江湾羽毛球馆 1号场',
      status: 1,
      type: 1,
      is_group: false,
      is_cancel: true,
      is_all_cancel: false,
      slots: [{
        date: '2031-01-04',
        time: '10:00-11:00',
        resource_name: '1号场',
        resource_id: 901,
        detail_id: 101,
        appointment_data_id: 201,
        active: true,
        can_cancel: true,
      }],
    },
    {
      id: 5567,
      resource_name: '江湾羽毛球馆 2号场',
      status: 1,
      type: 1,
      is_group: false,
      is_cancel: true,
      is_all_cancel: false,
      slots: [{
        date: '2031-01-04',
        time: '14:00-15:00',
        resource_name: '2号场',
        resource_id: 902,
        detail_id: 102,
        appointment_data_id: 202,
        active: true,
        can_cancel: true,
      }],
    },
    {
      id: 7788,
      resource_name: '正大健身房',
      status: 1,
      type: 7,
      is_group: false,
      is_cancel: false,
      is_all_cancel: false,
      slots: [{
        date: '2031-01-05',
        time: '15:00-16:00',
        resource_name: '健身房',
        active: true,
        can_cancel: true,
      }],
    },
  ];

  // 1. Standard appointment preparation
  const prepNormal = await prepareCancelAppointment(m.ctx, { account_id: 'fixture-a', appointment_id: 5566 });
  assert.ok(prepNormal.canonical_input);
  assert.equal(prepNormal.appointment_id, 5566);
  assert.deepEqual(prepNormal.appointment_detail_id, [101]);
  assert.deepEqual(prepNormal.appointment_data_ids, []);
  assert.equal(prepNormal.is_third_party, false);

  // 2. Normal execution with fresh re-check succeeding
  const cancelResult = await cancelAppointment(m.ctx, prepNormal);
  assert.equal(cancelResult.status, 'cancelled');
  assert.equal(cancelResult.appointment_id, 5566);
  assert.equal(m.writes.length, 1);
  assert.equal(m.writes[0].mutation_key, 'cancel:fixture-a:5566');
  assert.equal(m.writes[0].form_fields.appointment_id, '5566');
  assert.equal(m.writes[0].form_fields.appointment_detail_id, '[101]');

  // 3. Tampering / broadened detail IDs rejected at execution
  const prepTampered = await prepareCancelAppointment(m.ctx, { account_id: 'fixture-a', appointment_id: 5567 });
  prepTampered.canonical_input.appointment_detail_id = [102, 999]; // Broadened IDs
  await assert.rejects(cancelAppointment(m.ctx, prepTampered), { code: 'CancellationNotAllowed' });

  // 4. Third-party appointment cancellation
  const prepThirdParty = await prepareCancelAppointment(m.ctx, { account_id: 'fixture-a', appointment_id: 7788 });
  assert.equal(prepThirdParty.is_third_party, true);
  assert.ok(prepThirdParty.endpoint.includes('third-party'));

  const tpResult = await cancelAppointment(m.ctx, prepThirdParty);
  assert.equal(tpResult.status, 'cancelled');
  assert.equal(tpResult.appointment_id, 7788);
  assert.equal(m.writes.length, 2);
  assert.ok(m.writes[1].url.includes('third-party/cancel-appointment'));
  assert.equal(m.writes[1].form_fields.appointment_id, '7788');
  assert.equal(m.writes[1].form_fields.appointment_detail_id, undefined);
});

test('host policy binding_v1: schedule launch projections, choices, keys and form matching', () => {
  assert.ok(HOST_POLICY.binding_v1);
  assert.equal(HOST_POLICY.binding_v1.binding_version, 1);
  assert.equal(HOST_POLICY.binding_v1.plugin_id, 'official.fudan-sports');
  assert.ok(Array.isArray(HOST_POLICY.binding_v1.rules));
  assert.equal(HOST_POLICY.binding_v1.rules.length, 3);

  const consentInput = {
    account_id: 'student_a',
    task_id: 'task_100',
    venue_id: 900,
    target_date: '2031-01-04',
    release_at: '2031-01-02T07:00:01+08:00',
    plans: [
      {
        time: '10:00-11:00',
        period_id: 70,
        courts: [901, 902],
      },
    ],
  };

  // Valid projection matching choice 901, round 1
  const validKey = 'task:student_a:task_100:1:70:901';
  const validForm = {
    data: JSON.stringify([{
      resource_ids: [901],
      group_id: 900,
      period: [{ date: '2031-01-04', period_id: 70 }],
      number: 1,
    }]),
    data_colle: '[]',
    collective: '0',
    captcha: JSON.stringify({ token: '', pointJson: '' }),
  };

  const req = {
    url: 'https://booking.fudan.edu.cn/reservation/site/resource/launch',
    transport: 'xhr',
    headers: {
      Accept: 'application/json, text/plain, */*',
      'sign-key': '/reservation/site/resource/launchpost',
    },
    mutation_key: validKey,
    form_fields: validForm,
  };

  assert.equal(matchBindingRule(HOST_POLICY, 'schedule', req, consentInput, 1), true);

  // Valid projection matching choice 902, round 3
  const validKey2 = 'task:student_a:task_100:3:70:902';
  const validForm2 = {
    ...validForm,
    data: JSON.stringify([{
      resource_ids: [902],
      group_id: 900,
      period: [{ date: '2031-01-04', period_id: 70 }],
      number: 1,
    }]),
  };
  assert.equal(matchBindingRule(HOST_POLICY, 'schedule', { ...req, mutation_key: validKey2, form_fields: validForm2 }, consentInput, 3), true);

  // Tampered choice (court 999 not in consent courts [901, 902])
  const tamperedChoiceKey = 'task:student_a:task_100:1:70:999';
  const tamperedChoiceForm = {
    ...validForm,
    data: JSON.stringify([{
      resource_ids: [999],
      group_id: 900,
      period: [{ date: '2031-01-04', period_id: 70 }],
      number: 1,
    }]),
  };
  assert.equal(matchBindingRule(HOST_POLICY, 'schedule', { ...req, mutation_key: tamperedChoiceKey, form_fields: tamperedChoiceForm }, consentInput, 1), false);

  // Tampered venue ID (999 instead of 900)
  const tamperedVenueForm = {
    ...validForm,
    data: JSON.stringify([{
      resource_ids: [901],
      group_id: 999,
      period: [{ date: '2031-01-04', period_id: 70 }],
      number: 1,
    }]),
  };
  assert.equal(matchBindingRule(HOST_POLICY, 'schedule', { ...req, form_fields: tamperedVenueForm }, consentInput, 1), false);

  // Extra unmapped field rejected by default deny
  const extraFieldForm = { ...validForm, unapproved_field: 'malicious' };
  assert.equal(matchBindingRule(HOST_POLICY, 'schedule', { ...req, form_fields: extraFieldForm }, consentInput, 1), false);

  // Non-finite or negative round rejected
  const invalidRoundKey = 'task:student_a:task_100:0:70:901';
  assert.equal(matchBindingRule(HOST_POLICY, 'schedule', { ...req, mutation_key: invalidRoundKey }, consentInput, 0), false);
});

test('host policy binding_v1: cancel rules for standard and 3rd-party endpoints', () => {
  const cancelConsent = {
    account_id: 'student_a',
    appointment_id: '5566',
    appointment_detail_id: [101],
    appointment_data_ids: [],
  };

  const validCancelKey = 'cancel:student_a:5566';
  const validCancelForm = {
    appointment_id: '5566',
    appointment_detail_id: '[101]',
    appointment_data_ids: '[]',
  };

  const normalReq = {
    url: 'https://booking.fudan.edu.cn/reservation/site/appointment/appointment-cancel',
    transport: 'xhr',
    headers: {
      Accept: 'application/json, text/plain, */*',
      'sign-key': '/reservation/site/appointment/appointment-cancelpost',
    },
    mutation_key: validCancelKey,
    form_fields: validCancelForm,
  };

  assert.equal(matchBindingRule(HOST_POLICY, 'cancelAppointment', normalReq, cancelConsent), true);

  // Mismatched appointment ID in key or form rejected
  assert.equal(matchBindingRule(HOST_POLICY, 'cancelAppointment', { ...normalReq, mutation_key: 'cancel:student_a:9999' }, cancelConsent), false);
  assert.equal(matchBindingRule(HOST_POLICY, 'cancelAppointment', { ...normalReq, form_fields: { ...validCancelForm, appointment_id: '9999' } }, cancelConsent), false);

  // Third-party cancel rule
  const thirdPartyConsent = {
    account_id: 'student_a',
    appointment_id: '7788',
  };
  const tpReq = {
    url: 'https://booking.fudan.edu.cn/reservation/site/third-party/cancel-appointment',
    transport: 'xhr',
    headers: {
      Accept: 'application/json, text/plain, */*',
      'sign-key': '/reservation/site/third-party/cancel-appointmentpost',
    },
    mutation_key: 'cancel:student_a:7788',
    form_fields: { appointment_id: '7788' },
  };

  assert.equal(matchBindingRule(HOST_POLICY, 'cancelAppointment', tpReq, thirdPartyConsent), true);
});

test('identity probe fails closed without authoritative source, synthetic override in QA, and write uncertainty evaluation', () => {
  const published = HOST_POLICY.binding_v1.identity_probe;
  assert.equal(published.url,'https://booking.fudan.edu.cn/reservation/site/user/detail');
  assert.equal(published.json_pointer,'/d/number');

  const probeSession = { authenticated: true, session_handle: 'h-1' };
  // Fails closed with IdentityVerificationUnavailable
  assert.throws(() => verifyIdentityProbe('student1', probeSession, null), {
    code: 'IdentityVerificationUnavailable',
  });

  // QA synthetic probe override verification
  const syntheticProbe = {
    url: 'https://booking.fudan.edu.cn/api/user/whoami',
    method: 'GET',
    top_level_origin: 'https://booking.fudan.edu.cn',
    json_pointer: '/data/user/account_id',
  };

  const syntheticSession = {
    authenticated: true,
    body: { data: { user: { account_id: 'student1' } } },
  };

  const verified = verifyIdentityProbe('student1', syntheticSession, syntheticProbe);
  assert.equal(verified.verified, true);
  assert.equal(verified.account_id, 'student1');

  // Mismatch triggers AccountMismatch
  assert.throws(() => verifyIdentityProbe('student2', syntheticSession, syntheticProbe), { code: 'AccountMismatch' });

  // Unauthenticated triggers AuthenticationRequired
  assert.throws(() => verifyIdentityProbe('student1', { authenticated: false }, syntheticProbe), { code: 'AuthenticationRequired' });

  // Write uncertainty classification
  assert.equal(evaluateWriteOutcome(Object.assign(new Error('timeout'), { code: 'NeedsReconciliation' })), 'uncertain');
  assert.equal(evaluateWriteOutcome(Object.assign(new Error('timeout'), { code: 'LocalTimeout' })), 'uncertain');
  assert.equal(evaluateWriteOutcome({ status: 412 }), 'uncertain');
  assert.equal(evaluateWriteOutcome({ status: 502 }), 'uncertain');
  assert.equal(evaluateWriteOutcome({ status: 200 }), 'confirmed');
});

test('deterministic pack command produces reproducible .dspack outside tracked files', () => {
  const packTarget = resolve('.local/test-pack/official.fudan-sports.dspack');
  if (existsSync(packTarget)) rmSync(packTarget, { force: true });

  const first = pack(packTarget);
  assert.ok(existsSync(packTarget));
  assert.ok(first.byteLength > 0);
  assert.ok(first.entries.includes('manifest.json'));
  assert.ok(first.entries.includes('main.mjs'));
  assert.ok(first.entries.includes('host-policy.json'));
  assert.ok(first.entries.includes('README.md'));
  assert.equal(first.entries.some(e => e.includes('test')), false);

  const second = pack(packTarget);
  // Byte-exact deterministic hash
  assert.equal(first.sha256, second.sha256);
  assert.equal(first.byteLength, second.byteLength);

  rmSync(resolve('.local/test-pack'), { recursive: true, force: true });
});
