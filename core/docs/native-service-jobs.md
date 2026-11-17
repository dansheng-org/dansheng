# Persistent native service reads (M4)

Immediate `plugins.run` calls also use persistent jobs. Creation and lease
reservation now commit in one SQLite transaction, before waiting for a workflow
or worker slot, so the background scheduler cannot steal a new synchronous call.
The original caller's permissions are checked again before execution. Cancelling
or dropping a reserved invocation retains a recoverable uncertainty state; it is
not silently replayed. An already-active duplicate keeps its original job id and
does not execute twice; a future scheduled duplicate is not pulled forward.
Conflicting definitions sharing a custom dedup key are refused. Tests in
`crates/dansheng-core/tests/suites/immediate_plugin_jobs.rs` cover these boundaries.

Native jobs use the same SQLite jobs table, active dedup index, lease CAS,
deadline windows, periodic completion, wake-up port and public jobs methods as
plugin jobs. The executor is private to Engine (`src/native_jobs.rs`); no Core
service, connector or school-specific RPC is linked into this module. Existing
plugin jobs default to `kind:"plugin"` (or omit kind) and keep their existing
write uncertainty/reconciliation behavior.

## Interface

```json
{
  "kind": "service",
  "method": "canvas.courses.sync",
  "input": { "account_id": "campus" },
  "interval_seconds": 900,
  "deadline_window_seconds": 60
}
```

Pass this object to `jobs.schedule`. Other examples are
`fudan.timetable.sync`, `fudan.postgraduate.sync`, `mail.sync`, and `mail.read`.
Those methods must actually be registered by trusted embedding code. `method`
is the exact `CoreService` method, and `input` is passed unchanged as its params.
`input.account_id` is mandatory, nonempty, bounded and immutable. Input JSON is
limited to 1 MiB; results are limited to 4 MiB. Results stay in the private profile
database, subject to the same filesystem permissions as other Core data.

Optional fields: `run_at`, `deadline_at`, `deadline_window_seconds`,
`interval_seconds`, `dedup_key`, `prepare_at`, `wake_precision`. Times are RFC3339.
Default run time is now, default deadline window is 60 seconds. Windows must be
1 second..24 hours; recurring intervals must be 15 seconds..365 days. A supplied
deadline is canonicalized to a whole-second window relative to run time.
`prepare_at` must not follow run time; `wake_precision` is `exact` or `inexact`.
Unknown top-level fields, including caller-provided owner/principal/readOnly,
required_capability and internal binding fields, are rejected.

The response is `{job_id,kind:"service",run_at,state,wake_up}`. Use the existing
`jobs.status` with `job_id` for the private job data/result; omit id to list visible
jobs. `jobs.run` executes a due scheduled job, `jobs.cancel` stops a read, and
`jobs.resume` explicitly resumes a job waiting for authentication or approval.
`jobs.reconcile` is for plugin write uncertainty and is rejected for native reads.

## Trusted method and authority boundary

Only entries in Engine's **registered service directory** can run. The live
directory capability must end in `.read` or `.sync`. Known mutating method
segments (`configure`, `send`, `set_flags`, `save`, `write`, `set`, `create`,
`delete`, `remove`, `update`, `submit`, `cancel`, `reconcile`) are also refused,
even if an erroneous registration labels one as a read. Built-in Engine RPCs,
unregistered methods, `mail.send` preview/send phases, account configuration,
HTTP RPCs and plugin entry points cannot be scheduled through this executor.
Trusting the native service directory also requires its implementer to keep
methods labeled as reads free of external mutations; an input flag cannot make
a method read-only.

Creation requires `jobs.schedule`, the registered method capability, the matching
source read capability and the account grant. For a `.sync` capability such as
`mail.sync`, the read companion is `mail.read`; services already declaring
`canvas.read` or `fudan.academic.read` use that capability directly. The complete
original Principal (id **and** kind), method, account, input digest and directory
capability are bound in an internal versioned receipt. Execution calls
`Engine.handle` as that original Principal, never as owner or an invented service
principal. An owner running another client's job cannot elevate its execution.

Current grants are reloaded before execution, every 100 ms during an asynchronous
read, after receiving its response, and again before returning a completed result.
Engine also reloads the caller's current grant after every CoreService call and
its session-persistence await, checking the captured directory capability and
account before returning. This protects direct service callers, including a final
HTTP page or native IMAP response, independently of the native-job poll loop.
Cancellation/deadline selects drop the service future. The job's source/read
scope is conservative: it retains non-generic `.read` capabilities and source
ids from the creation and execution grants, because the generic CoreService
interface does not report which extra source permissions it used. Removing even
an unrelated captured sensitive read/source grant can therefore hide or pause
that job; schedule a fresh narrow job when intentional scope changes are needed.
Current source ACL labels for captured source ids are also checked, including
labels added after a cached result was produced.

Status, lists and stored results recheck current read/account/source permissions.
A revoked caller gets no private data via single status, and its hidden jobs are
omitted from lists. Other callers cannot inspect a job; the trusted profile owner
retains normal administrative visibility for valid jobs. Read revocation does
not prevent the original caller with `jobs.cancel` from stopping its own work:
cancel returns only id/state, never the old inputs or result.

## Persistence, recovery, periodic reads and cancellation

Ordinary scheduled jobs persist without process memory. A crash still causes the
unchanged Store to mark running leases `needs_reconciliation`. After services
have been registered, `tick`/`jobs.run` revalidate native receipts against the
**current** registered method/capability and original caller's current grant.
Valid interrupted reads can return to `scheduled`; revoked reads wait for
approval. Missing/changed services and malformed receipts stay quarantined and
do not execute. Backup-imported rows use the same validation; the serialized
`required_capability` field is never an authority source. Imported client grants
reset by backup restore cannot silently regain authority through a job.
Recovery scans use a private persistent cursor and a 64-row budget per pass;
unavailable/quarantined services cannot permanently starve other native jobs.

Dropping a running native RPC requeues only its validated read lease; dropping a
plugin RPC keeps the existing conservative write guard. Claim/finish updates use
the existing lease CAS, so competing runners execute only one read and an old
runner cannot overwrite a cancellation or another lease. Native cancellation
clears the lease, marks cancelled, signals the running read and cancels wake-up.
There is no claim that an already-completed local cache write can be rolled back.
Legacy plugin rows carrying arbitrary `kind/readOnly` fields are **not** converted
to native reads: plugin identity/action fields exclude them from native recovery
and cancellation. Their uncertain write state cannot be dismissed this way.

Success stores the bounded result. A recurring success reschedules from
completion time and uses Store's existing sliding `_deadline_window_seconds`
handling; cancellation stops future periods. Expired reads do not call services.
Authentication failures become `waiting_for_auth`; permission failures become
`waiting_for_approval`. Both require explicit resume after the host resolves the
condition. A source 401 never triggers password submission, origin-wide logout,
route switching or automatic source retries in this module. Other failures stop
the period and are recorded as failed. Audit/events contain ids, method, state
and codes, never input/result bodies or credentials.

Dedup keys are separated from plugins and include method, account and interval.
Default identity also includes input, while run/deadline time is excluded just
as for plugin retries. A caller's explicit dedup key is still scoped by method,
account and interval; reusing it with changed input returns `JobDedupConflict`.

## Host integration and validation

Trusted hosts must register their existing Canvas/campus/mail CoreService objects
on each Engine start **before** driving jobs. Their usual tick loop is sufficient;
no new daemon, browser, connector, vault, Store schema or public ABI helper is
required. UI/MCP clients still need explicit jobs and source/account grants. This
subtask does not change production UI, SDK method facades or lab endpoints.
The existing host/FFI already register CampusService/MailService and drive tick.
The current SDK's `JobScheduleParams` still requires `plugin_id/action`; parent
integration should add a host-side service-job union/schema. Plugin
`ctx.jobs.schedule` deliberately remains restricted to that plugin's own actions
and must not gain native-service scheduling through a blanket SDK widening.

Local synthetic tests are in `crates/dansheng-core/tests/suites/native_jobs.rs`,
registered in `tests/integration.rs`. They use
temporary profiles and in-process services only, with no network or real vault.
They cover restart/crashed leases, the trusted read directory, arbitrary-RPC/write
rejection, original caller and grant revocation, source/account/result isolation,
current source ACL labels, imported/tampered definitions, registration timing,
cancel/drop/lease races, explicit auth resume, recurring windows, bounds and old
plugin compatibility. Existing closed-loop plugin tests use only local fixtures.

```powershell
. ./scripts/dev.ps1
cargo test -p dansheng-core --test integration --locked native_jobs::
cargo test -p dansheng-core --test integration --locked closed_loop::
cargo clippy -p dansheng-core --lib --test integration --no-deps --locked -- -D warnings
```

Generated check logs: `target/native-jobs-check.log`,
`target/native-jobs-tests.log`, `target/native-jobs-plugin-regressions.log`,
`target/native-jobs-clippy.log`. This subtask does not claim real-service,
platform cross-compilation, production wake-up or full-workspace acceptance;
those are parent integration checks.

## Desktop Host scheduler and real IPC evidence (M1/M4)

`dansheng_host::serve` uses `serve_with_options(paths, ServeOptions::default(),
shutdown)`. Defaults remain a one-second tick and two-second foreground drain.
Only one background tick runs at a time, and missed timer ticks are skipped.
`ServeOptions` is a trusted Rust embedding API, not an IPC configuration: it can
register additional `Arc<dyn CoreService>` values before accepts/ticks and set
the timer/drain durations. It cannot override an existing registered service.
The interval must be nonzero and at most 60 seconds; foreground grace can be
0..60 seconds. Invalid options fail before creating profile/host files.

Host shutdown now stops accepts and immediately aborts and joins the background
tick. This prevents pending background work starting while foreground calls are
draining. Core's native read guard requeues an interrupted read, while the
existing plugin guard retains its write uncertainty behavior. Idle or still
authenticating IPC connections observe a shutdown signal and exit promptly.
Already-dispatched foreground requests can return their response within the
bounded grace; remaining connection tasks are then aborted and joined. The
profile owner lock is released only after these task handles have been drained.
The service does not remain alive just because an authenticated client kept an
idle socket/pipe open.

`crates/dansheng-host/tests/native_scheduler.rs` starts this same listener/event
loop with isolated temporary profiles and synthetic native Canvas/campus/mail
read services. It connects with real authenticated `Client` IPC (Windows named
pipes on the validated host; Unix sockets on Unix builds). Scheduling, permission
changes, cancel/resume, result/status reads and restart authentication all go
through IPC. There are no `jobs.run` requests or direct `Engine.tick` calls in
these scheduler tests; a successful run also checks the source-call audit and
absence of `jobs.run` audit entries.

The periodic test retains the real minimum `interval_seconds:15` and verifies
the resulting future run time and sliding deadline. Its test-clock injection
uses a separate SQLite connection **only to the isolated fixture profile** to
move `run_at` and `deadline_at` together into the past. It never alters state,
lease, identity, input, period or result, and never invokes the executor. The
next actual Host timer tick discovers, claims and executes that durable job.
This avoids a fixed 15-second wait while preserving the production execution
path. This is local fixture SQL while the Host is running, not a stopped-profile
restore and not evidence of 15 seconds of elapsed wall time. The clock adjustment
uses an immediate transaction so scheduler metadata writes cannot race a deferred
read-to-write transaction upgrade. Other tests use an actual short future run time and record the
source invocation timestamp to prove it never executes early.

Coverage includes repeated background periods and cancellation, pending-job
restart, shutdown abort/drop and safe read restart, live IPC grant/account
revocation, hidden cached results/lists, active read cancellation, prompt idle
connection shutdown, foreground response drain and invalid option bounds. The
shutdown tests deliberately configure a 30-second grace but require completion
within two seconds, so they prove background/idle work does not consume the
foreground grace. These are local transport/event-loop tests, not real mailbox,
campus endpoint, production wake-up or cross-platform runtime tests. DesktopPlatform
is initialized normally but the fixture profile has no session policy or vault
references; no real credential store is read or remote request made.

The test target uses `chrono.workspace = true` and `rusqlite.workspace = true`
in the Host's dev-dependencies. Both are integrated in the manifest and lockfile;
neither is a new production dependency.

```powershell
. ./scripts/dev.ps1
$env:CARGO_BUILD_JOBS = '2'
cargo test -p dansheng-host --test native_scheduler --locked
cargo test -p dansheng-host --test contract --locked
cargo clippy -p dansheng-host --lib --test native_scheduler --no-deps --locked -- -D warnings
```

Generated evidence logs: `target/host-native-scheduler-check.log`,
`target/host-native-scheduler-tests.log`, `target/host-native-scheduler-contract.log`,
`target/host-native-scheduler-clippy.log`.
