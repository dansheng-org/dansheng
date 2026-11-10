# Local profile snapshot and offline restore

The native APIs are `dansheng_core::backup::create(&Store) -> CoreResult<Value>` and `backup::restore(data_dir: &Path, snapshot: &Path) -> CoreResult<Value>`. They use existing rusqlite online-backup, SHA-256, fs2, serde, and UUID dependencies. There is no archive extractor, network request, platform-vault access, or live-engine restore operation.

Main has exported the module and wired `backup.create` through `spawn_blocking`. The host worker owns offline CLI wiring. An offline CLI must call `backup::restore` **before** opening a Store/server; an open Store already owns the profile lock and restore returns `DataDirectoryInUse`. Both APIs perform blocking disk work and belong on a blocking worker when called by an asynchronous host.

## What a successful snapshot contains

`create` returns an absolute `path` under `data_dir/backups/<UUID>`, its `snapshot_id`, file/byte counts, format version 1, database version 3, and `complete:true`. A snapshot is an ordinary directory containing:

- `manifest.json`: bounded versioned inventory with every relative file path, size, SHA-256, and directory name.
- `dansheng.db`: SQLite online backup, compacted into a standalone DELETE-journal database. WAL/SHM files are not copied as a substitute for SQLite backup.
- `assets/<managed UUID>`: exactly the asset rows whose captured state was `ready`, each checked against its database size and SHA-256. Partial downloads and asset lock files are excluded, and non-ready asset metadata is removed from the exported database.
- `plugins/<id>/versions/<generation>/**`, `.history/**`, `current.json`, and retained uninstall pointers: all installed and uninstalled immutable generations/history, not only the selected package. Each generation is validated with the existing plugin validator and its manifest/package digests. Registry entries must agree with their captured current pointer and manifest. Snapshot registry paths are portable managed relative paths.

`host/**`, `vault/**`, `package-downloads/**`, existing backups, core locks, and asset/plugin installation locks are never snapshot payloads. In-process HTTP sessions do not enter SQLite backup. Client authentication registrations/token hashes, grants, `core:session-policy`, `core:network-routes`, `core:credential-bindings`, `core:plugins`, and cached `core:catalogs` are removed from the exported image. Plugins are disabled in that image. Secure deletion plus VACUUM prevents deleted authentication/session-policy values from remaining in free pages of a completed export. The live database/grants and credential-binding epoch are not changed by create.

Business records, personal notes, package source, and file contents remain user data; the service does not guess whether arbitrary personal prose is a secret. The core contract still requires credentials to be kept in mediated platform vaults, not arbitrary user-record/KV fields.

## Snapshot consistency and responsiveness

The **only** Store mutex critical section is `Connection::backup`. Schema validation, all captured metadata reads, asset/plugin locking, file copies, hashes, VACUUM, and manifest validation operate outside the live Store mutex, on the independent database image and managed payloads. This keeps potentially large payload I/O from blocking normal core APIs or JavaScript host-call futures.

The database image is authoritative for the ready-asset set and plugin registry. Snapshot creation takes nonblocking asset OS locks and temporary plugin installation guards, validates immutable generation/history references against that image, and compares inventories and source hashes before publication. A current pointer that no longer matches the captured registry, an in-use file, or changed/missing selected payload returns `SnapshotBusy` for a later explicit retry. Normal database updates after the backup instant can proceed; they do not change the captured image. An added unrelated ready asset is not silently included in the earlier database snapshot.

Files and the manifest are written to a private `.incomplete-<UUID>` directory. Only after exact inventory, schema, package, asset, size, and hash validation does one rename publish the completed UUID directory. Failed staging is retained for inspection; it is not returned as success or recursively deleted. Incomplete work directories are not an export contract and may contain transient database work files; do not distribute them. A consumer must validate a complete manifest and its entire inventory, not infer completeness from a directory name.

## Offline restore contract

Paths must be explicit absolute paths. The target's parent must already exist and resolve to a regular directory; the target itself may be an existing profile or a new leaf under that parent. No symbolic links, Windows reparse points/junctions, or Unix hard links are accepted in snapshot paths. Path validation rejects `..`, absolute/drive paths in the manifest, backslashes, ADS/colon syntax, percent-encoded traversal, device aliases, trailing-dot/space aliases, duplicate/case-colliding paths, unexpected files, and unexpected directories.

Restore proceeds as follows:

1. Read and validate the entire snapshot: manifest and exact filesystem inventory, every hash/size, supported SQLite schema and integrity/foreign-key checks, ready-asset references, and every plugin generation/history/current pointer. Unknown future database versions, unknown schema objects/triggers/views, expression indexes, missing payloads, and unsupported extension schemas fail before the existing profile is moved. Merely recomputing the manifest hash does not make an unsupported SQLite schema acceptable.
2. Resolve the final target and canonical parent. Existing target root children must be exclusively `dansheng.db`, `dansheng.db-wal`, `dansheng.db-shm`, `core.lock`, `assets`, `plugins`, `backups`, `package-downloads`, `host`, or `vault`, with their expected file/directory types. Workspace roots, arbitrary notes/files, and unrelated directories are rejected. Before moving an existing profile, a bounded recursive inventory also rejects links and special files; a stale Unix `host/ipc.sock` is an explicitly recognized app endpoint.
3. Acquire `Store::acquire_profile_lock` at the stable canonical-parent `.dansheng-profile-<hash>.lock`, **before** creating the target leaf, staging, or swapping directories. This lock must also be held by Store throughout its lifetime. A refused Store startup must not create the target directory before acquiring this lock, including the gap between restore's two renames. A legacy `core.lock` is also checked for an active owner.
4. Read current target control-plane state while offline: the entire `core:plugins` KV namespace, its publisher trust/immutable key-ID history/catalog sequence floors, the current event-sequence floor, and current source read labels.
5. Build `.dansheng-stage-<UUID>` as a fresh **sibling** of the final target. Copy only the verified snapshot payload, verifying bytes again. Never overlay the old target. Revalidate the source snapshot, sanitize and normalize the staged database, verify all staged payload references, and sync regular files.
6. Immediately before commit, recheck canonical sibling parents and the complete old target inventory. Rename the old target to `.dansheng-previous-<UUID>`, then rename the complete stage to the exact original target path. Retain the entire previous profile. If activation fails, try to rename the previous profile back; if that recovery also fails, return `RestoreNeedsRecovery` identifying the retained previous profile. Existing profile directories are never recursively deleted.

No fallible copying or database changes follow a successful activation rename. Directory sync is best effort where supported; filesystem/power-loss behavior is not advertised as a cross-platform atomic directory exchange. A crash between renames can leave the retained previous/staging sibling directories for explicit offline recovery. Keep these closed, and recover under the same stable lock. The previous profile's old absolute plugin paths become valid again when it is moved back to the **original** target path; do not run a previous profile in place as a different data directory without normalization.

When restoring a snapshot from the target's own `backups` directory, that source snapshot moves with the old profile into the returned `previous_profile/backups` directory. Old backups/downloads/vault/host state remain intact in that previous profile; they are not recursively recopied into the new active profile.

## Restored activation and control-plane policy

- All restored plugin registry entries are disabled; grants and clients are cleared. Fresh host authentication tokens must be provisioned by the host, and non-owner permissions require explicit new grants.
- Restored HTTP session persistence policy is cleared, and host/vault files are absent. The host must reauthenticate; a saved session is not automatically revived from old ciphertext or an old policy flag.
- The entire `core:credential-bindings` namespace is discarded again during restore, including values injected into an old or modified snapshot. The current target's epoch is not preserved. External platform vaults (for example Linux Secret Service) may retain credentials after the directory swap; retained entries do not authorize restored service configuration to read or use them.
- Snapshot `core:plugins`/catalog cache state is discarded. The **current target's** complete `core:plugins` namespace is restored into the stage instead, preserving current trusted publisher keys, immutable key-ID history, and sequence floors. A fresh target receives no trust merely because an imported snapshot once trusted a publisher.
- Current source read labels are unioned into the snapshot labels, so restoring older data cannot remove a newer read-capability requirement on the same canonical writer/source.
- Event AUTOINCREMENT sequence is floored at the current target's sequence, without lowering the snapshot's own floor. New events do not reuse current profile event sequence numbers.
- Pending/running/waiting restored jobs become `needs_reconciliation`; no timed plugin action is automatically replayed. Outstanding notification delivery attempts become `uncertain`, pending inbox notifications are suppressed, and already overdue reminders are cancelled. Future user reminders remain scheduled; plugins/grants are still subject to the normal restored-disabled/reapproval policy. Existing delivered/cancelled receipts are retained.
- Every registry path is rewritten to `final_target/plugins/<id>/versions/<selected generation>`, never the staging directory, old source directory, or an arbitrary saved absolute path. Retained uninstalled generations remain uninstalled and recoverable through explicit plugin rollback.

`restore` returns `restored:true`, the canonical `data_dir`, `previous_profile`, source `snapshot_id`, disabled-plugin count, and explicit authentication/grant reset receipts. This is local profile activation evidence, not a live service test or proof of platform notification delivery.

## Credential bindings and mail migration

`Store::credential_binding_epoch() -> CoreResult<Option<String>>` reads local binding authority without creating it. `Store::ensure_credential_binding_epoch() -> CoreResult<String>` atomically initializes a random UUID in `core:credential-bindings` / `epoch`, or returns the existing nonempty epoch. Only a trusted configuration flow supplying explicit credentials may initialize it. Store startup, cache reads, and snapshot loading never initialize authority or adopt an epoch from imported service configuration. This is a generic core facility; core does not inspect mail settings or access platform vaults. Services using external credentials must enforce their own binding at their credential-read boundary.

Mail configuration stores an optional `credential_binding_epoch`. Every vault read for status, folder refresh, synchronization, flag reads/writes, attachment downloads, or SMTP requires a nonempty saved epoch matching the current nonempty profile epoch. Missing, empty, or mismatched bindings return `ConfigurationRequired` before vault access or a backend call. Equal missing epochs are never valid. Existing endpoint/configuration/key integrity checks still apply.

Restored configurations and older configurations without this field retain cached folders/messages, drafts, draft preview/submission-status access, confirmed submission receipts, and reconciliation state. Reading cached mail does not require a valid credential binding. The trusted owner must call `mail.configure` with explicit credentials to enable network access again. A configure call omitting credentials only preserves a currently valid binding for the same configuration; it cannot initialize or repair a restored/legacy binding or silently reuse its old vault reference. Configuring another account initializes a fresh profile epoch but does not rebind an older account. Confirmed draft/Message-ID identities remain immutable across reconfiguration; uncertain sends still require reconciliation before retrying. No SQLite schema or snapshot format migration is needed.

Synthetic regression fixtures retain one in-memory external vault and backend counters across Store destruction and real offline profile restore. A snapshot's mail endpoint is replaced with an internally valid former TLS endpoint/key pair carrying its old binding, and its manifest hash is recomputed. The core regression separately injects the epoch and another control key into a rehashed snapshot to verify independent restore sanitization. Restore must still block every credential path without a vault read or backend call, preserve offline messages/drafts and send identities, and require fresh owner-supplied credentials. Separate cases cover missing/empty/mismatched epochs, a new epoch established for another account, legacy confirmed receipts, and uncertain sends. These fixtures use disposable profiles and synthetic data only, without sockets, production vault access, personal mail, or live service requests.

Focused commands for this security change are `cargo test --offline -p dansheng-core --test backup` and `cargo test --offline -p dansheng-connectors --features services --lib credential_binding`. Workspace integration, cross-compilation, emulators, and real services are separate validation by the parent agent.

M5 focused Windows validation: the backup target passed **16 tests**, including the existing network-route exclusion regression and the new epoch regression. The mail module passed **19 tests**, including **4 new credential-binding tests**, with all socket fixtures excluded. After `. ./scripts/dev.ps1`, the exact mail command was:

```powershell
cargo test --offline -p dansheng-connectors --features services --lib mail::tests -- `
  --skip real_ `
  --skip outgoing_assets_use_original_file_account_source_and_capability_grants `
  --skip changed_asset_invalidates_preview_and_actual_mime_contains_exact_attachment `
  --skip uncertain_attachment_submission_cannot_be_edited_or_retried_after_asset_loss `
  --skip outgoing_attachment_per_file_total_and_count_limits_precede_smtp `
  --skip managed_attachment_mime_is_submitted_only_to_synthetic_tls_smtp `
  --skip confirmed_smtp_identity_is_not_replayed_after_configuration_changes
```

## Bounds and evidence

Format 1 supports root Store schema 3, the known managed-assets v1 table, organizer schema versions 1–2, and the core FTS tables/triggers. An extension introducing a new table/schema must extend validation before this module will accept it. The organizer/root database version counters are not silently rewritten during restore.

Limits are 8 MiB manifest, 20,000 payload files/directories, 1 GiB per file, 2 GiB total payload, 1,024 bytes/64 segments per relative path, and 200,000 inspected entries in an existing profile tree. Asset and package validators additionally enforce their smaller existing limits. Hashing/copying streams use bounded buffers; there is no archive decompression or recursive copy of arbitrary user roots. The manifest supplies integrity, not a signature or an automatic grant of publisher trust.

Run focused verification with `cargo test -p dansheng-core --test backup`. The fixtures use temporary directories only: online snapshot/asset/package-history roundtrip; preserved rollback and current controls; credential exclusion/auth reset; active core/asset/install locks; the stable-lock swap gap; traversal/ADS/case-sensitive file inventory; byte tampering/missing/extra files; future schema and injected trigger rejection; unrelated target files; uninstalled generations; partial download exclusion; and a 32 MiB payload test proving live Store APIs remain available while capture continues at a single database instant.

Final integrated Windows run: **14 passed, 0 failed**. Main fixed Store and host startup to acquire the stable parent lock before creating the profile leaf; the swap-gap regression now passes. A separate release-binary smoke test also passed snapshot creation through the running service, offline restore, preserved data, and cleared MCP grants. All restore targets were disposable test profiles. Windows symlink-fixture execution is conditional on OS link privilege. See [integrated validation](validation.md) for the final evidence and remaining platform limits.
