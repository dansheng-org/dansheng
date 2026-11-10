// SPDX-License-Identifier: GPL-3.0-or-later
// DanXi-Dev reference-derived service policy and slot calculations.
// Reference: C:/Code/danxi/lib/repository/fdu/sports_reserve_repository.dart and sports UI models.

export function fault(code, message) {
  const err = new Error(message || code);
  err.code = code;
  return err;
}

export function account(input) {
  if (!input || typeof input.account_id !== 'string' || !/^[A-Za-z0-9_.:@-]{1,160}$/.test(input.account_id)) {
    throw fault('InvalidAccount', 'Invalid or missing account_id');
  }
  return input.account_id;
}

export function positive(value, name = 'id') {
  const num = typeof value === 'number' ? value : Number(value);
  if (!Number.isSafeInteger(num) || num <= 0) {
    throw fault('InvalidId', `Invalid positive integer for ${name}: ${value}`);
  }
  return num;
}

export function taskId(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,100}$/.test(value)) {
    throw fault('InvalidTask', `Invalid task_id: ${value}`);
  }
  return value;
}

export function targetDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw fault('InvalidDate', `Invalid target_date format: ${value}`);
  }
  const parsed = new Date(value + 'T00:00:00Z');
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw fault('InvalidDate', `Invalid calendar date: ${value}`);
  }
  return value;
}

export function timeSlot(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 80) {
    throw fault('InvalidTime', `Invalid time period string: ${value}`);
  }
  return value.trim();
}

/**
 * Builds the deterministic canonical mutation key:
 * manual:{account_id}:{task_id}:{target_date}:{venue_id}:{period_id}:{court_id}
 */
export function mutationKey(canonical) {
  return [
    'manual',
    canonical.account_id,
    canonical.task_id,
    canonical.target_date,
    String(canonical.venue_id),
    String(canonical.period_id),
    String(canonical.court_id),
  ].join(':');
}

/**
 * Normalizes user/UI inputs into strictly typed canonical fields:
 * - account_id: string
 * - task_id: string
 * - venue_id: safe positive integer
 * - target_date: YYYY-MM-DD
 * - period_id: safe positive integer
 * - court_id: safe positive integer
 * - time: string
 * - mutation_key: computed string
 */
export function normalizeManualInput(input) {
  if (!input || typeof input !== 'object') {
    throw fault('InvalidInput', 'Input must be an object');
  }

  const accountId = account(input);

  let rawTaskId = input.task_id;
  if (rawTaskId == null || (typeof rawTaskId === 'string' && !rawTaskId.trim())) {
    rawTaskId = 'manual-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
  }
  const cleanTaskId = taskId(String(rawTaskId).trim());

  const cleanVenueId = positive(input.venue_id?.value ?? input.venue_id, 'venue_id');
  const cleanDate = targetDate(String(input.target_date ?? '').trim());
  const cleanPeriodId = positive(input.period_id?.value ?? input.period_id, 'period_id');
  const cleanCourtId = positive(input.court_id?.value ?? input.court_id, 'court_id');
  const cleanTime = timeSlot(String(input.time ?? '').trim());

  const canonical = {
    account_id: accountId,
    task_id: cleanTaskId,
    venue_id: cleanVenueId,
    target_date: cleanDate,
    period_id: cleanPeriodId,
    court_id: cleanCourtId,
    time: cleanTime,
  };

  const computedKey = mutationKey(canonical);
  if (input.mutation_key && input.mutation_key !== computedKey) {
    throw fault('InvalidMutationKey', 'Provided mutation_key does not match canonical fields');
  }
  canonical.mutation_key = computedKey;

  return canonical;
}

/**
 * Produces a human-readable typed approval preview summary for the host.
 */
export function formatSummary(canonical, extra = {}) {
  const venueDesc = extra.venue_name ? ` (${extra.venue_name})` : '';
  const courtDesc = extra.court_name ? ` (${extra.court_name})` : '';
  return `场地预约审批: 账号 ${canonical.account_id}, 任务 ${canonical.task_id}, 场馆 #${canonical.venue_id}${venueDesc}, 日期 ${canonical.target_date}, 时段 #${canonical.period_id} (${canonical.time}), 场地 #${canonical.court_id}${courtDesc} [Key: ${canonical.mutation_key}]`;
}

/**
 * Real DanXi cell parser matching SportsSlotState.fromCell.
 * Respects:
 * - read_only flag
 * - occupy boolean
 * - num capacity
 * - status int
 * Enforces DanXi rule: available = !occupied && remaining > 0
 */
export function parseSlotState(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { occupied: true, remaining: 0, available: false, read_only: false };
  }

  if (raw.read_only === true || raw.read_only === 1 || raw.read_only === '1') {
    return { occupied: true, remaining: 0, available: false, read_only: true };
  }

  let remaining = null;
  if (raw.num !== undefined && raw.num !== null && raw.num !== '') {
    const n = Number(raw.num);
    if (Number.isFinite(n)) {
      remaining = n < 0 ? 0 : Math.floor(n);
    }
  }

  let statusOccupied = null;
  if (raw.status !== undefined && raw.status !== null && raw.status !== '') {
    const s = Number(raw.status);
    if (Number.isFinite(s)) {
      statusOccupied = s !== 0;
    }
  }

  let occupyVal = null;
  if (typeof raw.occupy === 'boolean') {
    occupyVal = raw.occupy;
  }

  const occupied =
    occupyVal === true ||
    statusOccupied === true ||
    (remaining !== null && remaining <= 0) ||
    (occupyVal === null && statusOccupied === null && remaining === null);

  const rem = remaining !== null
    ? remaining
    : (occupied ? 0 : 1);

  const available = !occupied && rem > 0;

  return {
    occupied,
    remaining: rem,
    available,
    read_only: false,
  };
}

/**
 * Extracts the single day availability mapping from calendar response.
 * Follows DanXi _extractDayData.
 */
export function extractDayData(raw, dateKey) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  if (raw[dateKey] && typeof raw[dateKey] === 'object' && !Array.isArray(raw[dateKey])) {
    return raw[dateKey];
  }
  const keys = Object.keys(raw);
  const isDateMap = keys.some(k => /^\d{4}-\d{2}-\d{2}$/.test(k));
  if (!isDateMap) return raw;
  if (keys.length === 1 && typeof raw[keys[0]] === 'object') {
    return raw[keys[0]];
  }
  return {};
}

export function lookupValue(source, key) {
  if (!source || typeof source !== 'object') return undefined;
  return source[key] !== undefined ? source[key] : source[String(key)];
}

/**
 * Classifies booking response messages matching DanXi _classifyBookingFailure.
 */
export function classify(response) {
  if (!response) return 'failed';
  if (response.e === 'OK' || response.e === 0 || response.e === '0') return 'success';
  const m = typeof response.m === 'string' ? response.m : '';
  if (/未结束的预约|已有预约/.test(m)) return 'existingReservation';
  if (/拥挤|频繁/.test(m)) return 'throttled';
  if (/未到预约时间|不在预约时间|预约时间未开始|未开放|服务时间/.test(m)) return 'notOpen';
  if (/容量不足|已被|抢完|已满/.test(m)) return 'gone';
  return 'failed';
}

/**
 * Prepares the exact launch form fields expected by /reservation/site/resource/launch.
 * Matches DanXi SportsReserveRepository.book.
 */
export function launchForm(canonical) {
  return {
    data: JSON.stringify([
      {
        resource_ids: [canonical.court_id],
        group_id: canonical.venue_id,
        period: [
          {
            date: canonical.target_date,
            period_id: canonical.period_id,
          },
        ],
        number: 1,
      },
    ]),
    data_colle: '[]',
    collective: '0',
    captcha: JSON.stringify({ token: '', pointJson: '' }),
  };
}

/**
 * Builds the deterministic canonical cancellation mutation key:
 * cancel:{account_id}:{appointment_id}
 */
export function cancelMutationKey(accountId, appointmentId) {
  return ['cancel', accountId, String(appointmentId)].join(':');
}

/**
 * Produces a human-readable typed preview summary for cancellation approval.
 */
export function formatCancelSummary(canonical, extra = {}) {
  const resourceDesc = extra.resource_name ? ` (${extra.resource_name})` : '';
  const detailDesc = canonical.appointment_detail_id?.length ? `, detail_ids=[${canonical.appointment_detail_id.join(',')}]` : '';
  const dataDesc = canonical.appointment_data_ids?.length ? `, data_ids=[${canonical.appointment_data_ids.join(',')}]` : '';
  const tpDesc = extra.is_third_party ? ' [第三方系统预约]' : '';
  return `取消预约审批: 账号 ${canonical.account_id}, 预约 #${canonical.appointment_id}${resourceDesc}${detailDesc}${dataDesc}${tpDesc} [Key: ${canonical.mutation_key}]`;
}

/**
 * Prepares the cancel form fields for normal or third-party endpoint.
 */
export function cancelForm(canonical, isThirdParty = false) {
  if (isThirdParty) {
    return {
      appointment_id: String(canonical.appointment_id),
    };
  }
  return {
    appointment_id: String(canonical.appointment_id),
    appointment_detail_id: JSON.stringify(canonical.appointment_detail_id || []),
    appointment_data_ids: JSON.stringify(canonical.appointment_data_ids || []),
  };
}
