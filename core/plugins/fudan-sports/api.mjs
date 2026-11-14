// SPDX-License-Identifier: GPL-3.0-or-later
// Endpoint/form contract derived from DanXi-Dev's GPL-3.0-or-later sports repository.
import { account, positive, fault } from './policy.mjs';
export const ORIGIN = 'https://booking.fudan.edu.cn';
export const TOPIC_PAGE = ORIGIN + '/reservation/fe/site/special/special?id=48';
export const PATHS = Object.freeze({
  venues: '/reservation/api/topic/resource-list', calendar: '/reservation/site/resource/calendar',
  appointments: '/reservation/site/appointment/appointment-list', legacyAppointments: '/reservation/site/appointmentList',
  detail: '/reservation/site/appointment/appointment-detail', launch: '/reservation/site/resource/launch',
  cancel: '/reservation/site/appointment/appointment-cancel', thirdPartyCancel: '/reservation/site/third-party/cancel-appointment',
});
export function query(path, params) {
  return path + '?' + Object.keys(params).map(k => encodeURIComponent(k) + '=' + encodeURIComponent(String(params[k]))).join('&');
}
export async function session(ctx, input) {
  const id = account(input);
  // Core's native HTTP auth.status is a DIFFERENT session. No cookie copying or fallback.
  // Let the trusted port produce the typed error that Core can persist as waiting_for_auth.
  const s = await ctx.browser.evaluate({ operation: 'session.status', account_id: id, url: TOPIC_PAGE, require_authenticated: true });
  if (!s || s.authenticated !== true || typeof s.session_handle !== 'string' || s.account_id !== id) throw fault('AuthenticationRequired');
  return s.session_handle;
}
export async function request(ctx, input, path, fields, deadline = Date.now() + 8000) {
  const handle = await session(ctx, input);
  const write = fields !== undefined;
  let r;
  try {
    r = await ctx.browser.request({ account_id: account(input), session_handle: handle,
      url: ORIGIN + path, method: write ? 'POST' : 'GET', transport: write ? 'xhr' : 'fetch',
      ...(write ? { mutation_key: input.mutation_key } : {}),
      headers: write ? { Accept: 'application/json, text/plain, */*', 'sign-key': path + 'post' } : { Accept: 'application/json, text/plain, */*' },
      ...(write ? { form_fields: fields } : {}), deadline_epoch_ms: deadline });
  } catch (e) {
    // Preserve the exact host error object: QuickJS brands host errors privately.
    // Core may close the job lease immediately on this error; do not perform more
    // host calls on that same lease and overwrite uncertainty with Cancelled.
    if (write && e.code === 'NeedsReconciliation') { e.from_browser_host = true; throw e; }
    if (write && !['ApprovalRequired', 'PermissionDenied', 'AuthenticationRequired', 'DeadlineExceeded', 'SessionOwnershipMismatch'].includes(e.code)) throw fault('NeedsReconciliation');
    throw e;
  }
  if (!r || !Number.isInteger(r.status)) throw fault(write ? 'NeedsReconciliation' : 'InvalidResponse');
  if (r.status === 401 || r.status === 403 || /https:\/\/(?:id|uis)\.fudan\.edu\.cn(?:\/|$)/.test(r.url || '')) throw fault(write ? 'NeedsReconciliation' : 'AuthenticationRequired');
  if (r.status === 412) throw fault(write ? 'NeedsReconciliation' : 'WafChallengeRequired');
  if (r.status !== 200) throw fault(write ? 'NeedsReconciliation' : 'Http' + r.status);
  if (typeof r.body !== 'string' || r.body.length > 1024 * 1024) throw fault(write ? 'NeedsReconciliation' : 'InvalidResponse');
  let body;
  try { body = JSON.parse(r.body); } catch { throw fault(write ? 'NeedsReconciliation' : 'AuthenticationRequired'); }
  if (!body || typeof body !== 'object' || Array.isArray(body) || !Object.hasOwn(body, 'e')) throw fault(write ? 'NeedsReconciliation' : 'InvalidResponse');
  return body;
}
export function launchFields(plan, periodId, courtId) {
  return { data: JSON.stringify([{ resource_ids: [positive(courtId)], group_id: positive(plan.venue_id),
    period: [{ date: plan.target_date, period_id: positive(periodId) }], number: 1 }]),
    data_colle: '[]', collective: '0', captcha: JSON.stringify({ token: '', pointJson: '' }) };
}
export async function history(ctx, input) {
  const params = { p: input.page || 1, pageSize: 50, type: 0 };
  let response;
  try { response = await request(ctx, input, query(PATHS.appointments, params)); }
  catch (e) { if (e.code !== 'Http404') throw e; response = await request(ctx, input, query(PATHS.legacyAppointments, params)); }
  if (!['OK', 0, '0'].includes(response.e) || !response.d || !Array.isArray(response.d.data)) throw fault('InvalidHistory');
  return response.d.data;
}
