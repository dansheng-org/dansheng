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
