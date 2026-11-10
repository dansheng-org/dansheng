# MailService interrupted-sync evidence (M4)

This check exercises the actual `MailService.call("mail.sync", ...)` and
`NativeBackend::with_test_root` over loopback TLS IMAP. It is separate from
NativeScheduler cancellation tests and does not use the mail test `Backend`
mock or its queued `SyncBatch` results. Production MailService/protocol, Core,
Host, Cargo and SDK files are unchanged by this test-only task.

## Implementation boundary being checked

`NativeBackend.sync` uses EXAMINE, bounded UID FETCH BODY.PEEK and, for an existing
epoch, a rotating UID FLAGS refresh. It is intended to collect the complete
bounded body/flags batch before returning it to MailService; the clean-EOF issue
below shows why stream termination alone is insufficient. MailService parses/stages cache
and UID-index entries, and commits authoritative source rows plus the folder
checkpoint together through `Store.commit_source`. `mail.list/read` use the
committed checkpoint/epoch to bound visibility.

The new tests in `crates/dansheng-connectors/src/mail/tests.rs`, module
`sync_interruption`, put interruptions inside the real IMAP batch, including
one fully delivered FETCH response followed by an incomplete announced literal.
They prove the network operation's commit/visibility behavior; they do not
simulate an OS process kill, disk-full error or a crash between individual local
KV writes and the final SQLite transaction. They also do not claim that a body
arriving on the wire is already durably stored by MailService.

## Four scripted TLS sessions per case

1. A successful seed sync commits epoch 401, UID 1, UIDNEXT 2, with `\\Flagged`
   and no `\\Seen`. The test captures the complete checkpoint and source rows.
2. The server exposes more messages and interrupts or explicitly rejects the
   next sync at the case's designated boundary. A failed/cancelled/rejected call must leave that old checkpoint,
   cached listing/read visibility and actual source rows unchanged. The first
   uncommitted message must not appear even though its complete FETCH response
   was delivered before the interruption.
3. The test closes and reopens the **same temporary Store**, constructs a new
   MailService/NativeBackend, and retains only the synthetic in-memory vault and
   local test CA. It does not reconfigure credentials. A successful real TLS
   retry must request the same UID window, commit both pending messages and
   advance the checkpoint correctly.
4. A further no-new-data sync fetches only flags, returns `fetched:0` and leaves
   message/source identity counts unchanged. Content of every current-epoch
   UID is read back to prove no missing or duplicated messages.

| Test | Actual interruption | Required outcome |
| --- | --- | --- |
| `literal_disconnect_keeps_old_commit_and_reopens_without_skips_or_duplicates` | Epoch 401 UID 2 is complete; UID 3 literal is only half delivered before TLS EOF | Cursor remains 1, visible/source rows remain UID 1; restart retries 2:3 and commits exactly once |
| `cancelled_pending_tls_sync_keeps_old_commit_and_reopens_without_skips` | The server signals after sending a complete first response and a partial second literal; the actual MailService sync future is then dropped | Pending call has not completed, old checkpoint/source rows stay unchanged, and server observes the client's TLS stream close; restart retries 2:3 |
| `epoch_change_disconnect_does_not_publish_new_epoch_until_retry_commits` | UIDVALIDITY changes to 402; UID 1 is complete and UID 2 literal is cut | Epoch 401 remains current until successful retry of 1:2; then only epoch 402 is listed/read, with the old source row retained as archive |
| `interrupted_flag_refresh_does_not_commit_already_received_new_messages` | Both new bodies are complete; FLAGS loses the connection before any response or final tagged OK, while the old message still exists | The complete body window must not advance the checkpoint or publish source rows; restart repeats and commits the window. This caught the pre-fix failure below |
| `flags_tagged_no_keeps_commit_boundary_and_recovers_after_restart` | FLAGS receives its matching tagged NO on a live TLS connection | Reject the batch, preserve the old cursor/source/read state, then reopen and recover without skips/duplicates |
| `flags_tagged_bad_keeps_commit_boundary_and_recovers_after_restart` | FLAGS receives its matching tagged BAD on a live TLS connection | Same boundary and restart guarantees as NO; BAD cannot be mistaken for a successful completion |

Cancellation uses a wire barrier and a still-pending real service future, not a
mock cancellation token or an arbitrary sleep. The EOF cases force the real IMAP
parser to consume the preceding complete response before reaching the cut. The
test does not instrument or claim an exact internal per-message progress count
for the cancellation case. The server's close acknowledgement ensures the
cancelled native connection is actually gone before reopening the Store.

For tagged NO/BAD, the server does **not** close the connection after rejecting
FLAGS. It waits for LOGOUT, replies normally, and only then acknowledges session
completion. Both tests assert that this exact rejected session reached LOGOUT.
Thus a missing response/EOF cannot be the reason the batch is rejected. Both
new bodies already had their own tagged OK, and the rejection belongs to the
subsequent exact FLAGS command tag. All six cases retain checkpoint equality,
source-row equality, old-epoch read/list visibility, same-profile reopening,
the exact retry window and final no-duplicate/no-skip assertions.

## Read-only and credential boundaries

The six interrupted-read fixtures accept only synthetic TLS LOGIN, EXAMINE, bounded
`UID FETCH ... BODY.PEEK[]<0.1048576>`, UID FLAGS and LOGOUT. Commands are checked
against each session's exact UID range. SELECT, BODY[] reads, STORE/UID STORE,
EXPUNGE and other mutations fail the fixture. Source/list/read checks ensure
`\\Seen` was never added and the original `\\Flagged` state remains correct.

The test account, MIME messages, CA and password are generated/static synthetic
fixtures. Connections bind to `127.0.0.1` and use `localhost` with the local CA;
accepted peers must be loopback. Only the temporary Store and a synthetic RAM
PlatformPort vault are accessed. No user profile, real mailbox/password,
operating-system credential vault, production endpoint or SMTP server is used.
The in-memory trace excludes LOGIN/credential bytes and records only the
read-only command metadata needed to assert ranges and PEEK use.

## UID STORE acknowledgement regression (synthetic write fixture)

`real_tls_uid_store_ack_controls_readback_and_persistent_reconciliation` is one
parameterized test with four separate temporary profiles/TLS servers: OK, NO,
BAD and lost-ack EOF. It first commits a real read-only UID 1 sync. It then calls
the actual MailService `mail.set_flags` with `seen:true`, which reaches the
production NativeBackend.flags, SELECT and one exact
`UID STORE 1 +FLAGS.SILENT (\\Seen)` command. This is an intentional mutation of
only a synthetic loopback server; no external mailbox is contacted.

| STORE outcome | Required wire/cache behavior |
| --- | --- |
| Matching tagged OK | Exactly one STORE, then one `UID FETCH 1 (UID FLAGS)` with tagged OK; returned/cached flags include Seen and the pending marker becomes `observed` |
| Matching tagged NO | Connection stays live through LOGOUT; caller receives `NeedsReconciliation`, cached source rows/cursor stay unchanged, and no read-back FETCH or second STORE occurs |
| Matching tagged BAD | Same uncertain-write behavior and live-connection assertions as NO |
| EOF before acknowledgement | Server simulates having applied Seen but loses the acknowledgement; local cached flags remain unchanged and the caller must reconcile, with no automatic STORE/FETCH retry |

For all three failure outcomes, the test repeats the explicit request and reopens
the same profile before repeating again. The persisted `needs_reconciliation`
marker must block both requests. The loopback listener stays alive until those
checks finish and fails on any reconnect. The recorded write-session transcript
must contain exactly one STORE, zero read-back FETCHes on failure, and LOGOUT
for the still-live NO/BAD sessions. No NOOP completion substitute is used.

This new targeted case is additional to the previously completed 38-test mail
regression run; the old module is not rerun just to inflate that count.
The targeted test passed all four outcomes. The final local strict Clippy
(`-D warnings`), Rust formatting and scoped diff checks also passed.

## Targeted verification

After the parent's strict per-command completion correction, one complete
`mail::tests` run passed **38/38**, including the six interruption/rejection
cases, attachment paths, real loopback TLS IMAP/SMTP, credential binding and
uncertain-send/dedup regressions. Both tagged rejection cases completed LOGOUT
on their still-live rejected session and then passed the full old-boundary and
same-profile restart/retry assertions. Current full mail test evidence is
`target/mail-protocol-all-tests.log`; the pre-fix failure below is retained as
historical regression evidence, not a statement of current failure.

The pre-fix targeted run produced three passing restart/recovery cases and one
failing FLAGS-completion case. A refined single-case rerun confirmed this actual
production failure, without this worker changing production code:

```text
incomplete IMAP batch was committed:
scanned_before=1, scanned_after=3, source_rows=3,
visible_messages=2, seed_deleted_remotely=true
```

The old UID 1 was never removed from the server. With no FLAGS response at all,
the fetch stream ends at a clean TLS EOF and NativeBackend treats an empty flags
map as a successful complete observation. MailService commits UID 2/3, advances
the cursor and tombstones UID 1 locally. The existing literal-cut cases instead
produce a protocol error because their announced literal is incomplete.

Local `async-imap 0.12.0` source explains the difference: `parse_fetches` uses a
`take_while/filter` stream and does not require an observed successful tagged
completion before EOF. `parse_noop`, used by ordinary `session.noop()`, is also
permissive on clean EOF. A parent-owned fix must confirm successful completion
before publishing a batch or interpreting absent FLAGS as remote deletion.
`run_command_and_check_ok` explicitly rejects missing completion and may support
a strict read-only transport barrier; it must not be confused with `noop()`.
A later barrier alone also must not be used to justify a preceding FETCH's
explicit tagged NO/BAD response. The parent owns the production correction in
`protocol.rs`: Session.run_command plus per-response parsing must observe the
same command tag with Done/Status::Ok; EOF, NO, BAD, another tag and BYE fail.
This fixture needs no NOOP command and keeps the original read-only command
whitelist. Production protocol edits remain outside this worker's write scope.

Exact failure command:

```powershell
cargo test -p dansheng-connectors --features services --lib mail::tests::sync_interruption::interrupted_flag_refresh_does_not_commit_already_received_new_messages --locked --offline -- --exact
```

Refined failure evidence: `target/mail-sync-interruption-flags-repro.log`.

```powershell
. ./scripts/dev.ps1
$env:CARGO_BUILD_JOBS = '2'
cargo test -p dansheng-connectors --features services --lib mail::tests::sync_interruption:: --locked --offline --no-fail-fast
cargo test -p dansheng-connectors --features services --lib mail::tests --locked --offline --no-fail-fast
cargo clippy -p dansheng-connectors --features services --lib --tests --no-deps --locked --offline -- -D warnings
```

The final additional UID STORE check is run alone, followed by local Clippy:

```powershell
cargo test -p dansheng-connectors --features services --lib mail::tests::sync_interruption::real_tls_uid_store_ack_controls_readback_and_persistent_reconciliation --locked --offline -- --exact
```

Generated logs: `target/mail-sync-interruption-tests.log` (six cases),
`target/mail-protocol-all-tests.log` (complete mail module), and
`target/mail-sync-interruption-clippy.log`. This is local Windows protocol/cache
evidence; it does not substitute for Linux/Android execution, production mailbox
validation or external network failure testing. Any production failure found by
these tests is reported to the parent rather than fixed outside the allowed
test/documentation files.
The additional STORE acknowledgement evidence is
`target/mail-uid-store-ack-tests.log` (one test/four server outcomes).
