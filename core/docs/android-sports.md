# Android adapter and official Fudan sports plugin

## Active paths after the 2026-11-10 migration

Core main is `D:/Code/dansheng-core`; App main is the separate repository
`D:/Code/dansheng-app`. Build from the registered task under `D:/Worktrees`, with
its explicit Cargo target, dependency caches and artifacts in
`D:/Code/dansheng-workspace/local/runtime/<task>`. `platform/android/gradlew.ps1`
can use the pinned installation in `D:/DevCache/gradle` while keeping a task's
project cache separate. Android SDK/NDK and installed JDK remain at their actual
C-drive installation paths; they were not renamed with the project.

The dated runs below retain their original C paths, receipt identities, emulator
IDs and compile layouts. They are historical evidence, not commands to write
into the preserved C project today. New builds use the explicit task environment
and create new receipts; do not relabel the old binaries or source fingerprint.

Earlier parent validation on 2026-11-06: **25/25 instrumentation tests** passed with
the then-current x86_64 Rust/JNI library on the dedicated API 36 emulator; **5/5 JVM
tests** passed. The ARM64 release library also cross-compiled successfully, but
was not executed on ARM64 hardware. [Integrated validation](validation.md) is the
integrated acceptance record. The newer source-bound revalidation below records
additional fixtures and explicitly separates baseline runs from final-freeze work.
Older worker snapshots and resolved failures remain historical evidence.

## Android source-bound revalidation, 2026-11-06

Current phase: **425 frozen source accepted for this Android validation scope:
the original eight native tests passed once without changes or retry wrappers,
and two incremental mapped ARM64 release builds are byte-identical**.
Earlier 7/8 failures and 807 artifacts remain historical evidence, not current
failures or current release outputs. The exact source attempts are recorded below. Earlier
in-flight outputs preceded the parent's connector QR/mail and API-null fixes and
must not be labeled as the final frozen-source release.
No shared Rust, host, SDK, release scripts or dist files were edited by
this Android worker. The additionally authorized shared synthetic package is
`plugins/fixtures/closed-loop`; production interfaces remain unchanged.

### Final 425 acceptance (2026-11-06 local / 2026-11-07 UTC)

Final source fingerprint, using the parent's 57-file release-helper inventory:

`425318a872c96a78c39eaddb40e2a525160a92e2347863e8065a6aec92c1931d`

Only `crates/dansheng-core/src/engine.rs` and `store.rs` changed from the 807
production snapshot. The parent's fix atomically creates/claims an immediate
plugin invocation as running with a lease, installs its `JobGuard` before awaits,
and removes the scheduled window previously visible to the FFI tick. This
worker changed no Rust, Android test source, parent build script or shared fixture
file during the final verification. Both native classes and all assertions were
the same ones used to expose the failure.

| Final check | Actual result |
| --- | --- |
| x86_64 Rust/JNI build | Core, Connectors and FFI incrementally compiled in **32.97s**, jobs=2, locked/offline, epoch=0. Existing target retained. |
| APK update | Gradle succeeded in **8s**; Kotlin and test code stayed up-to-date. Only native packaging/linking changed. Installed app/test APK hashes match local outputs. |
| Actual runtime | `NativeAbiInstrumentationTest` (7) plus `ClosedLoopInstrumentationTest` (1): **8/8, zero failures/errors, 43.103s, one invocation** on `emulator-5588`. The previously failing migration case passed unchanged. |
| Scope/counts | No retry wrapper, swallowed error or `JobNotRunnable` success substitution. No pure Kotlin/JVM/browser suite rerun. Baseline **28 distinct instrumentation cases** and **5 JVM tests** retain their original execution records; they are not relabeled as final reruns. |
| Shared package | Four-file SHA256 remains `eb037c94a2bd146d0c7d50ec098597e99ba27f2c9ea7852f6bd70e1ec5b6bc1a`. Exactly one authenticated synthetic loopback GET; real QuickJS/storage/sources/UI and reopen checks passed. Normalized SHA256 remains `556afa430353b2329b39860c1bc7495eb31e758b7dbab04ef69a0a6c8fb91193`. |
| ARM64 main | Actual incremental Core/Connectors/FFI compilation in **2m39s** using the existing mapped main target. |
| ARM64 independent | Actual incremental Core/Connectors/FFI compilation in **2m12s** using the existing separately populated mapped target, started only after the main build finished. No clean/cold build and no compiled-object copying. |
| ARM64 identity | Both raw files are **16,313,648 bytes**, ELF64 little-endian AArch64, and byte-identical. Both receipts bind all 57 `425` inputs with epoch=0 and `native_source_prefix:"/dansheng-build"`. **Cross-compiled only; no ARM64 execution.** |

Final native hashes:

| Artifact | SHA256 |
| --- | --- |
| x86_64 FFI, raw build = JNI staging = installed APK payload | `13749b445b28d86519811a2ead772b05fd6078c670a535926c8d95ef10812b28` |
| x86_64 JNI adapter payload | `38536d12447679de762d34dfb482ccf016267c6734f43979de9648d914db5155` |
| ARM64 release, both independent targets | `cf92e6c3f3c330cb2e3ef0769defcf654d3204b52b7a20d24efca6a5e9b9a17d` |

Final build products and source-bound receipts:

- `C:/Code/dansheng/.local/build-x86_64/x86_64-linux-android/debug/libdansheng_ffi.so`
- `C:/Code/dansheng/.local/build-arm64/aarch64-linux-android/release/libdansheng_ffi.so`
- `C:/Code/dansheng/.local/build-arm64/independent-epoch0/aarch64-linux-android/release/libdansheng_ffi.so`
- `C:/Code/dansheng/.local/android-current/arm64-receipt.json`
- `C:/Code/dansheng/.local/android-current/arm64-independent-final-receipt.json`
- `C:/Code/dansheng/platform/android/verification-host/build/outputs/apk/debug/verification-host-debug.apk`
- `C:/Code/dansheng/platform/android/verification-host/build/outputs/apk/androidTest/debug/verification-host-debug-androidTest.apk`

Evidence is frozen under `C:/Code/dansheng/.local/android-current/final-425/`:
before/after inventories, source delta, exact commands, Cargo/Gradle logs, test
source hashes, APK/native hashes, installed-device identity, copied receipts and
`arm64-comparison.json`. The unmodified instrumentation output is
`C:/Code/dansheng/.local/android-current/final-425-native.log`.
`shared-package-android.json` now records this actual 425 execution, not reuse of
the earlier failing library. The old failures/SQLite evidence and old 807 mapped
binaries/receipts remain in `attempt-04bf/`, `final-807/` and
`prefix-map/mapped-807/`. No real campus requests, credentials or physical devices
were used; no commit, cache deletion or binary post-processing was performed.

### Earlier baselines and reproducibility investigation

Only `dansheng-core-api36` / `emulator-5588` was used. Initial `adb devices -l`
reported no devices, and no emulator process was running. The existing dedicated
AVD was started with `Start-Process -WindowStyle Hidden`, using its existing data
and SDK cache, and verified as API 36 / x86_64 before installation. Its existing
exact-alarm grant was read, not changed. No physical device or other AVD was used.

| Layer | Actual evidence |
| --- | --- |
| Toolchain | SDK `C:/Android/Sdk`, NDK `30.0.16138531`, JDK 21.0.12.1, Rust 1.99.1, existing Gradle 9.7.1; Cargo and Gradle offline, two build workers per invocation. |
| JVM | **5/5**, task explicitly rerun, zero failures/errors; `jvm-policy-results.xml`. |
| Full Android baseline | **27/27 in 99.587s**: original 25 plus real JNI plugin-storage migration and original sports package pairing; `instrumentation-full.log`. |
| New shared closed loop | **1/1 in 1.203s**, then output-normalization rerun **1/1 in 1.194s**; `closed-loop.log`, `closed-loop-normalized.log`. These cover one additional distinct case, not two new cases. |
| Baseline runtime identity | Built x86_64 FFI, staged FFI and APK FFI have identical SHA256 `3b0381f0b219cf29edb8f933c485223418a68c253ec3cf3e3a50fbf20eda7ab0`. Device APK hashes matched local APKs. The fixture APK contains unstripped debug FFI; it is not a release-size measurement. |
| First ARM64 release | Cross-compiled in 3m16s; SHA256 `424232a716a28f64dcc65015a98b26b4a51d40f06f06e6e88a8c7c28efc4ee9a`. **Not executed on ARM64.** |
| Independent ARM64 attempts | Fresh target directories completed in 11m49s and 12m02s; the second set `SOURCE_DATE_EPOCH=0`, the first did not. Connector inputs changed after launch, so their differing hashes are **not** valid same-source reproducibility evidence. Targets/caches are retained. |
| Real service / identity | No campus requests, real credentials, real login, booking or cancellation. Synthetic identity is never represented as real-school authentication. |

Evidence root: `C:/Code/dansheng/.local/android-current/`. Initial source inventory
is `sources-before.json`; its SHA256 is
`1b948fd45f0ba66aef46a4bdfdeecb2f9488c024798b4b4884620f429451688`.
All 57 release-helper inputs matched that pre-build inventory when the first
ARM64 receipt was written. Their combined source SHA256 was
`88995b91e44e5eb40806918a41465f7d119ac3d119b6a6daf8558514292286a5`.
`baseline-native/arm64-receipt.json` and `arm64-receipt-freeze-proof.json` bind that **baseline**
artifact to those sources; `source_date_epoch` is honestly null. Later
`x86-baseline-freeze.json` identifies changed connector files, and
`inflight-arm64-artifacts.json` records the independent outputs without claiming
a final source receipt. Later source-bound receipts are described below; the
original baseline binary is preserved under `baseline-native/`.

### Frozen-source attempt 04bf: actual native failure retained

The parent froze 57 inputs at
`04bf02709c0cd9ac96f6386659c639012d03dbc68409d5415118e7939fab4d0f`.
`final/build.ps1` checked that fingerprint before and after each build, set
`SOURCE_DATE_EPOCH=0`, used jobs=2, and allowed only one Android Cargo invocation
at a time. Parent Windows test/release processes were left untouched. Neither the
four-file shared fixture nor Kotlin test sources changed for this attempt.

- x86_64 debug FFI: rebuilt Core/Connectors/FFI in **1m39s**, SHA256
  `0ccb3abb8a898a9d62523a92b556eba0df01713fb59df6714846d6fa5fe29fca`.
  Build path: `.local/build-x86_64/x86_64-linux-android/debug/libdansheng_ffi.so`.
  The updated APK's FFI equals these raw bytes, and installed app/test APK hashes
  match the local APKs (`installed-identity.json`, `apk-native-hashes.json`).
- ARM64 release FFI: rebuilt Core/Connectors/FFI in **4m28s**, SHA256
  `bea53dcaba4600d9b505d9463d294a3b5c67a227c8024d49820f7dfab89ea9c9`.
  Build path: `.local/build-arm64/aarch64-linux-android/release/libdansheng_ffi.so`.
  The helper-generated `attempt-04bf/arm64-receipt.json` passed source/binary validation and
  records epoch zero. This library was cross-compiled, **not executed**.
- Actual final native selection: `NativeAbiInstrumentationTest` (7 tests) plus
  `ClosedLoopInstrumentationTest` (1 test), **8 executed / 7 passed / 1 failed in
  46.146s**. Baseline 28 distinct instrumentation cases and 5 JVM cases were not
  relabeled as rerun. Pure Kotlin/browser/Keystore tests were not repeated.
- The shared closed-loop case passed against the new x86_64 SO. Its normalized
  hash remains `556afa430353b2329b39860c1bc7495eb31e758b7dbab04ef69a0a6c8fb91193`.
  `shared-package-android.json` includes this source/binary identity and separately
  states the native suite failure; it is not a claim that all native tests passed.

The migration fixture's `plugins.run` reading `fixture-b/current` returned
`JobNotRunnable` at `NativeAbiInstrumentationTest.kt:124`. Its app-private
synthetic SQLite job `d3632d8a-5126-46bf-8f64-e22b7308f1b6` nevertheless persisted
`state:succeeded,result:{count:0,name:"fixture-b"}`. Source inspection shows that
`plugins.run` creates an immediately due job before calling `run_job`, while FFI's
one-second scheduler can also claim it. The losing synchronous path reports
`JobNotRunnable`; this is consistent with the observed successful persisted job.
The storage transform itself had the expected result. No test retry, null
normalization, success substitution or Rust modification was introduced.

Evidence: `final/native-first-attempt.log`, `final/scheduler-race-report.json`,
`final/storage-failure-jobs.json`, and the synthetic-only SQLite copy
`final/storage-failure-synthetic.db`. This defect was reported to the parent,
which owns the Rust fix. The running ARM64 build finished normally; another
Android Cargo build was not started while awaiting that disposition. All earlier
independent targets are preserved. The subsequent Host-only receipt refresh is
recorded separately below.

### Host-test-only freeze 807: cached validation, no repeated runtime

The release-helper fingerprint changed to
`8071546cb081b1c3934d66f0d0dec0fd6ee68cfb5e21484a42c766efc68f27db`.
Comparing all 57 input hashes found exactly one difference:
`crates/dansheng-host/src/mcp.rs`. Android Core/Connectors/FFI inputs were unchanged;
the parent identified this as a Host MCP test expectation fix. The four-file
shared fixture is unchanged as well.

Fresh `Before` inventories and actual jobs=2, epoch-zero Cargo invocations were
used for both main Android targets. ARM64 finished in **1.64s** and x86_64 in
**1.93s**, with no application crate compiled: these are **cached validation**,
not two more builds. Both FFI hashes are identical to the `04bf` attempt above.
The root `arm64-receipt.json` was regenerated with the helper and verified against
`807...`; the `04bf` receipt, binaries and failure evidence are preserved under
`attempt-04bf/`.

Android instrumentation was deliberately **not repeated** for this Host-only
change. `final-807/runtime-reuse.json` and `shared-package-android.json` distinguish
the actual `04bf` execution from the `807` source validation and retain the
**8 executed / 7 passed / 1 failed** result, rather than converting the scheduler
failure into success. The normalized shared-package result still matches the
desktop comparison: `556afa430353b2329b39860c1bc7495eb31e758b7dbab04ef69a0a6c8fb91193`.
Commands, hashes and source-delta evidence are under `final-807/`.

The independently populated `.local/build-arm64/independent-epoch0` target then
actually recompiled Core, Connectors and FFI against `807` in **2m26s**, also with
jobs=2 and `SOURCE_DATE_EPOCH=0`. No compiled artifacts were copied between the
two targets. This is an independent **incremental** compilation, not a clean
build. Combined with the main target's actual `04bf` compilation of the same
Android production inputs and its `807` cached validation, this supplies two
actual compilations of the relevant frozen production code without falsely
counting a cache hit as another compilation.

| Unmapped historical ARM64 artifact (preserved snapshot) | SHA256 |
| --- | --- |
| `.local/android-current/prefix-map/unmapped/main.so` | `bea53dcaba4600d9b505d9463d294a3b5c67a227c8024d49820f7dfab89ea9c9` |
| `.local/android-current/prefix-map/unmapped/independent.so` | `cedbc53df4c0483b14932dcbb46892911426cd6408efb04f20cf30f35fe03c43` |

Both are ELF64 little-endian AArch64 and **16,297,264 bytes**, but are **not
byte-identical**. Their then-generated source/binary receipts are preserved under
`prefix-map/unmapped/`; they do not claim stable native paths and do not qualify
as the later mapped release receipts.
Neither ARM64 artifact was executed. Read-only ELF analysis found differences in
`.rela.dyn`, `.rodata` and `.text`; the libraries contain different absolute
target paths to QuickJS-generated `quickjs.c`, `dtoa.c`, `libregexp.c` and
`libunicode.c`. This identifies a concrete build-path dependency, but does not
prove it is the only cause. No binary normalization, stripping workaround,
compiler flag change or additional rebuild was used to manufacture equality.
Evidence: `final-807/arm64-comparison.json`, `final-807/elf-diff.json` and the
reusable read-only `final-807/compare-elf.cjs` inspection script.

### Native path mapping: two actual ARM64 rebuilds match (807 history)

Rust source remained the same 57-file `807...` fingerprint. Read-only analysis
of the old pair found 52,519 changed dynamic relocations: location/type remained
the same, and their new addends referenced matching normalized `.rodata` strings.
LLVM decoded all 24,435 changed instruction words as `add` or `adrp`, with no
opcode/register-shape changes after ignoring address immediates. This was strong
structural evidence for a path/layout cause, not a substitute for a real rebuild.
Details remain in `final-807/path-difference-analysis.json`.

The parent-owned `scripts/build-android-release.ps1` was then run serially for
both existing targets with jobs=2, `SOURCE_DATE_EPOCH=0`, and target-specific
`CFLAGS_aarch64_linux_android` from `Get-DanshengNativePrefixFlags`:
`-ffile-prefix-map=<absolute target directory>=/dansheng-build`.
These are independent existing caches, not clean builds; `-Independent` was
correctly omitted because that switch requires a new empty directory. Native C
dependencies and the dependent Rust Core/Connectors/FFI actually recompiled in
both targets. No compiled objects were copied between them.

The first mapped launch failed because cc-rs's default whitespace parsing passed
the helper's outer quotes literally to Clang. The failure was recorded rather
than treated as a hung build. Local cc 1.11 documentation identifies
`CC_SHELL_ESCAPED_FLAGS=1` as its shlex parsing switch; setting it in the invocation
environment fixed the argument transport. The parent also added that setting and
restoration to the public build scripts. The retained failure log is
`prefix-map/main-quoted-flags-failure.log`.

Successful actual builds took **3m25s** (main) and **3m26s** (independent). Both
unmodified compiler-produced files are **16,297,264 bytes**, ELF64 little-endian
AArch64, with the exact same SHA256:

`73f6d93fd2c00310d4fc14ce2ff877946c79944b2c915fd6a9f0f0f2f86b0f13`

These 807 artifacts are now preserved as historical snapshots:

- `C:/Code/dansheng/.local/android-current/prefix-map/mapped-807/main.so`
- `C:/Code/dansheng/.local/android-current/prefix-map/mapped-807/independent.so`

Both contain the same `/dansheng-build` QuickJS C paths and no original target
directory strings. Their receipts, now archived in `prefix-map/mapped-807/`,
passed helper validation for 807 and
record `source_date_epoch:"0",native_source_prefix:"/dansheng-build"`.
`prefix-map/comparison.json` checks the full raw byte arrays and SHA256, not a
normalized or stripped binary. No artifact path replacement or binary
post-processing was performed. The mapping rebuild eliminated the observed
cross-target difference; the old unmapped outputs remain historically different.

These ARM64 artifacts were **not executed**. x86_64 remained exactly
`0ccb3abb8a898a9d62523a92b556eba0df01713fb59df6714846d6fa5fe29fca`;
its actual **8 executed / 7 passed / 1 failed** evidence and passing same-package
normalized result were retained without another runtime or pure Kotlin test run.
That 807 reproducibility result did not resolve the separately reported scheduler
race; the later unchanged 425 native regression above now passes after the parent
fixed it. Build commands, source inventories, script hashes, logs, object/ELF path
checks and comparison results are retained under `prefix-map/`.

Reproducible commands and full logs are retained in `build-native.ps1`,
`build-apk.ps1`, `invoke-gradle.ps1`, `invoke-fixture-build.ps1`, `run-device.ps1`,
`verify-apk-identity.ps1`, their adjacent logs, and `device-commands.log`.
The first Gradle launch failed before compilation because nested `pwsh -File`
split the drive-qualified `-P` argument. Passing the argument array within a
child script fixed that launcher issue; the failure log is preserved. No Rust
fix or production adapter change was needed. Baseline APKs and their original
identity records are retained in `baseline-apks/` before later test APK updates.

### Real JNI private-storage version and rollback fixture

`NativeAbiInstrumentationTest.testPluginStorageMigrationRestartRollbackAndSnapshotRestoreThroughJni`
installs a synthetic JS package and writes distinct state through QuickJS for two
synthetic accounts. A package upgrade applies `rename_key`, `patch_object`,
`set_default` and `delete_key` through the actual native SQLite migration engine.
It checks the SQLite file header, closes/reopens the JNI engine, verifies the
persisted schema and a snapshot containing two scopes/four entries, then rolls
back the package. Enabling the old version correctly returns
`PluginStorageVersionMismatch`; explicit snapshot restore recovers both original
account states. Restoring forward via the recovery snapshot preserves a later
edit to only one account. No database mutation is substituted for the public JNI
operations, and no browser/platform port is required.

### Same-package Android / Windows closed-loop contract

The fixed package `plugins/fixtures/closed-loop` has ID `fixture.closed-loop`.
Its four original files are copied byte-for-byte into verification APK assets;
the instrumentation asserts their inventory SHA256:
`eb037c94a2bd146d0c7d50ec098597e99ba27f2c9ea7852f6bd70e1ec5b6bc1a`.
The inventory uses ordinal filename order, lowercase file SHA256, two spaces,
filename, LF; the aggregate hashes UTF-8 bytes with no BOM. No manifest/origin
rewriting, fake host storage, or owner-side source insertion is used for this case.

`ClosedLoopInstrumentationTest.testSamePackageNativeHttpAuthStorageSourcesUiAndReopen`
exclusively binds the Android guest's own `127.0.0.1:19765` and fails if occupied;
it never terminates a port owner. With input `{"account_id":"fixture-account"}`,
`sync` first calls real `auth.status/requireLogin`, returns `auth_required` and
makes zero HTTP calls. The trusted test host installs the public synthetic bearer
for that exact account/origin with `persist:false`; verification remains
`local_credentials_only`. Actual Rust Native HTTP then makes exactly one GET
to `/fixture`, and the local server checks method/path/synthetic Authorization
without logging headers. The plugin itself performs private storage,
`sources.upsert/query` and `ui.publish`. `readCache`, owner source reads and owner
`ui.get` match after an engine close/reopen, while the in-memory credential is gone.
No security policy, WebView cleartext policy or core transport is relaxed.

The common output is `{sync,cache,source,ui}`, dropping only the core source row's
`updated_at`. Recursively ordinal-sorted, compact UTF-8 JSON without a trailing
newline has SHA256
`556afa430353b2329b39860c1bc7495eb31e758b7dbab04ef69a0a6c8fb91193`.
`closed-loop-contract.json`, `closed-loop-expected-hashes.json` and
`shared-package-android.json` contain exact inputs, response JSON, four-file
inventory, actual normalized output and per-layer hashes for parent comparison.
Desktop release CLI/IPC/MCP execution is parent-owned; Android does not implement
MCP and does not claim another principal may read plugin-private UI.

The earlier sports-pair fixture and `paired-package-contract.json` are retained
as separate evidence. That case uses the original sports package but explicitly
performs source ingestion as trusted owner; it is **not** the new closed-loop
package acceptance test and does not imply production desktop sports support.

The independent Gradle build lives in `platform/android`; it does not depend on
Flutter, the desktop host, Node or a bundled Chromium runtime. The adapter uses
the Android system WebView. `plugins/fudan-sports` contains the school endpoints,
form formats, typed data, selection order, timing and retry policy. Generic Kotlin
contains no Fudan URLs or sports policy. Reference material is read-only.

## Integration contract

`include/dansheng.h` is the source of truth for ABI v1. `NativeCore`/`dansheng_jni.c`
wrap async open/request/poll/cancel/close, and the two platform queue functions.
JNI copies UTF-8 bytes, consumes operation buffers once and calls `dansheng_free`
for every returned buffer, including platform buffers. It never uses modified
UTF-8 or treats engine/operation IDs as pointers. Native status errors throw a
fixed message; payloads never enter logs. Poll all created operations, including
cancelled operations and close. Cancellation does not undo a submitted write.

The trusted embedding opens a private app data directory and advertises only
`BrowserDispatcher.capabilities` while its `PlatformPump` is running:

```json
{"data_dir":"/private/app/files/core","platform_capabilities":["browser.open","browser.navigate","browser.login","browser.close","browser.request","browser.write","browser.evaluate"]}
```

Start `PlatformPump(engine, BrowserDispatcher(browser)).start()` on the same engine.
The pump uses exactly the current platform envelope:

```json
{"id":"123","capability":"browser.request","input":{"principal":{"id":"plugin:official.fudan-sports","kind":"plugin"},"grant":{"capabilities":["browser.request"],"account_ids":["account-a"],"origins":["https://booking.fudan.edu.cn"],"expires_at":null},"input":{"account_id":"account-a","session_handle":"opaque-host-handle","url":"https://booking.fudan.edu.cn/reservation/api/topic/resource-list?id=48","method":"GET","transport":"fetch","deadline_epoch_ms":1999999999999}}}
```

Only the C queue supplies principal/grant metadata. The adapter enforces capability,
account, origin and expiry itself; it never reads trusted identity from nested
plugin parameters. Responses match the string ID and use `result` or `error`;
the ABI respond function receives the numeric ID. Stop the pump before engine
close; the host must also revoke/close WebViews and cancel active work. A request
already dispatched when the queue is cancelled may still have an external effect.

Browser operations:

| Operation | Input / result |
| --- | --- |
| `browser.open`, `browser.login` | `account_id,url`; explicitly visible login, then verified opaque session. Opening is never silent login. Both require `browser.login` grant. |
| `browser.navigate` | `account_id,session_handle,url`; same authenticated origin only; navigation is asynchronous and returns `navigating:true`. |
| `browser.close` | `account_id,session_handle`; revoke and asynchronously clear the account profile. |
| `browser.evaluate` | Only named `session.status` and compatibility `session.requireLogin` operations. No plugin-provided JavaScript/DOM/cookie access. Login also checks `browser.login`. |
| `browser.request` | `account_id,session_handle,url,method,transport,headers?,body?,form_fields?,deadline_epoch_ms,mutation_key?`; bounded current-document fetch/XHR. POST additionally requires declared/granted `browser.write`, plus concrete host approval. |

Core's original `auth.status` is its native HTTP credential store, not the Android
page session. This plugin deliberately uses `browser.evaluate(session.status)`
and `browser.login` (compatibility fallback to the named evaluate operation).
Do not synchronize cookies/passwords into Rust or the JS runtime to make native
HTTP authentication appear equivalent. Package metadata `platform-support.json`
declares `browser:nativewebview`, `supportsAndroid:true`, `supportsDesktop:false`;
it is separate from manifest v1. Desktop returns `CapabilityUnavailable`.

## Required trusted host ports

`VisibleLoginPort.show(account,url,webView,complete)` must attach that same WebView
to visible UI, let the user complete SSO/2FA, and perform a read-only identity probe
that verifies the logged-in account, not just a cookie or URL. Only then complete
with the verified account ID. No password is accepted by any plugin API. The
library has no school-specific identity endpoint; that verifier is a production
UI/connector integration responsibility. Login is bounded to 50 seconds. The
verification host explicitly proves a synthetic fixture identity only.

`MutationAuthorizer.allowed(principal,account,request)` is a trusted host callback,
not a JSON approval flag. Default production behavior must deny absent concrete
user authorization. The embedding must match URL/form against the approved
account, action, task, dates, periods, court choices and deadline, and **atomically
claim `mutation_key`** to exclude duplicate/concurrent dispatch. It must persist
in-flight uncertainty across crashes and reconcile before permitting a new claim.
Never accept a broad capability or caller-supplied `approved:true` as approval.
`PersistentMutationGate` supplies a durable, hashed-key duplicate guard around
that host approval predicate. A claimed key remains uncertain across object/process
recreation; only host-only authoritative-absence reconciliation may clear it.
The verification host approves synthetic fixture account requests only and blocks
all network loads. This is not a production consent implementation.

`WakeExecutionPort` reloads the core/job and current grants in Application startup,
checks active account and job owner, atomically claims a core job, and completes
asynchronously. `AndroidWakePort.schedule(WakeSpec)` is called by the trusted host
after consuming the plugin's `native_wake_at`/`deadline_at` result, or through the
new generic `JobWakeDispatcher` below. The core job's
`run_at` is the browser preload stage, while native wake is earlier. The host must
keep the core scheduler/pump alive until the task deadline, rather than treating
the prewarm alarm as a reservation or finishing after one JS stage.

These are explicit ports; the production glue below supplies job wake mapping.
Generic core/FFI/Desktop
files are owned by other workers and are not modified here. No platform event
response signature is missing from the current header. Further auth or wake core
methods should route the same mediated envelope; do not guess new ABI callbacks.

## Session and lifecycle guarantees

Use a dedicated WebView process/profile for this adapter. Android's default
CookieManager/WebStorage are process-global; a production app must not share
that profile with unrelated account WebViews. The adapter intentionally supports
one account at a time. Cross-account/forged/stale handles fail. A failed login or
logout revokes handles before aborting in-flight operations, destroys the page,
clears WebStorage/cookies, waits for clearing completion and only then permits
another account. No session survives process death by invention. Account switching
must call `cancelAccount(oldAccount)` and `browser.logout(oldAccount)` first.

Page requests run through the current page's `window.fetch`, `XMLHttpRequest` and
`FormData`, preserving installed WAF wrappers/dynamic suffixes. The host does not
cache pristine browser constructors or synthesize signed URLs in Rust. No
`addJavascriptInterface` exposes native authority to a remote document. Native
polling reads only a random request mailbox. Navigation, render-process death,
logout and a deadline terminate local waiting. A POST timeout/network error,
unparseable response, redirect or lost page is `NeedsReconciliation`, never an
automatic write retry. A GET WAF response requires page/visible recovery;
no native HTTP substitute is attempted. Response headers and URL query/fragment
are not exported; school-specific data returned by the plugin is whitelisted.

Wake schedules persist app-privately with account, owner, absolute UTC epoch,
deadline and unique generation. PendingIntents have stable job/generation URIs,
are immutable and non-exported. Wrong owners cannot cancel another job. Stale
generations, missing account, expired work, missing runtime and revoked grants do
not execute. A durable claim prevents re-delivery from silently replaying work.
Claimed work after process restart requires reconciliation and visible resumption.
Boot/package replacement re-arms future unclaimed subscriptions and never starts
a dataSync foreground service directly. Claimed/missed wakes require visible resumption.
Missing exact-alarm permission is `ExactAlarmPermissionRequired`; there is no
silent inexact fallback. Background foreground-service denial requests user
resumption. START_NOT_STICKY, bounded wakelock, foreground notification, OS timeout,
account/grant rechecks and both wall and monotonic deadlines bound execution.

## Retained plugin policy

| Option | Default |
| --- | ---: |
| `nativePrewarmMs` | 300000 (5 min) |
| `browserPreloadMs` | 60000 (60 s) |
| `firstShotDelayMs` | 300 |
| `windowMs` | 300000 (5 min) |
| `scheduleRefreshMs` | 15000 |
| `throttleBackoffMs` / `errorBackoffMs` | 800 / 800 |
| `roundPauseMs` | 1200 |
| `requestTimeoutMs` | 8000 |
| `maxReservationSlots` | 3 |

Release timestamps must carry an offset (`+08:00` for Fudan) or `Z`; device timezone
does not reinterpret them. The reference's default release helper uses two days
before target at 07:00:01 China time; callers currently supply explicit release_at.
Plans retain selected time order and court preference order, refresh missing
period IDs, prefer the latest calendar ID over a saved one, allow saved IDs if
calendar is unavailable, remove successful slots, stop on existing reservation,
and retry `notOpen` within the window. Native reference code had a separate
15-minute stale-alarm cutoff; **it is not the execution window**. This adapter
consumes the explicit 5-minute plugin deadline and never extends it to 15 minutes.

The plugin is a persisted bounded state machine: preload, first shot, one court
attempt, continuation job. It does not hold a QuickJS action for five minutes.
Current core scheduler granularity and OS wake/WebView delays can add latency to
each continuation; 300 ms is the retained target, not a measured timing guarantee.
Request timeout is capped by the native transport's 8-second maximum. The 800 ms
error option is retained for compatibility, but **uncertain writes never use that
retry**; they require read-only reconciliation first. An empty history page does
not prove absence. Positive date/time/court matches can record success, with
explicit user resumption before further work. Cancellation uses freshly read
server flags and original normal/group/third-party form contracts; a cancellation
journal prevents automatic resubmission after an unknown outcome.

## Build and verification

Use JDK 21, Android SDK `C:/Android/Sdk`, NDK `30.0.16138531`, CMake 3.22.1,
Gradle 9.7.1 and AGP 9.3.2 (built-in Kotlin). The installed SDK is API 37; the
verification device is the main worker's disposable API 36 AVD. No Flutter SDK is
needed. Set `ANDROID_HOME`, then from `platform/android`:

```powershell
./gradlew.ps1 :adapter:testDebugUnitTest :adapter:assembleDebug :verification-host:assembleDebug :verification-host:assembleDebugAndroidTest --console=plain
```

From the repository root, development-only Node runs synthetic tests; it is not
included in released artifacts:

```powershell
node --test plugins/fudan-sports/tests/*.test.mjs
```

JNI is opt-in. Supply a directory containing `arm64-v8a/libdansheng_ffi.so` and
`x86_64/libdansheng_ffi.so` built by the FFI owner:

```powershell
./gradlew.ps1 '-PrustJniDir=C:/absolute/prebuilt-jni' :verification-host:assembleDebug
```

The fixture host offers a separate Native ABI smoke button; its normal browser
tests do not pretend that Rust is linked. CMake includes the shared header directly.
For an x86_64-only verification build add `-PandroidAbis=x86_64`; the default ABIs
are arm64-v8a and x86_64. Native-enabled test builds compile the C ABI platform
round trip, the real QuickJS sports read, owner continuation chain and synthetic
write-policy tests from `src/nativeTest`. Only the verification APK
stages the JS package as assets; the generic adapter AAR has no school package.
The fixture page may use the plugin-declared origin as a base URL for same-origin
checks, but all network loads are blocked and the document is bundled HTML.
Do not copy reference build products. Store generated JNI staging under
`platform/android/build` if staging is needed for this worker's build.

Install/run only the designated disposable emulator; never use unqualified adb:

```powershell
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 install -r verification-host/build/outputs/apk/debug/verification-host-debug.apk
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 install -r verification-host/build/outputs/apk/androidTest/debug/verification-host-debug-androidTest.apk
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 shell am instrument -w org.dansheng.verification.test/org.dansheng.verification.VerificationRunner
```

Verification status is reported separately for JVM policy tests, mocked JS/page
tests, Android build, emulator WebView/lifecycle tests, native cross-compilation
and native ABI execution. No real-service login/reservation/cancellation tests
are authorized or performed. A synthetic WAF fixture proves current-page API
behavior; it does not prove compatibility with the live school's WAF.

Platform behavior references: [Android WebView API](https://developer.android.com/reference/android/webkit/WebView),
[exact alarms](https://developer.android.com/develop/background-work/services/alarms),
[foreground-service restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).

Built-in Kotlin source directories follow the [AGP migration contract](https://developer.android.com/build/migrate-to-built-in-kotlin).

## Encrypted Android vault

`KeystoreVault` implements `vault.set/get/delete`: input `{key,value}` for set,
`{key}` for get/delete; get returns `{value}` or `{value:null}` if absent. Values
preserve their JSON type (including core-exported session arrays and opaque strings).
`CompositeDispatcher(BrowserDispatcher(browser), KeystoreVault(context))` combines
capability declarations for the platform pump. Core-internal vault calls use the
raw `{key,value}` shape, not browser principal/grant mediation. Accept that shape
only from the trusted core C queue; never expose this dispatcher to plugins or IPC.
If an explicit principal envelope is supplied, only the owner is accepted. Plugins
are never allowed to retrieve raw credentials, regardless of supplied JSON.
The core must namespace keys by its own account/service identity; it must not pass
caller-controlled identities as trusted vault keys.

The vault uses an AndroidKeyStore AES-256 key, randomized 12-byte GCM IV, 128-bit
authentication tag, and hashed-key AAD binding. Only versioned encrypted blobs and
hashed key names are persisted in app-private `dansheng-vault-v1` preferences.
Disable app backup or exclude that file. The AES key is non-exportable through
this interface; hardware backing depends on the device. Key loss/invalidation,
corruption or moved ciphertext fails closed, without plaintext or ephemeral fallback.
Encrypted persistence does not assert that restored WebView cookies prove a current
authenticated identity; the host still verifies account/session ownership.

To verify actual process restart persistence (synthetic values only):

```powershell
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 shell am instrument -w -e vault_phase seed org.dansheng.verification.test/org.dansheng.verification.VerificationRunner
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 shell am force-stop org.dansheng.verification
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 shell am instrument -w -e vault_phase check org.dansheng.verification.test/org.dansheng.verification.VerificationRunner
```

The check phase verifies the saved value in a different process, deletes it, and
verifies absence. It never prints the value. Platform reference:
[Android Keystore](https://developer.android.com/privacy-and-security/keystore).

## Observed verification in this checkout

On 2026-11-05 local time (2026-11-06 UTC):

The table records the successful 24-test platform run. The later parent Engine
wake wiring is verified separately by the real native wake test/suite below;
that targeted run must not be represented as a new full 25-test platform run.
Historical failures and binary/source identities remain below for audit.

| Layer | Observed result |
| --- | --- |
| JVM policy | 5 passed: account handles/revocation, grants/origins/expiry, wake ownership/generation/deadline, monotonic rollback and prepare/execute separation. |
| Development JS and mocked page | 21 passed, using Node only as a development test runner. |
| Android build | Standalone Kotlin host/library built; native-enabled x86_64 host and AAR linked/packaged with NDK 30. |
| Dedicated API 36 emulator | 24 instrumentation tests passed on **emulator-5588 only** (7 browser, 6 generic job bridge, 4 native/QuickJS, 3 vault, 4 wake/mutation lifecycle). |
| Native closed loop | open/request/platform poll/respond/poll/free/close passed; real QuickJS installed/ran `venues` through JNI into a bundled page whose network loads were blocked. |
| Keystore process restart | Seed PID 6797; app force-stopped; read/delete/absence PID 6838; both phases reported `passed`. |
| ARM64 | JNI C passed NDK aarch64 syntax checking; an ARM64 Rust library/build and ARM64 execution were **not** performed by this worker. |
| School service | **Not contacted.** No real login, reservation or cancellation, and no claim of live WAF compatibility. |

The x86_64 Rust library was supplied by the main worker at
`target/x86_64-linux-android/debug/libdansheng_ffi.so` and staged only under
`platform/android/build/rust-jni/x86_64`. This worker did not edit Rust,
FFI headers, desktop code or examples; later native verification rebuilds the
parent's sources with `--locked` in Android-owned `build/rust-current`. Debug stripping is separate from
the small JNI adapter; this is not a measured release artifact size.

Native build used:

```powershell
./gradlew.ps1 '-PrustJniDir=C:/Code/dansheng/platform/android/build/rust-jni' -PandroidAbis=x86_64 :adapter:testDebugUnitTest :adapter:assembleDebug :verification-host:assembleDebug :verification-host:assembleDebugAndroidTest --console=plain
```

Outputs: `adapter/build/outputs/aar/adapter-debug.aar`,
`verification-host/build/outputs/apk/debug/verification-host-debug.apk`, and
`verification-host/build/outputs/apk/androidTest/debug/verification-host-debug-androidTest.apk`.
Inspectable local verification output is under `platform/android/build/`:
`emulator-verification.txt`, `js-verification.txt`, `vault-restart-seed.txt`,
`vault-restart-check.txt`; JVM XML is under `adapter/build/test-results/`.

The disposable host's exact-alarm app-op was explicitly allowed for actual alarm/
foreground-service testing. Permission absence is handled by the adapter and is
also an available fixture test branch. These tests do not establish OEM battery
behavior, production identity-verifier integration, production consent UI, or
sub-second scheduler accuracy. Those host ports and timing limits remain explicit.

## Generic production job wake bridge (bounded follow-up)

The parent core can advertise/use these platform capabilities without changing ABI:

| Capability | Trusted input | Result |
| --- | --- | --- |
| `jobs.wake.schedule` | `job_id,run_at,prepare_at?,deadline_at,account_id?,precision?` | `job_id,scheduled,precision,exact,wake_at,run_at,deadline_at,capabilities` |
| `jobs.wake.cancel` | `job_id,account_id?` | `job_id,cancelled:true` |
| `jobs.wake.status` | `{}` | current `exact_available,inexact_available,inexact_background_fgs_guaranteed,exact_permission_requires_visible_ui,max_foreground_window_ms` |

Times are RFC3339 absolute timestamps. `precision` is `exact` by default; explicit
`inexact` uses `setAndAllowWhileIdle`. Missing exact permission returns
`ExactAlarmPermissionRequired`; no silent fallback or synthetic permission claim.
Inexact delivery can be delayed by Android, and does not grant a background FGS
start exemption. A denied FGS start invokes the trusted resume callback.

`JobWakeDispatcher` accepts the raw internal core platform input (like vault), or
the existing `{principal,grant,input}` envelope. Never expose the raw internal
port directly to plugins/IPC. For mediated calls it checks capability, expiry,
job owner and account scope. Scheduling resolves **trusted `jobs.status`**
through `JobBindingResolver`: owner/account/run/deadline cannot be supplied or
overridden by plugin JSON. Optional account IDs are checked against that binding;
accountless generic jobs remain accountless. No school IDs, endpoints or strategies
exist in the bridge. `prepare_at <= run_at < deadline_at` is required. Raw internal
cancellation uses the previously trusted persisted subscription binding, so it
still removes the alarm after core deletes the job row. Mediated cancellation
still resolves and checks the caller's owner/grant. Repeated cancellation is idempotent.

Install these production classes from the application's `Application.onCreate`:

```kotlin
val client = NativeCoreJobClient { ready ->
    // Your worker initializer opens/returns the private engine and starts its pump.
    // This is asynchronous and must supply Result<Long>; no UI-thread core opening.
    openOrGetEngineOnWorker(ready)
}
val worker = CoreJobWakeHost(client,
    accountNow = { currentAccountId },
    permissionNow = { spec -> currentHostGrantAllows(spec.jobId, spec.owner, spec.account) },
    onResumeRequired = { spec, reason -> publishVisibleResumeRequest(spec.jobId, reason) })
AndroidRuntime.execution = worker
val ports = CompositeDispatcher(BrowserDispatcher(browser), KeystoreVault(this), JobWakeDispatcher(this, worker))
// Open core with ports.capabilities, then start PlatformPump(engine, ports).
AndroidWakePort(this).restore()
```

The three application callbacks are real host responsibilities, not provided
synthetic authentication/permission implementations. `CoreJobClient` is an explicit
alternative port if a host already has its own core transport. It returns the
standard core Response envelope for `jobs.status`/`jobs.run`; `NativeCoreJobClient`
implements nonblocking ABI polling on workers. The app owns the engine/pump lifetime.

At the actual alarm, the existing receiver/FGS claims the persisted subscription
generation once. `CoreJobWakeHost` initializes the engine at `prepare_at`, re-reads
the job and current host authorization, waits until `run_at`, rechecks again, and
requests `jobs.run`. It does not bypass core's persistent atomic job claim, current
plugin grants or mutation authorization. If core's running scheduler wins a claim,
the worker follows job status instead of submitting another execution. Cancellation
stops local timers and cancels the native wait; it never asserts an external write
was undone. Expired, changed-owner, changed-account, changed-time or revoked work
does not run. Wall/monotonic FGS bounds and OS timeouts still apply (foreground
window is bounded to ten minutes). Keep the pump alive for any core execution
already in progress; never close the engine merely because a platform response ended.

Subscriptions persist app-privately, including wake time, execution time, deadline,
precision, owner/account and generation. `RestoreReceiver` on boot/package update
re-arms future unclaimed subscriptions; a missing runtime retains them, revoked
account/grant or lost exact access requests visible attention, and expired work
is removed. Claimed or missed subscriptions require reconciliation/visible resume.
No boot receiver directly starts a dataSync FGS. The application must install
`AndroidRuntime.execution` before restore. Synthetic tests exercise restore logic;
an actual OS reboot/OEM battery-policy test is not claimed.

The sports plugin now passes its retained native-prewarm option as generic
`prepare_at` on continuation schedules. Only the plugin computes that sports timing;
the Android bridge treats it as an absolute generic job time. The parent core now
calls the new mediated platform methods when persisting/cancelling jobs and when
disabling plugins. The native end-to-end verification below exercises that wiring;
this worker has not modified core sources.

For real exact alarms on Android 12+, a production UI must show the system
`ACTION_REQUEST_SCHEDULE_EXACT_ALARM` permission screen when needed and re-read
`canScheduleExactAlarms()` on return. Never auto-grant or invent success. The
verification emulator's app-op was explicitly allowed for actual alarm tests;
the provider reports the real OS value. The exact test fails with a clear grant
instruction if unavailable; explicit inexact/cancel/expired fixtures do not need it.

Sports uncertainty hardening in this follow-up: XHR onload `status=0`, timeout,
network loss, abort and POST body interruption preserve `NeedsReconciliation` at
the browser provider. The plugin journals pending writes and never resubmits on
uncertainty. It queries appointment-list through a **read-only** reconciliation
action; a still-valid lease can also attempt that query immediately. If the core
closes a lease upon a host `NeedsReconciliation`, the exact branded host error is
re-thrown without further calls on that lease (which would return `Cancelled`).
The already-persisted pending journal survives for a fresh `reconcile` action. Positive
confirmation enters `reconciled_requires_user_resume`, which `tick` will not resume
automatically. Write-side 412 stays uncertain without proven pre-execution rejection;
it is never used to retry a status-0 write.

The six job-bridge instrumentation cases use a mocked core client with **actual**
AlarmManager/foreground-service delivery. They verify initialization before run,
no early/duplicate `jobs.run`, cancellation (including after deleting a core row),
expired skip, account/owner/grant/time binding, persisted future restore, claimed
restore requiring reconciliation, and following an existing core claim. Parent
core-to-platform scheduling is now additionally exercised by the native integration
test below, using the parent's real Engine wiring.

## Real Rust sports deferred-authority regression

`NativeAbiInstrumentationTest.testOwnerSportsCreatePreloadAndDeferredContinuationWithoutPluginSelfGrants`
uses the real Android Rust core and QuickJS plugin runtime through JNI. It installs
the unmodified sports package in an isolated app-private core directory, grants only
the package's operational capabilities/accounts/origins, and deliberately grants no
`plugin:<id>:tick` or `execute:<id>:tick` capability to the plugin principal itself.

The owner calls the actual sports `schedule` action with default timings. The
native core's one-second scheduler executes the preload job. The fixture provides
a synthetic calendar through its current page fetch wrapper; WebView network loads
are blocked and the host's write authorizer separately denies every write for this
case. Assertions cover the initial job's owner/account, successful `preloaded`
result, exactly one next `tick` at release+300ms, the continuation's original owner
and account/task binding, and cancellation through the plugin's own `stop` action.
The page-call record must contain only GET/fetch operations. No reservation request
is submitted. This case exercises actual `ctx.jobs.schedule`/`ctx.jobs.cancel`
authority propagation, beyond the mocked core wake tests.

Run the regression on the designated emulator after building/installing native APKs:

```powershell
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 shell am instrument -w -e class org.dansheng.verification.NativeAbiInstrumentationTest#testOwnerSportsCreatePreloadAndDeferredContinuationWithoutPluginSelfGrants org.dansheng.verification.test/org.dansheng.verification.VerificationRunner
```

To rebuild the parent's current Rust sources without writing the shared root
target directory or changing Cargo.lock, use an isolated output directory:

```powershell
cd C:/Code/dansheng
. ./scripts/android-env.ps1 -Architecture x86_64
$env:CARGO_TARGET_DIR='C:/Code/dansheng/platform/android/build/rust-current'
cargo build --locked --target x86_64-linux-android -p dansheng-ffi
Copy-Item -LiteralPath platform/android/build/rust-current/x86_64-linux-android/debug/libdansheng_ffi.so -Destination platform/android/build/rust-jni/x86_64/libdansheng_ffi.so
```

Only build output under the Android-owned ignored build directory is changed;
core, FFI, connectors and desktop sources remain owned by the parent/other workers.

The new case was first run against the previously staged Android core and reproduced
`PermissionDenied` during sports creation. A fresh `--locked` x86_64 core build
under `platform/android/build/rust-current` then exposed an earlier read-only-call
failure: `venues` returned `NeedsReconciliation` before creation could be exercised.
At that snapshot, core used `remote_write.then_some(MutationGuard { ... })`;
`then_some` eagerly constructs/drops the armed guard even when false. Its Drop
marks a read-only invocation uncertain. The owner needs lazy
`remote_write.then(|| MutationGuard { ... })`; no core source was edited by this worker.

Evidence is in ignored build output: `sports-continuation-old-core.txt`,
`sports-continuation-current-core.txt`, `sports-continuation-core-build.json`
(binary/source/lock SHA256 identities). This follow-up is an actual Rust regression
case, not a mock pass. A successful create/preload/continuation result must only be
claimed after the parent's core guard fix is rebuilt and the same case passes.
That guard was subsequently fixed by the parent; the successful native verification
and additional sequence/write-policy changes are recorded below.

Caller isolation contract for that regression: effective host capabilities are
the intersection of the plugin grant and an original non-owner UI/MCP caller's
grant; owner intrinsic authority remains unchanged. Root `input.account_id`
further restricts the effective account set. Plugin storage is namespaced by plugin
and effective account/capability/origin/source scopes derived from caller authority; identical owner,
account and grants must preserve continuation state across `schedule`, `tick` and
`stop`. Changed scopes cannot access the old namespace, whose data is retained.
The sports fixture consistently supplies the same root account in all three phases.
An MCP caller must grant the actual host capabilities used from the manifest,
`jobs.schedule`, and the named child action/execute capabilities. No plugin-self
action grants are introduced to work around deferred caller checks. Parent-owned
core regression tests cover non-owner scope isolation; the Android fixture covers
the real owner sports scheduling path.

After the caller-scope tightening, the core was rebuilt again with `--locked`
(engine SHA256 `2F473C8852A5862BFD8794A086FE8BACED9E7C27B3FBDFA46A96D5A03AC16AE4`,
Android binary `291F1250330F38CE726488B1302085B36CA0DBE24176BFB1CEEB3619E77121F8`).
At that historical snapshot, the real owner regression failed at `plugins.run/venues: NeedsReconciliation`
before reaching creation, because that snapshot still has the eager
`then_some(MutationGuard...)` construction. This is not evidence of a storage-scope
regression or a passing owner continuation. New evidence:
`platform/android/build/sports-continuation-caller-scope-core.txt` and
`sports-continuation-caller-scope-build.json`. No core source was changed here.

## Current write-policy and continuation sequence

The sports manifest declares `browser.write` as well as `browser.request`.
`browser.write` is an additional permission/capability marker; it adds no ctx method
and every POST still uses `ctx.browser.request`. Android checks it before page
dispatch and rechecks it when accepting a response. GET remains read-only.
Concrete user authorization through `MutationAuthorizer` is still required even
when both capabilities are granted. Non-owner UI/MCP callers need the actual
manifest host capabilities and `execute:<plugin>:<action>` for actual writes,
including actions whose manifest falsely claims `mutating:false`. The core owns
that original-caller execution check; no Android fixture bypasses it.

`plugins.run` now creates a durable invocation job while retaining its existing
result payload. Native fixtures therefore select continuations by plugin/action/
task/sequence rather than assuming every job row is a scheduled tick. Known
pre-dispatch denials can be dismissed as waiting-for-approval work. An uncertain
write cannot be dismissed as remote undo, and an unknown prior job for the same
plugin/account blocks further actual writes until trusted owner reconciliation.
Reads and history queries remain available.

Core default dedup intentionally excludes run/deadline times. Sports now persists
`sequence`, `last_consumed_sequence` and a transition record. Every scheduled tick
receives `{account_id,task_id,sequence}`. Initial preload is sequence 1; its next
transition is sequence 2, giving different core job identity even while sequence 1
is running. Old/future sequence values return `stale_sequence` without execution;
missing/noninteger values are rejected. The expected tick marks the local transition
as executing; only creation of a next transition advances the sequence.

The transition is saved as `pending_schedule` before calling `jobs.schedule`.
If a local enqueue response is lost, retrying the same unchanged plan reuses the
persisted sequence and exact scheduling input, so core dedup finds the same job.
It does not bump identity merely to change a retry timestamp. Sequence handling
does not authorize replay of external POSTs: pending write journals and core
`NeedsReconciliation` fences remain authoritative. Pre-sequence queued tasks are
not silently migrated into write execution; stop/recreate them explicitly.

The real Rust owner fixture now asserts preload sequence 1, a separate scheduled
sequence-2 job at release+300ms, stale sequence-1 rejection, original owner/account
and scoped-storage continuity, and cancellation via the sports `stop` action.
The actual native write fixture removes `browser.write` and verifies the page sees
no POST, restores a concrete grant and performs a synthetic XHR, then injects
network loss to check durable uncertainty, refusal to dismiss that job, continued
read access and blocking a later write. All page network loads remain disabled.

Development JS verification now has 21 passing cases, including stable dedup
without run/deadline fields, a lost local enqueue response, stale-sequence rejection
missing write capability, and a late enqueue acknowledgement interleaving where
the child already advanced. A late acknowledgement reloads task state and never
rolls back its sequence/phase or overwrites a user stop. Native binary/source hashes
are in `platform/android/build/sports-sequence-write-core-build.json`.
The full current instrumentation run in `emulator-verification.txt` passed
**24 tests in 60.285 seconds**, including the expanded real Rust uncertainty/
cancellation/read-access assertions. The owner sequence chain is also re-run after
the final late-acknowledgement guard; its result is in
`sports-sequence-final-verification.txt`.

## Real Engine-to-Android wake integration

`NativeAbiInstrumentationTest.testRustScheduleArmsRealWakeAndNativeWorkerRunsThenCancels`
uses a freshly rebuilt Rust library, the real C platform queue, `PlatformPump`,
`CompositeDispatcher`, `JobWakeDispatcher`, `CoreJobWakeHost` and
`NativeCoreJobClient`. Unlike the six original wake fixtures, its core client is
**not mocked**. Only the authenticated remote page is synthetic and network-blocked;
the sports flow explicitly denies POSTs.

Verified assertions:

- A real `jobs.schedule` with no supplied deadline persists `deadline_at` at
  `run_at + 60s`; the Android binding and durable subscription read that exact value.
- Core sends `{principal,grant,input}` through the C queue with the ephemeral
  `jobs.wake.schedule` capability. The Android provider checks that mediation.
- A supported inexact wake is returned as `wake_up.scheduled:true,exact:false`.
  An intentionally unsupported precision returns `wake_up.state:not_armed` with
  `InvalidWake`, while the job remains persisted and can be cancelled.
- A real sports preload arms an exact native alarm. AlarmManager/FGS invokes the
  worker, initialization completes, and the actual `NativeCoreJobClient` submits
  `jobs.run`. The resulting preload schedules a distinct sequence-2 continuation.
- Sports' explicit release+5min deadline stays unchanged, rather than being replaced
  by the generic default. Its owner/account bindings and stored times are checked.
- The sports `stop` invokes real core cancellation and removes the continuation's
  native subscription. `plugins.disable` also cancels a separate pending native
  subscription. Cleanup touches only job IDs created by this fixture.

The targeted integration passed on `emulator-5588` in **11.412 seconds**.
Evidence: `platform/android/build/native-core-wake-integration.txt`.
Fresh binary, Engine and store SHA256 identities are recorded in
`platform/android/build/native-wake-core-build.json`. The complete native test
group also passed **5 tests in 26.146 seconds** against the same build, covering
existing read, continuation and write-policy cases alongside this wake chain;
its output is `native-core-wake-suite.txt`. That group was rerun after limiting
fixture cleanup to its own job IDs; no shared core/FFI sources were edited.

```powershell
C:/Android/Sdk/platform-tools/adb.exe -s emulator-5588 shell am instrument -w -e class org.dansheng.verification.NativeAbiInstrumentationTest#testRustScheduleArmsRealWakeAndNativeWorkerRunsThenCancels org.dansheng.verification.test/org.dansheng.verification.VerificationRunner
```

Exact-alarm availability is read from the real OS; the test fails with a visible
Settings-grant instruction if missing. No phone, campus service, real reservation
or cancellation is used. Actual reboot/OEM battery behavior and recurring-window
timing were not independently exercised by this targeted one-shot wake test.
