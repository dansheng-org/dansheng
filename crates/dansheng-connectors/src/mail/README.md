# Native mail service (M4)

Enable connector feature `services` and register `Arc::new(MailService::default())`
through trusted `Engine::register_service`. Host and FFI register this service;
there is no caller-controlled service registration. The service uses real
async-imap 0.12, Rustls/Tokio TLS, mail-parser 1 and lettre 0.11. This optional
feature requires Rust 1.98 or newer because of mail-parser 1.0.1. The core-only
API remains independent of mail protocols, MCP, browsers and school endpoints.

Every method requires `account_id` and checks both its capability and the account
grant, even when the service is called directly. Fixed namespace
`service:mail:{account_id}` and record owner `service:mail` let authorized UI/MCP
clients share one mailbox and draft implementation. Only public Store key/value,
record and query APIs are used; no extra raw database connection/schema is added.
The native host/FFI entry points compile `log` with `max_level_info` to remove
async-imap's sensitive wire DEBUG/TRACE statements. Other embedding applications
must use the same compile-time cap and must not enable lettre's optional protocol
tracing. Runtime "do not print" conventions alone are insufficient for these
upstream protocol loggers.

| Method | Capability | Behavior |
| --- | --- | --- |
| `mail.configure` | `mail.write`, owner only | Configure native servers and put credentials in the platform vault |
| `mail.status` | `mail.read` | Local configuration/vault availability; does not claim a successful server login |
| `mail.folders` | `mail.read` | Cached IMAP folders; `refresh:true` additionally requires `mail.sync` |
| `mail.sync` | `mail.sync` | Bounded UID-window fetch and rotating flag refresh |
| `mail.list` | `mail.read` | Current-epoch cached metadata, no body; `before_uid`, `limit` |
| `mail.read` | `mail.read` | Cached MIME text/HTML/attachment metadata, without marking Seen |
| `mail.attachment.read` | `mail.read` | UIDVALIDITY-bound, bounded base64 chunk from complete MIME fetched with BODY.PEEK |
| `mail.draft.save` | `mail.write` | Local draft and send preview/hash; never uploads/deletes server drafts |
| `mail.draft.list` | `mail.read` | Shared local draft summaries; optional `include_body:true`, `before_id` |
| `mail.send` | `mail.send` plus send authority | Explicit SMTP submission and persistent reconciliation ledger |
| `mail.set_flags` | `mail.write` | Explicit Seen/Flagged/Answered changes, or `reconcile:true` read-back |

## Configuration and credentials

Owner request params:

```json
{
  "account_id": "campus-mail",
  "config": {
    "address": "Student <student@example.edu>",
    "username": "student@example.edu",
    "imap": {"host":"imap.example.edu","port":993,"tls":"implicit"},
    "smtp": {"host":"smtp.example.edu","port":465,"tls":"implicit"}
  },
  "credentials": {"password":"<supply privately; do not log>"}
}
```

Use `imap_password` and `smtp_password` instead for separate app passwords.
`tls` permits only `implicit` or `starttls`: STARTTLS is mandatory when selected,
and LOGIN/AUTH is sent only after TLS certificate/hostname verification. No
plaintext, invalid-certificate override or native HTTP substitution exists.
Account configuration changes require explicitly supplied credentials. Server
configuration and usernames are metadata; passwords are never in KV/records,
status output or error messages. Credentials use internal `vault.set/get` with
the same contract as the desktop system vault and Android Keystore bridge.
An absent/locked vault is an error; there is no plaintext or invented-login
fallback. Native password authentication is supported; OAuth token refresh is
not part of this bounded milestone.

## Synchronization and MIME

`mail.sync` params are `{account_id, folder?:"INBOX", window?:16}`. Window counts
UID positions, not messages, and must be 1..128. No `UID SEARCH ALL` or `*` upper
bound is used. Server UIDNEXT and UIDVALIDITY are mandatory. A cursor is committed
only after all fetched data/index writes succeed, so interrupted reads can be
repeated by a later explicit sync without skipping messages. UIDVALIDITY changes
start a new epoch. Old cache records remain archived, while `mail.list/read`
select the current epoch and reject stale epoch identifiers. Changed server
configuration has a separate generation and cannot reuse another server's UIDs.
Source records (`mail.<folder/config hash>`) and their UID checkpoint commit
atomically through `Store::commit_source`. KV bodies/indexes are staged first;
listing and reading hide UIDs above the committed cursor.

Fetches use `EXAMINE` and `BODY.PEEK[]<0.1048576>`, with a 32 MiB connection read
budget and a 30-second command/connection deadline. Message text and HTML are
cached up to 128 KiB each; attachments retain name/type/decoded-size/content-id
metadata without attachment bytes. Larger raw messages are explicitly marked
`mime_complete:false`; prefix-only attachment metadata may be incomplete. Large
or truncated bodies are not represented as fully downloaded. `body_truncated`
also reports decoded text/HTML truncation. Each attachment's `size_complete` and
`content_complete` are false for prefix-only or structurally/transfer-damaged
content. A complete raw byte count alone cannot make a broken attachment complete.

Email HTML is untrusted data. The UI must sanitize it and disable remote images
and active content. No HTML is executed by this service. Exact IMAP folder wire
names are retained, including modified UTF-7 names, so they can be used unchanged
in subsequent requests; display-name decoding is left to the UI.

Each sync also rotates through a bounded old-UID flag window. Missing UIDs become
local tombstones; no EXPUNGE, Deleted flag, remote draft deletion or automatic
server-side mail removal is performed. Local reads never mark messages Seen.
`mail.read` with `refresh_flags:true` additionally requires `mail.sync`.
`mail.set_flags` requires `{account_id,folder,uid_validity,uid,flags:{seen?:true,
flagged?:false,answered?:true}}`. Timeout/disconnection after a flag write keeps a
pending reconciliation marker. Refresh flags through sync or use
`mail.set_flags` with `reconcile:true` before another flag mutation.

The local UID index is paged (512 UID positions per page, at most 4096 pages per
epoch). Listing scans at most 64 cached pages per call, limits response bytes,
and returns `next_before_uid`. Draft storage is bounded at 1000 local drafts per
account; list responses exclude bodies by default.

## Reading attachments

First sync and list/read the mailbox. Use its exact epoch and attachment id:

```json
{
  "account_id": "campus-mail",
  "folder": "INBOX",
  "uid_validity": 909,
  "uid": 1,
  "part": "attachment:0",
  "offset": 0,
  "length": 262144
}
```

`mail.attachment.read` requires `mail.read` and the account grant, including when
called directly as a service. It uses EXAMINE, verifies live UIDVALIDITY, requests
RFC822.SIZE first, then fetches `BODY.PEEK[]<0.8388608>` for that exact UID. It
never issues SELECT/STORE or substitutes sequence numbers. A changed epoch,
missing message, raw size over 8 MiB, incomplete literal, damaged MIME structure,
unsupported/malformed transfer encoding or decoded attachment over 4 MiB returns
an error with **no attachment data**. There is no truncated-as-complete fallback.
The original sync prefix remains limited to 1 MiB.

The response includes `attachment` metadata, `total_size`, `sha256`,
`content_complete:true`, `encoding:"base64"`, `data`, `offset`, `length`,
`next_offset`, `eof`, and `marked_seen:false`. It returns at most 256 KiB of decoded
bytes per call (the base64 JSON field is at most 349528 bytes). Pass the returned
SHA-256 as `sha256` on every continuation with `offset > 0`; a mismatch returns
`MailAttachmentChanged`. `content_complete` describes the validated whole
attachment; only `eof` says this chunk reaches its end. Decode and concatenate
chunks, then verify the complete SHA-256. Empty attachments return an empty final
chunk. `length` must be 1..262144. Offset past EOF and noncanonical part ids fail.

Each call re-fetches the bounded whole MIME message, so it rechecks the server
epoch even after a previous successful read. Complete metadata replaces the local
prefix metadata after successful validation; raw MIME and attachment bytes are
not persisted in mail KV or searchable source records. This is an online download
API, not an offline attachment cache. No arbitrary filesystem paths are accepted.

## Explicit send and uncertain outcomes

`mail.draft.save` accepts `{account_id,draft_id?,draft:{to,cc?,bcc?,subject?,text?,
html?,attachments?}}` and returns the saved draft, full preview, and `preview_hash`. The hash
covers account/server generation, sender, all recipients, content and stable
Message-ID. `mail.send` with `{account_id,draft_id,phase:"preview"}` can refresh
that preview. Recipients are validated and encoded by lettre, with no raw-header
input or CR/LF address/subject injection.

An outgoing attachment references an existing Core-managed asset:

```json
{
  "asset_id": "11111111-1111-4111-8111-111111111111",
  "account_id": "campus-mail",
  "name": "report.pdf",
  "mime_type": "application/pdf"
}
```

`name` and `mime_type` are explicit outgoing MIME labels supplied in the draft,
not a claim about an upstream file's original labels. They are required and are
bound into the preview. Names cannot be paths, CR/LF, control characters or `.` /
`..`; headers use lettre's MIME encoding, including Unicode filenames. Asset ids
must be canonical UUIDv4. Paths, caller-supplied bytes/hashes/sizes and unknown
attachment fields are rejected. Omit `account_id` to let the Core's normal asset
visibility scope choose accessible assets; specifying one adds a filter and
checks that account grant. A cross-account send needs both the mail account and
the asset account grant.

Draft save/preview and each **new** submission read asset bytes through
`assets::dispatch("files.read")` with the **original principal and unmodified
grant**. `files.read`, account visibility and source capabilities all apply;
the mail service never impersonates its trusted service owner or grants
`files.list`/`files.export`. Files are read in 256 KiB chunks with exact offset,
length and EOF validation. Each attachment is at most 4 MiB; total attachment
bytes are at most 8 MiB; at most eight attachments are allowed. Encoded SMTP input
is bounded to 12 MiB, including MIME/base64 overhead and text/HTML bodies.

The preview's `attachments` array contains each asset id/account filter, outgoing
name/MIME, actual byte size and SHA-256. At send, files are re-read and compared to
that snapshot **before** credentials/SMTP dispatch or a submitting ledger is
written. Changed content (even the same size) returns `MailAttachmentChanged`;
revoked permissions, incomplete/deleted assets and altered sizes also prevent
submission. Generate a fresh `mail.send` phase `preview` and explicitly approve
its new hash after changes. A draft list/status is a stored snapshot, not a fresh
file validation. Read bytes are retained in memory for the actual MIME builder,
so later file changes cannot replace the payload that was checked and approved.

Attachments form a `multipart/mixed` message around the plain text or the nested
`multipart/alternative` text/HTML body. Payloads use MIME base64 with attachment
disposition; binary octets are preserved without charset conversion.

A new SMTP submission must provide `{account_id,draft_id,preview_hash,confirm:true}`.
Non-owner clients additionally need either:

- `grant.action_inputs["mail:<account_id>:send"] = "<exact preview hash>"`; or
- the deliberately broad additional capability `mail.send:any`.

Both cases also require ordinary `mail.send` and the account grant. A caller's
`confirm` or `principal` parameter cannot grant authority. Owners use their
explicit confirmed request. Editing the draft/server invalidates an old preview.
The generic `action_inputs["mail:send"]` binding is also supported. Any binding
present must match exactly for a new submission, including when `mail.send:any` is granted; a broad
capability never overrides a narrower explicit input binding.

Before SMTP dispatch the service persists a `submitting` ledger with attempt id,
preview hash and stable Message-ID. A final positive DATA reply is recorded as
`sent` (SMTP accepted, not guaranteed delivery). Confirmed receipts are sealed
by both draft id and Message-ID, independently of the preview hash, sender or
server configuration. Repeating a confirmed draft returns its original receipt
and `already_submitted:true`, after the account and `mail.send` capability gate,
without contacting SMTP. Old confirmed active ledgers acquire the same identity
markers when read. A confirmed draft is immutable: editing it returns
`DraftAlreadySent`. Another send requires an explicitly new draft id and newly
generated Message-ID; changing configuration or a preview cannot replay the old
message. A separately stored draft reusing a confirmed Message-ID is also blocked.

Explicit 4xx/5xx rejection or a failure before MAIL submission is
`not_sent`; there is no automatic retry or SMTP connection pool. Missing final
response, timeout, cancellation or a process crash after dispatch leaves
`needs_reconciliation`/`submitting`. Draft editing and further submissions are
blocked until reconciliation; a new process reads the same ledger.

Inspect with `mail.send` phase `status`. After verifying the provider's Sent
folder/logs by Message-ID, the owner may call phase `reconcile` with matching
`attempt_id`, `outcome:"sent"` or `"not_sent"`, `confirmed:true`, and nonempty
`evidence`. Only an evidence digest is persisted. Reconciliation does not send;
if absence was verified, a separate explicit confirmed send is required. Local
drafts are retained after acceptance; SMTP does not automatically create a Sent
folder copy and no server draft is deleted.

Uncertain/sent drafts retain their original attachment preview. Preview requests
return `attachments_revalidated:false` for those frozen states; they never
silently update a pending submission. Status and owner reconciliation work even
if assets were removed or grants revoked. Confirmed Message-ID/draft receipts
still suppress duplicates without re-reading files or sending again. New sends
always perform the original caller's current file authorization checks.

## Validation scope

Unit/mock tests cover MIME decoding, UID epoch/range boundaries, shared account
cache, grants/owner checks, preview bindings, stale previews, persistent uncertain
submissions and duplicate-send suppression. TLS protocol tests use synthetic
mail and loopback servers with generated test certificates; no user mail is sent.
Attachment tests additionally cover exact binary/Unicode-name MIME round trips,
source/account/capability isolation, grant revocation, same-size file changes,
per-file/aggregate/count limits, prefix-to-complete reads, malformed/truncated
MIME, live UIDVALIDITY rejection and BODY.PEEK commands against a synthetic TLS
IMAP server. A synthetic TLS SMTP server accepts a real constructed attachment;
it is not an external delivery test. No user profile/vault or real mailbox is
accessed. Real providers, OAuth, Android Keystore and external delivery remain
outside this validation scope.

Run the canonical tests with:

```powershell
. ./scripts/dev.ps1
cargo test -p dansheng-connectors --features services mail:: --lib
```

`test-harness/Cargo.toml` is a standalone contract/lint runner that points at the
same `mod.rs`, without copying the implementation or editing connector/workspace
manifests. It was used while another contributor owned service feature exports:

```powershell
cargo clippy --manifest-path crates/dansheng-connectors/src/mail/test-harness/Cargo.toml --target-dir target/mail-contract-harness --all-targets --no-deps -- -D warnings
```

Attachment implementation handoff logs (generated/ignored, no credentials):

- `test-harness/attachments-tests.log`: canonical `services` mail tests, including
  synthetic TLS protocol tests.
- `test-harness/attachments-isolated-clippy.log`: mail-only contract harness,
  all targets, `-D warnings`.
- `test-harness/attachments-clippy.log`: the initial whole-connectors lint run;
  unrelated concurrent Canvas lint diagnostics are for the parent to integrate.

The parent enabled the existing `base64 0.22` optional dependency in `services`.
No additional Core helper or `files.export` implementation is required. No other
module, root manifest, user profile or real mailbox is part of this subtask.
