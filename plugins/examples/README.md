# Official JavaScript examples (manifest v1)

All three packages export named async `(ctx, input)` actions, use only contract ctx
methods, and contain plain ES module source. There is no direct `fetch`, Node,
DOM, embedded browser runtime, or token stored in the package. The platform host
enforces capability grants, account access, origin checks and plugin namespaces.
`mutating: false` means **no external mutation**; actions can persist local data,
publish UI descriptions, or schedule local jobs. Files are GPL-3.0-or-later; see
[source attribution](../../crates/dansheng-connectors/NOTICE.md).

`http-monitor/check` reads `https://example.com/` via `ctx.http.request`, loads
`{key:"last-check"}` from private storage, stores `{key,value}`, and publishes
`{id,component}`. It saves only status and time, never response bodies/headers.
`schedule` accepts a future ISO `run_at` and requests a persistent host job with
`plugin_id`, `action:"check"` and `input:{}`. Wake-up and execution belong to the
host, not JS timers. Host job execution must bind the original plugin's identity.

`canvas-courses/syncCourses` accepts `{account_id}`. It first calls `auth.status`;
an unauthenticated result delegates to `auth.requireLogin` and returns
`status:"auth_required"`. Re-run after the host has authenticated the account.
All reads use `ctx.http.request` with `account_id` and a host-managed HTTP Cookie
session; credentials stay in the host. It follows `Link` pagination, validates every course, then
persists `{source_id,external_id,kind,data}` through `sources.upsert` and publishes
the UI. `cachedCourses` uses `sources.query`. Neither action removes old sources.
Fetch/parser failures on later pages leave the existing cache untouched; local
upserts are individual host calls, so an interrupted local save is not atomic.

The Canvas example binds `https://elearning.fudan.edu.cn` in both the manifest and
module. To target another Canvas instance, change **both** and regrant its origin.
Only absolute same-origin or root-relative `/api/v1/` pagination links are accepted
(Canvas documents absolute links). Unsafe large numeric IDs fail instead of
silently rounding; the host should preserve them as strings in JSON if needed.

`fudan-timetable/syncUndergraduate` and `syncPostgraduate` take explicit
`{account_id,semester_id,starts_on}`; `starts_on` is the Monday of teaching week 1,
as `YYYY-MM-DD`. The undergraduate action queries the actual semester print-data
endpoint and parses all activities with Sunday-to-Monday week conversion. The PG
action queries current `loadKbxx.do`, with optional `endpoint:"secondary"`; its
semester metadata labels the response and does not filter historical semesters.
The PG origins use the HTTP URLs in pinned DanXi; no HTTPS support is assumed.
Both actions call `auth.requireLogin` for missing/expired sessions, and only use
`http.request` with `account_id`, matching public DanXi's Dio HTTP Cookie-session
transport. A browser execution capability is not required for these timetable
endpoints. They validate all rows before saving
namespaced `fudan.timetable` sources and publish a list. A 100-activity limit keeps
host calls within default plugin quotas. They do not perform login, token exchange,
course registration, reservations, or any external mutation.

Example HTTP response wire shape: `{status, url, headers, body}` where
`body` is JSON text and headers are an object or an array of `[name,value]` pairs.
`final_url` is also accepted for an adapter returning that spelling.
`auth.status` must return `{authenticated:boolean}` for the HTTP-usable session.
Missing/expired sessions produce an explicit challenge, never an empty success.
A trusted platform may complete browser-based login and import a valid HTTP-usable
session. These examples do not perform token extraction or login themselves.
No failed HTTP call falls back to a browser, token, or anonymous request. A separate
service such as local sports must explicitly use browser execution when required;
there is no such browser requirement for these public timetable endpoints.

Required capability names use the host policy mapping: `storage.read/write`,
`sources.read/write`, and literal `http.request`, `auth.status`, `auth.requireLogin`,
`ui.publish`, `jobs.schedule`. Capability names are distinct
from ctx method names such as `storage.get` and `sources.upsert`.

Offline contract tests: `node --test plugins/examples/tests/examples.test.mjs`.
Actual QuickJS checks against a read-only snapshot of the core plugin module:
`plugins/examples/tests/run-quickjs.ps1 -Cargo <cargo.exe>`. This creates an OS temp
workspace and does not edit core or the root Cargo.lock; the host is an offline
recording implementation, not a real platform/browser session.
Node is only used to run development tests; released plugin/core artifacts do not
include it. Native QuickJS/installed-host, real-service and platform validation
must be reported separately.
