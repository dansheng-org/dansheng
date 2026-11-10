# official.fudan-sports (v0.2.0)

Official Fudan University sports venue reservation and scheduled automation plugin for `dansheng-core`.

This package is an optional, independently distributable plugin executing within `dansheng-core`'s mediated QuickJS runtime and Android authenticated WebView page session.

## Architecture and Scope

- **Runtime Environment:** QuickJS ES module inside `dansheng-core`. Browser HTTP requests and mutations run inside the authenticated Android WebView page session (`https://booking.fudan.edu.cn`). No Node.js or Chromium runtime is present in release artifacts.
- **Reference Derivation:** Service endpoints, form structures, court ordering, scheduling lifecycle, and retry policies are derived from the read-only reference `reference/DanXi-local-sports` (Copyright (C) 2021 DanXi-Dev, GPL-3.0-or-later) and `C:/Code/danxi/lib/feature/sports_reservation/sports_sniper_runner.dart`.
- **Security & Authorization:** No passwords or raw credentials are accepted or stored. All write mutations require concrete user authorization and atomic host claims. Write timeouts preserve uncertainty and require history-based reconciliation.

## Scheduling Lifecycle & Execution Parity

The plugin faithfully reproduces the DanXi sports sniper lifecycle and timing guarantees:

### 1. Timing Contracts
- **Native Prewarm / Alarm:** Wake-up scheduled 5 minutes (300,000 ms) before release time (`release_at - 5min`), waking the host engine.
- **Browser Preload:** 60 seconds (60,000 ms) before release time (`release_at - 60s`). Session authentication is validated and venue calendar data is preloaded.
- **First Shot:** Dispatched at `release_at + 300ms` (`firstShotDelayMs: 300`).
- **Task Window / Deadline:** Bounded to 5 minutes (300,000 ms) after release (`release_at + 5min`). Any execution at or after deadline expires cleanly.
- **Schedule Refresh:** Calendar refreshed periodically (every 15s, `scheduleRefreshMs: 15000`) when period IDs are unpopulated or invalidated by a `notOpen` response.
- **Backoff & Round Pause:** 800 ms throttle backoff (`throttleBackoffMs: 800`) on rate limiting (`throttled`), and 1200 ms round pause (`roundPauseMs: 1200`) between full sweeps across unfulfilled plans.

### 2. Task Concurrency & Sequential Per-Task Execution
- **Multi-Task Concurrency:** Matching `sports_sniper_background.dart` where `Future.wait` runs across independent tasks, multiple sports reservation tasks for different dates/venues execute concurrently without interference.
- **Sequential per-slot priority & court fallback:** Matching `sports_sniper_runner.dart`, within each task slots and fallback courts are processed sequentially:
  - Iterates through unfulfilled time slots sequentially.
  - For each time slot, courts are attempted in descending priority order (`courtIds[0]`, then `courtIds[1]`, etc.).
  - Explicit rejection (`gone`, `failed`, `throttled`) triggers fallback to the next court for the slot.
  - `notOpen` advances to the next slot (does not burn remaining fallback courts within the same round), keeping the slot retryable in subsequent rounds.
  - `existingReservation` is an immediate terminal stop across all slots.
  - When all unfulfilled slots have completed their court attempts for the round, a 1200 ms round pause elapses before beginning the next round.

### 3. Android Host Scheduling & Subsecond Precision Considerations
- **AlarmManager vs In-Process Precision:** On Android, `AlarmManager` (`setExactAndAllowWhileIdle` / `setAlarmClock`) is an OS-level wake-up mechanism designed for coarse wake-up. It is scheduled 5 minutes prior to release (`release_at - 5min`) to launch the foreground service and start the runtime.
- **In-Process High-Precision Delays:** Subsecond scheduling (`release_at + 300ms`, `800ms` throttle delay, `1200ms` round pause) runs within the active process execution loop.
- **Limitations:** If the host OS terminates the background service or delays the initial alarm past `release_at`, the prewarm window is lost and subsecond timing guarantees cannot be met from a cold start. The host environment should hold a partial wake lock during the 5-minute prewarm window.

## Manifest and Generic UI Schema (ui_version: 1)

The plugin manifest declares declarative UI entries matching the generic UI v1 schema:

```json
{
  "id": "sports_schedule",
  "type": "form",
  "title": "场地预约与定时",
  "ui_version": 1,
  "time_zone": "Asia/Shanghai",
  "fields": [
    { "id": "task_id", "label": "任务 ID", "type": "identifier" },
    { "id": "venue_id", "label": "场馆", "type": "select", "source": { "action": "venueOptions" }, "clearOnChange": ["selected_slots"] },
    { "id": "target_date", "label": "预约日期", "type": "date", "clearOnChange": ["selected_slots"] },
    { "id": "release_at", "label": "开抢时间", "type": "datetime" },
    { "id": "selected_slots", "label": "预约时段与场地", "type": "multiselect", "source": { "action": "slotOptions", "dependsOn": ["venue_id", "target_date"] } }
  ],
  "buttons": [
    { "label": "预约定时", "action": "schedule", "prepare": "prepareSchedule", "fields": ["task_id", "venue_id", "target_date", "release_at", "selected_slots"], "confirm": true }
  ]
}
```

### UI Schema Field Specification

- **Field Types:** `text`, `date`, `datetime`, `select`, `multiselect`, `identifier`.
- **Identifier (`identifier`):** Host automatically binds or generates a stable task ID without manual user entry.
- **Dynamic Source (`source: { action, dependsOn }`):**
  - Source actions return an array of `{ label: string, value: JsonValue }`.
  - Values may be scalars or JSON objects.
  - Form passes `account_id` automatically to all source actions.
  - Dependent fields re-fetch options when `dependsOn` fields change.
- **Clear on Change (`clearOnChange: [field_ids]`):** Downstream fields are reset when upstream values change (e.g. changing venue or date resets selected slots).
- **Time Zone:** When the entry specifies `time_zone: 'Asia/Shanghai'`, native Dart datetime returns ISO format with `+08:00` offset (e.g. `2031-01-02T07:00:01+08:00`), preventing device timezone ambiguity.
- **Button Actions and Preparation:**
  - Buttons declare `action`, `fields`, and optional `prepare` action.
  - When present, the `prepare` action (`prepareSchedule`) normalizes UI form selections into a canonical, fully detailed `SportsPlan`.
  - The `prepare` action returns `{ canonical_input, summary, prepare, ...plan }`.
  - The canonical input is presented in host confirmation UI before `schedule` is called with user approval.

## Actions Reference

| Action | Mutating | Capabilities | Description |
| --- | --- | --- | --- |
| `listTasks` | `false` | `storage.read`, `jobs.status` | Read-only list of sports task summaries scoped strictly to `account_id`. Queries `jobs.status` for subtask details. Enqueue sequence and wake-up records are preserved; late or stale ACKs never overwrite later stages or stops. |
| `venueOptions` | `false` | `browser.request`, `browser.evaluate` | Returns venue selection options (`[{ label, value }]`) for generic UI select fields. |
| `slotOptions` | `false` | `browser.request`, `browser.evaluate` | Returns available time slot and court options (`[{ label, value }]`) for the selected venue and target date. |
| `prepareSchedule` | `false` | None (pure JS) | Normalizes generic form inputs into a canonical `SportsPlan` for user review and host approval. |
| `visibleLogin` | `false` | `browser.login`, `browser.evaluate` | Hands off to trusted visible Android WebView login; never accepts raw credentials. |
| `venues` | `false` | `browser.request`, `browser.evaluate` | Reads sports venue listing from the authenticated page. |
| `calendar` | `false` | `browser.request`, `browser.evaluate` | Reads periods and courts for a specified venue and date. |
| `appointments` | `false` | `browser.request`, `browser.evaluate` | Reads appointment history for the current account. |
| `appointmentDetail` | `false` | `browser.request`, `browser.evaluate` | Reads detailed voucher information for a specific appointment ID. |
| `cancelAppointment` | `true` | `browser.request`, `browser.write`, `storage.read`, `storage.write` | Re-reads server cancellation flags and cancels an appointment after concrete user authorization. |
| `schedule` | `true` | `storage.read`, `storage.write`, `jobs.schedule`, `ui.publish` | Persists and schedules an authorized `SportsPlan`. |
| `tick` | `true` | `browser.request`, `browser.write`, `storage.read`, `storage.write`, `jobs.schedule`, `ui.publish` | Executes one bounded stage of an authorized sports plan with sequential court fallback. |
| `stop` | `false` | `storage.read`, `storage.write`, `jobs.cancel` | Stops local execution and cancels pending jobs; already dispatched writes require reconciliation. |
| `reconcile` | `false` | `storage.read`, `storage.write`, `browser.request` | Reconciles an uncertain reservation state by probing read-only appointment history. |

## Host Policy Binding v1 (`binding_v1`)

The package includes a machine-readable Host Policy Binding v1 descriptor in `host-policy.json` adhering to the contract defined in `dansheng-app`:

1. **Machine-Readable Structure (`binding_v1`):**
   - Root or `binding_v1` declares `binding_version: 1`, `plugin_id: "official.fudan-sports"`, `identity_probe`, and `rules`.
   - Legacy and human-readable documentation resides in `documentation`. Fictitious `$schema` and unverified certifications are removed.

2. **Reservation Schedule Mutation Rules:**
   - Action: `schedule`
   - URL: `https://booking.fudan.edu.cn/reservation/site/resource/launch`
   - Transport: `xhr`
   - Headers: `Accept: "application/json, text/plain, */*"`, `sign-key: "/reservation/site/resource/launchpost"`
   - Exact Concrete Key: `["task", {"$input": "account_id"}, {"$input": "task_id"}, {"$positiveInteger": true}, {"$row": "period_id"}, {"$choice": true}]`
     yielding key `task:{account_id}:{task_id}:{round}:{period_id}:{court_id}`
   - Rows & Choices: `rows: "plans"`, `choices: "courts"`
   - Form Fields: Strict declarative projections matching `api.mjs launchFields`:
     - `data`: embedded JSON template projecting `resource_ids`, `group_id`, `period` with `period_id`, and `number: 1`
     - `data_colle`: `"[]"`
     - `collective`: `"0"`
     - `captcha`: embedded JSON `{ "token": "", "pointJson": "" }`
   - Default Deny: Extra unmapped form fields, unknown parameters, or non-finite positive rounds are rejected by the host.

3. **Cancellation Mutation Rules (Standard and Third-Party):**
   - Actions: `cancelAppointment`
   - Normal Endpoint: `https://booking.fudan.edu.cn/reservation/site/appointment/appointment-cancel`
     - Key: `["cancel", {"$input": "account_id"}, {"$input": "appointment_id"}]`
     - Form: `appointment_id`, `appointment_detail_id` (JSON array projection), `appointment_data_ids` (JSON array projection)
   - Third-Party Endpoint: `https://booking.fudan.edu.cn/reservation/site/third-party/cancel-appointment`
     - Key: `["cancel", {"$input": "account_id"}, {"$input": "appointment_id"}]`
     - Form: `appointment_id`
   - Execution Guard: `prepareCancelAppointment` performs a read-only fetch of the appointment record, returning canonical eligible detail and data ID arrays. At execution time, `cancelAppointment` re-reads the appointment freshly from the server and strictly verifies that eligible IDs match approved targets, preventing hidden broadening.

4. **Identity Probe Evaluation:**
   - The [published booking frontend](https://bookingassets.fudan.edu.cn/_nuxt/entry.76b5bf62.js) maps its personal profile read to `/reservation/site/user/detail` and supplies the GET signing header. Its [profile page](https://bookingassets.fudan.edu.cn/_nuxt/homePage.55980aba.js) reads the response's `d` object; the [profile fields](https://bookingassets.fudan.edu.cn/_nuxt/useUserInfo.0ba89a55.js) identify `number` as the student/staff number.
   - Verify in the current authenticated page. Require HTTP 200, `e === "OK"`, the bound origin and an exact string match at `/d/number`; return only the identity check result. Missing, masked or mismatched identity fails closed. This is public frontend evidence, not a live authenticated-account result.

5. **Write Uncertainty Preservation:**
   - Write timeouts, network interruptions, HTTP 412 (WAF), HTTP 5xx, or process termination while a request is in flight are strictly UNCERTAIN outcomes.
   - The plugin journals `needs_reconciliation` before dispatch.
   - Retries or resends are prohibited until authoritative absence is confirmed via `reconcile`.

## Packaging (.dspack)

The plugin can be packed into an independent, deterministic `.dspack` ZIP archive.

### Deterministic Pack Command

```powershell
node plugins/fudan-sports/pack.mjs [outputPath]
```

- **Default output:** `<repo-root>/.local/plugins/official.fudan-sports-0.2.0.dspack` (outside tracked files).
- **Archive contents:** Flat manifest, three QuickJS modules, a declarative host policy, platform metadata, types, README and attribution. The Node packer and test-side reference evaluator are not shipped.
- **Determinism:** Fixed file timestamps (2026-01-01), lexicographically sorted entries, standard deflate compression, zero external runtime or build dependencies. Repeated runs yield identical SHA-256 hashes.
