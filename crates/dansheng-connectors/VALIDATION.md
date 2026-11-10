# Connector/example validation

This file preserves the connector worker's scoped historical evidence. The parent
subsequently integrated the native services, compiled Windows and Android, and
ran the full workspace suite. A release-binary public AAO probe retrieved 14
records without credentials. Authenticated campus, Canvas and mail services remain
unverified against real accounts. See [current validation](../../docs/validation.md).

Validated on Windows x86_64 GNU, project-local stable Rust 1.99.1, 2026-11-05.
No commits, credential use, authenticated service requests, or remote mutations.
Only connectors and official examples were edited; the shared root/core sources
and reference checkouts were not changed by this worker.

| Check | Result |
| --- | --- |
| `. ./scripts/dev.ps1; cargo test -p dansheng-connectors --locked` | 49 offline integration tests passed: 27 campus/community and 22 existing timetable/Canvas tests |
| `cargo test -p dansheng-connectors --test campus --locked` | Freeze recheck: 27/27 passed against the current workspace lock; synthetic fixtures under fixtures/campus |
| `. ./scripts/dev.ps1; cargo clippy -p dansheng-connectors --all-targets --locked -- -D warnings` | Earlier run passed; transient lock mismatch during parent services wiring was superseded by the focused freeze check below |
| `cargo clippy -p dansheng-connectors --lib --test campus --no-default-features --locked -- -D warnings` | Freeze recheck: passed; optional parent adapters/mail excluded |
| Final source-only snapshot `cargo clippy --all-targets --offline -- -D warnings` | Passed for current campus/community + unchanged M1 source/tests; parent adapters/mail excluded |
| `node --test plugins/examples/tests/examples.test.mjs` | 15 contract/behavior tests passed |
| `. ./scripts/dev.ps1; plugins/examples/tests/run-quickjs.ps1 -Cargo <cargo.exe>` | 6 tests passed through the actual plugin runtime snapshot, with an offline host |
| Crate/example-only rustfmt | Passed; no workspace-wide formatter was run |
| Real-service authentication/data compatibility | Not run |
| Android/emulator/platform browser integration | Not run |
| Cross-compilation/MSRV validation | Not run |

The QuickJS checks validate manifest v1 parsing, named actions, status monitor
storage/UI, host scheduling, explicit auth-required errors, Canvas native HTTP
session pagination/sources, and Fudan UG/PG HTTP session/parser behavior. The
offline host does not supply browser execution to these examples. This is not proof of
a real authenticated platform session or the full installed-engine integration.

The Rust suite covers source/account/timestamp preservation; UG multi-unit and
Sunday week conversion; semester JavaScript string extraction without execution;
PG bitmap/string-number/null handling; stable activity identities; malformed and
explicit empty envelopes; Canvas lossless IDs/dates/file metadata; repeated and
case-insensitive Link headers, opaque cursor punctuation, cycles, origin/path
and credential checks, conflicting links, page/body/item quotas, later-page auth
failure, host mode separation, unsupported browser capability, and debug redaction.

## Integration questions/limits

- Parent supplies `ConnectorTransport`; see src/transport.rs for the exact owned
  request/response contract. `HostToken` is host HTTP with injected credentials;
  `HostSession` is native HTTP with host-owned Cookie/session data. `BrowserSession`
  explicitly requires page-context fetch/XHR. Challenges distinguish `Token`,
  `HttpSession` and `BrowserSession`. They are not fallback alternatives.
  Shared `Arc<dyn ConnectorTransport>` works with either client.
- The pinned PG source uses HTTP primary/secondary origins. Their HTTPS support
  and platform cleartext policy are unverified. Selection is explicit; there is
  no silent fallback. The endpoint returns current data, not an arbitrary semester.
- Canvas materials are course file metadata, with signed URLs discarded. Pages,
  modules, downloads, submissions and other sources are outside this implementation.
- JS source writes are individual local upserts; they are not a transactional
  replacement/deletion of stale rows. Fetch/parsing completes before saving.
- Hosts may return a structured challenge or `AuthenticationRequired`; the JS
  examples handle both. Fudan and Canvas examples use native HTTP session reads.
  Missing browser capability is an error only for explicitly requested browser mode.

## M3 campus/community extension

Owned changes: `src/campus.rs`, `src/community.rs`, `tests/campus.rs`, synthetic
`fixtures/campus/**`, README/this record, new module exports in lib.rs, and only
the Post enum variant/as_str mapping in transport.rs. Existing Fudan/Canvas code,
mail, root manifests/configuration and core were not edited. No new dependencies.
The parent owns mail's separate services feature/export and CoreService adapters.

The new suite exercises source-derived UG exam HTML, three grade envelopes, GPA
search form/query, exact ecard money and XML CDATA/CSRF pages, dorm kWh/time,
public library counts, dining escaped JS arrays/reporting hours, mixed classroom
script boundaries/14-to-13 slots, PE count/assessment selectors, multipart bus
queries, both AAO lists, QR state without credential export, and read-only Tea /
Danke routes and models. It checks source/account/time/revision tracking even for
empty observations, explicit incomplete coverage, bounded offsets/page sizes,
short pages with authoritative totals, HTTP/session/token separation, source
drift/auth/permission/timeout handling, no fallback/retry, no view-count patch,
unknown-token-field removal and Send futures for host registration.

M3 verification is native Windows offline only. The public checkout revision was
verified as `3c1f5f026fbc7ca50e151865f813cdb381807abe`; source copyrights and direct
file links are recorded in README and module headers. Fixture contents were
authored for tests. No campus/forum requests, live authentication, real credentials,
emulator, cross-compilation or new installed-host/FFI integration tests were run.
The earlier JS/QuickJS results above belong to the unchanged M1 examples.

Known source limits are explicit: PG grades/GPA can return UnsupportedRemainder,
AAO/Tea lists are bounded windows rather than full-archive claims, classroom LAN
routing and Neo/Neo2FA/legacy UIS session setup belong to the parent, and the QR
payload is intentionally not exported. No library loan/renewal, mail, payment,
registration, PE submission, forum/review mutation or invented endpoint is added.

The old `tools/test-isolated.ps1` predates root-level `fixtures/campus`; it needs a
parent-owned copy-step update and optional path-dependency handling to validate
M3 snapshots. Workspace test commands above include the fixtures and were used
for this extension. The parent concurrently added optional core/services wiring;
the worker did not update Cargo.lock. The earlier source-only lint excludes those new
host adapters/mail and includes the current campus/community code, unchanged M1
modules, both integration test files and all their synthetic fixtures.
The successful final lint manifest remains at
`C:/Users/ASCENDER/AppData/Local/Temp/dansheng-campus-lint-89294cfd770b4eb48ed20bf2e4bfb1a8/Cargo.toml`.

## Campus/community integration freeze

Status: frozen after focused verification. No source changes or new features were
needed in this freeze turn. The current workspace passed the 27-case campus suite,
the focused library/campus Clippy command above, and rustfmt --check on campus.rs,
community.rs and tests/campus.rs. The earlier 49-case combined result remains
separate evidence; the freeze did not rerun unrelated mail or adapter tests.

The public reference checkout still resolves to the pinned DanXi revision. No
live campus/forum/raw endpoint availability probes, credentials, remote mutations,
emulator or cross-compilation were used. Live endpoint compatibility remains
unverified; unsupported and version-sensitive capabilities are documented in
README. Parent-owned core_adapter.rs, source capability wiring, mail, Cargo
manifests and root configuration were not edited by this worker.

Frozen SHA-256 values for parent review:

| File | SHA-256 |
| --- | --- |
| src/campus.rs | 9ABC4BFC77D4621FB64399E45B7A6D51A18C40695B20F7941AB46159B7F33863 |
| src/community.rs | CDCDC66937C537E437E89A6B073C39B34C0C90536EFA7DC5F50DE91D36F020FE |
| tests/campus.rs | BB0F2625C24B514DC212EF603C2B58D5598FB0943CA9CE8D170DFCECB2913E97 |
