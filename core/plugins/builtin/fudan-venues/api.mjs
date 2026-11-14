// SPDX-License-Identifier: GPL-3.0-or-later
// DanXi-Dev reference-derived service client and session handling.
// No Node.js runtime globals or credentials. Runs inside mediated QuickJS.

import { account, fault } from './policy.mjs';

export const ORIGIN = 'https://booking.fudan.edu.cn';
export const TOPIC_PAGE = ORIGIN + '/reservation/fe/site/special/special?id=48';

export const PATHS = Object.freeze({
  venues: '/reservation/api/topic/resource-list',
  calendar: '/reservation/site/resource/calendar',
  appointments: '/reservation/site/appointment/appointment-list',
  legacyAppointments: '/reservation/site/appointmentList',
  detail: '/reservation/site/appointment/appointment-detail',
  launch: '/reservation/site/resource/launch',
  cancel: '/reservation/site/appointment/appointment-cancel',
  thirdPartyCancel: '/reservation/site/third-party/cancel-appointment',
  identity: '/reservation/site/user/detail',
});

export function query(path, params) {
  if (!params || Object.keys(params).length === 0) return path;
  const queryString = Object.keys(params)
    .map(k => encodeURIComponent(k) + '=' + encodeURIComponent(String(params[k])))
    .join('&');
  return path + '?' + queryString;
}

export async function session(ctx, input) {
  const id = account(input);
  if (!ctx || !ctx.browser || typeof ctx.browser.evaluate !== 'function') {
    throw fault('CapabilityUnavailable', 'Browser capability is unavailable');
  }
  const s = await ctx.browser.evaluate({
    operation: 'session.status',
    account_id: id,
    url: TOPIC_PAGE,
    require_authenticated: true,
  });
  if (!s || s.authenticated !== true || typeof s.session_handle !== 'string' || s.account_id !== id) {
    throw fault('AuthenticationRequired', 'Authenticated page session required');
  }
  return s.session_handle;
}

export async function request(ctx, input, path, fields, deadline = Date.now() + 8000) {
  const handle = await session(ctx, input);
  const write = fields !== undefined;

  let r;
  try {
    const params = {
      account_id: account(input),
      session_handle: handle,
      url: ORIGIN + path,
      method: write ? 'POST' : 'GET',
      transport: write ? 'xhr' : 'fetch',
      headers: write
        ? { Accept: 'application/json, text/plain, */*', 'sign-key': path + 'post' }
        : { Accept: 'application/json, text/plain, */*' },
      deadline_epoch_ms: deadline,
    };
    if (write) {
      if (typeof input.mutation_key === 'string' && input.mutation_key.length > 0) {
        params.mutation_key = input.mutation_key;
      }
      params.form_fields = fields;
    }
    r = await ctx.browser.request(params);
  } catch (e) {
    // Write outcomes on network errors or timeouts are uncertain and require reconciliation.
    // Explicit permission/auth rejections are definitive pre-write rejections.
    if (write && e.code === 'NeedsReconciliation') {
      e.from_browser_host = true;
      throw e;
    }
    const preWriteErrors = [
      'ApprovalRequired',
      'PermissionDenied',
      'AuthenticationRequired',
      'DeadlineExceeded',
      'SessionOwnershipMismatch',
    ];
    if (write && !preWriteErrors.includes(e.code)) {
      const wrapped = fault('NeedsReconciliation', e.message || 'Write request outcome is uncertain');
      wrapped.cause = e;
      wrapped.original_code = e.code;
      throw wrapped;
    }
    throw e;
  }

  if (!r || !Number.isInteger(r.status)) {
    throw fault(write ? 'NeedsReconciliation' : 'InvalidResponse', 'Missing or invalid HTTP status code');
  }

  // Handle auth redirection / expiration
  if (r.status === 401 || r.status === 403 || /https:\/\/(?:id|uis)\.fudan\.edu\.cn(?:\/|$)/.test(r.url || '')) {
    throw fault(write ? 'NeedsReconciliation' : 'AuthenticationRequired', 'Session expired or login redirect detected');
  }

  // WAF Challenge
  if (r.status === 412) {
    throw fault(write ? 'NeedsReconciliation' : 'WafChallengeRequired', 'WAF challenge encountered');
  }

  if (r.status !== 200) {
    throw fault(write ? 'NeedsReconciliation' : 'Http' + r.status, `HTTP error ${r.status}`);
  }

  if (typeof r.body !== 'string' || r.body.length > 1024 * 1024) {
    throw fault(write ? 'NeedsReconciliation' : 'InvalidResponse', 'Response body invalid or exceeds limit');
  }

  let body;
  try {
    body = JSON.parse(r.body);
  } catch {
    throw fault(write ? 'NeedsReconciliation' : 'AuthenticationRequired', 'Failed to parse JSON response body');
  }

  if (!body || typeof body !== 'object' || Array.isArray(body) || !Object.hasOwn(body, 'e')) {
    throw fault(write ? 'NeedsReconciliation' : 'InvalidResponse', 'Response JSON missing required envelope');
  }

  return body;
}

export async function history(ctx, input) {
  const params = { p: input.page || 1, pageSize: input.pageSize || 50, type: input.type ?? 0 };
  let response;
  try {
    response = await request(ctx, input, query(PATHS.appointments, params));
  } catch (e) {
    if (e.code !== 'Http404') throw e;
    response = await request(ctx, input, query(PATHS.legacyAppointments, params));
  }
  if (!['OK', 0, '0'].includes(response.e) || !response.d || !Array.isArray(response.d.data)) {
    throw fault('InvalidHistory', 'Malformed history response');
  }
  return response.d.data;
}
