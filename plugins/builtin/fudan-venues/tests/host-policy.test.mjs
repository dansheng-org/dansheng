// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  HOST_POLICY,
  verifyIdentityProbe,
  evaluateKey,
  evaluateForm,
  matchBindingRule,
} from './host-policy-fixture.mjs';

import {
  FIXTURE_ACCOUNT,
  FIXTURE_VENUE_ID,
  FIXTURE_DATE,
  IDENTITY_PROBE_SUCCESS,
  IDENTITY_PROBE_MISMATCH,
} from './fixtures.mjs';

import { normalizeManualInput, launchForm } from '../policy.mjs';

test('host-policy: valid binding_v1 specification', () => {
  const binding = HOST_POLICY.binding_v1;
  assert.ok(binding, 'binding_v1 must be declared');
  assert.equal(binding.binding_version, 1);
  assert.equal(binding.plugin_id, 'official.fudan-venues');

  // Verify identity probe
  const probe = binding.identity_probe;
  assert.ok(probe);
  assert.equal(probe.url, 'https://booking.fudan.edu.cn/reservation/site/user/detail');
  assert.equal(probe.method, 'GET');
  assert.equal(probe.json_pointer, '/d/number');
  assert.equal(probe.headers['sign-key'], '/reservation/site/user/detailget');

  // Verify reserve rule
  const reserveRule = binding.rules.find(r => r.action === 'reserve');
  assert.ok(reserveRule, 'reserve rule must exist');
  assert.equal(reserveRule.url, 'https://booking.fudan.edu.cn/reservation/site/resource/launch');
  assert.equal(reserveRule.transport, 'xhr');
  assert.equal(reserveRule.headers['sign-key'], '/reservation/site/resource/launchpost');
});

test('identity-probe: verifies correct account extraction from /d/number', () => {
  const probeConfig = HOST_POLICY.binding_v1.identity_probe;

  // Matching account succeeds
  const res = verifyIdentityProbe(FIXTURE_ACCOUNT, IDENTITY_PROBE_SUCCESS, probeConfig);
  assert.equal(res.verified, true);
  assert.equal(res.account_id, FIXTURE_ACCOUNT);

  // Mismatched account throws AccountMismatch
  assert.throws(
    () => verifyIdentityProbe(FIXTURE_ACCOUNT, IDENTITY_PROBE_MISMATCH, probeConfig),
    { code: 'AccountMismatch' }
  );

  // Unauthenticated throws AuthenticationRequired
  assert.throws(
    () => verifyIdentityProbe(FIXTURE_ACCOUNT, { authenticated: false }, probeConfig),
    { code: 'AuthenticationRequired' }
  );

  // Missing or corrupted probe config fails closed
  assert.throws(
    () => verifyIdentityProbe(FIXTURE_ACCOUNT, IDENTITY_PROBE_SUCCESS, null),
    { code: 'IdentityVerificationUnavailable' }
  );
  assert.throws(
    () => verifyIdentityProbe(FIXTURE_ACCOUNT, IDENTITY_PROBE_SUCCESS, { json_pointer: null }),
    { code: 'IdentityVerificationUnavailable' }
  );
});

test('host-policy: evaluates key format keyed by account/task/date/venue/period/court', () => {
  const reserveRule = HOST_POLICY.binding_v1.rules.find(r => r.action === 'reserve');
  const canonical = normalizeManualInput({
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-77',
    venue_id: FIXTURE_VENUE_ID,
    target_date: FIXTURE_DATE,
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  const generatedKey = evaluateKey(reserveRule.key, canonical);
  const expectedKey = `manual:${FIXTURE_ACCOUNT}:task-77:${FIXTURE_DATE}:${FIXTURE_VENUE_ID}:70:901`;
  assert.equal(generatedKey, expectedKey);
  assert.equal(canonical.mutation_key, expectedKey);
});

test('host-policy: rule matching against canonical reservation POST', () => {
  const canonical = normalizeManualInput({
    account_id: FIXTURE_ACCOUNT,
    task_id: 'task-match',
    venue_id: FIXTURE_VENUE_ID,
    target_date: FIXTURE_DATE,
    period_id: 70,
    court_id: 901,
    time: '10:00-11:00',
  });

  const validReq = {
    url: 'https://booking.fudan.edu.cn/reservation/site/resource/launch',
    method: 'POST',
    transport: 'xhr',
    headers: {
      Accept: 'application/json, text/plain, */*',
      'sign-key': '/reservation/site/resource/launchpost',
    },
    mutation_key: canonical.mutation_key,
    form_fields: launchForm(canonical),
  };

  // Valid request matches rule
  assert.equal(matchBindingRule(HOST_POLICY, 'reserve', validReq, canonical), true);

  // Wrong mutation key fails match
  const badKeyReq = { ...validReq, mutation_key: 'manual:wrong-key' };
  assert.equal(matchBindingRule(HOST_POLICY, 'reserve', badKeyReq, canonical), false);

  // Wrong sign-key fails match
  const badHeaderReq = { ...validReq, headers: { Accept: 'application/json' } };
  assert.equal(matchBindingRule(HOST_POLICY, 'reserve', badHeaderReq, canonical), false);

  // Mismatched court in form fields fails match
  const badForm = structuredClone(validReq.form_fields);
  badForm.data = JSON.stringify([{
    resource_ids: [999], // court 999 instead of 901
    group_id: FIXTURE_VENUE_ID,
    period: [{ date: FIXTURE_DATE, period_id: 70 }],
    number: 1,
  }]);
  const badFormReq = { ...validReq, form_fields: badForm };
  assert.equal(matchBindingRule(HOST_POLICY, 'reserve', badFormReq, canonical), false);
});

test('host-policy: valid cancel rules and key format', () => {
  const binding = HOST_POLICY.binding_v1;
  const cancelRules = binding.rules.filter(r => r.action === 'cancel');
  assert.equal(cancelRules.length, 2, 'Must have normal and third-party cancel rules');

  const normalRule = cancelRules.find(r => r.url.includes('/appointment-cancel'));
  assert.ok(normalRule);
  assert.equal(normalRule.headers['sign-key'], '/reservation/site/appointment/appointment-cancelpost');

  const thirdPartyRule = cancelRules.find(r => r.url.includes('/third-party/cancel-appointment'));
  assert.ok(thirdPartyRule);
  assert.equal(thirdPartyRule.headers['sign-key'], '/reservation/site/third-party/cancel-appointmentpost');

  const consentInput = {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5501,
    appointment_detail_id: [8801],
    appointment_data_ids: [],
  };

  const normalKey = evaluateKey(normalRule.key, consentInput);
  assert.equal(normalKey, `cancel:${FIXTURE_ACCOUNT}:5501`);

  const normalForm = evaluateForm(normalRule.form, consentInput);
  assert.equal(normalForm.appointment_id, '5501');
  assert.equal(normalForm.appointment_detail_id, JSON.stringify([8801]));
  assert.equal(normalForm.appointment_data_ids, JSON.stringify([]));

  const validNormalReq = {
    url: 'https://booking.fudan.edu.cn/reservation/site/appointment/appointment-cancel',
    method: 'POST',
    transport: 'xhr',
    headers: {
      Accept: 'application/json, text/plain, */*',
      'sign-key': '/reservation/site/appointment/appointment-cancelpost',
    },
    mutation_key: `cancel:${FIXTURE_ACCOUNT}:5501`,
    form_fields: normalForm,
  };
  assert.equal(matchBindingRule(HOST_POLICY, 'cancel', validNormalReq, consentInput), true);

  // Third-party cancel match
  const tpConsent = {
    account_id: FIXTURE_ACCOUNT,
    appointment_id: 5502,
  };
  const tpForm = evaluateForm(thirdPartyRule.form, tpConsent);
  assert.equal(tpForm.appointment_id, '5502');

  const validTpReq = {
    url: 'https://booking.fudan.edu.cn/reservation/site/third-party/cancel-appointment',
    method: 'POST',
    transport: 'xhr',
    headers: {
      Accept: 'application/json, text/plain, */*',
      'sign-key': '/reservation/site/third-party/cancel-appointmentpost',
    },
    mutation_key: `cancel:${FIXTURE_ACCOUNT}:5502`,
    form_fields: tpForm,
  };
  assert.equal(matchBindingRule(HOST_POLICY, 'cancel', validTpReq, tpConsent), true);

  // Mismatched key fails rule match
  const badCancelKeyReq = { ...validNormalReq, mutation_key: 'cancel:other-user:5501' };
  assert.equal(matchBindingRule(HOST_POLICY, 'cancel', badCancelKeyReq, consentInput), false);

  // Mismatched sign-key fails rule match
  const badCancelSignReq = { ...validNormalReq, headers: { Accept: 'application/json' } };
  assert.equal(matchBindingRule(HOST_POLICY, 'cancel', badCancelSignReq, consentInput), false);
});
