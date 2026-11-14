// SPDX-License-Identifier: GPL-3.0-or-later
// Selection and timing derived from DanXi-local-sports, Copyright DanXi-Dev.
export const DEFAULT_OPTIONS = Object.freeze({
  nativePrewarmMs: 300000, browserPreloadMs: 60000, firstShotDelayMs: 300,
  windowMs: 300000, scheduleRefreshMs: 15000, throttleBackoffMs: 800,
  errorBackoffMs: 800, roundPauseMs: 1200, requestTimeoutMs: 8000,
  maxReservationSlots: 3,
});
export function fault(code) { const e = new Error(code); e.code = code; return e; }
export function account(input) {
  if (!input || typeof input.account_id !== 'string' || !/^[A-Za-z0-9_.:@-]{1,160}$/.test(input.account_id)) throw fault('InvalidAccount');
  return input.account_id;
}
export function positive(value) {
  if (!Number.isSafeInteger(value) || value <= 0) throw fault('InvalidId');
  return value;
}
export function taskKey(input) {
  account(input);
  if (typeof input.task_id !== 'string' || !/^[A-Za-z0-9_-]{1,100}$/.test(input.task_id)) throw fault('InvalidTask');
  return 'task:' + input.account_id + ':' + input.task_id;
}
export function options(input = {}) {
  const result = { ...DEFAULT_OPTIONS };
  for (const key of Object.keys(input)) {
    if (!Object.prototype.hasOwnProperty.call(DEFAULT_OPTIONS, key)) throw fault('InvalidOptions');
    if (!Number.isSafeInteger(input[key]) || input[key] < 0 || input[key] > 600000) throw fault('InvalidOptions');
    result[key] = input[key];
  }
  if (!result.windowMs || !result.requestTimeoutMs || !result.scheduleRefreshMs || !result.roundPauseMs ||
      result.browserPreloadMs > result.nativePrewarmMs || result.firstShotDelayMs >= result.windowMs ||
      result.maxReservationSlots < 1 || result.maxReservationSlots > 3) throw fault('InvalidOptions');
  return result;
}
export function validatePlan(input) {
  account(input); taskKey(input); positive(input.venue_id);
  if (typeof input.target_date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(input.target_date) ||
      new Date(input.target_date + 'T00:00:00Z').toISOString().slice(0, 10) !== input.target_date) throw fault('InvalidDate');
  // Require an explicit offset, so Shanghai release time is not interpreted in device timezone.
  if (typeof input.release_at !== 'string' || !/(?:Z|[+-]\d\d:\d\d)$/.test(input.release_at) || !Number.isFinite(Date.parse(input.release_at))) throw fault('InvalidReleaseTime');
  const o = options(input.options);
  if (!Array.isArray(input.plans) || input.plans.length < 1 || input.plans.length > o.maxReservationSlots) throw fault('InvalidPlan');
  const seen = new Set();
  const plans = input.plans.map(p => {
    if (!p || typeof p.time !== 'string' || !p.time.trim() || p.time.length > 80 || seen.has(p.time) ||
        !Array.isArray(p.courts) || !p.courts.length || p.courts.length > 50 || new Set(p.courts).size !== p.courts.length) throw fault('InvalidPlan');
    seen.add(p.time);
    return { time: p.time, period_id: p.period_id == null ? null : positive(p.period_id), courts: p.courts.map(positive) };
  });
  return { task_id: input.task_id, account_id: input.account_id, venue_id: input.venue_id,
    target_date: input.target_date, release_at: input.release_at, plans, options: o };
}
export function classify(response) {
  if (response.e === 'OK' || response.e === 0 || response.e === '0') return 'success';
  const m = typeof response.m === 'string' ? response.m : '';
  if (/未结束的预约|已有预约/.test(m)) return 'existingReservation';
  if (/拥挤|频繁/.test(m)) return 'throttled';
  if (/未到预约时间|不在预约时间|预约时间未开始|未开放|服务时间/.test(m)) return 'notOpen';
  if (/容量不足|已被|抢完|已满/.test(m)) return 'gone';
  return 'failed';
}
export function calendarData(data) {
  if (!data || !Array.isArray(data.time)) throw fault('InvalidCalendar');
  return { periods: data.time.filter(t => t && Number.isSafeInteger(Number(t.id)) && Number(t.id) > 0 && typeof t.str_time === 'string')
    .map(t => ({ id: Number(t.id), time: t.str_time })), courts: (Array.isArray(data.resource) ? data.resource : [])
    .filter(c => c && Number.isSafeInteger(Number(c.id)) && typeof c.name === 'string').map(c => ({ id: Number(c.id), name: c.name })) };
}
