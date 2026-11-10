// SPDX-License-Identifier: GPL-3.0-or-later
// DanXi-Dev reference-derived service policy and official built-in manual venue module.
// Runs inside Core QuickJS with authenticated page session. No Node.js runtime globals.

import {
  account,
  positive,
  taskId,
  targetDate,
  timeSlot,
  mutationKey,
  normalizeManualInput,
  formatSummary,
  parseSlotState,
  extractDayData,
  lookupValue,
  classify,
  launchForm,
  cancelMutationKey,
  formatCancelSummary,
  cancelForm,
  fault,
} from './policy.mjs';

import {
  ORIGIN,
  TOPIC_PAGE,
  PATHS,
  query,
  session,
  request,
  history,
} from './api.mjs';

export {
  ORIGIN,
  TOPIC_PAGE,
  PATHS,
  normalizeManualInput,
  mutationKey,
  parseSlotState,
  classify,
};

const ok = r => r && (r.e === 'OK' || r.e === 0 || r.e === '0');

function journalKey(accountId, id) {
  return 'journal:manual:' + accountId + ':' + id;
}

/**
 * Traverses raw appointment structures to extract individual slots matching DanXi model.
 */
function extractAppointmentSlots(raw) {
  const found = [];
  const seen = new Set();

  function visit(v, inheritedResource) {
    if (v == null || typeof v !== 'object') return;
    if (Array.isArray(v)) {
      for (const item of v) visit(item, inheritedResource);
      return;
    }

    const resourceName = typeof v.resource_name === 'string' && v.resource_name.trim().length > 0
      ? v.resource_name.trim()
      : inheritedResource;

    const date = typeof v.date === 'string' ? v.date.trim() : '';
    const time = typeof (v.str_time ?? v.time) === 'string' ? String(v.str_time ?? v.time).trim() : '';

    if (date.length > 0 && time.length > 0) {
      const key = `${date}|${time}|${resourceName}`;
      if (!seen.has(key)) {
        seen.add(key);
        found.push({
          date,
          time,
          resource_name: resourceName,
          resource_id: Number(v.resource_id) || null,
          detail_id: Number(v.detail_id) || null,
          appointment_data_id: Number(v.appointment_data_id) || null,
          active: v.active !== false && v.active !== 0 && v.active !== '0',
          can_cancel: v.can_cancel === true || v.can_cancel === 1 || v.can_cancel === '1',
          cancel_message: typeof v.cancel_message === 'string' ? v.cancel_message : '',
        });
      }
    }

    for (const [k, child] of Object.entries(v)) {
      if (k === 'date' || k === 'str_time' || k === 'time') continue;
      if (typeof child === 'object') visit(child, resourceName);
    }
  }

  visit(raw, '');
  return found;
}

function typedAppointment(raw) {
  const slots = extractAppointmentSlots(raw);
  const id = Number(raw.id ?? raw.appointment_id ?? raw.detail_id ?? raw.extra?.appointment_id);
  const resourceName = typeof raw.resource_name === 'string' && raw.resource_name.trim().length > 0
    ? raw.resource_name.trim()
    : slots[0]?.resource_name || '';

  const isCancel = raw.is_cancel === true || raw.is_cancel === 1 || raw.is_cancel === '1';
  const type = Number.isSafeInteger(Number(raw.type)) ? Number(raw.type) : null;
  const canCancel = type === 7 || (isCancel && slots.some(s => s.active && s.can_cancel));

  return {
    id: Number.isSafeInteger(id) ? id : null,
    resource_name: resourceName,
    status: Number.isSafeInteger(Number(raw.status)) ? Number(raw.status) : null,
    status_name: typeof raw.status_name === 'string' ? raw.status_name : '',
    type,
    is_group: raw.is_group === true || raw.is_group === 1 || raw.is_group === '1',
    is_cancel: isCancel,
    is_all_cancel: raw.is_all_cancel === true || raw.is_all_cancel === 1 || raw.is_all_cancel === '1',
    can_cancel: canCancel,
    cancel_message: typeof raw.cancel_message === 'string' ? raw.cancel_message : '',
    slots,
  };
}

/**
 * visibleLogin: hand off to trusted visible Android login session.
 * Contract: { account_id } -> { operation, ... }
 */
export async function visibleLogin(ctx, input) {
  const p = {
    operation: 'session.requireLogin',
    account_id: account(input),
    url: TOPIC_PAGE,
  };
  return typeof ctx.browser.login === 'function' ? ctx.browser.login(p) : ctx.browser.evaluate(p);
}

/**
 * venues: returns list of bookable venues.
 * Contract: venues returns [{id, name}]
 */
export async function venues(ctx, input) {
  const r = await request(ctx, input, query(PATHS.venues, { id: 48, pageSize: 200 }));
  if (!ok(r) || !r.d || !Array.isArray(r.d.data)) {
    throw fault('InvalidVenues', 'Failed to retrieve sports venue list');
  }

  return r.d.data
    .filter(v => v && v.base && Number.isSafeInteger(Number(v.base.id)) && typeof v.base.name === 'string')
    .map(v => {
      const id = Number(v.base.id);
      const name = String(v.base.name).trim();
      const segments = name.split('-');
      const sport = segments.length > 1 ? segments[segments.length - 1].trim() : name;
      const building = segments.length > 1 ? segments.slice(0, segments.length - 1).join('-') : '';
      return {
        id,
        name,
        type: Number.isSafeInteger(Number(v.base.type)) ? Number(v.base.type) : null,
        building,
        sport,
      };
    });
}

/**
 * calendar: reads venue calendar for a target date, preserving date+time period and per-court availability.
 * Contract: calendar {account_id, venue_id, target_date} returns {slots:[{period_id,time,court_id,court_name,available:boolean,...}], ...}
 */
export async function calendar(ctx, input) {
  const venueId = positive(input.venue_id?.value ?? input.venue_id, 'venue_id');
  const date = targetDate(input.target_date);

  const r = await request(
    ctx,
    input,
    query(PATHS.calendar, {
      id: venueId,
      collective: 0,
      date: JSON.stringify({ start_date: date, end_date: date }),
    })
  );

  if (!ok(r) || !r.d) {
    throw fault('CalendarUnavailable', 'Failed to retrieve venue calendar');
  }

  const rawTimes = Array.isArray(r.d.time) ? r.d.time : [];
  const periods = rawTimes
    .filter(t => t && Number.isSafeInteger(Number(t.id)) && Number(t.id) > 0 && typeof (t.str_time ?? t.time) === 'string')
    .map(t => ({
      id: Number(t.id),
      time: String(t.str_time ?? t.time).trim(),
      start_time: typeof t.start_time === 'string' ? t.start_time : null,
      end_time: typeof t.end_time === 'string' ? t.end_time : null,
    }));

  const rawCourts = Array.isArray(r.d.resource) ? r.d.resource : [];
  const courts = rawCourts
    .filter(c => c && Number.isSafeInteger(Number(c.id)) && typeof c.name === 'string')
    .map(c => ({
      id: Number(c.id),
      name: String(c.name).trim(),
    }));

  const dayData = extractDayData(r.d.data, date);
  const slots = [];

  for (const p of periods) {
    for (const c of courts) {
      const courtData = lookupValue(dayData, c.id) || {};
      const rawCell = lookupValue(courtData, p.id);
      const slotState = parseSlotState(rawCell);

      slots.push({
        period_id: p.id,
        time: p.time,
        start_time: p.start_time,
        end_time: p.end_time,
        court_id: c.id,
        court_name: c.name,
        available: slotState.available,
        occupied: slotState.occupied,
        remaining: slotState.remaining,
        read_only: slotState.read_only,
        target_date: date,
      });
    }
  }

  return {
    venue_id: venueId,
    target_date: date,
    periods,
    courts,
    slots,
  };
}

/**
 * appointments: reads appointment history.
 */
export async function appointments(ctx, input) {
  const rows = await history(ctx, input);
  return rows.map(typedAppointment);
}

/**
 * detail: reads appointment voucher details.
 */
export async function detail(ctx, input) {
  const appointmentId = positive(input.appointment_id?.value ?? input.appointment_id ?? input.id, 'appointment_id');
  const r = await request(ctx, input, query(PATHS.detail, { id: appointmentId }));
  if (!ok(r) || !r.d) {
    throw fault('InvalidAppointment', 'Failed to retrieve appointment details');
  }

  const resourceInfo = r.d.resource_info || {};
  const config = resourceInfo.config || {};
  const slots = extractAppointmentSlots(r.d.appointment_time ?? r.d);

  return {
    id: appointmentId,
    resource_name: String(r.d.resource_name || resourceInfo.name || ''),
    status: Number.isSafeInteger(Number(r.d.status)) ? Number(r.d.status) : null,
    status_name: String(r.d.status_name || ''),
    qrcode: String(r.d.qrcode || resourceInfo.qrcode || ''),
    show_code: config.is_show_code === true || config.is_show_code === 1 || config.is_show_code === '1',
    refresh_seconds: Number.isSafeInteger(Number(config.refresh_time)) ? Number(config.refresh_time) : 15,
    slots,
  };
}

/**
 * prepareManual: normalizes input into canonical fields and generates host preview approval summary.
 * Contract: input {account_id, venue_id, target_date, period_id, court_id, time, task_id} returns {canonical_input, summary}
 */
export async function prepareManual(ctx, input) {
  const canonical = normalizeManualInput(input);
  const summary = formatSummary(canonical, {
    venue_name: input.venue_name,
    court_name: input.court_name,
  });

  return {
    canonical_input: canonical,
    summary,
  };
}

/**
 * reserve: executes single manual reservation POST after host approval.
 * Contract: takes the same canonical_input returned by prepareManual.
 * - Rechecks latest availability on confirmed execution
 * - Single POST keyed by account/task/date/venue/period/court
 * - Preserves uncertain journal on write timeout / network failure
 * - No retry, no real network
 */
export async function reserve(ctx, canonicalInput) {
  const canonical = normalizeManualInput(canonicalInput);
  const key = journalKey(canonical.account_id, canonical.task_id);

  // 1. Check existing journal state in storage
  if (ctx.storage && typeof ctx.storage.get === 'function') {
    const existing = await ctx.storage.get({ key });
    if (existing) {
      if (existing.status === 'uncertain' || existing.status === 'in_flight') {
        throw fault('NeedsReconciliation', 'Task has in-flight or uncertain outcome; reconciliation required before retry');
      }
      if (existing.status === 'success' || existing.status === 'reconciled_success') {
        return {
          status: 'success',
          message: 'Reservation already completed',
          already_completed: true,
          appointment_id: existing.appointment_id || existing.result?.d?.order_id || null,
          body: existing.result,
        };
      }
    }
  }

  // 2. Recheck latest availability on confirmed execution
  const cal = await calendar(ctx, {
    account_id: canonical.account_id,
    venue_id: canonical.venue_id,
    target_date: canonical.target_date,
  });

  const slot = cal.slots.find(
    s => s.period_id === canonical.period_id && s.court_id === canonical.court_id
  );

  if (!slot) {
    throw fault('SlotUnavailable', 'The selected court and period slot was not found in the venue calendar');
  }

  if (!slot.available) {
    throw fault(
      'CourtOccupied',
      `The selected court is no longer available on recheck (occupied: ${slot.occupied}, remaining: ${slot.remaining})`
    );
  }

  // 3. Record in-flight journal state before submitting write
  if (ctx.storage && typeof ctx.storage.set === 'function') {
    await ctx.storage.set({
      key,
      value: {
        ...canonical,
        status: 'in_flight',
        started_at: Date.now(),
      },
    });
  }

  // 4. Execute single POST with typed form fields and sign-key
  let response;
  try {
    response = await request(
      ctx,
      canonical,
      PATHS.launch,
      launchForm(canonical)
    );
  } catch (err) {
    // Explicit permission/auth checks: clean up or record denial
    const isDenial = ['PermissionDenied', 'ApprovalRequired', 'AuthenticationRequired'].includes(err.code);
    if (ctx.storage && typeof ctx.storage.set === 'function') {
      if (isDenial) {
        await ctx.storage.set({
          key,
          value: {
            ...canonical,
            status: 'denied',
            error: err.code,
            ended_at: Date.now(),
          },
        });
      } else {
        // Any other write failure is uncertain! Preserve uncertain journal.
        await ctx.storage.set({
          key,
          value: {
            ...canonical,
            status: 'uncertain',
            error: err.original_code || err.cause?.code || err.code || 'WriteTimeout',
            uncertain_at: Date.now(),
          },
        });
      }
    }
    throw err;
  }

  // 5. Evaluate response
  if (ok(response)) {
    if (ctx.storage && typeof ctx.storage.set === 'function') {
      await ctx.storage.set({
        key,
        value: {
          ...canonical,
          status: 'success',
          result: response,
          completed_at: Date.now(),
        },
      });
    }
    return {
      status: 'success',
      message: typeof response.m === 'string' && response.m.trim().length > 0 ? response.m.trim() : '预约成功',
      body: response,
    };
  }

  // Remote server rejected request (e.g. 已被预约, 未开放)
  const classified = classify(response);
  if (ctx.storage && typeof ctx.storage.set === 'function') {
    await ctx.storage.set({
      key,
      value: {
        ...canonical,
        status: 'failed',
        reason: response.m,
        classified,
        result: response,
        completed_at: Date.now(),
      },
    });
  }

  return {
    status: classified,
    message: typeof response.m === 'string' ? response.m : '预约失败',
    body: response,
  };
}

/**
 * reconcile: reconciles an uncertain reservation against appointment history.
 */
export async function reconcile(ctx, input) {
  const accountId = account(input);
  const id = taskId(input.task_id);
  const key = journalKey(accountId, id);

  if (!ctx.storage || typeof ctx.storage.get !== 'function') {
    throw fault('CapabilityUnavailable', 'Storage capability required for reconciliation');
  }

  const entry = await ctx.storage.get({ key });
  if (!entry) {
    return { status: 'not_found' };
  }

  // If already proven record: repeat reconcile returns same positive id for host job reconciliation
  if (entry.status === 'reconciled_success') {
    return {
      status: 'reconciled_success',
      appointment_id: entry.appointment_id,
      already_reconciled: true,
      entry,
    };
  }

  // If already successful from initial reserve:
  if (entry.status === 'success') {
    return {
      status: 'reconciled_success',
      appointment_id: entry.appointment_id || entry.result?.d?.order_id || null,
      already_reconciled: true,
      entry,
    };
  }

  // Only uncertain or in_flight states are eligible for history reconciliation
  if (entry.status !== 'uncertain' && entry.status !== 'in_flight') {
    return { status: entry.status, entry };
  }

  // Query appointments to verify whether the booking actually took effect
  const historyList = await appointments(ctx, { account_id: accountId });
  const match = historyList.find(a =>
    a.slots && a.slots.some(
      s => s.active &&
           s.date === entry.target_date &&
           s.time === entry.time &&
           (s.resource_id === entry.court_id || (typeof s.resource_name === 'string' && s.resource_name.includes(String(entry.court_id))))
    )
  );

  if (match) {
    const appointmentId = Number(match.id);
    if (!Number.isSafeInteger(appointmentId) || appointmentId <= 0) {
      throw fault('InvalidAppointment', 'Authoritative match lacks positive appointment id');
    }
    entry.status = 'reconciled_success';
    entry.appointment_id = appointmentId;
    entry.reconciled_at = Date.now();
    await ctx.storage.set({ key, value: entry });
    return {
      status: 'reconciled_success',
      appointment_id: appointmentId,
      appointment: match,
    };
  }

  // Absence from history does NOT prove failure (could be pagination, backend lag, or pending index).
  // Preserve uncertain/in_flight across restart; no freeing under empty/lagging history.
  // Return 'needs_reconciliation' without marking failed.
  if (entry.status === 'in_flight') {
    entry.status = 'uncertain';
    entry.updated_at = Date.now();
    await ctx.storage.set({ key, value: entry });
  }

  return {
    status: 'needs_reconciliation',
    task_id: entry.task_id,
    entry,
  };
}

/**
 * journal: reads the stored journal record for a task.
 */
export async function journal(ctx, input) {
  const accountId = account(input);
  const id = taskId(input.task_id);
  const key = journalKey(accountId, id);

  if (!ctx.storage || typeof ctx.storage.get !== 'function') {
    throw fault('CapabilityUnavailable', 'Storage capability required');
  }

  const entry = await ctx.storage.get({ key });
  return {
    task_id: id,
    account_id: accountId,
    entry: entry || null,
  };
}

/**
 * prepareCancel: validates appointment cancellation eligibility and formats host preview summary.
 * Contract: input { account_id, appointment_id } -> { canonical_input, summary, ... }
 */
export async function prepareCancel(ctx, input) {
  const accountId = account(input);
  const appointmentId = positive(input.appointment_id?.value ?? input.appointment_id ?? input.id, 'appointment_id');

  const rows = await appointments(ctx, { account_id: accountId });
  const a = rows.find(item => item.id === appointmentId);
  if (!a) {
    throw fault('AppointmentNotFound', `Appointment #${appointmentId} was not found in history`);
  }

  let detail = [];
  let data = [];
  let path = PATHS.cancel;
  const isThirdParty = a.type === 7;

  if (isThirdParty) {
    path = PATHS.thirdPartyCancel;
  } else {
    const active = a.slots.filter(s => s.active);
    const eligible = active.filter(s => s.can_cancel);
    if (!a.is_cancel || eligible.length === 0 || (a.is_all_cancel && active.length !== eligible.length)) {
      throw fault('CancellationNotAllowed', a.cancel_message || 'Appointment is not eligible for cancellation');
    }

    detail = a.is_group ? [] : eligible.map(s => positive(s.detail_id, 'detail_id'));
    data = a.is_group ? eligible.map(s => positive(s.appointment_data_id, 'appointment_data_id')) : [];

    if ((!a.is_group && detail.length === 0) || (a.is_group && data.length === 0)) {
      throw fault('CancellationNotAllowed', 'Missing slot detail/data IDs for cancellation');
    }
  }

  const key = cancelMutationKey(accountId, a.id);
  const canonical = {
    account_id: accountId,
    appointment_id: a.id,
    appointment_detail_id: detail,
    appointment_data_ids: data,
    mutation_key: key,
  };

  const summary = formatCancelSummary(canonical, {
    resource_name: a.resource_name,
    is_third_party: isThirdParty,
  });

  return {
    canonical_input: canonical,
    summary,
    appointment_id: a.id,
    resource_name: a.resource_name,
    is_third_party: isThirdParty,
    is_group: a.is_group,
    endpoint: path,
    appointment_detail_id: detail,
    appointment_data_ids: data,
    slots: a.slots,
  };
}

/**
 * cancel: cancels an authorized appointment with fresh server state verification.
 * Contract: takes canonical_input returned by prepareCancel (or { account_id, appointment_id, ... }).
 */
export async function cancel(ctx, input) {
  const rawInput = (input && typeof input === 'object' && input.canonical_input) ? input.canonical_input : input;
  const accountId = account(rawInput);
  const appointmentId = positive(rawInput.appointment_id?.value ?? rawInput.appointment_id ?? rawInput.id, 'appointment_id');
  const journalKey = 'journal:cancel:' + accountId + ':' + appointmentId;

  // 1. Check existing cancellation journal in storage
  if (ctx.storage && typeof ctx.storage.get === 'function') {
    const existing = await ctx.storage.get({ key: journalKey });
    if (existing) {
      if (existing.status === 'uncertain' || existing.status === 'in_flight') {
        throw fault('NeedsReconciliation', 'Cancellation is in-flight or uncertain; reconciliation required before retry');
      }
      if (existing.status === 'confirmed' || existing.status === 'reconciled_cancelled') {
        return {
          status: 'cancelled',
          appointment_id: appointmentId,
          already_cancelled: true,
        };
      }
    }
  }

  // 2. Re-read server cancellation flags freshly; never trust unverified client parameters
  const rows = await appointments(ctx, { account_id: accountId });
  const a = rows.find(item => item.id === appointmentId);
  if (!a) {
    throw fault('AppointmentNotFound', `Appointment #${appointmentId} was not found on execution recheck`);
  }

  let path = PATHS.cancel;
  let fields;
  const isThirdParty = a.type === 7;

  if (isThirdParty) {
    path = PATHS.thirdPartyCancel;
    fields = cancelForm({ appointment_id: a.id }, true);
  } else {
    const active = a.slots.filter(s => s.active);
    const eligible = active.filter(s => s.can_cancel);
    if (!a.is_cancel || eligible.length === 0 || (a.is_all_cancel && active.length !== eligible.length)) {
      throw fault('CancellationNotAllowed', a.cancel_message || 'Appointment is no longer eligible for cancellation');
    }

    const freshDetail = a.is_group ? [] : eligible.map(s => positive(s.detail_id, 'detail_id'));
    const freshData = a.is_group ? eligible.map(s => positive(s.appointment_data_id, 'appointment_data_id')) : [];

    if ((!a.is_group && freshDetail.length === 0) || (a.is_group && freshData.length === 0)) {
      throw fault('CancellationNotAllowed', 'Missing slot detail/data IDs on execution recheck');
    }

    // Strict fresh comparison against approved target: require compare freshly at execution, no hidden broadening
    if (Array.isArray(rawInput.appointment_detail_id) && JSON.stringify(freshDetail) !== JSON.stringify(rawInput.appointment_detail_id)) {
      throw fault('CancellationNotAllowed', 'Target detail slot IDs changed or broader than approved');
    }
    if (Array.isArray(rawInput.appointment_data_ids) && JSON.stringify(freshData) !== JSON.stringify(rawInput.appointment_data_ids)) {
      throw fault('CancellationNotAllowed', 'Target data slot IDs changed or broader than approved');
    }

    fields = cancelForm({
      appointment_id: a.id,
      appointment_detail_id: freshDetail,
      appointment_data_ids: freshData,
    }, false);
  }

  const mutKey = cancelMutationKey(accountId, a.id);

  // 3. Durably persist in_flight before write dispatch
  if (ctx.storage && typeof ctx.storage.set === 'function') {
    await ctx.storage.set({
      key: journalKey,
      value: {
        account_id: accountId,
        appointment_id: a.id,
        status: 'in_flight',
        started_at: Date.now(),
        mutation_key: mutKey,
      },
    });
  }

  // 4. Dispatch single POST request
  let response;
  try {
    response = await request(
      ctx,
      { ...rawInput, mutation_key: mutKey },
      path,
      fields
    );
  } catch (err) {
    const isDenial = ['PermissionDenied', 'ApprovalRequired', 'AuthenticationRequired'].includes(err.code);
    if (ctx.storage && typeof ctx.storage.set === 'function') {
      if (isDenial) {
        await ctx.storage.set({
          key: journalKey,
          value: {
            account_id: accountId,
            appointment_id: a.id,
            status: 'denied',
            error: err.code,
            ended_at: Date.now(),
          },
        });
      } else {
        await ctx.storage.set({
          key: journalKey,
          value: {
            account_id: accountId,
            appointment_id: a.id,
            status: 'uncertain',
            error: err.original_code || err.cause?.code || err.code || 'WriteTimeout',
            uncertain_at: Date.now(),
          },
        });
      }
    }
    throw err;
  }

  if (!ok(response)) {
    if (ctx.storage && typeof ctx.storage.set === 'function') {
      await ctx.storage.set({
        key: journalKey,
        value: {
          account_id: accountId,
          appointment_id: a.id,
          status: 'failed',
          reason: response.m,
          ended_at: Date.now(),
        },
      });
    }
    throw fault('CancellationRejected', response.m || 'Server rejected cancellation');
  }

  if (ctx.storage && typeof ctx.storage.set === 'function') {
    await ctx.storage.set({
      key: journalKey,
      value: {
        account_id: accountId,
        appointment_id: a.id,
        status: 'confirmed',
        completed_at: Date.now(),
      },
    });
  }

  return {
    status: 'cancelled',
    appointment_id: a.id,
  };
}

/**
 * reconcileCancel: reconciles an uncertain or in_flight cancellation against appointment history.
 * Absence from the first history page does NOT prove cancellation; positive proof requires
 * authoritative record confirming status cancelled (status === 0 / status_name cancelled) or all relevant slots inactive.
 */
export async function reconcileCancel(ctx, input) {
  const accountId = account(input);
  const appointmentId = positive(input.appointment_id?.value ?? input.appointment_id ?? input.id, 'appointment_id');
  const journalKey = 'journal:cancel:' + accountId + ':' + appointmentId;

  if (!ctx.storage || typeof ctx.storage.get !== 'function') {
    throw fault('CapabilityUnavailable', 'Storage capability required for cancellation reconciliation');
  }

  const entry = await ctx.storage.get({ key: journalKey });
  if (!entry) {
    return { status: 'not_found' };
  }

  // Already confirmed or reconciled cancelled
  if (entry.status === 'confirmed' || entry.status === 'reconciled_cancelled') {
    return {
      status: 'reconciled_cancelled',
      appointment_id: appointmentId,
      already_reconciled: true,
      entry,
    };
  }

  if (entry.status !== 'uncertain' && entry.status !== 'in_flight') {
    return { status: entry.status, entry };
  }

  // Probe appointment history
  const historyList = await appointments(ctx, { account_id: accountId });
  const a = historyList.find(item => item.id === appointmentId);

  if (a) {
    // A historic/used slot or a label such as “不可取消” is not proof of cancellation.
    const isCancelledStatus = ['已取消', '取消成功', '已撤销'].includes(String(a.status_name).trim());
    if (isCancelledStatus) {
      entry.status = 'reconciled_cancelled';
      entry.appointment_id = appointmentId;
      entry.reconciled_at = Date.now();
      await ctx.storage.set({ key: journalKey, value: entry });
      return {
        status: 'reconciled_cancelled',
        appointment_id: appointmentId,
        appointment: a,
      };
    }

    // If slots are still active, cancellation has not taken effect
    return {
      status: 'still_active',
      appointment_id: appointmentId,
      appointment: a,
    };
  }

  // Row absent from first result page: NOT evidence of cancellation!
  // Elevate in_flight to uncertain if needed, preserve locked record, return needs_reconciliation.
  if (entry.status === 'in_flight') {
    entry.status = 'uncertain';
    entry.updated_at = Date.now();
    await ctx.storage.set({ key: journalKey, value: entry });
  }

  return {
    status: 'needs_reconciliation',
    appointment_id: appointmentId,
    entry,
  };
}
