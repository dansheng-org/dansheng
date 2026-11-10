//! Desktop broker and authenticated local IPC clients. Only `serve` opens core storage.
pub mod frame;
pub mod mcp;
pub mod platform;
pub mod security;

use dansheng_core::{CoreError, CoreResult, Engine, Principal, PrincipalKind, Request, Response};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{Mutex, watch},
    task::JoinSet,
};

pub trait LocalStream: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> LocalStream for T {}
type Stream = Box<dyn LocalStream>;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientConfig {
    pub endpoint: String,
    pub token_file: PathBuf,
}

#[derive(Clone)]
pub struct HostPaths {
    pub data: PathBuf,
    pub private: PathBuf,
    pub owner: ClientConfig,
    pub mcp: ClientConfig,
}
impl HostPaths {
    pub fn new(data: &Path) -> CoreResult<Self> {
        if data.as_os_str().is_empty() {
            return Err(CoreError::invalid("data directory is empty"));
        }
        let data = dansheng_core::store::Store::profile_path(data)?;
        let private = data.join("host");
        #[cfg(windows)]
        let endpoint = {
            use sha2::{Digest, Sha256};
            let hash = Sha256::digest(data.to_string_lossy().to_lowercase().as_bytes());
            let suffix: String = hash[..16].iter().map(|b| format!("{b:02x}")).collect();
            format!(r"\\.\pipe\dansheng-{suffix}")
        };
        #[cfg(unix)]
        let endpoint = private.join("ipc.sock").to_string_lossy().into_owned();
        Ok(Self {
            owner: ClientConfig {
                endpoint: endpoint.clone(),
                token_file: private.join("owner-token"),
            },
            mcp: ClientConfig {
                endpoint,
                token_file: private.join("mcp-token"),
            },
            data,
            private,
        })
    }
    pub fn mcp_config_path(&self) -> PathBuf {
        self.private.join("mcp-client.json")
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Authentication {
    token: String,
}
#[derive(Serialize, Deserialize)]
struct Authenticated {
    principal: Principal,
}

fn response_error(id: &str, code: &str, message: &str) -> Response {
    Response {
        id: id.into(),
        result: None,
        error: Some(CoreError::new(code, message)),
    }
}

#[derive(Clone)]
pub struct Client {
    stream: Arc<Mutex<Option<Stream>>>,
    pub principal: Principal,
}
impl Client {
    pub async fn connect(config: &ClientConfig) -> CoreResult<Self> {
        let token = security::read_token(&config.token_file)?;
        Self::connect_token(&config.endpoint, token).await
    }
    pub async fn connect_token(endpoint: &str, token: String) -> CoreResult<Self> {
        let mut stream = connect(endpoint).await?;
        let principal = tokio::time::timeout(Duration::from_secs(10), async {
            frame::write_json(&mut stream, &Authentication { token }).await?;
            let response: Response = frame::read_json(&mut stream).await?;
            if let Some(error) = response.error {
                return Err(error);
            }
            let result: Authenticated =
                serde_json::from_value(response.result.ok_or_else(|| {
                    CoreError::new("ProtocolError", "missing authentication response")
                })?)?;
            Ok::<_, CoreError>(result.principal)
        })
        .await
        .map_err(|_| CoreError::new("AuthenticationTimeout", "local authentication timed out"))??;
        Ok(Self {
            stream: Arc::new(Mutex::new(Some(stream))),
            principal,
        })
    }
    /// A failed/abandoned call must not be retried automatically: writes may already have occurred.
    pub async fn call(&self, request: Request) -> CoreResult<Response> {
        let mut slot = self.stream.lock().await;
        let mut stream = slot.take().ok_or_else(|| {
            CoreError::new(
                "Disconnected",
                "connection is closed; reconcile previous requests before reconnecting",
            )
        })?;
        // Taking the stream also closes it on future cancellation, preventing response mix-ups.
        frame::write_json(&mut stream, &request)
            .await
            .map_err(|_| {
                CoreError::new(
                    "OutcomeUnknown",
                    "IPC write failed; reconcile state before retrying",
                )
            })?;
        let response: Response = frame::read_json(&mut stream).await.map_err(|_| {
            CoreError::new(
                "OutcomeUnknown",
                "IPC disconnected after dispatch; reconcile state before retrying",
            )
        })?;
        if response.id != request.id {
            return Err(CoreError::new(
                "ProtocolError",
                "response id did not match request",
            ));
        }
        *slot = Some(stream);
        Ok(response)
    }
    pub async fn invoke(&self, method: &str, params: serde_json::Value) -> CoreResult<Response> {
        self.call(Request {
            id: uuid::Uuid::new_v4().to_string(),
            method: method.into(),
            params,
        })
        .await
    }
}

pub async fn serve_connection<S: LocalStream>(stream: S, engine: Arc<Engine>) -> CoreResult<()> {
    let (_keep_open, stopped) = watch::channel(false);
    serve_connection_until_shutdown(stream, engine, stopped).await
}

async fn serve_connection_until_shutdown<S: LocalStream>(
    mut stream: S,
    engine: Arc<Engine>,
    mut stopped: watch::Receiver<bool>,
) -> CoreResult<()> {
    let auth = tokio::select! { biased;
        _ = stopped.changed() => return Ok(()),
        auth = tokio::time::timeout(Duration::from_secs(10), frame::read_json::<_, Authentication>(&mut stream)) => auth,
    };
    let principal = match auth {
        Ok(Ok(auth)) => engine.authenticate(&auth.token),
        _ => Err(CoreError::new(
            "Unauthenticated",
            "authentication required as the first frame",
        )),
    };
    let principal = match principal {
        Ok(principal) => principal,
        Err(_) => {
            frame::write_json(
                &mut stream,
                &response_error(
                    "auth",
                    "Unauthenticated",
                    "invalid client token or authentication frame",
                ),
            )
            .await?;
            return Ok(());
        }
    };
    frame::write_json(
        &mut stream,
        &Response {
            id: "auth".into(),
            result: Some(serde_json::to_value(Authenticated {
                principal: principal.clone(),
            })?),
            error: None,
        },
    )
    .await?;
    loop {
        let read = tokio::select! { biased;
            _ = stopped.changed() => return Ok(()),
            read = frame::read_frame(&mut stream) => read,
        };
        let data = match read {
            Ok(data) => data,
            Err(error) if error.code == "IoError" => return Ok(()),
            Err(error) => return Err(error),
        };
        let request = match serde_json::from_slice::<Request>(&data) {
            Ok(request) => request,
            Err(_) => {
                frame::write_json(
                    &mut stream,
                    &response_error("", "InvalidInput", "invalid request envelope"),
                )
                .await?;
                continue;
            }
        };
        // Identity is bound by authenticate, never by request fields or params.
        let response = engine.handle(principal.clone(), request).await;
        if serde_json::to_vec(&response)?.len() > frame::MAX_FRAME {
            frame::write_json(
                &mut stream,
                &response_error(
                    &response.id,
                    "ResponseTooLarge",
                    "response exceeds 8 MiB; narrow the query",
                ),
            )
            .await?;
        } else {
            frame::write_json(&mut stream, &response).await?;
        }
    }
}

#[cfg(unix)]
async fn connect(endpoint: &str) -> CoreResult<Stream> {
    Ok(Box::new(tokio::net::UnixStream::connect(endpoint).await?))
}
#[cfg(windows)]
async fn connect(endpoint: &str) -> CoreResult<Stream> {
    use tokio::net::windows::named_pipe::ClientOptions;
    if !endpoint.starts_with(r"\\.\pipe\") {
        return Err(CoreError::invalid("only local named pipes are supported"));
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        match ClientOptions::new().open(endpoint) {
            Ok(pipe) => return Ok(Box::new(pipe)),
            Err(e) if e.raw_os_error() == Some(231) && tokio::time::Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(25)).await
            }
            Err(e) => return Err(e.into()),
        }
    }
}

struct Listener {
    #[cfg(unix)]
    inner: tokio::net::UnixListener,
    #[cfg(windows)]
    inner: tokio::net::windows::named_pipe::NamedPipeServer,
    endpoint: String,
}
impl Listener {
    fn bind(endpoint: String) -> CoreResult<Self> {
        #[cfg(unix)]
        let inner = {
            let listener = tokio::net::UnixListener::bind(&endpoint)?;
            security::restrict(Path::new(&endpoint))?;
            listener
        };
        #[cfg(windows)]
        let inner = Self::pipe(&endpoint, true)?;
        Ok(Self { inner, endpoint })
    }
    #[cfg(windows)]
    fn pipe(
        endpoint: &str,
        first: bool,
    ) -> CoreResult<tokio::net::windows::named_pipe::NamedPipeServer> {
        let security = security::windows::UserSecurity::new()?;
        let mut attrs = security.attributes();
        let mut options = tokio::net::windows::named_pipe::ServerOptions::new();
        options
            .first_pipe_instance(first)
            .reject_remote_clients(true);
        Ok(unsafe {
            options.create_with_security_attributes_raw(
                endpoint,
                (&mut attrs as *mut _ as *mut std::ffi::c_void).cast(),
            )?
        })
    }
    async fn accept(&mut self) -> CoreResult<Stream> {
        #[cfg(unix)]
        {
            Ok(Box::new(self.inner.accept().await?.0))
        }
        #[cfg(windows)]
        {
            self.inner.connect().await?;
            let next = Self::pipe(&self.endpoint, false)?;
            Ok(Box::new(std::mem::replace(&mut self.inner, next)))
        }
    }
}
#[cfg(unix)]
impl Drop for Listener {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.endpoint);
    }
}

/// Trusted embedding configuration, never accepted from IPC or a plugin.
pub struct ServeOptions {
    /// Statically trusted services in addition to the built-in connector services.
    pub services: Vec<Arc<dyn dansheng_core::services::CoreService>>,
    /// Production default is one second; shorter test intervals use the same loop.
    pub tick_interval: Duration,
    /// In-flight foreground IPC calls can finish; idle connections close immediately.
    pub shutdown_grace: Duration,
}
impl Default for ServeOptions {
    fn default() -> Self {
        Self {
            services: Vec::new(),
            tick_interval: Duration::from_secs(1),
            shutdown_grace: Duration::from_secs(2),
        }
    }
}

/// Run one local database owner using the normal services and scheduler defaults.
pub async fn serve(paths: HostPaths, shutdown: impl Future<Output = ()>) -> CoreResult<()> {
    serve_with_options(paths, ServeOptions::default(), shutdown).await
}

/// Run the real authenticated listener and event loop with trusted service/timer injection.
/// Shutdown stops accepts/background work, closes idle IPC, and drains active calls.
pub async fn serve_with_options(
    paths: HostPaths,
    options: ServeOptions,
    shutdown: impl Future<Output = ()>,
) -> CoreResult<()> {
    if options.tick_interval.is_zero()
        || options.tick_interval > Duration::from_secs(60)
        || options.shutdown_grace > Duration::from_secs(60)
    {
        return Err(CoreError::invalid(
            "invalid host scheduler interval or shutdown grace",
        ));
    }
    let profile_lock = dansheng_core::store::Store::acquire_profile_lock(&paths.data)?;
    security::private_dir(&paths.data)?;
    security::private_dir(&paths.private)?;
    // Bind before registering tokens or opening storage, excluding another daemon.
    let mut listener = Listener::bind(paths.owner.endpoint.clone())?;
    let owner_token = security::provision_token(&paths.owner.token_file)?;
    let mcp_token = security::provision_token(&paths.mcp.token_file)?;
    let engine = Engine::from_store(
        dansheng_core::store::Store::open_locked(profile_lock)?,
        Arc::new(platform::DesktopPlatform::new(&paths.data)),
    );
    #[cfg(feature = "services")]
    {
        engine.register_service(Arc::new(dansheng_connectors::core_adapter::CampusService))?;
        engine.register_service(Arc::new(dansheng_connectors::mail::MailService::default()))?;
    }
    for service in options.services {
        engine.register_service(service)?;
    }
    engine.register_client("owner", PrincipalKind::Owner, &owner_token)?;
    engine.register_client("desktop-mcp", PrincipalKind::Mcp, &mcp_token)?;
    security::write_private_json(&paths.mcp_config_path(), &paths.mcp)?;
    let mut connections = JoinSet::new();
    let mut scheduler = JoinSet::new();
    let (stopping, stopped) = watch::channel(false);
    let mut interval = tokio::time::interval(options.tick_interval);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    tokio::pin!(shutdown);
    let mut result = Ok(());
    loop {
        tokio::select! { biased;
            _ = &mut shutdown => break,
            Some(tick) = scheduler.join_next(), if !scheduler.is_empty() => {
                if !matches!(tick, Ok(Ok(_))) { eprintln!("scheduler tick failed; job state retained"); }
            },
            _ = interval.tick(), if scheduler.is_empty() => { let engine = engine.clone(); scheduler.spawn(async move { engine.tick().await }); }
            _ = connections.join_next(), if !connections.is_empty() => {},
            accepted = listener.accept(), if connections.len() < 128 => match accepted {
                Ok(stream) => { let engine = engine.clone(); let stopped = stopped.clone(); connections.spawn(async move { let _ = serve_connection_until_shutdown(stream, engine, stopped).await; }); }
                Err(error) => { result = Err(error); break; }
            },
        }
    }
    drop(listener);
    let _ = stopping.send(true);
    // A tick can contain queued jobs as well as an active read. Stop it now so
    // queued background work cannot start during foreground-call drain. Core's
    // native/plugin guards retain their distinct safe-retry/uncertain states.
    scheduler.abort_all();
    while scheduler.join_next().await.is_some() {}
    if tokio::time::timeout(options.shutdown_grace, async {
        while connections.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        connections.abort_all();
        while connections.join_next().await.is_some() {}
    }
    result
}

pub fn schema() -> serde_json::Value {
    serde_json::json!({"request": schemars::schema_for!(Request), "response": schemars::schema_for!(Response),
        "ipc": {"lengthPrefix":"u32 big endian", "maxFrameBytes":frame::MAX_FRAME, "firstFrame":{"token":"<token file contents>"}}})
}
