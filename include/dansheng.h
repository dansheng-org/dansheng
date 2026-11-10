#ifndef DANSHENG_H
#define DANSHENG_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && !defined(DANSHENG_STATIC)
#define DANSHENG_API __declspec(dllimport)
#else
#define DANSHENG_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ABI v1. C calling convention. All functions are thread-safe; Rust unwinds are
 * caught. Invalid integers are rejected without dereferencing them as pointers.
 * Caller-supplied pointers must reference valid, aligned memory of the declared
 * size for the duration of the call. An arbitrary invalid address cannot be
 * validated by a C ABI. JSON inputs are UTF-8, at most 8 MiB, and copied before
 * return. Inputs need not be NUL terminated. No callback runs on the C thread.
 *
 * This is an embedding API for a trusted local app, using Principal::owner().
 * Do not expose this library directly to untrusted plugins or remote callers.
 * Desktop clients should use the authenticated IPC host instead.
 * The shared worker runtime is process-lived: keep a dynamic library loaded
 * until process exit. Dynamic unloading is not supported.
 */
enum dansheng_status {
    DANSHENG_OK = 0,
    DANSHENG_PENDING = 1,
    DANSHENG_INVALID_ARGUMENT = -1,
    DANSHENG_INVALID_HANDLE = -2,
    DANSHENG_PANIC = -3,
    DANSHENG_LIMIT = -4,
    DANSHENG_ALREADY_COMPLETE = -5,
    DANSHENG_NOT_CANCELLABLE = -6
};

typedef struct dansheng_buffer {
    uint64_t allocation;
    const uint8_t *data;
    size_t len;
} dansheng_buffer;

/* Start async open. options: {"data_dir":"absolute/path",
 * "platform_capabilities":["browser.request","notifications.show"]}.
 * Omit capabilities for an explicitly unavailable platform. Success sets a
 * nonzero operation handle. Poll result is the core Response envelope:
 * {"id":"open","result":{"engine":123}} or {"id":"open","error":...}.
 * The embedding must use a private app data directory, not a shared directory.
 * Open starts a one-second scheduler while the engine is alive.
 */
DANSHENG_API int32_t dansheng_open(const uint8_t *options, size_t len,
                                  uint64_t *out_operation);

/* Start a core Request: {"id":"opaque","method":"sources.query","params":{}}.
 * Result is the matching core Response. Unknown/malformed handles are rejected;
 * malformed JSON/envelopes return INVALID_ARGUMENT without creating an operation.
 */
DANSHENG_API int32_t dansheng_request(uint64_t engine, const uint8_t *request,
                                     size_t len, uint64_t *out_operation);

/* Nonblocking poll: PENDING clears out_buffer. OK consumes the operation once
 * and transfers a read-only byte buffer whose allocation handle must be freed
 * exactly once with dansheng_free. Buffers are not NUL terminated. Never use
 * free()/delete on them. Engine close does not invalidate returned buffers.
 */
DANSHENG_API int32_t dansheng_poll(uint64_t operation,
                                  dansheng_buffer *out_buffer);

/* Cancel local waiting; poll still returns a Cancelled Response. Cancellation
 * does not undo external effects or persistent jobs; reconcile before retrying.
 * An already-completed operation cannot be cancelled. Close is not cancellable.
 */
DANSHENG_API int32_t dansheng_cancel(uint64_t operation);

/* Invalidate engine immediately and start async cleanup. In-flight requests
 * become Closed; their operation handles still must be polled/freed. Poll the
 * close operation until {"id":"close","result":{"closed":true}}. Cleanup
 * stops the scheduler and awaits aborted requests before releasing the engine.
 */
DANSHENG_API int32_t dansheng_close(uint64_t engine, uint64_t *out_operation);
DANSHENG_API int32_t dansheng_free(uint64_t allocation);

/* Optional platform bridge. Only explicitly advertised capabilities are queued.
 * Poll returns PENDING or a buffer: {"id":"123","capability":"browser.request",
 * "input":...}. The input includes core principal/grant mediation metadata;
 * browser fetch/XHR must run in the authenticated page. It can contain secrets:
 * never log it. Free the buffer after reading, then respond using the numeric id.
 * Response uses core envelope {"id":"123","result":...} or {"id":"123",
 * "error":{"code":"...","message":"..."}}. Reply once, within 60 seconds.
 * Timeout/cancellation may leave external outcomes uncertain. The queue is
 * bounded at 128 requests. No synthetic browser or credential implementation.
 */
DANSHENG_API int32_t dansheng_platform_poll(uint64_t engine,
                                           dansheng_buffer *out_buffer);
DANSHENG_API int32_t dansheng_platform_respond(uint64_t engine, uint64_t request,
                                              const uint8_t *response, size_t len);

#ifdef __cplusplus
}
#endif
#endif
