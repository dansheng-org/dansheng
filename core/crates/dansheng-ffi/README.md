# C embedding ABI

Build `dansheng-ffi` for a `cdylib` and `staticlib`; include
[`../../include/dansheng.h`](../../include/dansheng.h) from the repository root's
`include` directory. Define `DANSHENG_STATIC` when linking the static library on
Windows. Exported functions use the platform C ABI. No Node.js, Chromium, or UI
framework is embedded.

The FFI is a trusted local embedding boundary using `Principal::owner()`. A desktop
MCP process must instead use the host's authenticated IPC and dedicated MCP token.
Every engine, operation, and allocation is a validated, monotonically assigned
integer handle. None is a Rust object pointer. A global two-thread Tokio runtime
executes requests; C calls return immediately. Rust panics are contained at both
the C entry point and asynchronous operation boundary.

1. Call `dansheng_open` with UTF-8 JSON options and receive an operation handle.
2. Poll it until `DANSHENG_OK`. Decode `{"id":"open","result":{"engine":...}}`,
   or the core error envelope, then free the buffer's allocation.
3. Call `dansheng_request` with a core Request. Poll and free its core Response.
4. Service platform requests on the app's proper UI/browser thread when enabled.
5. Call `dansheng_close` and poll its operation to completion before reopening the
   same data directory. Close invalidates the engine
   immediately and stops its one-second scheduler. Existing request operations
   still need polling and freeing. Already-returned buffers survive engine close.

The options are `{"data_dir":"<private-app-directory>","platform_capabilities":[]}`.
Input buffers must be live and readable for their lengths, and output pointers
must be valid, aligned writable C storage. Inputs are copied before returning.
Outputs are read-only UTF-8 JSON, without trailing NUL. Only
`dansheng_free(buffer.allocation)` releases an output. A second free is rejected.
Do not keep `buffer.data` after freeing. Close completion consumes its operation;
operation polling is single-consumer. The implementation bounds outstanding
operations and allocations at 1024 each, open engines at 128, and JSON at 8 MiB.
The shared Tokio worker runtime is process-lived. Link statically or keep the
dynamic library loaded until process exit; dynamic unloading is not supported.

`dansheng_cancel` stops local waiting and produces a `Cancelled` Response with the
original request id. It cannot cancel close cleanup or an already complete
operation. Cancellation does not undo a stored job or an external side effect;
reconcile before retrying. ABI validation errors return negative status with no
operation. Asynchronous core failures are ordinary core Response errors. An
arbitrary invalid memory address cannot be validated by any C interface; callers
remain responsible for valid pointers while integer handles are always checked.

## Polling platform bridge

Advertise only real capabilities in the open options. With no capabilities the
engine uses `UnavailablePlatform`. `dansheng_platform_poll` returns `PENDING` when
empty or a buffer `{"id":"123","capability":"browser.request","input":...}`.
The input preserves core's `{principal,grant,input}` context; it is not rewritten
by the FFI. It may include secrets, so do not log or export it. Perform browser
fetch/XHR in the authenticated page and supply real status/errors. Do not replace
page requests with native HTTP or manufacture authentication success.

Reply with `dansheng_platform_respond(engine,123,bytes,len)` and the core envelope
`{"id":"123","result":...}` (including null) or
`{"id":"123","error":{"code":"...","message":"..."}}`. One reply consumes
the pending id. The id string in JSON must match the numeric request argument.
Wrong ids, malformed responses, and repeated replies are rejected. The bridge
has 128 pending slots and a sixty-second deadline. Canceled/closed/timed-out calls
invalidate their pending ids. A platform write timeout is an uncertain outcome;
return a reconciliation error and do not blindly retry.

Capability names are generic strings, so `browser.open`, `browser.navigate`,
`browser.login`, `browser.close`, `browser.request`, `browser.evaluate`, and
`notifications.show` share this ABI when core exposes them. Platform events are
polled instead of invoking raw callbacks, allowing Android/JNI to marshal work
onto its UI thread without calling arbitrary C function pointers from Rust.

`cargo test -p dansheng-ffi` checks exported lifecycle/storage persistence,
malformed input and handles, synchronous/asynchronous panic containment,
platform round trips and null results, cancellation and clean close. These are
offline tests; compilation for Android or another target is not a device test.

`tests/smoke.c` also exercises the actual header and shared-library boundary. On
Windows, after building the library, compile it with the local GCC toolchain:

```powershell
gcc -std=c11 -Wall -Wextra -Werror -Iinclude crates/dansheng-ffi/tests/smoke.c -Ltarget/debug/deps -ldansheng_ffi -o target/debug/deps/ffi-c-smoke.exe
target/debug/deps/ffi-c-smoke.exe C:/private/fresh-ffi-test
```

Finish native smoke processes before rebuilding the DLL; Windows locks a loaded DLL.
