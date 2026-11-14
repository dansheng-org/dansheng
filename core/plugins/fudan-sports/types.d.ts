// SPDX-License-Identifier: GPL-3.0-or-later
export interface SportsOptions {
  nativePrewarmMs: number; browserPreloadMs: number; firstShotDelayMs: number;
  windowMs: number; scheduleRefreshMs: number; throttleBackoffMs: number;
  errorBackoffMs: number; roundPauseMs: number; requestTimeoutMs: number; maxReservationSlots: number;
}
export interface SportsTimePlan { time: string; period_id?: number | null; courts: number[] }
export interface SportsTickInput {
  account_id: string; task_id: string;
  /** Persisted transition identity; time changes alone must never create a new job. */
  sequence: number;
}
export interface SportsPlan {
  account_id: string; task_id: string; venue_id: number; target_date: string;
  /** RFC3339 with explicit Z or timezone offset; Fudan uses Asia/Shanghai (+08:00). */
  release_at: string; plans: SportsTimePlan[]; options?: Partial<SportsOptions>;
}
export interface PageRequest {
  account_id: string; session_handle: string; url: string; method: 'GET' | 'POST';
  transport: 'fetch' | 'xhr'; headers: Record<string, string>;
  form_fields?: Record<string, string>; deadline_epoch_ms: number;
  /** Provider atomically claims against host-approved task/action. This is not an approval token. */
  mutation_key?: string;
}
export interface PageResponse { status: number; url: string; body: string }
export interface BrowserSession { account_id: string; authenticated: boolean; session_handle?: string }
export interface AppointmentSlot {
  date: string; time: string; resource_name: string; resource_id: number | null;
  detail_id: number | null; appointment_data_id: number | null; active: boolean; can_cancel: boolean;
}
export interface Appointment {
  id: number; resource_name: string; status: number | string; type: number;
  is_group: boolean; is_cancel: boolean; is_all_cancel: boolean; slots: AppointmentSlot[];
}

export interface TaskTransition {
  sequence: number;
  phase: string;
  run_at: string;
  prepare_at: string;
  deadline_at: string;
}

export interface TaskPending {
  time: string;
  court_id: number;
  period_id: number;
  round: number;
}

export interface SubtaskSummary {
  id: string;
  state: string | null;
  run_at: string | null;
}

export interface TaskSummary {
  task_id: string;
  account_id: string;
  venue_id: number;
  target_date: string;
  release_at: string;
  status: string;
  display_status: string;
  planned_count: number;
  success_count: number;
  round: number;
  sequence: number;
  job_id: string | null;
  job_sequence: number | null;
  wake_up: Record<string, unknown> | null;
  transition: TaskTransition | null;
  pending: TaskPending | null;
  pendings?: TaskPending[];
  subtask: SubtaskSummary | null;
}

export interface VenueOption {
  label: string;
  value: number;
}

export interface SlotOptionValue {
  time: string;
  period_id?: number | null;
  court_id?: number;
  courts?: number[];
  court_name?: string;
}

export interface SlotOption {
  label: string;
  value: SlotOptionValue;
}

export interface PrepareScheduleInput {
  account_id: string;
  task_id?: string;
  venue_id: number | { value: number };
  target_date: string;
  release_at: string;
  selected_slots?: (SlotOptionValue | string)[];
  plans?: SportsTimePlan[];
  options?: Partial<SportsOptions>;
}

export interface PrepareScheduleOutput extends SportsPlan {
  canonical_input: SportsPlan;
  summary: string;
  prepare: string;
}

export interface PrepareCancelAppointmentInput {
  account_id: string;
  appointment_id: number | string | { value: number | string };
}

export interface PrepareCancelAppointmentOutput {
  canonical_input: {
    account_id: string;
    appointment_id: number | string;
    appointment_detail_id: number[];
    appointment_data_ids: number[];
  };
  appointment_id: number | string;
  appointment_detail_id: number[];
  appointment_data_ids: number[];
  endpoint: string;
  is_third_party: boolean;
  is_group: boolean;
  summary: string;
  prepare: string;
}

export interface CancelAppointmentInput {
  account_id: string;
  appointment_id: number | string | { value: number | string };
  appointment_detail_id?: number[];
  appointment_data_ids?: number[];
  canonical_input?: PrepareCancelAppointmentOutput['canonical_input'];
}

export interface CancelAppointmentOutput {
  status: 'cancelled';
  appointment_id: number;
}

export interface OptionItem<T = unknown> {
  label: string;
  value: T;
}

export type TaskOption = OptionItem<string>;
export type AppointmentOption = OptionItem<number>;
