# Trusted native services and MCP surface

Host and FFI enable their default `services` feature and register
`CampusService` and `MailService` immediately after `Engine::open`, through its
trusted service registry. `--no-default-features` builds the smaller base adapter.
The connector feature is optional and requires the repository's Rust 1.98+ MSRV.
No service is selected or registered by caller request parameters.

MCP's `core_call` allowlist includes action previews, current todo/calendar/
activity/reminder methods, and managed `files.list/read/index/download`. It never
exposes arbitrary-path exports, permissions, client registration, vault calls,
session credential import, `mail.configure` or `canvas.configure`.
`fudan.qr.present` is also excluded: it is an owner-only credential presentation
operation, not a read/sync query. It hands a bounded, transient value directly to
a trusted `credentials.present` platform port and never returns/caches the code.
An absent presenter fails before network access; see `docs/qr-presentation.md`.
`jobs.reconcile` is also excluded because reconciliation requires trusted owner
evidence. `jobs.resume` remains exposed and is subject to core state/grant checks.

Read/sync operations for the official Fudan and Canvas clients are exposed after
service registration, with the same account/origin/session policy as native UI.
Mail exposes status, folders, bounded sync, list/read, local drafts, explicit send
and supported flag changes. `mail.send` has additional preview/action authority
checks within the service, beyond the MCP method allowlist. Account IDs and
identity always come from the authenticated core principal/grant policy; the
allowlist grants no privileges.

The Fudan research branch adds these registered read methods. They share native
UI/FFI/IPC/MCP account grants and the same source cache; see
`sdk/campus-services.d.ts` for request/result declarations.

| Methods | Capability | Source behavior |
| --- | --- | --- |
| `fudan.catalog.semesters/lessons/course/syllabus` | `fudan.catalog.read` | Anonymous dynamic semester discovery and bounded catalog pages; `course` reads a cached semester projection; syllabus uses lesson ID and keeps text coverage |
| `fudan.programs.list/detail` | `fudan.programs.read` | Public undergraduate/integrated program rules and bounded course-tree projection; detail IDs must have appeared in this account's public catalog cache; no personal credit/degree calculation |
| `fudan.ehall.catalog` | `fudan.ehall.catalog.read` | Anonymous bounded directory; inconsistent server total/limit remains a window |
| `fudan.ehall.tasks`, `fudan.ehall.tasks.sync` | `fudan.ehall.tasks.read` | Account HTTP session; todo/done/application are separate sources; scan stop/coverage remain explicit |
| `fudan.library.lookup/bibliography/holdings` | `fudan.library.catalog.read` | Anonymous exact barcode/call-number lookup and public metadata; lookup is not keyword search |
| `fudan.library.loans.current` | `fudan.library.loans.read` | Exact library origin with host-injected secret headers and an independently verified reader binding |
| `fudan.library.loans.history` | `fudan.library.history.read` | Separate optional history capability/source; private schema not yet accepted against a real reader |
| `canvas.quizzes.sync`, `canvas.quiz.read` | `canvas.read` | Classic Quizzes metadata; no attempt/question/answer endpoint |
| `canvas.discussions.sync`, `canvas.discussion.read/view` | `canvas.read` | Inert discussion text and authorized cached replies; no read-state mutation |
| `canvas.assignment_groups.sync`, `canvas.submission.self`, `canvas.enrollments.self`, `canvas.grades.self` | `canvas.read` | Group rules and self-only submission/enrollment/published grades; profile/filter identity checked |

`fudan.library.reader.observe/bind/clear` are owner-only configuration operations
and are excluded from MCP and service jobs. Observation returns only an unbound
fingerprint and never auto-binds it. The owner must independently verify the
intended reader before supplying that fingerprint. A changed token subject fails
before loan reads; caller parameters cannot replace the stored baseline.

Canvas `access:"browser_session"` requires a trusted platform status containing
the account, authenticated page origin and live opaque handle. The bridge verifies
that binding on each GET and calls the platform's current-page `browser.request`.
Missing/stale capability or binding never changes the mode to native HTTP. The
Android port preserves safe pagination headers and unchanged caller query fields,
so a removed self filter cannot be reconstructed after a redirect.

Nonstandard credentials enter only through owner `auth.session.set` with
`secret_headers`, using platform Vault persistence or explicit `persist:false`.
Ordinary HTTP credential mode does not send them. Official clients explicitly
select `HostHeaders`; injected headers are account/origin-bound, collision-checked
and filtered from responses. Explicit Proto/octet-stream requests use the Core's
bounded native byte API; that capability alone is not a cloud protocol connector.

Read-only resources include local organizer lists and managed files. Mail URI
templates are `dansheng://mail/{account_id}/folders`, `/messages` (cached INBOX
metadata) and `/drafts` (local summaries). There is no send or configuration
resource. Templates do not enumerate private account IDs.

Native entry points compile the `log` facade with `max_level_info`: upstream
async-imap's wire trace includes credentials and bodies and must not survive into
released artifacts. Lettre's optional `tracing` feature is not enabled. Do not
relax these settings to troubleshoot mail. Errors and audit events remain
sanitized; diagnose using error codes and synthetic loopback protocol fixtures.

See `crates/dansheng-connectors/src/mail/README.md` for the mail wire contract,
limits and the distinction between SMTP acceptance, delivery and uncertain
submissions. Tests send synthetic messages only to local TLS fixtures; user mail
accounts and delivery to external mailboxes have not been tested.
