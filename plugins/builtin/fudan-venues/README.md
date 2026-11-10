# official.fudan-venues

Official Core-side built-in manual sports venue module for `dansheng-core`.

This package is shipped as an official trusted, baked capability within `dansheng-core`. It provides manual venue inquiry, calendar exploration with real slot capacity/availability, and host-authorized single manual reservations executing within the authenticated Android WebView page session (`https://booking.fudan.edu.cn`).

## Architecture and Scope

- **Execution Runtime:** QuickJS ES module inside `dansheng-core`. Standalone package without Node.js runtime globals or dependencies in production module files.
- **Trusted Baked Capability:** Core-side official module. Contains **NO background jobs** (`jobs.schedule`, `jobs.cancel`, `jobs.status`), **NO timers** (`setTimeout`, `setInterval`), and requires no external plugin to function.
- **Reference Derivation:** Service endpoints, form structures, calendar parsing and booking status classifications are derived from the read-only DanXi reference (`C:/Code/danxi/lib/repository/fdu/sports_reserve_repository.dart` and `C:/Code/danxi/lib/model/sports_reservation.dart`, GPL-3.0-or-later).
- **Transport Security:** Authenticated browser page session ONLY (`ctx.browser.request` and `ctx.browser.evaluate`). Never substitutes native Rust HTTP.
- **Zero Raw Credentials:** No passwords or raw credentials are accepted or stored. Visible SSO login handoff via `visibleLogin`.

---

## Canonical Fields & Type Conversions

When user or UI inputs enter `prepareManual`, fields are validated and normalized into the strictly typed canonical input:

| Field | Source Type | Canonical Type | Format & Validation | Example |
|---|---|---|---|---|
| `account_id` | String | `string` | Safe identifier `/^[A-Za-z0-9_.:@-]{1,160}$/` | `"21307130001"` |
| `task_id` | String | `string` | Safe task identifier `/^[A-Za-z0-9_-]{1,100}$/` | `"manual-1731088800-abc123"` |
| `venue_id` | Number / String | `number` | Safe positive integer `> 0` | `900` (from `"900"`) |
| `target_date` | String | `string` | Gregorian date `YYYY-MM-DD` | `"2026-11-09"` |
| `period_id` | Number / String | `number` | Safe positive integer `> 0` | `70` (from `"70"`) |
| `court_id` | Number / String | `number` | Safe positive integer `> 0` | `901` (from `"901"`) |
| `time` | String | `string` | Trimmed period string | `"10:00-11:00"` |
| `mutation_key` | Computed | `string` | Deterministic key format | `manual:21307130001:manual-1731088800-abc123:2026-11-09:900:70:901` |

### Key Format

The deterministic mutation key binds every dimension of the user's manual authorization:
```
manual:{account_id}:{task_id}:{target_date}:{venue_id}:{period_id}:{court_id}
```
This key is evaluated both by the plugin module in `prepareManual` / `reserve` and by the host policy runtime in `host-policy.json`.

---

## API Contract

### 1. `visibleLogin`
- **Input:** `{ account_id: string }`
- **Output:** `{ success: boolean, operation: string }`
- **Description:** Hands off to trusted visible login in Android WebView; never accepts credentials.

### 2. `venues`
- **Input:** `{ account_id: string }`
- **Output:** `[{ id: number, name: string, building?: string, sport?: string, type?: number }]`
- **Description:** Queries `/reservation/api/topic/resource-list?id=48&pageSize=200` and extracts venue IDs and names.

### 3. `calendar`
- **Input:** `{ account_id: string, venue_id: number | string, target_date: string }`
- **Output:**
  ```json
  {
    "venue_id": 900,
    "target_date": "2026-11-09",
    "periods": [{ "id": 70, "time": "10:00-11:00", "start_time": "10:00", "end_time": "11:00" }],
    "courts": [{ "id": 901, "name": "羽毛球 1 号场" }],
    "slots": [
      {
        "period_id": 70,
        "time": "10:00-11:00",
        "court_id": 901,
        "court_name": "羽毛球 1 号场",
        "available": true,
        "occupied": false,
        "remaining": 1,
        "read_only": false,
        "target_date": "2026-11-09"
      }
    ]
  }
  ```
- **DanXi Shape Preservation:**
  Does NOT assume all courts are free. Evaluates cell properties matching `SportsSlotState.fromCell`:
  - `read_only === true` $\rightarrow$ `available: false, read_only: true, occupied: true, remaining: 0`
  - `occupy === true` $\rightarrow$ `available: false, occupied: true, remaining: 0`
  - `num !== undefined && num <= 0` $\rightarrow$ `available: false, occupied: true, remaining: 0`
  - `status !== undefined && status !== 0` $\rightarrow$ `available: false, occupied: true, remaining: 0`
  - Available only if `!occupied && remaining > 0`.

### 4. `appointments`
- **Input:** `{ account_id: string, page?: number, pageSize?: number }`
- **Output:** List of typed appointment objects (`id`, `resource_name`, `status_name`, `slots`).

### 5. `detail`
- **Input:** `{ account_id: string, appointment_id: number | string }`
- **Output:** Voucher details including `qrcode`, `show_code`, and `refresh_seconds`.

### 6. `prepareManual`
- **Input:** `{ account_id, venue_id, target_date, period_id, court_id, time, task_id? }`
- **Output:**
  ```json
  {
    "canonical_input": {
      "account_id": "21307130001",
      "task_id": "manual-1001",
      "venue_id": 900,
      "target_date": "2026-11-09",
      "period_id": 70,
      "court_id": 901,
      "time": "10:00-11:00",
      "mutation_key": "manual:21307130001:manual-1001:2026-11-09:900:70:901"
    },
    "summary": "场地预约审批: 账号 21307130001, 任务 manual-1001, 场馆 #900, 日期 2026-11-09, 时段 #70 (10:00-11:00), 场地 #901 [Key: manual:21307130001:manual-1001:2026-11-09:900:70:901]"
  }
  ```

### 7. `reserve`
- **Input:** Exact same `canonical_input` returned by `prepareManual`.
- **Pre-execution Recheck:** Automatically queries `calendar` for `venue_id` and `target_date`. If `period_id` and `court_id` is no longer available, throws `CourtOccupied` or `SlotUnavailable` and executes **0 POST writes**.
- **Single POST:** Executes exactly one POST request to `/reservation/site/resource/launch`.
- **Output:** `{ status: "success" | "failed" | ... , message: string, body: object }`.

### 8. `reconcile`
- **Input:** `{ account_id: string, task_id: string }`
- **Output:** `{ status: "reconciled_success" | "needs_reconciliation" | "not_found", appointment_id?: number }`.
- **Authoritative Proven Match:** Matches active slot, date, time, court, and account. Transitions state to `reconciled_success` with positive `appointment_id`.
- **Absence/Lagging History Safety:** Absence from the appointment list cannot prove absence (due to pagination or eventual consistency). Returns `status: "needs_reconciliation"` without marking failed, preserving the locked uncertain/in-flight record so the task is not prematurely freed.
- **Repeat Idempotency:** Subsequent calls on an already proven record return the same positive `appointment_id` for host job reconciliation.

### 9. `prepareCancel`
- **Input:** `{ account_id: string, appointment_id: number | string }`
- **Output:**
  ```json
  {
    "canonical_input": {
      "account_id": "21307130001",
      "appointment_id": 5501,
      "appointment_detail_id": [8801],
      "appointment_data_ids": [],
      "mutation_key": "cancel:21307130001:5501"
    },
    "summary": "取消预约审批: 账号 21307130001, 预约 #5501 (正大体育馆-羽毛球馆), detail_ids=[8801] [Key: cancel:21307130001:5501]",
    "appointment_id": 5501,
    "is_third_party": false,
    "endpoint": "/reservation/site/appointment/appointment-cancel"
  }
  ```
- **Description:** Read-only preparation that re-reads server cancellation flags, verifies current slot eligibility (`is_cancel`, active, can_cancel), checks group/standard data and detail IDs, and produces a typed preview summary.

### 10. `cancel`
- **Input:** Canonical input from `prepareCancel` (`{ account_id, appointment_id, appointment_detail_id, appointment_data_ids }`).
- **Output:** `{ status: "cancelled", appointment_id: number }`.
- **Anti-Broadening Verification:** Refetches appointment freshly from the server immediately prior to write; strictly verifies that `freshDetail` and `freshData` match the approved parameters; throws `CancellationNotAllowed` without sending any POST if selection broadened or changed.
- **Third-Party Support:** Automatically targets `/reservation/site/third-party/cancel-appointment` with `sign-key: /reservation/site/third-party/cancel-appointmentpost` when appointment `type === 7`.
- **Single POST & Uncertainty:** Single POST with unique key `cancel:{account_id}:{appointment_id}`. Timeouts/network interruptions persist `status: 'uncertain'` in journal; automatic retries are strictly prohibited.

### 11. `reconcileCancel`
- **Input:** `{ account_id: string, appointment_id: number | string }`
- **Output:** `{ status: "reconciled_cancelled" | "needs_reconciliation" | "still_active" | "not_found", appointment_id?: number }`.
- **Authoritative Proven Proof:** Positive proof requires authoritative appointment record showing cancelled status (`status === 0` or status name cancelled) or all relevant slots inactive (`active === false`). Returns `reconciled_cancelled` and positive `appointment_id`.
- **Absence Non-Proof:** Absence from the first history page is NOT evidence of cancellation. Returns `status: "needs_reconciliation"` without marking failed, preserving the locked record across restarts.

### 12. `journal`
- **Input:** `{ account_id: string, task_id: string }`
- **Output:** Stored task journal record (`{ task_id, account_id, entry }`).

---

## Host Policy Binding v1 (`host-policy.json`)

```json
{
  "binding_v1": {
    "binding_version": 1,
    "plugin_id": "official.fudan-venues",
    "identity_probe": {
      "url": "https://booking.fudan.edu.cn/reservation/site/user/detail",
      "method": "GET",
      "top_level_origin": "https://booking.fudan.edu.cn",
      "headers": {
        "sign-key": "/reservation/site/user/detailget",
        "Accept": "application/json"
      },
      "success_pointer": "/e",
      "success_value": "OK",
      "json_pointer": "/d/number"
    },
    "consent_scopes": {
      "reserve": {
        "key": "/task_id"
      }
    },
    "rules": [
      {
        "action": "reserve",
        "url": "https://booking.fudan.edu.cn/reservation/site/resource/launch",
        "transport": "xhr",
        "headers": {
          "Accept": "application/json, text/plain, */*",
          "sign-key": "/reservation/site/resource/launchpost"
        },
        "key": [
          "manual",
          { "$input": "account_id" },
          { "$input": "task_id" },
          { "$input": "target_date" },
          { "$input": "venue_id" },
          { "$input": "period_id" },
          { "$input": "court_id" }
        ],
        "form": {
          "data": {
            "$json": [
              {
                "resource_ids": [{ "$input": "court_id" }],
                "group_id": { "$input": "venue_id" },
                "period": [
                  {
                    "date": { "$input": "target_date" },
                    "period_id": { "$input": "period_id" }
                  }
                ],
                "number": 1
              }
            ]
          },
          "data_colle": "[]",
          "collective": "0",
          "captcha": {
            "$json": {
              "token": "",
              "pointJson": ""
            }
          }
        }
      },
      {
        "action": "cancel",
        "url": "https://booking.fudan.edu.cn/reservation/site/appointment/appointment-cancel",
        "transport": "xhr",
        "headers": {
          "Accept": "application/json, text/plain, */*",
          "sign-key": "/reservation/site/appointment/appointment-cancelpost"
        },
        "key": [
          "cancel",
          { "$input": "account_id" },
          { "$input": "appointment_id" }
        ],
        "form": {
          "appointment_id": { "$text": { "$input": "appointment_id" } },
          "appointment_detail_id": {
            "$json": { "$input": "appointment_detail_id" }
          },
          "appointment_data_ids": {
            "$json": { "$input": "appointment_data_ids" }
          }
        }
      },
      {
        "action": "cancel",
        "url": "https://booking.fudan.edu.cn/reservation/site/third-party/cancel-appointment",
        "transport": "xhr",
        "headers": {
          "Accept": "application/json, text/plain, */*",
          "sign-key": "/reservation/site/third-party/cancel-appointmentpost"
        },
        "key": [
          "cancel",
          { "$input": "account_id" },
          { "$input": "appointment_id" }
        ],
        "form": {
          "appointment_id": { "$text": { "$input": "appointment_id" } }
        }
      }
    ]
  }
}
```

### Method, Header & Form Matching
- **Endpoint:** `POST https://booking.fudan.edu.cn/reservation/site/resource/launch`
- **Transport:** `xhr` (required by server WAF challenge and XHR wrapper)
- **Headers:**
  - `Accept: application/json, text/plain, */*`
  - `sign-key: /reservation/site/resource/launchpost`
- **Form Data Fields:**
  - `data`: stringified JSON of `[{ resource_ids: [court_id], group_id: venue_id, period: [{ date: target_date, period_id: period_id }], number: 1 }]`
  - `data_colle`: `"[]"`
  - `collective`: `"0"`
  - `captcha`: `'{"token":"","pointJson":""}'`

---

## Availability Recheck & Uncertainty Lifecycle

```
[User Form / UI]
       │
       ▼
[prepareManual] ──────────► Returns { canonical_input, summary }
       │
       ▼ (User Review & Host Approval)
[reserve(canonical_input)]
       │
       ├──► 1. Check Journal:
       │       ├── If 'in_flight' or 'uncertain' ──► REJECT: NeedsReconciliation (No re-submission)
       │       └── If 'success' / 'reconciled'   ──► Return already completed (0 writes issued)
       │
       ├──► 2. Recheck Availability (Query calendar)
       │       └── If slot occupied / capacity 0:
       │           FAIL CLOSED: CourtOccupied (0 writes issued)
       │
       ├──► 3. Durably Persist Journal: 'in_flight' (Recoverable across restarts)
       │
       ├──► 4. Issue Single POST with sign-key and mutation_key
       │       │
       │       ├── Success (200, e: "OK") ──► Mark Journal: 'success'
       │       ├── Remote Error (e: 1) ────► Mark Journal: 'failed'
       │       └── Timeout / Net Error ────► Mark Journal: 'uncertain'
       │                                     THROW NeedsReconciliation
       │                                     (NO RETRY ALLOWED)
       ▼
[reconcile(account_id, task_id)]
       │
       ├── Already proven (reconciled_success) ──► Return same positive appointment_id
       │
       ├── Query /appointment-list for authoritative positive match
       │       ├── Match found ──► Mark Journal: 'reconciled_success' (with positive appointment_id)
       │       └── Not found ────► Preserve 'uncertain' status (No freeing/failure marking)
       │                           Return 'needs_reconciliation'
```

---

## Test Fixtures & Coverage

Offline integration tests are contained in `tests/`:
- `fixtures.mjs`: Real DanXi response fixtures including calendar capacity permutations, topic venue listings, appointment histories, voucher details, and identity probe responses.
- `host-policy-fixture.mjs`: Test harness implementing `binding_v1` JSON pointer resolution, identity extraction from `/d/number`, key evaluation, form comparison, and rule matching.
- `plugin.test.mjs`: Unit and integration test suite covering:
  - Manifest declaration and validation
  - Visible login handoff without credentials
  - Venue listing retrieval
  - DanXi calendar availability parsing (occupied, num=0, status!=0, read_only)
  - Canonical input normalization and deterministic mutation key calculation
  - Recheck-before-write availability gating
  - Single POST dispatch with sign-key and form template matching
  - Denial and uncertain state transitions (network timeouts, journal persistence, retry suppression)
  - History reconciliation
- `host-policy.test.mjs`: Binding v1 validation against `RuntimeHost` policy rules.
