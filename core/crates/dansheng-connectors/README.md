# Official connectors

The default parser/client library is read-only and independent of dansheng-core,
Flutter, MCP, reqwest, Node, Chromium and credential stores. Network/browser
implementations are supplied through `ConnectorTransport::execute(ConnectorRequest)`.
The parent-owned optional `services` feature bridges these clients to core's generic
service registry; that adapter and mail are outside the campus/community slice.

## Host integration

- Requests own `method`, `url`, ordered repeated `headers`, optional byte `body`,
  and `auth`. Responses own `status`, `final_url`, headers and body bytes.
- `HttpMethod::Get.as_str()` is `"GET"`, and `Post.as_str()` is `"POST"` for the
  source-defined read-only campus queries below. `Arc<dyn ConnectorTransport>` is
  accepted by the generic clients. The host must bind principal/grants independently of
  any supplied SourceContext or request account reference.
- `HostToken { account_id }`: the host retrieves a credential and injects it into
  mediated HTTP as an Authorization header. No token is passed to this crate.
- `HostSession { account_id }`: mediated **native HTTP** with the host's opaque
  Cookie/session jar. Fudan timetable/UIS follows public DanXi's Dio HTTP model;
  basic timetable reads do not require a browser execution capability. A trusted
  platform login can import an HTTP-usable session when valid.
- `BrowserSession { account_id }`: explicitly required page-context fetch/XHR.
  Only use this when the service requires its authenticated browser context (such
  as the separate local sports implementation). Missing browser capability is
  `CapabilityUnavailable`; do not substitute native HTTP for this mode.
- Authentication challenge modes are `Token`, `HttpSession`, `BrowserSession`.
  They serialize as `token`, `http_session`, `browser_session`. No token/session/
  browser transport silently falls back to another or to anonymous access.
- The host must check account/origin grants **before** I/O, prohibit credentialed
  cross-origin redirects, and bound I/O time and downloaded bytes. Parsing limits
  do not replace transport streaming limits. Host errors must use the typed enum,
  never attach raw upstream bodies, URLs or headers. Raw wire types have a redacted
  Debug implementation and intentionally cannot be serialized.
- A missing/expired session or token returns `AuthRequired(AuthChallenge)`.
  HTTP 403 is `PermissionDenied`; it does not falsely promise a login will fix it.
  HTTP 401, redirect/login forms and SSO destinations produce a challenge. No
  automatic login, token/session fallback or remote writes are implemented.
- A host supplies `SourceContext` with opaque account/source IDs and observation
  time. Records retain that identity, external IDs, observation/update timestamps,
  and typed payloads. Do not put credentials into context identifiers.

```rust,ignore
let canvas = CanvasClient::new(host_transport, "https://canvas.school.example",
    CanvasAccess::HostSession)?;
let records = canvas.courses(&source_context).await?;
// Or CanvasAccess::HostToken / ::BrowserSession, explicitly selected by the host.
```

## Implemented services

Fudan undergraduate: `undergraduate_semesters` parses the actual `JSON.parse`
semester script without executing it and reads `#allSemesters` for the default.
`undergraduate(source, None)` discovers that semester, then queries its actual
`/student/for-std/course-table/semester/{id}/print-data` endpoint. Supplying a
`Semester` skips discovery. Teachers, rooms, lesson codes, inclusive unit ranges
and activity-specific week lists are retained. These timetable reads use native HTTP
`HostSession`, not `BrowserSession`. Sunday week indices shift back
one, including week zero; source semester Sundays become Mondays.

Fudan postgraduate: `postgraduate` reads `loadKbxx.do` and parses `results`,
`KCMC/JASMC/JSXM/ZCBH/XQ/KSJCDM`. Bit zero is week 1. Null teacher/room data stays
absent. PG records are separate slots; an explicit `JSJCDM` is honored if present.
The source endpoint selects the **current** schedule; caller-provided semester
metadata does not request a historical semester. Select Primary or Secondary
explicitly; no silent session-origin switch occurs. The pinned source uses HTTP
for these two PG origins. A host can refuse that transport; HTTPS availability
and real-service compatibility are unverified.

Fudan activity IDs are deterministic content fingerprints scoped to the semester,
with original lesson identity preserved in the typed payload. Exact duplicates
are deduplicated; source ordering does not affect IDs. An activity content change
can create a different ID, so persist a successful timetable as a source snapshot.

Generic Canvas: configure any HTTPS origin (including nondefault ports), choosing
host token HTTP, host Cookie-session HTTP, or explicit browser execution.
`courses`, `assignments(course_id)` and `materials(course_id)` query `/api/v1`.
Materials currently means course **file metadata**, not pages/modules, file
downloads or submissions. Signed URLs are discarded. IDs are lossless decimal
strings; due dates normalize to UTC and optional values stay absent. HTTP reads
always follow opaque `Link rel=next`, even after an empty page; header names are
case insensitive, repeated fields and quoted commas are supported. Origin/API
path boundaries, cycles, conflicting next links and byte/page/item limits fail
closed. A later-page failure returns an error, never a partial successful list.

## Validation

Normal integrated build: `cargo test -p dansheng-connectors`.

M3 targeted checks: `cargo test -p dansheng-connectors --test integration --locked campus::` and
`cargo clippy -p dansheng-connectors --all-targets --locked -- -D warnings` after
`. ./scripts/dev.ps1`. M3 fixtures live in `fixtures/campus/`. The older isolated
validation script below copies `src/tests` only; use the workspace command for M3
until the parent adds this new fixture directory to its snapshot copy step.

During parallel work, `tools/test-isolated.ps1 -Cargo <cargo.exe>` copies only this
crate and root workspace dependency declarations into an OS temporary workspace.
It prints the location and runs the crate tests without changing root manifests,
Cargo.lock or another worker's sources. `-Clippy` runs clippy with warnings denied.
Provide the project-local toolchain environment in the shell when required.

Ordinary integration tests live by business module in `tests/suites/*.rs` and are
registered in `tests/integration.rs`. Add new ordinary suites there and register
their modules in that entry point, preserving any required feature gates. Select
one module with `--test integration <module>::`, or omit the filter to run the
whole group. For multiple modules, run separate commands or the whole group;
Cargo accepts only one runtime filter. Focused integration Clippy uses
`cargo clippy -p dansheng-connectors --test integration --locked -- -D warnings`
without a runtime filter.

`forum_live.rs` and `webvpn_live.rs` remain separate targets with ignored live
tests, requiring explicit authorization and their feature/environment setup.
The ordinary suites use synthetic fixtures and fake/local transports; they do
not establish real-service compatibility.
JavaScript example tests: `node --test plugins/examples/tests/examples.test.mjs`
from the repository root (Node is development tooling only). These tests verify
the host-call contract and offline behavior. `plugins/examples/tests/run-quickjs.ps1`
runs the examples through an isolated snapshot of the actual QuickJS plugin
module with an offline host; it does not validate a real browser/platform. No real-service,
Android emulator or cross-compilation success is implied by native offline tests.

## M3 campus API and coverage

`campus::FudanCampusClient<T>::new(transport)` is independent of core and uses the
same owned transport contract. All methods take `&SourceContext` as their first
argument. `CampusError::Transport(ConnectorError)` preserves authentication,
permission and capability failures. `SchemaChanged { domain, field }` reports
unknown/malformed layouts without echoing remote bodies. There is no login or
transport fallback. Native HTTP Cookie sessions remain the school transport.

| Client method (arguments after source) | Typed payload / protocol |
| --- | --- |
| `student_association(semester: &str)` | `SourceRecord<String>`; the JWGL internal student association from print-data, not an assumed student number |
| `exams(student_assoc: &str, include_finished: bool)` | `SourceBatch<Exam>`; JWGL exam HTML, source finished flag, date/time/room/category/type/note |
| `undergraduate_grades(student_assoc: &str, semester: &str)` | `SourceBatch<Grade>`; semester-specific JWGL JSON, nullable GP, no invented credits |
| `graduate_grades()` | `SourceBatch<Grade>`; `datas.jdjscjcx.rows`, source total retained; unverified remaining pages flagged |
| `data_center_grades(PageWindow {offset, size})` | `SourceBatch<Grade>`; read-only POST JSON to data tables, explicit totals and continuation |
| `gpa(student_assoc: &str)` | `SourceBatch<GpaEntry>`; source search-index form followed by GPA search, fractional credits and nullable GPA |
| `ecard_balance()` | `SourceRecord<EcardBalance>`; authenticated holder signal and exact CNY cents from epay HTML |
| `ecard_transactions(start: NaiveDate, end: NaiveDate, page: u32)` | `SourceBatch<EcardTransaction>`; GET CSRF then form POST, XML CDATA table, 10-row source pages |
| `electricity()` | `SourceRecord<Electricity>`; current room kWh and source update time |
| `empty_classrooms(building: &str, on: NaiveDate)` | `SourceBatch<EmptyClassroom>`; LAN status/detail pair, mixed script extraction without execution |
| `library_occupancy()` | `SourceBatch<LibraryOccupancy>`; public anonymous POST, campus name and inside count only |
| `dining_occupancy(area_code: u8)` | `SourceBatch<DiningOccupancy>`; source script name/current/capacity arrays; reporting-hours failure is explicit |
| `pe_records()` | `SourceBatch<PeRecord>`; exercise counts and assessments from source row-6/row-26 tables |
| `bus(holiday: bool)` | `SourceBatch<BusDeparture>`; read-only multipart POST, holiday flag, direction and nullable times |
| `aao_notices(AaoKind, page: u32)` | `SourceBatch<AaoNotice>`; separate UG/PG list selectors, title/date/same-origin article link |
| `qr_state()` | `SourceRecord<QrState>`; `Ready` / `TermsNotAccepted`, never QR content and never automatic agreement |

`SourceBatch<T>` retains `source: SourceContext` even for a verified empty response,
and contains source revision, account/source/external IDs and
observation timestamps through `SourceRecord<T>`, plus `Coverage`:

- `Complete`: a source-defined unpaged response, not a claim about other sources.
- `Page {next, total}`: a bounded page with verified offset/page-number convention.
- `Window {position}`: one bounded window with unverified archive continuation
  (AAO page / Tea timestamp window); `next=None` is not invented for it.
- `UnsupportedRemainder {reported_total, returned}`: the server says more rows
  exist, but the pinned source does not prove how to request them (PG grades/GPA).

PageWindow size is 1..100 and offset is at most 1,000,000. Ecard dates are ordered,
at most 366 days apart, and page numbers are 1..10,000. AAO pages are 1..1000.
Parsers and host responses are bounded to 8 MiB / 10,000 top-level items. Host
streaming, principal, account, origin and private-network checks still apply.
No client automatically crawls to an unknown end or retries an uncertain response.

Where the source supplies no stable ID (for example transaction rows), record
IDs are deterministic content fingerprints, not invented upstream transaction IDs.
Treat batches as scoped observations; do not use these fingerprints to reconcile
banking operations or infer that two identical source rows are distinct transactions.
School local timestamps use Asia/Shanghai UTC+8; money uses signed integer cents.

The source uses Neo2FA for `my.fudan.edu.cn` data-center/dining queries, Neo for
the other supported school Cookie sessions, and legacy UIS for PE. Session setup,
second factor and credential storage belong to trusted host/platform code. PE's
source login entry is
`https://uis.fudan.edu.cn/authserver/login?service=http%3A%2F%2Ftac.fudan.edu.cn%2Fthirds%2Ftjb.act%3Fredir%3DsportScore`;
graduate grades use
`https://yzsfwapp.fudan.edu.cn/gsapp/sys/wdcjapp/*default/index.do`; epay bootstraps
at `https://ecard.fudan.edu.cn/epay`. These are public source constants, not login
implementations. Plain HTTP transport does not establish authentication by itself.
`QrState::Ready` means the source page contains a nonempty `#myText` value;
credential validity/expiry is not inferred from that presence check.

Empty classrooms preserves `http://10.64.130.6` and requires an explicit host LAN
grant or separately configured VPN routing; no probe/proxy fallback is performed.
The pinned source removes the 14th source slot; the parser verifies exactly 14
before producing the same 13-unit view. PE/AAO/dining selectors are version-sensitive
and fail on missing required structure. No live-service compatibility is claimed.
Library loans/renewals, graduate exam arrangements, QR credential export, payments,
PE submissions and other remote mutations have no implementation here: the
selected sources do not establish a safe read protocol for those capabilities.

## M3 read-only Tea and Danke

`community::CommunityClient<T>::new(transport)` defaults to the public source
origins `https://forum.fduhole.com` and `https://danke.fduhole.com`. `with_origins`
allows explicitly configured HTTPS origins; the source `/api` prefix is retained.
All calls use `HostToken {account_id}`; no token enters a domain model. No login,
refresh, verification email, posting, voting, view-count increment or AI generation
endpoint is called. These reads are separable from the original mutable repositories.

| Method (after `&SourceContext`) | Result |
| --- | --- |
| `tea_divisions()` | `SourceBatch<TeaDivision>` |
| `tea_hole(hole_id: u64)` | `SourceRecord<TeaHole>`, including first/last-floor preview |
| `tea_holes(division: Option<u64>, before: DateTime<Utc>, size: u16, TeaOrder)` | Timestamp-bounded `SourceBatch<TeaHole>` window; no guessed cursor subtraction across tied timestamps |
| `tea_floors(hole_id: u64, PageWindow)` | Offset/size `SourceBatch<TeaFloor>`, including deletion state |
| `danke_search(keyword: &str, page: u32, page_size: u16)` | Bounded v3 `SourceBatch<DankeCourseGroup>` with response page validation |
| `danke_group(group_id: u64)` | v3 `SourceRecord<DankeCourseGroup>` with typed offerings/review summaries |
| `danke_reviews(course_id: u64)` | Source-defined unpaged `SourceBatch<DankeReview>` from `/courses/{id}/reviews` |

Danke rating values retain raw API directions; the upstream UI displays
`6-content` and `6-workload`. Source timestamp strings remain in payloads;
`SourceRecord.updated_at` is set only for timestamps with an explicit RFC3339
offset. An unzoned timestamp is not silently assigned a timezone. Unknown token
fields are discarded, source envelope changes fail, and page sizes are bounded.

## M3 source copyright and revision

Mappings/selectors/request forms are adapted from DanXi-Dev, copyright (C) 2021,
2022, 2023 and 2025, GPL version 3 or any later version. Rust adaptation copyright
(C) 2026 dansheng-core contributors. Provided without warranty under the included
LICENSE. This worker read only the pinned public checkout; fixtures are newly
authored synthetic data, not captured service responses.

Pinned revision: `3c1f5f026fbc7ca50e151865f813cdb381807abe`.

- [Academic fields/selectors and GPA](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/edu_service_repository.dart)
- [Graduate grades](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/graduate_exam_repository.dart)
- [Data center grades/dining](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/data_center_repository.dart)
- [Ecard](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/ecard_repository.dart)
- [Dorm electricity](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/dorm_repository.dart)
- [Empty classrooms](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/empty_classroom_repository.dart)
- [Library occupancy](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/library_repository.dart)
- [PE](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/pe_repository.dart)
- [Bus](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/bus_repository.dart)
- [AAO notices](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/aao_repository.dart)
- [QR state](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/qr_code_repository.dart)
- [Tea request routes](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/forum/forum_repository.dart) and [models](https://github.com/DanXi-Dev/DanXi/tree/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/model/forum)
- [Danke request routes](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/danke/curriculum_board_repository.dart) and [models](https://github.com/DanXi-Dev/DanXi/tree/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/model/danke)
