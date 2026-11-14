// SPDX-License-Identifier: GPL-3.0-or-later
// DanXi-Dev reference-derived service policy. No Node, browser globals or credentials.
import { DEFAULT_OPTIONS, account, taskKey, positive, validatePlan, classify, calendarData, fault } from './policy.mjs';
import { ORIGIN, TOPIC_PAGE, PATHS, query, session, request, launchFields, history } from './api.mjs';
export { DEFAULT_OPTIONS };
export const SUPPORT = Object.freeze({ supportsAndroid: true, supportsDesktop: false, session: 'nativewebview' });
const PLUGIN = 'official.fudan-sports';
const ok = r => r.e === 'OK' || r.e === 0 || r.e === '0';
async function save(ctx, state) { await ctx.storage.set({ key: taskKey(state.plan), value: state }); }
async function load(ctx, input) {
  const state = await ctx.storage.get({ key: taskKey(input) });
  if (!state || !state.plan || state.plan.account_id !== account(input)) throw fault('TaskNotFound');
  return state;
}
async function publish(ctx, state) {
  await ctx.ui.publish({ id: 'sports', component: { type: 'card', title: 'Sports task',
    task_id: state.plan.task_id, account_id: state.plan.account_id, status: state.status,
    success_count: state.successes.length, planned_count: state.plan.plans.length,
    wake_status: state.wake_up?.state ?? (state.transition?.phase === 'scheduled' ? 'armed' : null),
    partial: state.successes.length > 0 && state.successes.length < state.plan.plans.length } });
}
async function enqueue(ctx, state, at) {
  const deadline = Date.parse(state.plan.release_at) + state.plan.options.windowMs;
  if (at >= deadline || Date.now() >= deadline) { state.status = 'expired'; await save(ctx, state); return state; }
  // Persist the next transition before scheduling. Retrying an unconfirmed local
  // enqueue reuses its sequence/time/input so core dedup finds the SAME job.
  // A consumed tick creates a DIFFERENT input even while its own job is running.
  if (state.transition?.phase !== 'pending_schedule') {
    const previous = state.sequence || 0;
    if (!Number.isSafeInteger(previous) || previous < 0 || previous >= Number.MAX_SAFE_INTEGER) throw fault('InvalidSequence');
    const runAt = Math.max(at, Date.now());
    state.last_consumed_sequence = previous;
    state.sequence = previous + 1;
    state.transition = { sequence: state.sequence, phase: 'pending_schedule', run_at: new Date(runAt).toISOString(),
      prepare_at: new Date(Math.max(Date.now(), Math.min(runAt, Date.parse(state.plan.release_at) - state.plan.options.nativePrewarmMs))).toISOString(),
      deadline_at: new Date(deadline).toISOString() };
  }
  const transition = state.transition;
  await save(ctx, state);
  const job = await ctx.jobs.schedule({ plugin_id: PLUGIN, action: 'tick', account_id: state.plan.account_id,
    run_at: transition.run_at, prepare_at: transition.prepare_at, deadline_at: transition.deadline_at,
    input: { account_id: state.plan.account_id, task_id: state.plan.task_id, sequence: transition.sequence } });
  const latest = await load(ctx, state.plan);
  if (latest.sequence !== transition.sequence || latest.transition?.phase !== 'pending_schedule' ||
      ['stopped', 'completed', 'expired', 'existingReservation'].includes(latest.status)) {
    // A due child may already have advanced while the parent waited for the
    // enqueue acknowledgement. Never restore an older sequence or undo a stop.
    Object.assign(state, latest);
    return state;
  }
  state.job_id = job.job_id;
  state.job_sequence = transition.sequence;
  state.wake_up = job.wake_up ?? null;
  state.wake_status = job.wake_up?.state ?? 'armed';
  state.transition.phase = 'scheduled';
  state.transition.job_id = job.job_id;
  state.transition.wake_up = job.wake_up ?? null;
  await save(ctx, state);
  return state;
}

export async function visibleLogin(ctx, input) {
  const p = { operation: 'session.requireLogin', account_id: account(input), url: TOPIC_PAGE };
  return typeof ctx.browser.login === 'function' ? ctx.browser.login(p) : ctx.browser.evaluate(p);
}

export async function venues(ctx, input) {
  const r = await request(ctx, input, query(PATHS.venues, { id: 48, pageSize: 200 }));
  if (!ok(r) || !r.d || !Array.isArray(r.d.data)) throw fault('InvalidVenues');
  return r.d.data.filter(v => v && v.base && Number.isSafeInteger(Number(v.base.id)) && typeof v.base.name === 'string')
    .map(v => ({
      id: Number(v.base.id),
      name: v.base.name,
      type: v.base.type ?? null,
      label: v.base.name,
      value: Number(v.base.id),
    }));
}

export async function venueOptions(ctx, input) {
  const list = await venues(ctx, input);
  return list.map(v => ({ label: v.name, value: Number(v.id) }));
}

export async function calendar(ctx, input) {
  positive(Number(input.venue_id?.value ?? input.venue_id));
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.target_date || '')) throw fault('InvalidDate');
  const r = await request(ctx, input, query(PATHS.calendar, { id: Number(input.venue_id?.value ?? input.venue_id), collective: 0,
    date: JSON.stringify({ start_date: input.target_date, end_date: input.target_date }) }));
  if (!ok(r)) throw fault('CalendarUnavailable');
  return calendarData(r.d);
}

export async function slotOptions(ctx, input) {
  if (!input) return [];
  const venueId = Number(input.venue_id?.value ?? input.venue_id);
  const targetDate = typeof input.target_date === 'string' ? input.target_date : '';
  if (!Number.isSafeInteger(venueId) || venueId <= 0 || !/^\d{4}-\d{2}-\d{2}$/.test(targetDate)) {
    return [];
  }
  const cal = await calendar(ctx, { ...input, venue_id: venueId, target_date: targetDate });
  const options = [];
  const courts = Array.isArray(cal.courts) ? cal.courts : [];
  for (const p of (Array.isArray(cal.periods) ? cal.periods : [])) {
    const periodId = Number(p.id);
    if (!Number.isSafeInteger(periodId) || periodId <= 0) continue;
    if (courts.length > 0) {
      for (const c of courts) {
        const courtId = Number(c.id);
        if (!Number.isSafeInteger(courtId) || courtId <= 0) continue;
        options.push({
          label: `${p.time} (${c.name})`,
          value: { time: p.time, period_id: periodId, court_id: courtId, courts: [courtId], court_name: c.name },
        });
      }
    } else {
      options.push({
        label: p.time,
        value: { time: p.time, period_id: periodId, courts: [] },
      });
    }
  }
  return options;
}

export async function prepareSchedule(ctx, input) {
  if (!input || typeof input !== 'object') throw fault('InvalidPlan');
  const accountId = account(input);
  let taskId = input.task_id;
  if (typeof taskId !== 'string' || !taskId.trim()) {
    taskId = 'sports-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
  }
  const venueId = positive(Number(input.venue_id?.value ?? input.venue_id));
  const targetDate = String(input.target_date || '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(targetDate)) throw fault('InvalidDate');

  let releaseAt = input.release_at;
  if (typeof releaseAt !== 'string' || !releaseAt) throw fault('InvalidReleaseTime');
  // Handle timezone: Native Dart datetime returns ISO with +08:00 when entry specifies time_zone:'Asia/Shanghai'
  if (!/(?:Z|[+-]\d\d:\d\d)$/.test(releaseAt)) {
    releaseAt = releaseAt + '+08:00';
  }

  let plans = [];
  if (Array.isArray(input.plans)) {
    plans = input.plans.map(p => ({
      time: String(p.time),
      period_id: p.period_id == null ? null : positive(Number(p.period_id)),
      courts: Array.isArray(p.courts) ? p.courts.map(c => positive(Number(c))) : [],
    }));
  } else if (Array.isArray(input.selected_slots)) {
    const timeMap = new Map();
    for (const slot of input.selected_slots) {
      const s = typeof slot === 'string' ? JSON.parse(slot) : slot;
      if (!s || typeof s !== 'object' || typeof s.time !== 'string') continue;
      if (!timeMap.has(s.time)) {
        const pid = s.period_id != null ? positive(Number(s.period_id)) : null;
        timeMap.set(s.time, { time: s.time, period_id: pid, courts: [] });
      }
      const entry = timeMap.get(s.time);
      if (s.period_id != null && entry.period_id == null) {
        entry.period_id = positive(Number(s.period_id));
      }
      if (Array.isArray(s.courts)) {
        for (const cid of s.courts) {
          const num = Number(cid);
          if (Number.isSafeInteger(num) && num > 0 && !entry.courts.includes(num)) {
            entry.courts.push(num);
          }
        }
      } else if (s.court_id != null) {
        const num = Number(s.court_id);
        if (Number.isSafeInteger(num) && num > 0 && !entry.courts.includes(num)) {
          entry.courts.push(num);
        }
      }
    }
    plans = Array.from(timeMap.values());
  }

  // Ensure all period_ids are valid positive integers if available
  for (const p of plans) {
    if (p.period_id != null) positive(p.period_id);
    if (!Array.isArray(p.courts) || !p.courts.length) throw fault('InvalidPlan');
  }

  const raw = {
    account_id: accountId,
    task_id: taskId,
    venue_id: venueId,
    target_date: targetDate,
    release_at: releaseAt,
    plans,
    options: input.options || {},
  };

  const plan = validatePlan(raw);
  const summary = `预约计划: 账号 ${plan.account_id}, 任务 ${plan.task_id}, 场馆 #${plan.venue_id}, 日期 ${plan.target_date}, 开抢 ${plan.release_at}, 时段数: ${plan.plans.length}`;

  return {
    canonical_input: plan,
    summary,
    prepare: summary,
    ...plan,
  };
}

function slots(raw) {
  const found = [];
  const visit = (v, depth) => {
    if (!v || typeof v !== 'object' || depth > 12 || found.length >= 500) return;
    if (Array.isArray(v)) { for (const i of v) visit(i, depth + 1); return; }
    if (typeof v.date === 'string' && typeof (v.str_time ?? v.time) === 'string') {
      found.push({ date: v.date, time: v.str_time ?? v.time, resource_name: String(v.resource_name || ''),
        resource_id: Number(v.resource_id) || null, detail_id: Number(v.detail_id) || null,
        appointment_data_id: Number(v.appointment_data_id) || null,
        active: v.active !== 0 && v.active !== '0',
        can_cancel: v.can_cancel === true || v.can_cancel === 1 || v.can_cancel === '1' });
    }
    for (const [k, child] of Object.entries(v)) if (typeof child === 'object' && k !== 'extra') visit(child, depth + 1);
  };
  visit(raw, 0); return found;
}

function typedAppointment(raw) {
  const truth = v => v === true || v === 1 || v === '1';
  const id = Number(raw.id ?? raw.appointment_id ?? raw.extra?.appointment_id);
  if (!Number.isSafeInteger(id) || id <= 0) throw fault('InvalidAppointment');
  return { id, resource_name: String(raw.resource_name || ''), status: raw.status,
    type: Number(raw.type), is_group: truth(raw.is_group), is_cancel: truth(raw.is_cancel),
    is_all_cancel: truth(raw.is_all_cancel), slots: slots(raw) };
}

export async function appointments(ctx, input) { return (await history(ctx, input)).map(typedAppointment); }

export async function appointmentOptions(ctx, input) {
  const list = await appointments(ctx, input);
  return list.map(a => ({
    label: `${a.resource_name} (ID: ${a.id}, 状态: ${a.status})`,
    value: Number(a.id),
  }));
}

export async function cancellableAppointmentOptions(ctx, input) {
  const list = await appointments(ctx, input);
  return list.filter(a => a.is_cancel || a.type === 7).map(a => ({
    label: `${a.resource_name} (ID: ${a.id}, 时段: ${a.slots?.[0]?.time || ''})`,
    value: Number(a.id),
  }));
}

export async function taskOptions(ctx, input) {
  const tasks = await listTasks(ctx, input);
  return tasks.map(t => ({
    label: `任务 ${t.task_id} (${t.display_status || t.status})`,
    value: String(t.task_id),
  }));
}

export async function appointmentDetail(ctx, input) {
  const appointmentId = positive(Number(input.appointment_id?.value ?? input.appointment_id));
  const r = await request(ctx, input, query(PATHS.detail, { id: appointmentId }));
  if (!ok(r) || !r.d) throw fault('InvalidAppointment');
  // QR/check-in tokens are intentionally not cached, logged or returned in diagnostics.
  return { id: appointmentId, resource_name: String(r.d.resource_name || ''), slots: slots(r.d) };
}

export async function prepareCancelAppointment(ctx, input) {
  const appointmentId = positive(Number(input.appointment_id?.value ?? input.appointment_id));
  account(input);
  const rows = await appointments(ctx, input);
  const a = rows.find(item => item.id === appointmentId);
  if (!a) throw fault('AppointmentNotFound');

  let detail = [];
  let data = [];
  let path = PATHS.cancel;
  const isThirdParty = a.type === 7;

  if (isThirdParty) {
    path = PATHS.thirdPartyCancel;
  } else {
    const active = a.slots.filter(s => s.active);
    const eligible = active.filter(s => s.can_cancel);
    if (!a.is_cancel || !eligible.length || (a.is_all_cancel && active.length !== eligible.length)) {
      throw fault('CancellationNotAllowed');
    }
    detail = a.is_group ? [] : eligible.map(s => positive(s.detail_id));
    data = a.is_group ? eligible.map(s => positive(s.appointment_data_id)) : [];
  }

  const canonical = {
    account_id: input.account_id,
    appointment_id: a.id,
    appointment_detail_id: detail,
    appointment_data_ids: data,
  };
  const summary = `取消预约 #${a.id} (${a.resource_name}): detail_ids=[${detail.join(',')}], data_ids=[${data.join(',')}]`;

  return {
    canonical_input: canonical,
    appointment_id: a.id,
    appointment_detail_id: detail,
    appointment_data_ids: data,
    endpoint: path,
    is_third_party: isThirdParty,
    is_group: a.is_group,
    summary,
    prepare: summary,
    ...canonical,
  };
}

export async function cancelAppointment(ctx, input) {
  const rawInput = (input && typeof input === 'object' && input.canonical_input) ? input.canonical_input : input;
  const appointmentId = positive(Number(rawInput.appointment_id?.value ?? rawInput.appointment_id));
  account(rawInput);
  const journalKey = 'cancel:' + rawInput.account_id + ':' + appointmentId;
  if (await ctx.storage.get({ key: journalKey })) throw fault('NeedsReconciliation');

  // Re-read server cancellation flags freshly; never trust unverified client parameters
  const a = (await appointments(ctx, rawInput)).find(a => a.id === appointmentId);
  if (!a) throw fault('AppointmentNotFound');

  let path = PATHS.cancel;
  let fields;
  if (a.type === 7) {
    path = PATHS.thirdPartyCancel;
    fields = { appointment_id: String(a.id) };
  } else {
    const active = a.slots.filter(s => s.active);
    const eligible = active.filter(s => s.can_cancel);
    if (!a.is_cancel || !eligible.length || (a.is_all_cancel && active.length !== eligible.length)) {
      throw fault('CancellationNotAllowed');
    }
    const freshDetail = a.is_group ? [] : eligible.map(s => positive(s.detail_id));
    const freshData = a.is_group ? eligible.map(s => positive(s.appointment_data_id)) : [];

    // Strict fresh comparison against approved target: require compare freshly at execution, no hidden broadening
    if (Array.isArray(rawInput.appointment_detail_id) && JSON.stringify(freshDetail) !== JSON.stringify(rawInput.appointment_detail_id)) {
      throw fault('CancellationNotAllowed');
    }
    if (Array.isArray(rawInput.appointment_data_ids) && JSON.stringify(freshData) !== JSON.stringify(rawInput.appointment_data_ids)) {
      throw fault('CancellationNotAllowed');
    }

    fields = {
      appointment_id: String(a.id),
      appointment_detail_id: JSON.stringify(freshDetail),
      appointment_data_ids: JSON.stringify(freshData),
    };
  }

  await ctx.storage.set({ key: journalKey, value: { state: 'in_flight', account_id: rawInput.account_id, appointment_id: a.id } });
  const r = await request(ctx, { ...rawInput, mutation_key: journalKey }, path, fields);
  if (!ok(r)) { await ctx.storage.delete({ key: journalKey }); throw fault('CancellationRejected'); }
  await ctx.storage.set({ key: journalKey, value: { state: 'confirmed', account_id: rawInput.account_id, appointment_id: a.id } });
  return { status: 'cancelled', appointment_id: a.id };
}

export async function schedule(ctx, input) {
  const raw = (input && typeof input === 'object' && input.canonical_input) ? input.canonical_input : input;
  const plan = validatePlan(raw);
  const key = taskKey(plan);
  if (Date.now() >= Date.parse(plan.release_at) + plan.options.windowMs) throw fault('DeadlineExceeded');
  const existing = await ctx.storage.get({ key });
  if (existing) {
    if (existing.transition?.phase !== 'pending_schedule' || JSON.stringify(existing.plan) !== JSON.stringify(plan)) throw fault('TaskAlreadyExists');
    await session(ctx, plan);
    await enqueue(ctx, existing, Date.parse(existing.transition.run_at));
    await publish(ctx, existing);
    return scheduledResult(existing);
  }
  // This call proves Android browser capability without pretending a native HTTP session is usable.
  await session(ctx, plan);
  const indexKey = 'index:' + plan.account_id;
  const index = (await ctx.storage.get({ key: indexKey })) || [];
  let count = 0;
  for (const id of index) {
    const existing = await ctx.storage.get({ key: taskKey({ account_id: plan.account_id, task_id: id }) });
    if (existing && !['stopped', 'completed', 'expired', 'existingReservation'].includes(existing.status)) {
      count += existing.plan.plans.length - existing.successes.length;
      if (existing.plan.target_date === plan.target_date && existing.plan.plans.some(p => plan.plans.some(q => q.time === p.time))) throw fault('TimeConflict');
    }
  }
  if (count + plan.plans.length > plan.options.maxReservationSlots) throw fault('SlotLimit');
  const state = { plan, status: 'scheduled', successes: [], periods: [], refreshed_at: 0,
    plan_index: 0, court_index: 0, round: 1, pending: null, job_id: null,
    job_sequence: null, wake_up: null, wake_status: 'pending',
    sequence: 0, last_consumed_sequence: 0, transition: null, needs_calendar_refresh: false };
  await save(ctx, state);
  await ctx.storage.set({ key: indexKey, value: [...index, plan.task_id] });
  await enqueue(ctx, state, Math.max(Date.now(), Date.parse(plan.release_at) - plan.options.browserPreloadMs));
  await publish(ctx, state);
  return scheduledResult(state);
}

function scheduledResult(state) {
  const plan = state.plan;
  return {
    status: state.status,
    task_id: plan.task_id,
    job_id: state.job_id,
    sequence: state.sequence,
    wake_status: state.wake_up?.state ?? (state.transition?.phase === 'scheduled' ? 'armed' : 'pending'),
    wake_up: state.wake_up ?? null,
    native_wake_at: new Date(Date.parse(plan.release_at) - plan.options.nativePrewarmMs).toISOString(),
    deadline_at: new Date(Date.parse(plan.release_at) + plan.options.windowMs).toISOString(),
    wake_integration: 'trusted_android_host_must_bind_job_to_WakeExecutionPort',
    options: plan.options,
  };
}

export async function tick(ctx, input) {
  const state = await load(ctx, input);
  if (!Number.isSafeInteger(input.sequence) || input.sequence < 1) throw fault('InvalidSequence');
  if (input.sequence !== state.sequence || input.sequence <= state.last_consumed_sequence)
    return { status: 'stale_sequence', sequence: input.sequence, expected_sequence: state.sequence };
  if (state.pending || state.status === 'needs_reconciliation') throw fault('NeedsReconciliation');
  if (['stopped', 'completed', 'expired', 'existingReservation', 'reconciled_requires_user_resume'].includes(state.status)) return { status: state.status };
  if (state.transition) state.transition.phase = 'executing';
  await save(ctx, state);
  const plan = state.plan, o = plan.options;
  const release = Date.parse(plan.release_at), deadline = release + o.windowMs;
  if (Date.now() >= deadline) { state.status = 'expired'; await save(ctx, state); return { status: state.status, partial: state.successes.length > 0 && state.successes.length < plan.plans.length }; }
  if (Date.now() < release - o.browserPreloadMs) { await enqueue(ctx, state, release - o.browserPreloadMs); return { status: 'waiting_preload' }; }
  await session(ctx, plan);
  const needCalendar = state.refreshed_at === 0 ||
    plan.plans.some(p => p.period_id === null || !state.periods?.some(sp => sp.time === p.time)) ||
    Boolean(state.needs_calendar_refresh);
  if (needCalendar && Date.now() - state.refreshed_at >= o.scheduleRefreshMs) {
    try { state.periods = (await calendar(ctx, plan)).periods; state.refreshed_at = Date.now(); state.needs_calendar_refresh = false; }
    catch (e) { if (['AuthenticationRequired', 'CapabilityUnavailable'].includes(e.code)) throw e; }
  }
  if (Date.now() < release + o.firstShotDelayMs) { await enqueue(ctx, state, release + o.firstShotDelayMs); return { status: 'preloaded' }; }
  if (Date.now() >= deadline) { state.status = 'expired'; await save(ctx, state); return { status: 'expired', partial: state.successes.length > 0 && state.successes.length < plan.plans.length }; }
  const remaining = plan.plans.filter(p => !state.successes.some(s => s.time === p.time));
  if (!remaining.length) { state.status = 'completed'; await save(ctx, state); return { status: state.status }; }

  const resolvePeriod = p => state.periods?.find(sp => sp.time === p.time)?.id ?? p.period_id ?? null;
  let delay = 0;

  state.plan_index %= remaining.length;
  const selected = remaining[state.plan_index];
  const period = resolvePeriod(selected);
  let advancePlan = false;
  if (period == null) {
    advancePlan = true;
    state.needs_calendar_refresh = true;
  } else {
    state.court_index = state.court_index || 0;
    if (state.court_index >= selected.courts.length) {
      state.court_index = 0;
    }
    const court = selected.courts[state.court_index];
    state.pending = { time: selected.time, court_id: court, period_id: period, round: state.round };
    state.status = 'in_flight';
    await save(ctx, state);
    const mutationKey = taskKey(plan) + ':' + state.round + ':' + period + ':' + court;
    let response;
    try {
      response = await request(ctx, { ...plan, mutation_key: mutationKey }, PATHS.launch, launchFields(plan, period, court),
        Math.min(deadline, Date.now() + o.requestTimeoutMs));
    } catch (e) {
      if (e.code === 'NeedsReconciliation' && e.from_browser_host) throw e;
      state.status = 'needs_reconciliation';
      await save(ctx, state);
      try { await reconcile(ctx, input); } catch (_) {}
      if (e.code === 'NeedsReconciliation') throw e;
      throw fault('NeedsReconciliation');
    }
    const result = classify(response);
    state.pending = null;
    if (result === 'success') {
      state.successes.push({ time: selected.time, court_id: court, period_id: period });
      state.court_index = 0;
      if (state.successes.length === plan.plans.length) state.status = 'completed';
    } else if (result === 'existingReservation') {
      state.status = result;
    } else if (result === 'notOpen') {
      advancePlan = true;
      state.needs_calendar_refresh = true;
    } else {
      state.court_index++;
      delay = result === 'throttled' ? o.throttleBackoffMs : 0;
      if (state.court_index >= selected.courts.length) advancePlan = true;
    }
    if (!['completed', 'existingReservation'].includes(state.status)) state.status = 'running';
  }
  if (advancePlan) {
    state.court_index = 0;
    state.plan_index++;
    if (state.plan_index >= remaining.length) {
      state.plan_index = 0;
      state.round++;
      delay += o.roundPauseMs;
    }
  }

  // A user stop can arrive while the page request is in flight; never overwrite it with a retry.
  const latest = await load(ctx, input);
  if (latest.status === 'stopped') { state.status = 'stopped'; }
  await save(ctx, state);
  if (!['completed', 'existingReservation', 'stopped'].includes(state.status)) await enqueue(ctx, state, Date.now() + delay);
  await publish(ctx, state);
  return { status: state.status, success_count: state.successes.length, partial: state.successes.length > 0 && state.successes.length < plan.plans.length };
}

export async function stop(ctx, input) {
  const state = await load(ctx, input);
  state.status = 'stopped'; await save(ctx, state);
  if (state.job_id) await ctx.jobs.cancel({ job_id: state.job_id, account_id: state.plan.account_id });
  const hasPending = Boolean(state.pending && (!Array.isArray(state.pending) || state.pending.length > 0));
  return { status: hasPending ? 'stopped_needs_reconciliation' : 'stopped', remote_effects_undone: false };
}

export async function reconcile(ctx, input) {
  const state = await load(ctx, input);
  if (!state.pending) return { status: state.status };
  const pendings = Array.isArray(state.pending) ? state.pending : [state.pending];
  if (!pendings.length) return { status: state.status };
  const rows = await appointments(ctx, input);
  let allMatched = true;
  let firstMatchId = null;
  for (const pending of pendings) {
    const match = rows.find(a => a.slots.some(s => s.active && s.date === state.plan.target_date &&
      s.time === pending.time && s.resource_id === pending.court_id));
    if (match) {
      if (!firstMatchId) firstMatchId = match.id;
      if (!state.successes.some(s => s.time === pending.time)) state.successes.push(pending);
    } else {
      allMatched = false;
    }
  }
  if (!allMatched) throw fault('NeedsReconciliation');
  state.pending = null;
  state.status = state.status === 'stopped' ? 'stopped' : 'reconciled_requires_user_resume';
  await save(ctx, state);
  return { status: state.status, appointment_id: firstMatchId, success_count: state.successes.length };
}

export async function listTasks(ctx, input) {
  const id = account(input);
  const indexKey = 'index:' + id;
  const index = (await ctx.storage.get({ key: indexKey })) || [];
  const tasks = [];
  for (const taskId of index) {
    if (typeof taskId !== 'string') continue;
    const key = taskKey({ account_id: id, task_id: taskId });
    let state;
    try { state = await ctx.storage.get({ key }); } catch (_) { continue; }
    if (!state || !state.plan || state.plan.account_id !== id) continue;

    let subtask = null;
    if (state.job_id && ctx.jobs && typeof ctx.jobs.status === 'function') {
      try {
        const j = await ctx.jobs.status({ job_id: state.job_id });
        if (j) {
          subtask = {
            id: j.id ?? j.job_id ?? state.job_id,
            state: j.state ?? null,
            run_at: j.run_at ?? null,
          };
        }
      } catch (_) {
        // Query error or missing capability does not break listing
      }
    }

    const hasPartialSuccess = (state.successes?.length || 0) > 0 &&
      (state.successes?.length || 0) < (state.plan.plans?.length || 0);

    let displayStatus = state.status;
    if (state.status === 'needs_reconciliation' || state.pending) {
      displayStatus = 'needs_reconciliation';
    } else if (state.status === 'scheduled') {
      if (state.wake_up?.state === 'not_armed') {
        displayStatus = 'saved_alarm_not_armed';
      } else {
        displayStatus = 'waiting_wake';
      }
    } else if (state.status === 'running' || state.status === 'waiting_preload' || state.status === 'preloaded') {
      displayStatus = 'waiting_wake';
    } else if (state.status === 'expired' && hasPartialSuccess) {
      displayStatus = 'partial_expired';
    }

    const p = state.pending ? (Array.isArray(state.pending) ? (state.pending[0] || null) : state.pending) : null;
    const summary = {
      task_id: state.plan.task_id,
      account_id: state.plan.account_id,
      venue_id: state.plan.venue_id,
      target_date: state.plan.target_date,
      release_at: state.plan.release_at,
      status: state.status,
      display_status: displayStatus,
      planned_count: state.plan.plans?.length || 0,
      success_count: state.successes?.length || 0,
      partial: hasPartialSuccess,
      round: state.round || 1,
      sequence: state.sequence || 0,
      job_id: state.job_id || null,
      job_sequence: state.job_sequence ?? state.transition?.sequence ?? null,
      wake_status: state.wake_up?.state ?? (state.status === 'scheduled' ? 'armed' : null),
      wake_up: state.wake_up ?? null,
      transition: state.transition ? {
        sequence: state.transition.sequence,
        phase: state.transition.phase,
        run_at: state.transition.run_at,
        prepare_at: state.transition.prepare_at,
        deadline_at: state.transition.deadline_at,
      } : null,
      pending: p ? {
        time: p.time,
        court_id: p.court_id,
        period_id: p.period_id,
        round: p.round,
      } : null,
      pendings: Array.isArray(state.pending) ? state.pending.map(item => ({
        time: item.time,
        court_id: item.court_id,
        period_id: item.period_id,
        round: item.round,
      })) : (p ? [{
        time: p.time,
        court_id: p.court_id,
        period_id: p.period_id,
        round: p.round,
      }] : []),
      subtask,
    };
    tasks.push(summary);
  }
  tasks.tasks = tasks;
  return tasks;
}
