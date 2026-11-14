//! Stable C ABI. See `include/dansheng.h` and this crate's README for ownership rules.
use async_trait::async_trait;
use dansheng_core::{
    CoreError, CoreResult, Engine, PlatformPort, Principal, Request, Response, UnavailablePlatform,
};
use futures_util::FutureExt;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{runtime::Runtime, sync::oneshot, task::JoinHandle};

pub const OK: i32 = 0;
pub const PENDING: i32 = 1;
pub const INVALID_ARGUMENT: i32 = -1;
pub const INVALID_HANDLE: i32 = -2;
pub const PANIC: i32 = -3;
pub const LIMIT: i32 = -4;
pub const ALREADY_COMPLETE: i32 = -5;
pub const NOT_CANCELLABLE: i32 = -6;
const MAX_JSON: usize = 8 * 1024 * 1024;
const MAX_OPERATIONS: usize = 1024;

/// Data stays valid until its allocation handle is passed to `dansheng_free`.
#[repr(C)]
pub struct DanshengBuffer {
    pub allocation: u64,
    pub data: *const u8,
    pub len: usize,
}
impl Default for DanshengBuffer {
    fn default() -> Self {
        Self {
            allocation: 0,
            data: ptr::null(),
            len: 0,
        }
    }
}

struct Entry {
    engine: Arc<Engine>,
    bridge: Option<Arc<PlatformBridge>>,
    scheduler: Mutex<Option<JoinHandle<()>>>,
}
struct Operation {
    owner: Option<u64>,
    wire_id: String,
    cancellable: bool,
    ready: Option<Vec<u8>>,
    task: Option<JoinHandle<()>>,
}
#[derive(Default)]
struct Registry {
    engines: HashMap<u64, Arc<Entry>>,
    operations: HashMap<u64, Operation>,
    buffers: HashMap<u64, Box<[u8]>>,
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);

fn registry() -> &'static Mutex<Registry> {
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}
fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("dansheng-ffi")
            .enable_all()
            .build()
            .expect("FFI runtime unavailable")
    })
}
fn next() -> u64 {
    let mut current = NEXT.load(Ordering::Relaxed);
    loop {
        let following = current.checked_add(1).expect("handle space exhausted");
        match NEXT.compare_exchange_weak(current, following, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return current,
            Err(observed) => current = observed,
        }
    }
}
fn boundary(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(PANIC)
}
fn encoded(response: &Response) -> Vec<u8> {
    let bytes = serde_json::to_vec(response).unwrap_or_else(|_| b"{\"id\":\"\",\"error\":{\"code\":\"SerializationError\",\"message\":\"response serialization failed\"}}".to_vec());
    if bytes.len() > MAX_JSON {
        error(&response.id, "ResponseTooLarge", "response exceeds 8 MiB")
    } else {
        bytes
    }
}
fn error(id: &str, code: &str, message: &str) -> Vec<u8> {
    serde_json::to_vec(&Response {
        id: id.into(),
        result: None,
        error: Some(CoreError::new(code, message)),
    })
    .expect("error serialization")
}
fn complete(id: u64, bytes: Vec<u8>) {
    if let Some(op) = lock(registry()).operations.get_mut(&id)
        && op.ready.is_none()
    {
        op.ready = Some(bytes);
    }
}
fn operation(owner: Option<u64>, wire_id: &str, cancellable: bool) -> Result<u64, i32> {
    let mut registry = lock(registry());
    if owner.is_some_and(|id| !registry.engines.contains_key(&id)) {
        return Err(INVALID_HANDLE);
    }
    if registry.operations.len() >= MAX_OPERATIONS || registry.buffers.len() >= MAX_OPERATIONS {
        return Err(LIMIT);
    }
    let id = next();
    registry.operations.insert(
        id,
        Operation {
            owner,
            wire_id: wire_id.into(),
            cancellable,
            ready: None,
            task: None,
        },
    );
    Ok(id)
}
fn spawn(id: u64, future: impl Future<Output = ()> + Send + 'static) {
    let mut state = lock(registry());
    let Some(op) = state.operations.get_mut(&id) else {
        return;
    };
    if op.ready.is_some() {
        return;
    }
    let task = runtime().spawn(async move {
        if AssertUnwindSafe(future).catch_unwind().await.is_err() {
            let wire_id = lock(registry())
                .operations
                .get(&id)
                .map(|op| op.wire_id.clone())
                .unwrap_or_default();
            complete(
                id,
                error(
                    &wire_id,
                    "InternalPanic",
                    "operation failed inside the core",
                ),
            );
        }
    });
    op.task = Some(task);
}
// SAFETY: C must provide a live readable region for the declared length. No ABI can validate arbitrary addresses.
unsafe fn input<'a>(data: *const u8, len: usize) -> Result<&'a [u8], i32> {
    if data.is_null() || len == 0 || len > MAX_JSON {
        return Err(INVALID_ARGUMENT);
    }
    Ok(unsafe { std::slice::from_raw_parts(data, len) })
}
unsafe fn output_handle(out: *mut u64) -> Result<(), i32> {
    if out.is_null() || !(out as usize).is_multiple_of(align_of::<u64>()) {
        return Err(INVALID_ARGUMENT);
    }
    unsafe {
        out.write(0);
    }
    Ok(())
}
unsafe fn output_buffer(out: *mut DanshengBuffer) -> Result<(), i32> {
    if out.is_null() || !(out as usize).is_multiple_of(align_of::<DanshengBuffer>()) {
        return Err(INVALID_ARGUMENT);
    }
    unsafe {
        out.write(DanshengBuffer::default());
    }
    Ok(())
}
fn buffer(registry: &mut Registry, bytes: Vec<u8>) -> Result<DanshengBuffer, i32> {
    if registry.buffers.len() >= MAX_OPERATIONS {
        return Err(LIMIT);
    }
    let id = next();
    let bytes = bytes.into_boxed_slice();
    let result = DanshengBuffer {
        allocation: id,
        data: bytes.as_ptr(),
        len: bytes.len(),
    };
    registry.buffers.insert(id, bytes);
    Ok(result)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OpenOptions {
    data_dir: String,
    #[serde(default)]
    platform_capabilities: Vec<String>,
}

/// # Safety
/// Input must be readable for len bytes; out_operation must be writable and aligned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dansheng_open(
    data: *const u8,
    len: usize,
    out_operation: *mut u64,
) -> i32 {
    boundary(|| {
        if let Err(e) = unsafe { output_handle(out_operation) } {
            return e;
        }
        let bytes = match unsafe { input(data, len) } {
            Ok(v) => v,
            Err(e) => return e,
        };
        let options: OpenOptions = match serde_json::from_slice(bytes) {
            Ok(v) => v,
            Err(_) => return INVALID_ARGUMENT,
        };
        if options.data_dir.trim().is_empty()
            || options.platform_capabilities.len() > 128
            || options
                .platform_capabilities
                .iter()
                .any(|v| v.is_empty() || v.len() > 128)
        {
            return INVALID_ARGUMENT;
        }
        let id = match operation(None, "open", true) {
            Ok(id) => id,
            Err(e) => return e,
        };
        spawn(id, async move {
            let bridge = if options.platform_capabilities.is_empty() {
                None
            } else {
                Some(Arc::new(PlatformBridge::new(options.platform_capabilities)))
            };
            let platform: Arc<dyn PlatformPort> = bridge
                .clone()
                .map(|b| b as Arc<dyn PlatformPort>)
                .unwrap_or_else(|| Arc::new(UnavailablePlatform));
            let opened = tokio::task::spawn_blocking(move || {
                let engine = Engine::open(options.data_dir, platform)?;
                #[cfg(feature = "services")]
                {
                    engine.register_service(Arc::new(
                        dansheng_connectors::core_adapter::CampusService,
                    ))?;
                    engine.register_service(Arc::new(
                        dansheng_connectors::mail::MailService::default(),
                    ))?;
                }
                Ok::<_, CoreError>(engine)
            })
            .await;
            let engine = match opened {
                Ok(Ok(engine)) => engine,
                Ok(Err(e)) => {
                    complete(
                        id,
                        encoded(&Response {
                            id: "open".into(),
                            result: None,
                            error: Some(e),
                        }),
                    );
                    return;
                }
                Err(_) => {
                    complete(
                        id,
                        error("open", "InternalPanic", "engine initialization failed"),
                    );
                    return;
                }
            };
            let mut registry = lock(registry());
            let pending = registry
                .operations
                .get(&id)
                .is_some_and(|op| op.ready.is_none());
            if !pending {
                return;
            }
            if registry.engines.len() >= 128 {
                registry.operations.get_mut(&id).unwrap().ready =
                    Some(error("open", "ResourceLimit", "too many open engines"));
                return;
            }
            let engine_id = next();
            let tick_engine = engine.clone();
            let scheduler = tokio::spawn(async move {
                let mut interval = tokio::time::interval(Duration::from_secs(1));
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                loop {
                    interval.tick().await;
                    let _ = AssertUnwindSafe(tick_engine.tick()).catch_unwind().await;
                }
            });
            registry.engines.insert(
                engine_id,
                Arc::new(Entry {
                    engine,
                    bridge,
                    scheduler: Mutex::new(Some(scheduler)),
                }),
            );
            registry.operations.get_mut(&id).unwrap().ready = Some(encoded(&Response {
                id: "open".into(),
                result: Some(json!({"engine":engine_id})),
                error: None,
            }));
        });
        unsafe {
            out_operation.write(id);
        }
        OK
    })
}

/// Trusted embedded caller uses owner authority. This ABI is not an untrusted transport.
/// # Safety
/// Input must be readable for len bytes; out_operation must be writable and aligned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dansheng_request(
    engine: u64,
    data: *const u8,
    len: usize,
    out_operation: *mut u64,
) -> i32 {
    boundary(|| {
        if let Err(e) = unsafe { output_handle(out_operation) } {
            return e;
        }
        let bytes = match unsafe { input(data, len) } {
            Ok(v) => v,
            Err(e) => return e,
        };
        let request: Request = match serde_json::from_slice(bytes) {
            Ok(v) => v,
            Err(_) => return INVALID_ARGUMENT,
        };
        let entry = match lock(registry()).engines.get(&engine).cloned() {
            Some(v) => v,
            None => return INVALID_HANDLE,
        };
        let id = match operation(Some(engine), &request.id, true) {
            Ok(id) => id,
            Err(e) => return e,
        };
        spawn(id, async move {
            let response = entry.engine.handle(Principal::owner(), request).await;
            drop(entry);
            complete(id, encoded(&response));
        });
        unsafe {
            out_operation.write(id);
        }
        OK
    })
}

/// # Safety
/// out_buffer must point to writable, aligned storage. Poll consumes a completed operation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dansheng_poll(operation: u64, out_buffer: *mut DanshengBuffer) -> i32 {
    boundary(|| {
        if let Err(e) = unsafe { output_buffer(out_buffer) } {
            return e;
        }
        let mut registry = lock(registry());
        let op = match registry.operations.get(&operation) {
            Some(v) => v,
            None => return INVALID_HANDLE,
        };
        if op.ready.is_none() || op.task.as_ref().is_some_and(|task| !task.is_finished()) {
            return PENDING;
        }
        if registry.buffers.len() >= MAX_OPERATIONS {
            return LIMIT;
        }
        let op = registry.operations.remove(&operation).unwrap();
        let result = match buffer(&mut registry, op.ready.unwrap()) {
            Ok(v) => v,
            Err(e) => return e,
        };
        unsafe {
            out_buffer.write(result);
        }
        OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dansheng_cancel(operation: u64) -> i32 {
    boundary(|| {
        let mut registry = lock(registry());
        let op = match registry.operations.get_mut(&operation) {
            Some(v) => v,
            None => return INVALID_HANDLE,
        };
        if op.ready.is_some() {
            return ALREADY_COMPLETE;
        }
        if !op.cancellable {
            return NOT_CANCELLABLE;
        }
        if let Some(task) = &op.task {
            task.abort();
        }
        op.ready = Some(error(
            &op.wire_id,
            "Cancelled",
            "caller stopped waiting; reconcile possible external effects before retrying",
        ));
        OK
    })
}

/// # Safety
/// out_operation must point to writable aligned storage. The engine handle becomes invalid immediately.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dansheng_close(engine: u64, out_operation: *mut u64) -> i32 {
    boundary(|| {
        if let Err(e) = unsafe { output_handle(out_operation) } {
            return e;
        }
        let id = match operation(None, "close", false) {
            Ok(id) => id,
            Err(e) => return e,
        };
        let (entry, tasks) = {
            let mut registry = lock(registry());
            let entry = match registry.engines.remove(&engine) {
                Some(v) => v,
                None => {
                    registry.operations.remove(&id);
                    return INVALID_HANDLE;
                }
            };
            let mut tasks = vec![];
            for op in registry
                .operations
                .values_mut()
                .filter(|op| op.owner == Some(engine))
            {
                if let Some(task) = op.task.take() {
                    task.abort();
                    tasks.push(task);
                }
                if op.ready.is_none() {
                    op.ready = Some(error(
                        &op.wire_id,
                        "Closed",
                        "engine closed; reconcile possible external effects before retrying",
                    ));
                }
            }
            (entry, tasks)
        };
        if let Some(bridge) = &entry.bridge {
            bridge.close();
        }
        let scheduler = lock(&entry.scheduler).take();
        if let Some(task) = &scheduler {
            task.abort();
        }
        spawn(id, async move {
            for task in tasks {
                let _ = task.await;
            }
            if let Some(task) = scheduler {
                let _ = task.await;
            }
            drop(entry);
            complete(
                id,
                encoded(&Response {
                    id: "close".into(),
                    result: Some(json!({"closed":true})),
                    error: None,
                }),
            );
        });
        unsafe {
            out_operation.write(id);
        }
        OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dansheng_free(allocation: u64) -> i32 {
    boundary(|| {
        if lock(registry()).buffers.remove(&allocation).is_some() {
            OK
        } else {
            INVALID_HANDLE
        }
    })
}

#[derive(Default)]
struct PlatformState {
    queue: VecDeque<Value>,
    pending: HashMap<u64, oneshot::Sender<CoreResult<Value>>>,
    closed: bool,
}
struct PlatformBridge {
    capabilities: Vec<String>,
    state: Mutex<PlatformState>,
}
impl PlatformBridge {
    fn new(capabilities: Vec<String>) -> Self {
        Self {
            capabilities,
            state: Mutex::new(PlatformState::default()),
        }
    }
    fn close(&self) {
        let mut state = lock(&self.state);
        state.closed = true;
        state.queue.clear();
        state.pending.clear();
    }
}
struct PendingPlatform<'a> {
    bridge: &'a PlatformBridge,
    id: u64,
}
impl Drop for PendingPlatform<'_> {
    fn drop(&mut self) {
        let mut state = lock(&self.bridge.state);
        state.pending.remove(&self.id);
        let expected = self.id.to_string();
        state
            .queue
            .retain(|v| v["id"].as_str() != Some(expected.as_str()));
    }
}
#[async_trait]
impl PlatformPort for PlatformBridge {
    fn capabilities(&self) -> Vec<String> {
        self.capabilities.clone()
    }
    async fn call(&self, capability: &str, input: Value) -> CoreResult<Value> {
        if !self.capabilities.iter().any(|v| v == capability) {
            return Err(CoreError::new(
                "CapabilityUnavailable",
                "platform capability not provided",
            ));
        }
        let id = next();
        let (tx, rx) = oneshot::channel();
        {
            let mut state = lock(&self.state);
            if state.closed {
                return Err(CoreError::new("Closed", "platform closed"));
            }
            if state.pending.len() >= 128 {
                return Err(CoreError::new("PlatformBusy", "platform queue is full"));
            }
            let request = json!({"id":id.to_string(), "capability":capability, "input":input});
            if serde_json::to_vec(&request)?.len() > MAX_JSON {
                return Err(CoreError::invalid("platform request exceeds 8 MiB"));
            }
            state.pending.insert(id, tx);
            state.queue.push_back(request);
        }
        let _pending = PendingPlatform { bridge: self, id };
        tokio::time::timeout(Duration::from_secs(60), rx)
            .await
            .map_err(|_| {
                CoreError::new(
                    "OutcomeUnknown",
                    "platform response timed out; reconcile before retrying",
                )
            })?
            .map_err(|_| CoreError::new("Closed", "platform responder closed"))?
    }
}

/// # Safety
/// out_buffer must point to writable aligned storage. Values can contain secrets and must not be logged.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dansheng_platform_poll(
    engine: u64,
    out_buffer: *mut DanshengBuffer,
) -> i32 {
    boundary(|| {
        if let Err(e) = unsafe { output_buffer(out_buffer) } {
            return e;
        }
        let mut registry = lock(registry());
        let entry = match registry.engines.get(&engine).cloned() {
            Some(v) => v,
            None => return INVALID_HANDLE,
        };
        let bridge = match &entry.bridge {
            Some(v) => v,
            None => return PENDING,
        };
        if registry.buffers.len() >= MAX_OPERATIONS {
            return LIMIT;
        }
        let Some(request) = lock(&bridge.state).queue.pop_front() else {
            return PENDING;
        };
        let result = match buffer(&mut registry, serde_json::to_vec(&request).unwrap()) {
            Ok(v) => v,
            Err(e) => return e,
        };
        unsafe {
            out_buffer.write(result);
        }
        OK
    })
}

/// # Safety
/// data must be readable for len bytes. JSON is the core Response envelope with matching string id.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dansheng_platform_respond(
    engine: u64,
    request: u64,
    data: *const u8,
    len: usize,
) -> i32 {
    boundary(|| {
        let bytes = match unsafe { input(data, len) } {
            Ok(v) => v,
            Err(e) => return e,
        };
        let value: Value = match serde_json::from_slice(bytes) {
            Ok(v) => v,
            Err(_) => return INVALID_ARGUMENT,
        };
        let expected = request.to_string();
        if value["id"].as_str() != Some(expected.as_str())
            || value.get("error").is_some() == value.get("result").is_some()
        {
            return INVALID_ARGUMENT;
        }
        let result = if let Some(error) = value.get("error") {
            match serde_json::from_value::<CoreError>(error.clone()) {
                Ok(e) => Err(e),
                Err(_) => return INVALID_ARGUMENT,
            }
        } else {
            Ok(value["result"].clone())
        };
        let entry = match lock(registry()).engines.get(&engine).cloned() {
            Some(v) => v,
            None => return INVALID_HANDLE,
        };
        let bridge = match &entry.bridge {
            Some(v) => v,
            None => return INVALID_HANDLE,
        };
        let Some(tx) = lock(&bridge.state).pending.remove(&request) else {
            return INVALID_HANDLE;
        };
        if tx.send(result).is_ok() {
            OK
        } else {
            INVALID_HANDLE
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn finish(operation: u64) -> Value {
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        loop {
            let mut out = DanshengBuffer::default();
            match unsafe { dansheng_poll(operation, &mut out) } {
                OK => {
                    let value = serde_json::from_slice(unsafe {
                        std::slice::from_raw_parts(out.data, out.len)
                    })
                    .unwrap();
                    assert_eq!(dansheng_free(out.allocation), OK);
                    assert_eq!(dansheng_free(out.allocation), INVALID_HANDLE);
                    assert_eq!(
                        unsafe { dansheng_poll(operation, &mut out) },
                        INVALID_HANDLE
                    );
                    return value;
                }
                PENDING => {
                    assert!(out.data.is_null());
                    assert_eq!(out.allocation, 0);
                    assert!(
                        std::time::Instant::now() < deadline,
                        "FFI operation timed out"
                    );
                    std::thread::sleep(Duration::from_millis(5));
                }
                status => panic!("unexpected FFI status {status}"),
            }
        }
    }
    fn request(engine: u64, method: &str, params: Value) -> u64 {
        let data = json!({"id":"ffi-contract", "method":method,"params":params}).to_string();
        let mut operation = 0;
        assert_eq!(
            unsafe { dansheng_request(engine, data.as_ptr(), data.len(), &mut operation) },
            OK
        );
        operation
    }
    fn open(directory: &std::path::Path, capabilities: Vec<&str>) -> u64 {
        let options =
            json!({"data_dir":directory,"platform_capabilities":capabilities}).to_string();
        let mut operation = 0;
        assert_eq!(
            unsafe { dansheng_open(options.as_ptr(), options.len(), &mut operation) },
            OK
        );
        finish(operation)["result"]["engine"].as_u64().unwrap()
    }
    fn platform_request(engine: u64) -> Value {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let mut out = DanshengBuffer::default();
            match unsafe { dansheng_platform_poll(engine, &mut out) } {
                OK => {
                    let value = serde_json::from_slice(unsafe {
                        std::slice::from_raw_parts(out.data, out.len)
                    })
                    .unwrap();
                    assert_eq!(dansheng_free(out.allocation), OK);
                    return value;
                }
                PENDING => {
                    assert!(std::time::Instant::now() < deadline);
                    std::thread::sleep(Duration::from_millis(5));
                }
                status => panic!("unexpected platform status {status}"),
            }
        }
    }
    #[test]
    fn invalid_handles_malformed_envelopes_and_panic_boundary() {
        let mut operation = 99;
        let mut buffer = DanshengBuffer::default();
        assert_eq!(
            unsafe { dansheng_poll(u64::MAX, &mut buffer) },
            INVALID_HANDLE
        );
        assert_eq!(dansheng_cancel(0), INVALID_HANDLE);
        assert_eq!(dansheng_free(u64::MAX), INVALID_HANDLE);
        assert_eq!(unsafe { dansheng_close(0, &mut operation) }, INVALID_HANDLE);
        assert_eq!(operation, 0);
        for bytes in [b"{".as_slice(), b"{}", b"[]", b"null", b"\xff"] {
            assert_eq!(
                unsafe { dansheng_open(bytes.as_ptr(), bytes.len(), &mut operation) },
                INVALID_ARGUMENT
            );
            assert_eq!(
                unsafe { dansheng_request(0, bytes.as_ptr(), bytes.len(), &mut operation) },
                INVALID_ARGUMENT
            );
            assert_eq!(operation, 0);
        }
        assert_eq!(
            unsafe { dansheng_open(ptr::null(), 0, &mut operation) },
            INVALID_ARGUMENT
        );
        assert_eq!(
            unsafe { dansheng_poll(0, ptr::null_mut()) },
            INVALID_ARGUMENT
        );
        assert_eq!(boundary(|| panic!("synthetic FFI contract panic")), PANIC);
        let id = super::operation(None, "async-panic", true).unwrap();
        spawn(id, async {
            panic!("synthetic async contract panic");
        });
        let response = finish(id);
        assert_eq!(response["id"], "async-panic");
        assert_eq!(response["error"]["code"], "InternalPanic");
    }

    #[test]
    fn exported_lifecycle_platform_roundtrip_cancel_and_close() {
        let temp = tempfile::tempdir().unwrap();
        let engine = open(temp.path(), vec!["browser.request"]);
        #[cfg(feature = "services")]
        {
            assert!(log::STATIC_MAX_LEVEL <= log::LevelFilter::Info);
            assert_eq!(
                finish(request(
                    engine,
                    "mail.status",
                    json!({"account_id":"offline-mail"})
                ))["result"]["configured"],
                false
            );
            assert_eq!(
                finish(request(engine, "fudan.semesters", json!({})))["error"]["code"],
                "InvalidInput"
            );
        }
        assert_eq!(
            finish(request(
                engine,
                "storage.set",
                json!({"key":"proof","value":{"offline":true}})
            ))["id"],
            "ffi-contract"
        );
        assert_eq!(
            finish(request(engine, "storage.get", json!({"key":"proof"})))["result"]["offline"],
            true
        );
        let op = request(
            engine,
            "browser.request",
            json!({"url":"https://fixture.invalid/offline"}),
        );
        let queued = platform_request(engine);
        assert_eq!(queued["capability"], "browser.request");
        assert_eq!(queued["input"]["principal"]["id"], "owner");
        assert_eq!(
            queued["input"]["input"]["url"],
            "https://fixture.invalid/offline"
        );
        let id = queued["id"].as_str().unwrap().parse::<u64>().unwrap();
        let malformed =
            json!({"id":id.to_string(),"result":1,"error":{"code":"x","message":"x"}}).to_string();
        assert_eq!(
            unsafe { dansheng_platform_respond(engine, id, malformed.as_ptr(), malformed.len()) },
            INVALID_ARGUMENT
        );
        let reply = json!({"id":id.to_string(),"result":{"status":200,"body":"offline fixture"}})
            .to_string();
        assert_eq!(
            unsafe { dansheng_platform_respond(engine, id, reply.as_ptr(), reply.len()) },
            OK
        );
        assert_eq!(
            unsafe { dansheng_platform_respond(engine, id, reply.as_ptr(), reply.len()) },
            INVALID_HANDLE
        );
        assert_eq!(finish(op)["result"]["body"], "offline fixture");
        let null_op = request(engine, "browser.request", json!({}));
        let queued = platform_request(engine);
        let id = queued["id"].as_str().unwrap().parse::<u64>().unwrap();
        let reply = json!({"id":id.to_string(),"result":null}).to_string();
        assert_eq!(
            unsafe { dansheng_platform_respond(engine, id, reply.as_ptr(), reply.len()) },
            OK
        );
        assert!(finish(null_op).get("result").is_some());
        let cancelled = request(engine, "browser.request", json!({}));
        platform_request(engine);
        assert_eq!(dansheng_cancel(cancelled), OK);
        let response = finish(cancelled);
        assert_eq!(response["id"], "ffi-contract");
        assert_eq!(response["error"]["code"], "Cancelled");
        let pending = request(engine, "browser.request", json!({}));
        platform_request(engine);
        let mut closing = 0;
        assert_eq!(unsafe { dansheng_close(engine, &mut closing) }, OK);
        assert_eq!(finish(pending)["error"]["code"], "Closed");
        assert_eq!(finish(closing)["result"]["closed"], true);
        assert_eq!(
            unsafe { dansheng_close(engine, &mut closing) },
            INVALID_HANDLE
        );
        // Core storage really persists across teardown/open; the scheduler does not retain it.
        let engine = open(temp.path(), vec![]);
        assert_eq!(
            finish(request(engine, "storage.get", json!({"key":"proof"})))["result"]["offline"],
            true
        );
        assert_eq!(
            finish(request(engine, "browser.request", json!({})))["error"]["code"],
            "CapabilityUnavailable"
        );
        assert_eq!(unsafe { dansheng_close(engine, &mut closing) }, OK);
        finish(closing);
    }
}
