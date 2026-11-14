# Managed files and document indexing (M4)

`assets::dispatch(&Store, &Network, &Principal, &Grant, method, params)` implements
`files.download`, `files.list`, `files.read`, `files.delete`, `files.index`, and the
explicit unavailable result for `files.export`. The module owns only its
`managed_assets_v1` table and index, initialized through `Store::with`; it does not
change the Store database version or networking policy.

## Authorization and integration

The trusted adapter supplies the principal and grant. Every dispatch checks the
exact `files.*` capability, including direct Rust callers. Downloads additionally
require `http.request`; indexing additionally requires `sources.write`.

Non-owner SQL queries require `(owner = principal.id OR source_id IN
grant.source_ids)` **and** `(account_id = '' OR account_id IN grant.account_ids)`,
and must hold every active capability required by the source ACL described below.
Account access alone does not reveal another principal's managed files. Explicit
source grants let an authorized MCP/UI client share course files downloaded by
the UI owner, while plugins remain private by default. The trusted owner can
manage all assets.
Revoked/expired grants take effect on subsequent calls; permission and account
checks are repeated by Network before the actual HTTP operation.

Sharing a source does not grant an operation: `files.read` is still required to
read, `files.list` to list, `files.delete` to delete, and `files.export` to obtain
an internal platform export descriptor. An account-bound shared file requires
both the source grant and its account grant; anonymous files need no account
grant. Source comparisons are exact, parameterized SQL matches, not prefixes.

For example, an MCP grant for UI-downloaded campus course documents can be:

```json
{"capabilities":["files.list","files.read"],"source_ids":["official.documents"],"account_ids":["campus-a"]}
```

This exposes only matching anonymous or `campus-a` files, and does not authorize
deletion or export. With no `source_ids`, it exposes only the MCP principal's own
assets within the account scope.

### Sensitive source ACLs and cached attachments

Assets read the parent Store's schema-v3 `source_access` table, keyed by
`(asset.owner, asset.source_id)`, whose `capabilities` value is a JSON array.
For each non-owner query, a correlated SQL `NOT EXISTS` with `json_each` rejects
an asset if **any** required label is absent from the caller's active exact
capabilities. This check is shared by listing, byte reads, indexing, deletion,
existing-download lookup, and the trusted export descriptor. It applies to a
plugin's own cached files too: owning an asset row cannot bypass a revoked
sensitive grant. The trusted profile owner retains access.

The parent PluginHost records the effective sensitive `*.read` capabilities
through `Store::require_source_capabilities` before `files.download`. Its label
union is preserved by Store, so a later cache operation cannot weaken a source's
requirements. The asset module does not create or migrate this shared table.
Sharing a source/account and granting `files.read` or `files.export` does not
erase labels such as `mail.read` or `calendar.read`; all are required together.
Revoking any one hides bytes, metadata, and export descriptors on subsequent
calls. Wildcard-looking capabilities such as `mail.*` do not satisfy `mail.read`.

For legacy/unlabeled assets, source IDs matching SQL `LIKE 'mail.%'` additionally
require exact `mail.read`, matching Store's mail-source fallback. Missing access
is filtered in SQL and appears as an absent list item or `NotFound` for a specific
asset, rather than leaking its metadata. ACLs from another owner with the same
source name do not attach to this asset.

Main integration supplies:

- `pub mod assets` and the six `files.*` routes in Engine. Plugin host routing must
  apply plugin manifest origins to downloads as it does to `http.request`.
- Core dependencies `base64 = "0.22"` and `scraper = "0.24"`.
- Optional feature `pdf = ["dep:pdf-extract"]`, with `pdf-extract = "0.12.1"`.
  Default features are empty; base/mobile builds do not link the PDF dependency.
- `Network::download(principal, grant, HttpRequest, PathBuf, max_bytes, resume)`
  returning `DownloadReceipt { status, headers, size, sha256 }`. Network owns the
  shared origin, DNS pinning, private-network, redirect, credential and session
  rules; the asset layer never substitutes its own HTTP client.
- `Network::session_fingerprint(account: Option<&str>) -> CoreResult<String>`:
  an opaque session revision that changes on session replacement/logout and does
  not contain credentials. Anonymous requests have a stable anonymous marker.

The download function must stream to the supplied `.part` path, bound the
cumulative size, hash existing bytes when appending, validate a 206 range offset,
truncate/restart on 200, and preserve the sink on failure/cancellation. Asset code
sets Range and If-Range when requesting resume and also validates the completed
range extent, validator, receipt size and optional expected SHA-256.

## Wire methods

All parameters are objects. Unknown fields are rejected; no method accepts a
filesystem path, caller principal, or arbitrary destination.

| Method | Parameters | Result |
|---|---|---|
| `files.download` | Required `url`; optional `asset_id`, `resume`, `account_id`, `source_id`, `name`, `mime_type`, `sha256`, `headers`, `max_bytes`, `timeout_ms`, `method` (GET only) | Asset metadata after confirmed completion; errors leave discoverable partial metadata |
| `files.list` | Optional `account_id`, `source_id`, `state`, `limit` (1–500; default 50), `offset` | `{items, offset, limit}`; items contain metadata only |
| `files.read` | `asset_id`; optional `account_id`, byte `offset` (default 0), `length` (default 64 KiB, maximum 1 MiB) | `{asset_id, encoding:"base64", data, offset, length, next_offset, eof}` |
| `files.delete` | `asset_id`; optional `account_id` | `{asset_id, deleted:true}` after bytes, metadata and the derived document record are removed |
| `files.index` | `asset_id`; optional `account_id` | Document source identity, extraction byte count and index timestamp |
| `files.export` | `asset_id`; optional `account_id` | Engine returns only `{asset_id, exported}` after its trusted platform callback; `CapabilityUnavailable` when no platform port exists or when calling asset dispatch directly |

Downloads require GET with no body. Range, conditional and Accept-Encoding headers
are manager-controlled. A filename is display metadata only; the default name is
`document`, never a URL-derived or Content-Disposition-derived filename.
`source_id` defaults to `<plugin-id>.documents` for plugins and `files.documents`
for other callers. Plugin source IDs must use their own `<plugin-id>.` prefix.

Resume uses `files.download` again with the original URL, account, expected hash
and request headers, the returned `asset_id`, and `resume:true`. Bindings are
checked even when restarting an existing asset with `resume:false`. Metadata
cannot be changed during resume. The session fingerprint is checked before and
after the network transfer; session changes return `ResumeMismatch`.

```json
{"url":"https://approved.example/documents/42","account_id":"campus-a","source_id":"official.documents","name":"课程资料.txt","max_bytes":10485760}
```

The metadata result has `asset_id`, `owner`, `account_id`, `source_id`, `name`,
`mime_type`, `state`, `size`, `max_bytes`, `sha256`, timestamps, `indexed_at`,
`error_code`, `progress:{bytes,limit}`, and `resumable`. The limit is a safety
ceiling, not a claimed Content-Length or percentage. Listing reads current `.part`
size for live progress. Errors persist only a bounded error code, never the error
message or HTTP inputs. Failures before an asset row is created return no asset.

## Storage, quotas and recovery

Paths are `<dataDir>/assets/<uuid-v4>.part` and `<dataDir>/assets/<uuid-v4>`.
Canonical UUID checks, regular-file checks, a confined assets directory, and
per-asset OS locks reject path traversal, links and concurrent writes. The data
directory belongs to the trusted host; arbitrary local filesystem writers are
outside the plugin isolation boundary. Small `<uuid>.lock` coordination files may
remain after deletion and contain no user data.

The fixed default/hard limits are 100 MiB per file and 512 MiB across the data
directory. `max_bytes` can lower the file limit. An SQLite transaction reserves
the whole sink limit before transfer, preventing simultaneous downloads from
overcommitting the total quota. Retained partial bytes and completed bytes count
toward the total. A cancelled/dropped download future releases its excess
reservation while preserving partial data. Reservations can therefore reject a
large new transfer even when its eventual response might be small; callers can
choose a smaller `max_bytes` or delete retained assets.

States are `downloading`, `partial`, `promoting`, `ready`, and `deleting`.
OS locks distinguish active calls from stale persistent state. Restart recovery
recounts interrupted partial bytes, releases excess reservations, completes
pending deletion, and verifies the size and SHA-256 of a final file left by an
interrupted promotion. Before renaming, the module records a promotion intent;
the downloader flushes and syncs completed bytes and the final rename is atomic.
Readers and indexing require `ready`, so they cannot consume a partial download.

Before the first GET (or an unvalidated restart), a mediated HEAD captures only a
strong ETag. GET uses If-Match so the validator also binds those initial bytes.
An interrupted first transfer can then resume with Range + If-Range. No raw URL,
signed query string, credential or arbitrary response header is persisted. URL
and canonical request bindings are SHA-256 fingerprints. The strong ETag itself
is private database metadata and is not included in list/read results.

Missing/weak ETags, unsupported HEAD and absent validators make an interrupted
partial nonresumable: its bytes remain available for accounting/deletion but a
subsequent download restarts from zero. A server that ignores Range and returns
200 also restarts from zero. Changed URLs, request headers, expected hashes,
accounts or host sessions return `ResumeMismatch`; they cannot authenticate an
existing partial. Failed expected hashes discard the untrusted bytes.

Deletion first records a durable intent. After removing the `.part` and final
files, a transaction removes both the asset and its exact derived Store record.
This also updates the Store FTS index through its existing triggers. A crash or
file error leaves an intent that the next call retries locally.

## Indexing

Indexing verifies the managed file's size and SHA-256, then extracts on a blocking
worker. Supported formats are valid UTF-8 `text/*`, HTML/XHTML, JSON and XML as
text. UTF-8 BOMs are accepted. HTML uses an HTML5 parser to decode entities and
collect text, excluding head/script/style/noscript/template content; it does not
execute scripts, fetch resources, interpret CSS visibility, or render the page.
Normal malformed HTML is recovered by the parser; binary/NUL/non-UTF-8 text fails
with `DocumentParseError`. Input is at most 8 MiB, extracted text at most 256 KiB;
larger documents return `DocumentTooLarge` instead of silently truncating search
content. HTML nesting is limited to 256 levels and markup to 16,384 opening
delimiters, with `DocumentTooComplex` on excessive structure.

The idempotent Store record uses the asset's original owner/account/source,
`external_id = "asset:<uuid>"`, `kind = "document"`, and typed data containing the
asset ID, display name, MIME type, hash and extracted text. Search/query uses
Store's existing FTS and short-query behavior and its source/account grants;
asset byte access also requires the exact file capability and the owner/source
plus account scope described above.

### Optional PDF text extraction

Enable `--features pdf` to index text from PDF MIME types or a `%PDF-` signature.
With the feature off these return `CapabilityUnavailable`. The optional module
uses [pdf-extract's page output API](https://docs.rs/pdf-extract/0.12.1/pdf_extract/fn.output_doc_page.html)
and a bounded output writer; it does not collect unbounded strings for all pages.
Compressed content streams and encoded text are supported. Image streams are
discarded before content execution; a PDF with only images/graphics or whitespace
returns `NoExtractableText`. There is no OCR or Office document conversion.
Encrypted PDFs return `EncryptedDocument`; this API accepts no PDF password.
Corrupt or unsupported structures return a redacted `DocumentParseError`.

Resource policy:

- At most 8 MiB input, 128 pages, and 4096 loaded objects/xref entries.
- At most 65,536 direct object nodes and 32 levels of dictionary/array/page
  inheritance nesting; cyclic page inheritance is rejected.
- At most 4 MiB per decoded stream/page content and 16 MiB total retained decoded
  stream bytes. Images are discarded without image decoding.
- At most 16 nested Form XObjects and 65,536 expanded content operations;
  recursive forms are rejected, and repeated form invocations count repeatedly.
- At most 256 KiB UTF-8 output, enforced during writes, including page separators.
- Two blocking extraction tasks at a time (shared with text/HTML indexing).
  A cancelled caller cannot release a running parser's worker permit.
- A 15-second cooperative deadline checked between streams/pages, during content
  validation and during output. It does not interrupt a parser/decompressor call.

These are admission/execution/accounting limits, **not a security sandbox or a
hard process heap/CPU limit**. Object/stream limits are checked after the library
has loaded or decoded those structures, so third-party parsing, decompression,
font/CMap processing and their intermediate allocations are not preemptible or
strictly memory bounded by this module. `spawn_blocking` keeps work off async I/O
threads; it does not kill a running parser when the caller is cancelled. Hosts
that require hard limits for hostile documents need process isolation. Parser
errors are not copied by the asset layer into responses or Store records.

### Trusted export descriptor

Public `assets::dispatch(..., "files.export", ...)` continues to return
`CapabilityUnavailable` rather than a filesystem path. The trusted Engine may
instead call this synchronous Rust-only helper:

```rust,ignore
assets::export_descriptor(store, principal, grant, params) -> CoreResult<Value>
```

It accepts only `asset_id` and optional `account_id`. It checks `files.export`,
the owner/source plus account SQL scope, the per-asset lock, complete state, regular-file
confinement, file size and SHA-256. The result is an **internal-only** object:

```json
{"asset_id":"<managed uuid>","path":"<canonical absolute managed path>","name":"资料.txt","mime_type":"text/plain","size":123,"sha256":"<hex>"}
```

Engine passes this descriptor internally to trusted `PlatformPort files.export`
to present a file picker, and returns only `{asset_id, exported}` as a sanitized
success/cancellation receipt. It must never return or log the descriptor or a platform-chosen path to
plugins/clients/MCP. No request-supplied source or destination path is accepted.
The descriptor is a checked snapshot, not an open-handle lease; the callback must
handle a concurrent local deletion or a missing file and must not reinterpret the
source as a caller-selected path. No actual platform file-picker export is
implemented or verified in this module; the parent owns that platform route.

## Validation evidence

`crates/dansheng-core/tests/assets.rs` uses local TCP fixtures, synthetic sessions
and disposable data directories. It covers stream interruption, strong-validator
resume, ignored Range, invalid range offsets, missing validators, future
cancellation and live byte progress, restart/promotion recovery, owner/account
isolation and revoked account access, byte quotas and deletion reclamation,
bounded base64 reads, signed-URL fingerprinting, expected hash failure, Unicode
and HTML entity extraction, parser limits and missing platform capabilities.
The total quota fixture seeds a reservation rather than transmitting 512 MiB.

Verified on Windows with the repository's portable toolchain:

```powershell
. ./scripts/dev.ps1
cargo test -p dansheng-core --test assets --offline
cargo test -p dansheng-core --features pdf --test assets --offline
cargo test -p dansheng-core --no-default-features --test assets --offline
```

Results after the source-ACL follow-up: **22 passed, 0 failed with `pdf`**; **18 passed,
0 failed with `--no-default-features`**. The original 14 offline tests remain in
both suites. Additional tests generate a tiny valid PDF with actual xref offsets,
compressed PDF streams, Unicode text, encryption, corrupt/no-text input,
page/object/operation/output limits, nested/recursive Forms, cyclic page parents,
image-only pages without OCR, and scoped internal export descriptors. The sharing
test covers UI-owner downloads read by MCP, account-only denial, explicit exact
source sharing, required account scope, anonymous files, private sources, and
independent read/delete/export capabilities. These
also cover all-label source ACL enforcement, exact capability grants and
revocation (including the producing plugin), owner/source ACL key isolation,
and the legacy `mail.read` fallback without an ACL row. These
remain offline Windows tests; they do not establish Android/Linux execution,
emulator behavior, authenticated school-service compatibility or platform
file-picker export.

### Integration freeze verification

After resolving the two asset-local `collapsible_if` warnings:

```powershell
cargo test -p dansheng-core --all-features --test assets --locked --offline
cargo clippy -p dansheng-core --all-features --test assets --locked --offline
rustfmt --edition 2024 --check crates/dansheng-core/src/assets.rs crates/dansheng-core/tests/assets.rs
```

All-features asset tests: **22 passed, 0 failed**. Focused Clippy: **zero
diagnostics**. Both Rust files pass formatting checks. `assets.rs`, its integration
tests and this document are frozen for the parent's independent full-suite
review. No commit was made by this worker.
