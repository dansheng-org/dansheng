# M4 local organizer

`dansheng_core::organizer` is an offline service over the existing `Store`. It does not depend on a connector, Flutter, MCP, a browser, platform notifications, or an external service. It never makes external writes, accepts filesystem paths, or executes caller-supplied SQL. The host supplies the trusted `Principal` and `Grant`; request parameters cannot override either.

## Integration and permissions

The entry point is:

```rust
pub fn dispatch(
    store: &Store,
    principal: &Principal,
    grant: &Grant,
    method: &str,
    params: serde_json::Value,
) -> CoreResult<serde_json::Value>;
```

`Organizer::new(&Store)` initializes the independent schema. `Organizer::dispatch` and the free entry point also ensure initialization, so startup ordering does not require an organizer singleton. Authorization is checked before request-driven initialization. Calls are synchronous local SQLite transactions; no transaction spans platform I/O.

Main integration is present outside this worker's write scope:

1. `lib.rs` exports `pub mod organizer;`.
2. Engine delegates recognized methods to `organizer::dispatch(&self.store, principal, &grant, method, params)` after its permission gate.
3. `policy::capability_for` consults `organizer::required_capability(method)`, including the plugin manifest gate. The service repeats the check for direct callers.
4. `Engine.tick` calls its notification publisher before running jobs. The publisher collects native claims, rechecks each claim, publishes `activity_notification` events, optionally calls the available `notifications.show` port, and records separate channel receipts. The helpers remain absent from wire dispatch, the capability map, and plugin host APIs. Scope-aware event audience filtering remains the host's responsibility, as described below.

No new dependencies are needed: chrono, chrono-tz, serde, serde_json, uuid, and rusqlite are already present. Existing tempfile is used in offline tests.

| Methods | Required capability |
| --- | --- |
| `todo.list`, `todo.get` | `todo.read` |
| `todo.create`, `todo.update`, `todo.complete`, `todo.delete`, `todo.link` | `todo.write` |
| `calendar.list`, `calendar.get`, `calendar.conflicts`, `calendar.export_ics` | `calendar.read` |
| `calendar.create`, `calendar.update`, `calendar.delete`, `calendar.link` | `calendar.write` |
| `activity.list` | `activity.read` |
| `activity.sync`, `activity.read`, `activity.archive`, `activity.notifications` | `activity.write` |
| `reminders.list` | `reminders.read` |
| `reminders.schedule`, `reminders.cancel`, `reminders.due` | `reminders.write` |

Additional checks:

- `calendar.export_ics` includes TODOs by default and additionally requires `todo.read`. Pass `include_todos:false` to export only events.
- Creating source links requires `sources.read`. Every later projection rechecks the live source/account grant and all canonical source read labels in SQL. Source permissions are not snapshotted into the link.
- Reminder scheduling requires the target item's `todo.read` or `calendar.read`; reminder listing, due claiming, and reminder-generated inbox visibility apply the same underlying read checks in SQL. Linked items additionally require current source access. This prevents reminder summaries from becoming a route around item read permission.
- Activities associated with a nonempty `account_id` require that live account grant for synchronization, inbox access, local state changes, and notification claims.

One data directory is one user profile. Owner, Client, and MCP adapters address the **same profile organizer**, with mandatory `todo.*`, `calendar.*`, `activity.*`, and `reminders.*` grants on every non-owner request. A TODO created by an authorized MCP client is immediately visible to an authorized UI client and the owner. Revoking the creating agent stops future agent calls; it does not remove the user's data or stop the user's already scheduled profile reminders. Separate user profiles use separate data directories.

Plugins default to a private namespace keyed by their trusted `(kind,id)`. An explicit trusted `Grant.organizer_scope = Some("profile")` permits an approved plugin to contribute to the profile, still subject to operation/account/source grants. This field is never accepted as a request parameter. Changing a plugin's scope selects its current namespace; it does not automatically copy old private data. Profile readers cannot inspect private plugin organizer data merely by having broad organizer capabilities. Every organizer SQL statement restricts the resolved profile/private namespace; account/source references additionally use live canonical-record ACLs. Authorization identity is not a user tenant identifier.

## TODO and event API

Parameters are objects with unknown fields rejected. IDs are generated UUIDs, stable across updates and reopen. Creates and updates return the resulting item. Item views contain `id`, `kind` (`todo` or `event`), `origin` (`personal` or `source`), `title`, `notes`, `location`, `timezone`, `due_at`, `start_at`, `end_at`, `completed_at`, `source`, `created_at`, and `updated_at`; inapplicable fields are null or empty strings.

| Method | Parameters |
| --- | --- |
| `todo.create` | `title`, optional `notes`, `due_at`, `timezone` |
| `todo.update` | `id`, `changes` containing one or more of `title`, `notes`, `due_at`, `timezone` |
| `todo.complete` | `id`, optional `completed` (default true); false reopens |
| `todo.get`, `todo.delete` | `id` |
| `todo.list` | optional `completed`, `limit`, `offset`, `from`, `to`, `timezone` |
| `calendar.create` | `title`, `start_at`, `end_at`, optional `notes`, `location`, `timezone` |
| `calendar.update` | `id`, `changes` containing event fields |
| `calendar.get`, `calendar.delete` | `id` |
| `calendar.list` | optional `limit`, `offset`, `from`, `to`, `timezone` |
| `todo.link`, `calendar.link` | `source` reference described below |

`due_at:null` clears a personal TODO deadline. Other update fields cannot be cleared with null. Unspecified fields remain unchanged. Completing an already completed TODO preserves the original completion timestamp. Completion cancels pending reminders; reopening does not rearm them. Delete/unlink also removes its reminders and reminder-generated activities, without modifying any canonical source record.

Lists return `{ "items": [...], "total": n }` after visibility and range filtering, ordered by due/start time and stable ID. Pagination defaults to 50, accepts 1–500, and supports offsets up to 100,000. Range parameters must be supplied together. Event windows use half-open overlap (`start < to && end > from`); TODO windows include deadlines in `[from,to)` and exclude undated TODOs.

The default timezone is `Asia/Shanghai`. Inputs accept RFC3339 with an explicit offset or a local ISO datetime such as `2026-11-06T09:00`. Local inputs are resolved using the validated IANA timezone. Ambiguous DST folds and nonexistent local times are rejected; callers can disambiguate with an explicit RFC3339 offset. Offset inputs specify the instant, while `timezone` retains the display zone. Stored/output instants are UTC at millisecond precision. Calendar/window boundaries require whole seconds for interoperable ICS; event durations and query windows must be positive and at most 366 days. Years must be 1900–9999. Timed, finite occurrences are supported; all-day and recurrence expansion are not part of this interface.

## Canonical source links

A source reference has `source_id`, `external_id`, optional `account_id` (default empty), and optional `record_owner`. The latter only disambiguates canonical source identity; it never supplies a personal principal and cannot bypass source access checks. Ambiguous authorized source matches return `AmbiguousSource`.

Canonical reads use the root Store schema 3 `source_access(owner,source_id,capabilities)` table, with the same rules as `Store::records`. For every non-owner, a correlated SQL `NOT EXISTS` rejects the row if **any** required label is absent from the current active grant. Repeated `Store::require_source_capabilities` calls union labels; having one of several labels is insufficient. Labels are matched to the canonical record writer and source, not the organizer namespace or requesting principal. Anonymous records written by the caller are still subject to their labels. Legacy rows whose kind or source ID matches `mail.%` additionally require `mail.read`, even without an explicit label row. The intrinsic owner retains access.

The same SQL predicate filters canonical link resolution before disambiguation/body parsing, existing source projections, conflict scans, ICS export, reminder visibility/due selection, reminder-generated inbox access, scheduler claims, and live lease rechecks. For example, `sources.read`, the account grant, and `calendar.write` do not expose a timetable labeled `fudan.academic.read` until that label is granted. Revocation hides an existing reference without deleting the user's link or marking its reminder fired. An inaccessible row cannot create a false `AmbiguousSource` result. This layer interprets generic labels; it does not hardcode school service capabilities.

```json
{
  "source": {
    "account_id": "school-account",
    "source_id": "official.timetable",
    "external_id": "dated-occurrence-1"
  }
}
```

`todo.link` requires a canonical `records.kind` of `assignment`; `calendar.link` requires `timetable`. Links store only the canonical identity, local completion overlay, and local timestamps. Linking the same canonical record again within the same personal namespace returns its existing ID. A later source update is reflected on the next read, conflict check, or export; the canonical update timestamp participates in `updated_at`. Canonical entities are never copied into a separate authoritative organizer item.

The generic projection contract for `records.data` is deliberately small:

- Both: `title` or `name`; optional validated `timezone`.
- Assignment: optional nullable `due_at`.
- Timetable: `start_at`, `end_at`, optional `location`.

These are allowlisted fields; raw payloads, credentials, URLs, and HTML are not copied into views or ICS. School-specific week/unit-to-clock conversion belongs to the official connector or its host adapter, which must publish dated normalized occurrences. The shared core does not assume a school's teaching-hour table. Malformed source projections return `InvalidInput`; missing or revoked sources are hidden from lists/exports and return `NotFound` on get. Source links cannot be edited as personal items (`ReadOnlySource`); linked TODO completion is a local overlay and never submits an assignment. Local unlink remains possible after source access is revoked.

## Conflicts and ICS

`calendar.conflicts` accepts optional `from`, `to`, `timezone`. It returns `{ "conflicts": [...] }` with each pair's `left_id`, `right_id`, and intersecting `start_at`/`end_at`. Adjacent events do not conflict; different offsets are compared as UTC instants. It includes visible linked timetable occurrences. A bounded scan covers all personal events, not just a list page; more than 5,000 conflict pairs returns `LimitExceeded` instead of silently truncating.

An optional `candidate` object (`start_at`, `end_at`, optional `exclude_id`) tests a proposed event without saving it. Results then contain the existing event's `id` and the intersection. `exclude_id` supports editing an existing event.

`calendar.export_ics` accepts optional `from`, `to`, `timezone`, `completed`, and `include_todos` (default true), and returns `{ "content_type": "text/calendar; charset=utf-8", "ics": "..." }`. Export is complete for the selected range; pagination parameters are rejected.

The exporter follows [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545.html): CRLF lines, TEXT escaping of backslash/semicolon/comma/newlines, UTF-8-safe folding at at most 75 octets including continuation whitespace, generated stable UID, DTSTAMP, and UTC DTSTART/DTEND/DUE/COMPLETED. UTC properties do not use TZID or require VTIMEZONE. `X-DANSHENG-TIMEZONE` retains the display zone as TEXT metadata. Exports include VEVENT and optionally VTODO; there are no invitations, attendees, transport instructions, or notification deliveries. Creation/update metadata in ICS is represented at its standard second precision.

## Reminder claims

| Method | Parameters and result |
| --- | --- |
| `reminders.schedule` | `item_id`, `at`, optional `timezone` (defaults to target item's zone); returns reminder |
| `reminders.list` | optional `item_id`, `limit`, `offset`; returns `{items:[...]}` |
| `reminders.cancel` | `id`; cancels pending state without removing dedup history |
| `reminders.due` | optional `now`, `limit`; atomically claims due reminders and returns `{items:[{reminder,activity_id}]}` |

Reminders include `id`, `item_id`, UTC `at`, `timezone`, `state`, `created_at`, `fired_at`. Deduplication is the unique SQL tuple `(personal owner, item_id, instant-at-millisecond-precision)`. Equivalent offsets deduplicate. Rescheduling the same instant returns the original reminder even after fired/cancelled; choose a new instant for a new reminder. Completed TODOs cannot be scheduled.

`reminders.due` defaults to current UTC. An explicit `now` supports host clock/testing and follows the same datetime parser with UTC as its default. Each claim and its single inbox entry commit in one transaction. Repeated calls, concurrent calls, process restart, or an uncertain local response cannot produce duplicate reminder entries. Notifications for revoked/invisible linked items remain unclaimed; restoring access may surface an overdue reminder. Claims do not call a platform port. Host wake-up and notification delivery are separate responsibilities.

## Activity inbox and initial synchronization

`activity.sync` parameters are `source_id`, optional `account_id` (empty by default), `items`, and optional `complete` (default true). Each item is a bounded plain summary with `external_id`, `title`, `kind`, `occurred_at`. There is no arbitrary payload/body/credential field. `organizer.reminders` is reserved for internal reminder entries. External event identifiers must be stable; use a distinct external event ID when a source update should itself become a new activity.

Initial-sync checkpoints are independent for `(personal owner, account_id, source_id)`. Every new entry while that checkpoint is uninitialized is stored with `notification:"suppressed"`. For paged baseline imports, use `complete:false` on every initial page except the final one. The final page is also suppressed and then marks the checkpoint initialized. Empty complete imports establish an empty baseline. This survives process restart; duplicate replay never changes suppression or re-notifies. Later new IDs become `pending`. Existing IDs update summary/time while preserving their local read/archive/notification state and stable local ID. The entire batch and checkpoint commit together; invalid input rolls both back. A caller-supplied first-sync override is not accepted.

| Method | Parameters and result |
| --- | --- |
| `activity.list` | optional `account_id`, `source_id`, `unread`, `archived` (default false), `limit`, `offset`; returns `{items,total}` |
| `activity.read` | `id`, optional `value` (default true); false marks unread |
| `activity.archive` | `id`, optional `value` (default true); false restores to inbox |
| `activity.notifications` | optional `limit`; atomically changes visible unread/unarchived `pending` entries to `claimed` and returns `{items}` |

Inbox entries expose stable local ID, source/account/external IDs, title/kind/time, notification state, nullable `read_at`/`archived_at`, and optional local reminder `item_id`. Read/archive operations consume pending alerts; undoing those local states never rearms notifications. Suppressed history remains available in the inbox.

Notification claims implement durable at-most-once **local handoff**, not guaranteed platform delivery. A host crash after claiming and before displaying can lose a display; the host can always inspect the durable inbox. Claims are not automatically replayed to a platform. User content is not emitted to the global audit/event log by this module.

## Trusted scheduler and delivery receipts

These are native Rust integration APIs for the trusted host, **not wire methods**. No caller can choose another owner through request JSON. They require no new dependency and perform no platform, network, or GUI operation:

```rust
pub fn claim_due_notifications(
    store: &Store,
    now: DateTime<Utc>,
    options: NotificationOptions,
) -> CoreResult<NotificationBatch>;

pub fn notification_claim_is_current(
    store: &Store, claim: &NotificationClaim, now: DateTime<Utc>,
) -> CoreResult<bool>;

pub fn finish_notification(
    store: &Store, claim: &NotificationClaim,
    outcome: DeliveryOutcome, now: DateTime<Utc>,
) -> CoreResult<DeliveryReceipt>;

pub fn inspect_notification(
    store: &Store, delivery_key: &str,
) -> CoreResult<DeliveryReceipt>;

pub fn reconcile_notification(
    store: &Store, delivery_key: &str,
    outcome: DeliveryOutcome, now: DateTime<Utc>,
) -> CoreResult<DeliveryReceipt>;
```

`NotificationOptions { limit, lease_seconds, include_platform }` defaults to 50 claims, a 60-second lease, and **no platform channel**. Limits are 1–500 claims and 5–300 lease seconds. The host sets `include_platform:true` only when it actually supplies `notifications.show`. When the host is headless, only an event delivery is created; becoming GUI-capable later does not automatically display that already consumed activity. A platform delivery that was previously created but is waiting for an explicitly confirmed retry remains queued until the host enables the platform channel again.

The helper reconstructs identity from stored namespace ownership and reloads the current stored grant in the same SQLite transaction. Shared-profile work uses `Principal::owner()` and its intrinsic authority; no scheduling agent token is retained. Private plugin work requires current grants: `reminders.write` to fire reminders, `activity.read` plus `activity.write` to claim notifications, underlying TODO/calendar reads and source/account grants, and additionally `notifications.show` for a platform channel. A missing/expired/revoked private grant does not become background authority merely because a prior manual call once had permission.

Due reminders are atomically converted into their existing deduplicated inbox entries. Both new reminder entries and pending source activities can then receive delivery records. First-sync `suppressed`, manually consumed, read, or archived activities are excluded. Reading/archiving cancels outstanding delivery rows; undoing local read/archive state does not rearm them. A persistent owner cursor scans at most 100 owners per call, at most 50 reminder candidates/claims per owner, with 500 total returned claims. This provides bounded work and round-robin progress past revoked owners. An owner savepoint isolates malformed-source/quota failures; `NotificationBatch.issues` reports only that stored principal and sanitized error code, while other owners can commit their work.

`NotificationBatch` returns `claims`, `issues`, and `scanned_owners`. Each `NotificationClaim` contains the stored `principal`, `activity_id`, `channel` (`event` or `platform`), stable `delivery_key`, opaque per-attempt `lease_id`, `lease_expires_at`, monotonic `attempt`, and allowlisted `activity` inbox summary. Profile claim identity is the user owner even if an agent originally created the reminder. Private plugin identity remains private. `lease_id` is deliberately omitted by serde serialization; never copy it into a global event, platform request, audit log, or export.

Host integration sequence (currently invoked by `Engine.tick`):

1. In tick, collect claims with `Utc::now()` and platform availability. Call `notification_claim_is_current` immediately before each sink operation to recheck live grants, source/account visibility, read/archive state, and the lease. A claim alone is not permanent authority. A false result must not be delivered.
2. For `DeliveryChannel::Event`, the current publisher calls `store.event("activity_notification", data)` with the claim's trusted `principal.id`, stable `delivery_key`, and approved activity summary, and receipts `Delivered { event_sequence: Some(sequence) }`. Main owns event audience filtering: a profile event belongs to authorized profile UI/MCP readers, not only a raw match against the scheduling agent's ID. The current `events.poll` filter still uses intrinsic-owner/raw-principal matching; profile/private scope and underlying source read checks must be respected when extending that filter. Do not expose private plugin summaries to profile readers through the event stream.
3. For `DeliveryChannel::Platform`, call the already available platform notification port with the same stable `delivery_key` as its deduplication key and trusted principal. Receipt `Delivered { event_sequence: None }` only after an affirmative delivery result. This module never launches a GUI or invokes a port.
4. For a **confirmed nondelivery**, receipt `Retry { after_seconds }` (1–3600). The next claim keeps its stable delivery key and receives a fresh lease token. Repeating an acknowledgment never shifts its already recorded retry time or rearms delivered work. Stale attempt tokens fail with `LeaseLost`.
5. For a timeout/uncertain outcome, receipt `Uncertain`. Lease expiry after a process crash also becomes uncertain; neither case automatically resends. Use `inspect_notification` to inspect state and `reconcile_notification` only after the host determines whether the sink already accepted it. Reconcile as Delivered with the existing receipt/sequence, or as Retry only after confirming nondelivery. Reconciliation rejects active unexpired work. Current private grants are rechecked on every subsequent claim.

Event and platform channels have separate stable keys and receipts, so a platform retry does not republish an already delivered event. Receipts expose principal/activity/channel/key, state, attempts, lease expiry, next attempt, delivered time, and optional event sequence. An already completed sink call can be receipted even if an agent grant was revoked during the operation: a receipt records the fact of delivery, not future authorization. No SQLite transaction spans the host operation. There is an unavoidable crash boundary between sink acceptance and receipt commit; stable sink keys plus explicit uncertain-state reconciliation address this without claiming exactly-once external delivery.

The old `reminders.due` remains an authorized, namespace-scoped **inbox creation** operation; it does not itself mark a display delivered. The old `activity.notifications` remains an at-most-once manual handoff without receipts. Do not call that manual handoff ahead of the scheduler for work the scheduler should deliver: manually claimed legacy entries remain consumed and are not automatically rearmed.

## Storage, bounds, and validation

All tables/indexes use the `organizer_` prefix. `organizer_schema` holds a singleton version, currently **2**, and migration plus version update is transactional and idempotent. Version 2 adds delivery receipts/cursor and promotes old v1 Client/MCP namespaces into the shared profile. Existing personal IDs are retained. Duplicate canonical link wrappers, reminder instants, and activity identities from old adapters merge into one existing ID; completion/read/archive and consumed/suppressed notification state are conservatively preserved, with dependent references remapped. Private plugin namespaces remain private. Migration validates foreign keys at commit and does not silently overwrite unrelated rows. The module never reads or changes root `PRAGMA user_version`. Newer/unknown organizer schema versions fail explicitly with `UnsupportedDatabaseVersion`. The existing Store owner lock and mutex remain in charge; no second Store or database path is opened by the service.

Titles are at most 512 UTF-8 bytes, notes 16,384, locations 1,024, identifiers generally 128/256/512 depending on their role, and activity kinds 64. Text rejects unsupported control characters. Parameters are capped at 256 KiB; activity batches at 500; pagination at 500; organizer items at 2,000 per resolved namespace; reminder histories at 10,000 per namespace; unarchived inbox entries at 10,000 per namespace. Archiving frees inbox capacity while retaining replay deduplication. Removing an item releases its reminder histories. Quota failures are explicit and roll back the operation. Errors do not echo submitted values, SQL, filesystem paths, or raw source payloads. The host must supply summaries and canonical fixtures without secrets; no heuristic can safely distinguish a secret from arbitrary personal prose.

The focused integration suite is `cargo test -p dansheng-core --test organizer`. It covers UI/MCP profile sharing, scoped/negative grants, private/opted-in plugins, separate data directories, canonical reference ACLs and unioned read labels, labeled-source revocation across conflicts/ICS/reminders/inbox/leases, mail read fallback, repeated/concurrent reminders, scheduler grants and revocation, separate delivery channels/receipts, crash/restart/lease uncertainty, retry/stale tokens, local read cancellation, first-sync suppression, source failure isolation, half-open conflicts, UTC/DST, Chinese/emoji ICS, and v1-to-v2 profile/dedup migration. These are synthetic offline SQLite tests, not emulator, cross-compilation, or real-service evidence.

Worker validation: the focused command executed on Windows with **27 passed, 0 failed**. `rustfmt --check --edition 2024` passed for the organizer source and integration test. No emulator, cross-compilation, or authenticated real-service validation was performed by this worker.
