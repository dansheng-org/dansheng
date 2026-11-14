//! Development-only, loopback UI host. The browser never receives raw vault data.
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Request as WebRequest, State, rejection::JsonRejection},
    http::{HeaderMap, HeaderValue, Method, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use dansheng_core::{CoreError, CoreResult, Engine, PlatformPort, Principal, Request};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, Semaphore};
use zeroize::{Zeroize, ZeroizeOnDrop};

const CREDENTIAL_KEY: &str = "lab:fudan-credentials:v1";
const PUBLIC_ACCOUNT: &str = "lab-public";

pub struct Lab {
    engine: Arc<Engine>,
    platform: Arc<dyn PlatformPort>,
    origin: String,
    host: String,
    cookie_name: String,
    control_token: String,
    browser_token: String,
    csrf_token: String,
    bootstrap: Mutex<Bootstrap>,
    started: Instant,
    browser_expires_at: AtomicU64,
    credential_gate: Mutex<()>,
    probe_slots: Semaphore,
    last_attempt: Mutex<Option<Instant>>,
    last_login: Mutex<Option<Value>>,
    shutdown: tokio::sync::Notify,
}
struct Bootstrap {
    token: String,
    issued: Instant,
    used: bool,
}
#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(deny_unknown_fields)]
struct CredentialInput {
    student_id: String,
    password: String,
}
#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(deny_unknown_fields)]
struct CanvasTokenInput {
    token: String,
}
#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
struct StoredCredentials {
    student_id: String,
    password: String,
    account_id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BootstrapInput {
    token: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginInput {
    target: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProbeInput {
    probe: String,
    #[serde(default)]
    course_index: Option<usize>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WebvpnInput {
    mode: dansheng_core::network_routes::RouteMode,
    #[serde(default)]
    origins: Option<Vec<String>>,
}

fn random_token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}
fn same_secret(candidate: &str, expected: &str) -> bool {
    if candidate.len() > 512 {
        return false;
    }
    let left = Sha256::digest(candidate.as_bytes());
    let right = Sha256::digest(expected.as_bytes());
    left.iter()
        .zip(right.iter())
        .fold(0u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}
fn text_header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name)?.to_str().ok()
}
fn failure(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        Json(json!({"error":{"code":code,"message":message}})),
    )
        .into_response()
}
fn core_failure(error: CoreError) -> Response {
    // Only structured diagnostics made from static connector labels/status are
    // disclosed. Upstream bodies, locations, credentials and parser values are not.
    if matches!(
        error.code.as_str(),
        "SourceSchemaChanged" | "SourceHttpError"
    ) {
        return failure(
            StatusCode::BAD_REQUEST,
            &error.code,
            &format!("来源响应检查失败：{}", error.message),
        );
    }
    let message = match error.code.as_str() {
        "AuthenticationRequired" => "请先导入对应来源的登录会话，再执行只读测试。",
        "CapabilityUnavailable" => "当前平台能力不可用，凭据不会降级为明文保存。",
        "PermissionDenied" => "当前操作没有所需权限。",
        "NetworkError" | "HttpError" | "RequestTimeout" | "SourceTransportUnavailable" => {
            "网络请求未完成，请检查网络或校园网连接后手动重试。"
        }
        "InvalidInput" => "输入格式不正确，请检查后重新提交。",
        _ => "操作未完成。请根据错误代码排查；响应内容已脱敏。",
    };
    failure(StatusCode::BAD_REQUEST, &error.code, message)
}
fn json_input<T>(input: Result<Json<T>, JsonRejection>) -> CoreResult<T> {
    input
        .map(|Json(v)| v)
        .map_err(|_| CoreError::invalid("invalid JSON input"))
}

impl Lab {
    pub fn new(engine: Arc<Engine>, platform: Arc<dyn PlatformPort>, port: u16) -> Arc<Self> {
        Arc::new(Self {
            engine,
            platform,
            origin: format!("http://127.0.0.1:{port}"),
            host: format!("127.0.0.1:{port}"),
            cookie_name: format!("dansheng_lab_{port}"),
            control_token: random_token(),
            browser_token: random_token(),
            csrf_token: random_token(),
            bootstrap: Mutex::new(Bootstrap {
                token: random_token(),
                issued: Instant::now(),
                used: false,
            }),
            started: Instant::now(),
            browser_expires_at: AtomicU64::new(8 * 3600),
            credential_gate: Mutex::new(()),
            probe_slots: Semaphore::new(2),
            last_attempt: Mutex::new(None),
            last_login: Mutex::new(None),
            shutdown: tokio::sync::Notify::new(),
        })
    }
    pub async fn control_file(&self) -> Value {
        json!({"base_url":self.origin,"browser_url":self.browser_url().await,
            "control_token":self.control_token,"pid":std::process::id(),"started_at":chrono::Utc::now()})
    }
    pub async fn wait_for_shutdown(&self) {
        self.shutdown.notified().await;
    }
    async fn browser_url(&self) -> String {
        format!(
            "{}/#token={}",
            self.origin,
            self.bootstrap.lock().await.token
        )
    }
    fn is_control(&self, headers: &HeaderMap) -> bool {
        text_header(headers, "authorization")
            .and_then(|s| s.strip_prefix("Bearer "))
            .is_some_and(|s| same_secret(s, &self.control_token))
    }
    fn is_browser(&self, headers: &HeaderMap) -> bool {
        if self.started.elapsed().as_secs() > self.browser_expires_at.load(Ordering::Acquire) {
            return false;
        }
        text_header(headers, "cookie").is_some_and(|cookies| {
            cookies.split(';').any(|part| {
                part.trim().split_once('=').is_some_and(|(key, value)| {
                    key == self.cookie_name && same_secret(value, &self.browser_token)
                })
            })
        })
    }
    async fn credentials(&self) -> CoreResult<Option<StoredCredentials>> {
        let value = self
            .platform
            .call("vault.get", json!({"key":CREDENTIAL_KEY}))
            .await?;
        if value["value"].is_null() {
            return Ok(None);
        }
        let stored: StoredCredentials = serde_json::from_value(value["value"].clone())?;
        if uuid::Uuid::parse_str(&stored.account_id).is_err() {
            return Err(CoreError::new("VaultError", "invalid stored account"));
        }
        Ok(Some(stored))
    }
    async fn active_account(&self) -> CoreResult<String> {
        Ok(self
            .credentials()
            .await?
            .map(|c| c.account_id.clone())
            .unwrap_or_else(|| PUBLIC_ACCOUNT.into()))
    }
    async fn core(&self, method: &str, params: Value) -> CoreResult<Value> {
        let response = self
            .engine
            .handle(
                Principal::owner(),
                Request {
                    id: uuid::Uuid::new_v4().to_string(),
                    method: method.into(),
                    params,
                },
            )
            .await;
        if let Some(error) = response.error {
            return Err(error);
        }
        Ok(response.result.unwrap_or(Value::Null))
    }
}

pub fn router(state: Arc<Lab>) -> Router {
    Router::new()
        .route(
            "/",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
                    include_str!("../static/index.html"),
                )
            }),
        )
        .route(
            "/app.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../static/app.js"),
                )
            }),
        )
        .route(
            "/app.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
                    include_str!("../static/app.css"),
                )
            }),
        )
        .route("/api/session", get(session).post(bootstrap))
        .route("/api/open", post(open_browser))
        .route("/api/stop", post(stop))
        .route("/api/status", get(status))
        .route(
            "/api/credentials",
            post(save_credentials).delete(delete_credentials),
        )
        .route("/api/login", post(login))
        .route("/api/probe", post(probe))
        .route("/api/diagnostic/academic", post(academic_diagnostic))
        .route("/api/diagnostic/rooms", post(rooms_diagnostic))
        .route("/api/diagnostic/canvas", post(canvas_token_diagnostic))
        .route("/api/routes/webvpn", post(configure_webvpn))
        .route("/api/canvas/token", post(configure_canvas_token))
        .fallback(|| async {
            failure(StatusCode::NOT_FOUND, "NotFound", "页面或操作不存在。")
        })
        .layer(DefaultBodyLimit::max(16 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), guard))
        .with_state(state)
}

async fn guard(State(state): State<Arc<Lab>>, request: WebRequest, next: Next) -> Response {
    let rejected = validate_request(&state, &request);
    let mut response = match rejected {
        Some(value) => value,
        None => next.run(request).await,
    };
    for (key, value) in [
        ("cache-control", "no-store"),
        ("pragma", "no-cache"),
        (
            "content-security-policy",
            "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
        ),
        ("x-content-type-options", "nosniff"),
        ("x-frame-options", "DENY"),
        ("referrer-policy", "no-referrer"),
        (
            "permissions-policy",
            "camera=(), microphone=(), geolocation=()",
        ),
    ] {
        response
            .headers_mut()
            .insert(key, HeaderValue::from_static(value));
    }
    response
}
fn validate_request(state: &Lab, request: &WebRequest) -> Option<Response> {
    let headers = request.headers();
    if text_header(headers, "host") != Some(&state.host) {
        return Some(failure(
            StatusCode::FORBIDDEN,
            "InvalidHost",
            "只允许本机地址访问。",
        ));
    }
    if let Some(origin) = text_header(headers, "origin")
        && origin != state.origin
    {
        return Some(failure(
            StatusCode::FORBIDDEN,
            "InvalidOrigin",
            "请求来源不匹配。",
        ));
    }
    if text_header(headers, "sec-fetch-site").is_some_and(|v| !matches!(v, "same-origin" | "none"))
    {
        return Some(failure(
            StatusCode::FORBIDDEN,
            "InvalidOrigin",
            "不接受跨站请求。",
        ));
    }
    if !request.uri().path().starts_with("/api/") {
        return None;
    }
    let mutation = !matches!(*request.method(), Method::GET | Method::HEAD);
    let control = state.is_control(headers);
    if mutation {
        if text_header(headers, "content-type").and_then(|v| v.split(';').next())
            != Some("application/json")
        {
            return Some(failure(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "InvalidContentType",
                "仅接受 JSON 请求。",
            ));
        }
        if !control && text_header(headers, "origin") != Some(&state.origin) {
            return Some(failure(
                StatusCode::FORBIDDEN,
                "InvalidOrigin",
                "请求来源不匹配。",
            ));
        }
    }
    let bootstrap_request =
        request.uri().path() == "/api/session" && request.method() == Method::POST;
    if bootstrap_request {
        return None;
    }
    if !control && !state.is_browser(headers) {
        return Some(failure(
            StatusCode::UNAUTHORIZED,
            "SessionRequired",
            "请使用启动脚本重新打开测试台。",
        ));
    }
    if mutation
        && !control
        && !text_header(headers, "x-csrf-token").is_some_and(|v| same_secret(v, &state.csrf_token))
    {
        return Some(failure(
            StatusCode::FORBIDDEN,
            "InvalidCsrfToken",
            "页面会话已失效，请重新打开测试台。",
        ));
    }
    None
}
async fn session(State(state): State<Arc<Lab>>) -> Json<Value> {
    Json(json!({"csrf_token":state.csrf_token}))
}
async fn bootstrap(
    State(state): State<Arc<Lab>>,
    headers: HeaderMap,
    input: Result<Json<BootstrapInput>, JsonRejection>,
) -> Response {
    let input = match json_input(input) {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    let mut token = state.bootstrap.lock().await;
    let valid = !token.used
        && token.issued.elapsed() < Duration::from_secs(600)
        && same_secret(&input.token, &token.token);
    if !valid && !state.is_browser(&headers) {
        return failure(
            StatusCode::UNAUTHORIZED,
            "SessionRequired",
            "打开链接已使用或过期，请运行启动脚本重新打开。 ",
        );
    }
    token.used = true;
    state.browser_expires_at.store(
        state.started.elapsed().as_secs() + 8 * 3600,
        Ordering::Release,
    );
    let mut response = Json(json!({"csrf_token":state.csrf_token})).into_response();
    let cookie = format!(
        "{}={}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800",
        state.cookie_name, state.browser_token
    );
    response.headers_mut().insert(
        header::SET_COOKIE,
        HeaderValue::from_str(&cookie).expect("generated cookie"),
    );
    response
}
async fn open_browser(State(state): State<Arc<Lab>>, headers: HeaderMap) -> Response {
    if !state.is_control(&headers) {
        return failure(
            StatusCode::FORBIDDEN,
            "ControlRequired",
            "此操作仅供本机启动脚本使用。",
        );
    }
    *state.bootstrap.lock().await = Bootstrap {
        token: random_token(),
        issued: Instant::now(),
        used: false,
    };
    Json(json!({"url":state.browser_url().await})).into_response()
}
async fn stop(State(state): State<Arc<Lab>>, headers: HeaderMap) -> Response {
    if !state.is_control(&headers) {
        return failure(
            StatusCode::FORBIDDEN,
            "ControlRequired",
            "此操作仅供本机管理脚本使用。",
        );
    }
    state.shutdown.notify_one();
    Json(json!({"stopping":true})).into_response()
}
fn mask_id(student_id: &str) -> String {
    let chars: Vec<_> = student_id.chars().collect();
    if chars.len() < 6 {
        return "已保存账号".into();
    }
    format!(
        "{}****{}",
        chars.iter().take(2).collect::<String>(),
        chars.iter().skip(chars.len() - 2).collect::<String>()
    )
}
async fn status(State(state): State<Arc<Lab>>) -> Response {
    let credentials = match state.credentials().await {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    let account = credentials
        .as_ref()
        .map(|c| c.account_id.as_str())
        .unwrap_or(PUBLIC_ACCOUNT);
    let session = match state
        .core("auth.status", json!({"account_id":account}))
        .await
    {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    Json(json!({"account_id":account,"credentials":{"stored":credentials.is_some(),"username_hint":credentials.as_ref().map(|c|mask_id(&c.student_id))},
        "session":session,"runtime":{"mode":"local_lab","version":env!("CARGO_PKG_VERSION"),"core_available":true},"last_login":state.last_login.lock().await.clone()})).into_response()
}
async fn save_credentials(
    State(state): State<Arc<Lab>>,
    input: Result<Json<CredentialInput>, JsonRejection>,
) -> Response {
    let input = match json_input(input) {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    if !(4..=64).contains(&input.student_id.len())
        || !input.student_id.bytes().all(|b| b.is_ascii_digit())
        || input.password.is_empty()
        || input.password.len() > 512
        || input
            .password
            .chars()
            .any(|c| matches!(c, '\0' | '\r' | '\n'))
    {
        return failure(
            StatusCode::BAD_REQUEST,
            "InvalidInput",
            "请输入有效学号与密码，密码最多 512 字节。",
        );
    }
    let Ok(_gate) = state.credential_gate.try_lock() else {
        return failure(
            StatusCode::CONFLICT,
            "Busy",
            "已有凭据或登录操作进行中，请稍候。",
        );
    };
    let previous = match state.credentials().await {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    let account = previous
        .as_ref()
        .filter(|c| c.student_id == input.student_id)
        .map(|c| c.account_id.clone())
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    if let Some(old) = &previous
        && let Err(e) = state
            .core("auth.logout", json!({"account_id":old.account_id}))
            .await
    {
        return core_failure(e);
    }
    if let Err(e) = state
        .core(
            "accounts.upsert",
            json!({"account_id":account,"label":"复旦测试账号","provider":"fudan"}),
        )
        .await
    {
        return core_failure(e);
    }
    if let Err(e)=state.platform.call("vault.set",json!({"key":CREDENTIAL_KEY,"value":{"student_id":input.student_id,"password":input.password,"account_id":account}})).await {return core_failure(e);}
    *state.last_login.lock().await = None;
    Json(json!({"stored":true,"username_hint":mask_id(&input.student_id)})).into_response()
}
async fn delete_credentials(State(state): State<Arc<Lab>>) -> Response {
    let Ok(_gate) = state.credential_gate.try_lock() else {
        return failure(
            StatusCode::CONFLICT,
            "Busy",
            "已有凭据或登录操作进行中，请稍候。",
        );
    };
    if let Some(previous) = match state.credentials().await {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    } && let Err(e) = state
        .core("auth.logout", json!({"account_id":previous.account_id}))
        .await
    {
        return core_failure(e);
    }
    if let Err(e) = state
        .platform
        .call("vault.delete", json!({"key":CREDENTIAL_KEY}))
        .await
    {
        return core_failure(e);
    }
    *state.last_login.lock().await = None;
    Json(json!({"stored":false})).into_response()
}
async fn login(
    State(state): State<Arc<Lab>>,
    input: Result<Json<LoginInput>, JsonRejection>,
) -> Response {
    let input = match json_input(input) {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    let target = match input.target.as_str() {
        "academic" => dansheng_connectors::login::LoginTarget::Academic,
        "canvas" => dansheng_connectors::login::LoginTarget::Canvas,
        "ecard" => dansheng_connectors::login::LoginTarget::Ecard,
        "webvpn" => dansheng_connectors::login::LoginTarget::WebVpn,
        _ => {
            return failure(
                StatusCode::BAD_REQUEST,
                "InvalidInput",
                "不支持此登录来源。",
            );
        }
    };
    let Ok(_gate) = state.credential_gate.try_lock() else {
        return failure(StatusCode::CONFLICT, "Busy", "已有登录操作进行中，请稍候。");
    };
    let credentials = match state.credentials().await {
        Ok(Some(v)) => v,
        Ok(None) => {
            return failure(
                StatusCode::BAD_REQUEST,
                "CredentialsRequired",
                "请先加密保存凭据。",
            );
        }
        Err(e) => return core_failure(e),
    };
    {
        let mut last = state.last_attempt.lock().await;
        if last.is_some_and(|v| v.elapsed() < Duration::from_secs(45)) {
            return failure(
                StatusCode::TOO_MANY_REQUESTS,
                "LoginThrottled",
                "请至少间隔 45 秒再尝试登录，避免重复尝试密码。",
            );
        }
        *last = Some(Instant::now());
    }
    let progress = dansheng_connectors::login::LoginProgress::default();
    let session = match tokio::time::timeout(
        Duration::from_secs(60),
        dansheng_connectors::login::login_with_progress(
            &credentials.student_id,
            &credentials.password,
            target,
            progress.clone(),
        ),
    )
    .await
    {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => {
            *state.last_login.lock().await = Some(
                json!({"target":input.target,"state":"failed","code":e.code(),"progress":progress.snapshot()}),
            );
            return (StatusCode::BAD_REQUEST,Json(json!({"error":{"code":e.code(),"message":e.message(),"progress":progress.snapshot()}}))).into_response();
        }
        Err(_) => {
            return failure(
                StatusCode::GATEWAY_TIMEOUT,
                "LoginTimeout",
                "登录超时；不会自动重复提交，请稍后手动检查。",
            );
        }
    };
    if let Err(e)=state.core("auth.session.set",json!({"account_id":credentials.account_id,"origin":session.origin,"cookies":session.cookies,"persist":true})).await {return core_failure(e);}
    if input.target=="canvas" && let Err(e)=state.core("canvas.configure",json!({"account_id":credentials.account_id,"origin":"https://elearning.fudan.edu.cn","access":"host_session"})).await {
        return core_failure(e);
    }
    *state.last_login.lock().await =
        Some(json!({"target":input.target,"state":"session_imported"}));
    Json(json!({"state":"session_imported","target":input.target,"origin":session.origin,"message":"会话已加密导入；请继续执行对应业务的只读测试确认可用。"})).into_response()
}
async fn probe(
    State(state): State<Arc<Lab>>,
    input: Result<Json<ProbeInput>, JsonRejection>,
) -> Response {
    let input = match json_input(input) {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    let Ok(_slot) = state.probe_slots.try_acquire() else {
        return failure(
            StatusCode::TOO_MANY_REQUESTS,
            "Busy",
            "测试正在执行，请稍候。",
        );
    };
    let account = if matches!(
        input.probe.as_str(),
        "academic_semesters"
            | "canvas_courses"
            | "canvas_content"
            | "native_job"
            | "network_routes"
            | "ecard_balance"
            | "rooms"
            | "library_occupancy"
            | "bus"
            | "cache"
    ) {
        match state.active_account().await {
            Ok(v) => v,
            Err(e) => return core_failure(e),
        }
    } else {
        PUBLIC_ACCOUNT.into()
    };
    if input.probe == "canvas_content" {
        return canvas_content_probe(&state, &account, input.course_index.unwrap_or(0)).await;
    }
    if input.probe == "native_job" {
        return native_job_probe(&state, &account).await;
    }
    let (method, params) = match input.probe.as_str() {
        "core" => ("core.info", json!({})),
        "public_notices" => (
            "fudan.notices",
            json!({"account_id":PUBLIC_ACCOUNT,"page":1}),
        ),
        "academic_semesters" => ("fudan.semesters", json!({"account_id":account})),
        "canvas_courses" => ("canvas.courses.sync", json!({"account_id":account})),
        "ecard_balance" => ("fudan.ecard.balance", json!({"account_id":account})),
        "rooms" => (
            "fudan.rooms",
            json!({"account_id":account,"building":"HGD","date":(chrono::Utc::now()+chrono::Duration::hours(8)).date_naive().to_string()}),
        ),
        "library_occupancy" => ("fudan.library.occupancy", json!({"account_id":account})),
        "bus" => ("fudan.bus", json!({"account_id":account,"holiday":false})),
        "network_routes" => ("http.routes.get", json!({"account_id":account})),
        "cache" => ("sources.query", json!({"account_id":account,"limit":25})),
        _ => {
            return failure(
                StatusCode::BAD_REQUEST,
                "UnknownProbe",
                "测试台仅开放预设的只读测试。",
            );
        }
    };
    let start = Instant::now();
    let result =
        match tokio::time::timeout(Duration::from_secs(60), state.core(method, params)).await {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => return core_failure(e),
            Err(_) => {
                return failure(
                    StatusCode::GATEWAY_TIMEOUT,
                    "RequestTimeout",
                    "只读测试超时，请稍后手动重试。",
                );
            }
        };
    let count = result
        .as_array()
        .map(Vec::len)
        .or_else(|| result["records"].as_array().map(Vec::len))
        .or_else(|| result["semesters"].as_array().map(Vec::len))
        .or_else(|| result["routes"].as_array().map(Vec::len))
        .or_else(|| result.get("payload").map(|_| 1));
    Json(json!({"probe":input.probe,"ok":true,"elapsed_ms":start.elapsed().as_millis(),
        "summary":{"count":count,"message":"Core 调用已完成；结果仅在当前测试页面展示。"},"result":result})).into_response()
}

async fn configure_webvpn(
    State(state): State<Arc<Lab>>,
    headers: HeaderMap,
    input: Result<Json<WebvpnInput>, JsonRejection>,
) -> Response {
    if !state.is_control(&headers) {
        return failure(
            StatusCode::FORBIDDEN,
            "ControlRequired",
            "网络路由仅能由可信本机宿主管理。",
        );
    }
    let input = match json_input(input) {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let account = match state.active_account().await {
        Ok(account) if account != PUBLIC_ACCOUNT => account,
        Ok(_) => {
            return failure(
                StatusCode::BAD_REQUEST,
                "CredentialsRequired",
                "请先配置本机测试账号。",
            );
        }
        Err(error) => return core_failure(error),
    };
    let origins = input.origins.unwrap_or_else(|| {
        dansheng_connectors::webvpn::DEFAULT_ORIGINS
            .iter()
            .map(|origin| (*origin).to_owned())
            .collect()
    });
    let mut routes = match dansheng_connectors::webvpn::gateway_routes(&origins, input.mode) {
        Ok(routes) => routes,
        Err(error) => return core_failure(error),
    };
    let existing = match state
        .core("http.routes.get", json!({"account_id":account}))
        .await
    {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let existing: Vec<dansheng_core::network_routes::GatewayRoute> =
        match serde_json::from_value(existing["routes"].clone()) {
            Ok(value) => value,
            Err(_) => {
                return failure(
                    StatusCode::BAD_REQUEST,
                    "RouteError",
                    "已有路由配置格式不正确。",
                );
            }
        };
    routes.extend(
        existing
            .into_iter()
            .filter(|route| route.provider != "fudan.webvpn"),
    );
    match state
        .core(
            "http.routes.set",
            json!({"account_id":account,"routes":routes}),
        )
        .await
    {
        Ok(_) => Json(json!({"configured":true,"mode":input.mode,"origin_count":origins.len()}))
            .into_response(),
        Err(error) => core_failure(error),
    }
}

async fn native_job_probe(state: &Lab, account: &str) -> Response {
    let started = Instant::now();
    let queued=match state.core("jobs.schedule",json!({"kind":"service","method":"canvas.courses.sync","input":{"account_id":account},"deadline_window_seconds":60})).await {Ok(value)=>value,Err(error)=>return core_failure(error)};
    let Some(job_id) = queued["job_id"].as_str() else {
        return failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            "InvalidJobReceipt",
            "任务回执不完整。",
        );
    };
    if let Err(error) = state.core("jobs.run", json!({"job_id":job_id})).await {
        return core_failure(error);
    }
    let status = match state.core("jobs.status", json!({"job_id":job_id})).await {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let count = status["result"].as_array().map(Vec::len);
    Json(json!({"probe":"native_job","ok":status["state"]=="succeeded","elapsed_ms":started.elapsed().as_millis(),
        "summary":{"count":count,"message":"原生只读任务已完成调度、执行和持久化结果检查。"},
        "result":{"kind":"service","method":"canvas.courses.sync","state":status["state"],"record_count":count}})).into_response()
}

fn canvas_identity(response: &Value) -> Option<(String, Option<String>)> {
    if response["status"] != 200 {
        return None;
    }
    let profile: Value = serde_json::from_str(response["body"].as_str()?).ok()?;
    let id = profile["id"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| profile["id"].as_u64().map(|id| id.to_string()))?;
    if id.is_empty() || id.len() > 32 || !id.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let login = profile["login_id"]
        .as_str()
        .or_else(|| profile["sis_user_id"].as_str())
        .map(str::to_owned);
    Some((id, login))
}

async fn configure_canvas_token(
    State(state): State<Arc<Lab>>,
    headers: HeaderMap,
    input: Result<Json<CanvasTokenInput>, JsonRejection>,
) -> Response {
    if !state.is_control(&headers) {
        return failure(
            StatusCode::FORBIDDEN,
            "ControlRequired",
            "令牌绑定仅供可信本机宿主使用。",
        );
    }
    let input = match json_input(input) {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let token = input.token.trim();
    if token.is_empty()
        || token.len() > 4096
        || !token.is_ascii()
        || token
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
    {
        return failure(StatusCode::BAD_REQUEST, "InvalidInput", "令牌格式不正确。");
    }
    let Ok(_gate) = state.credential_gate.try_lock() else {
        return failure(StatusCode::CONFLICT, "Busy", "已有凭据操作正在执行。");
    };
    let credentials = match state.credentials().await {
        Ok(Some(value)) => value,
        Ok(None) => {
            return failure(
                StatusCode::BAD_REQUEST,
                "CredentialsRequired",
                "请先配置本机账号。",
            );
        }
        Err(error) => return core_failure(error),
    };
    let origin = "https://elearning.fudan.edu.cn";
    let profile_url = format!("{origin}/api/v1/users/self/profile");
    // Verify in an isolated in-memory account before replacing the current session.
    let temporary = uuid::Uuid::new_v4().to_string();
    if let Err(error)=state.core("auth.session.set",json!({"account_id":temporary,"origin":origin,"bearer":token,"cookies":[],"persist":false})).await {return core_failure(error);}
    let verified=state.core("http.request",json!({"account_id":temporary,"url":profile_url,"method":"GET","headers":{"Accept":"application/json"},"follow_redirects":false})).await;
    let _ = state
        .core("auth.logout", json!({"account_id":temporary}))
        .await;
    let _ = state
        .engine
        .store
        .kv_delete("core:session-policy", &temporary);
    let identity = match verified {
        Ok(value) => canvas_identity(&value),
        Err(error) => return core_failure(error),
    };
    let Some((token_user, login_id)) = identity else {
        return failure(
            StatusCode::BAD_REQUEST,
            "CanvasTokenRejected",
            "Canvas 未确认令牌身份；原会话未替换。",
        );
    };
    let matches_login = login_id.as_deref().is_some_and(|login| {
        login.eq_ignore_ascii_case(&credentials.student_id)
            || login.eq_ignore_ascii_case(&format!("{}@fudan.edu.cn", credentials.student_id))
    });
    let matches_existing = if matches_login {
        true
    } else {
        state.core("http.request",json!({"account_id":credentials.account_id,"url":profile_url,"method":"GET","headers":{"Accept":"application/json"},"follow_redirects":false})).await.ok().and_then(|value|canvas_identity(&value)).is_some_and(|(id,_)|id==token_user)
    };
    if !matches_existing {
        return failure(
            StatusCode::BAD_REQUEST,
            "AccountIdentityMismatch",
            "令牌身份无法与当前账号匹配；原会话未替换。",
        );
    }
    if let Err(error)=state.core("auth.session.set",json!({"account_id":credentials.account_id,"origin":origin,"bearer":token,"cookies":[],"persist":true})).await{return core_failure(error);}
    if let Err(error) = state
        .core(
            "canvas.configure",
            json!({"account_id":credentials.account_id,"origin":origin,"access":"host_token"}),
        )
        .await
    {
        return core_failure(error);
    }
    *state.last_login.lock().await = Some(json!({"target":"canvas","state":"token_verified"}));
    Json(json!({"configured":true,"access":"host_token","identity_verified":true,"persisted":true}))
        .into_response()
}

// Verify the already saved bearer in an isolated in-memory Core session. The
// credential and upstream identity never enter the returned diagnostic object.
async fn canvas_token_diagnostic(State(state): State<Arc<Lab>>, headers: HeaderMap) -> Response {
    if !state.is_control(&headers) {
        return failure(
            StatusCode::FORBIDDEN,
            "ControlRequired",
            "此诊断仅供本机脚本使用。",
        );
    }
    let Ok(_gate) = state.credential_gate.try_lock() else {
        return failure(StatusCode::CONFLICT, "Busy", "已有凭据操作正在执行。");
    };
    let account = match state.active_account().await {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let saved = match state
        .platform
        .call(
            "vault.get",
            json!({"key":format!("http-sessions:{account}")}),
        )
        .await
    {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let origin = "https://elearning.fudan.edu.cn";
    let bearer = saved["value"]
        .as_array()
        .and_then(|sessions| sessions.iter().find(|session| session["origin"] == origin))
        .and_then(|session| session["bearer"].as_str())
        .filter(|token| !token.trim().is_empty());
    let Some(bearer) = bearer else {
        return Json(
            json!({"ok":false,"stored_bearer":false,"error_code":"StoredCanvasBearerMissing"}),
        )
        .into_response();
    };
    let temporary = uuid::Uuid::new_v4().to_string();
    if let Err(error)=state.core("auth.session.set",json!({"account_id":temporary,"origin":origin,"bearer":bearer,"cookies":[],"persist":false})).await {return core_failure(error);}
    let result = state.core("http.request",json!({"account_id":temporary,"url":format!("{origin}/api/v1/users/self/profile"),"method":"GET","headers":{"Accept":"application/json"},"follow_redirects":false,"timeout_ms":15000})).await;
    let _ = state
        .core("auth.logout", json!({"account_id":temporary}))
        .await;
    let _ = state
        .engine
        .store
        .kv_delete("core:session-policy", &temporary);
    match result {
        Ok(value) => {
            let verified = canvas_identity(&value).is_some();
            Json(json!({"ok":verified,"stored_bearer":true,"http_status":value["status"],"identity_verified":verified})).into_response()
        }
        Err(error) => {
            Json(json!({"ok":false,"stored_bearer":true,"error_code":error.code})).into_response()
        }
    }
}

fn canvas_probe_error(method: &str, error: &CoreError) -> Value {
    let mut report = json!({"method":method,"ok":false,"code":error.code});
    // Only a complete numeric HTTP status may leave the connector error message.
    // AuthenticationRequired can also mean a redirect, so do not infer a 401.
    if error.code == "SourceHttpError"
        && error.message.len() == 3
        && error.message.bytes().all(|byte| byte.is_ascii_digit())
        && let Ok(status) = error.message.parse::<u16>()
        && (100..=599).contains(&status)
    {
        report["http_status"] = json!(status);
    }
    report
}

async fn canvas_content_probe(state: &Lab, account: &str, index: usize) -> Response {
    let started = Instant::now();
    let courses = match state
        .core("canvas.courses.sync", json!({"account_id":account}))
        .await
    {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let Some(courses) = courses.as_array() else {
        return failure(
            StatusCode::BAD_REQUEST,
            "SourceSchemaChanged",
            "课程列表结构不正确。",
        );
    };
    let Some(course) = courses.get(index) else {
        return failure(
            StatusCode::BAD_REQUEST,
            "InvalidInput",
            "课程序号超出范围。",
        );
    };
    let Some(course_id) = course["payload"]["id"].as_str() else {
        return failure(
            StatusCode::BAD_REQUEST,
            "SourceSchemaChanged",
            "课程标识结构不正确。",
        );
    };
    let mut reports = Vec::new();
    for method in [
        "canvas.assignments.sync",
        "canvas.materials.sync",
        "canvas.folders.sync",
        "canvas.modules.sync",
        "canvas.pages.sync",
        "canvas.announcements.sync",
    ] {
        let result = tokio::time::timeout(
            Duration::from_secs(20),
            state.core(method, json!({"account_id":account,"course_id":course_id})),
        )
        .await;
        match result {
            Ok(Ok(value)) => {
                let count = value.as_array().map(Vec::len).unwrap_or(0);
                reports.push(json!({"method":method,"ok":true,"count":count}));
                let detail = if method == "canvas.modules.sync" {
                    value
                        .as_array()
                        .and_then(|rows| rows.first())
                        .and_then(|row| row["payload"]["id"].as_str())
                        .map(|id| {
                            (
                                "canvas.module_items.sync",
                                json!({"account_id":account,"course_id":course_id,"module_id":id}),
                            )
                        })
                } else if method == "canvas.pages.sync" {
                    value.as_array().and_then(|rows|rows.first()).and_then(|row|row["payload"]["page_slug"].as_str()).map(|slug|("canvas.page.read",json!({"account_id":account,"course_id":course_id,"page_slug":slug})))
                } else {
                    None
                };
                if let Some((detail_method, params)) = detail {
                    match tokio::time::timeout(Duration::from_secs(15),state.core(detail_method,params)).await {
                        Ok(Ok(data))=>reports.push(json!({"method":detail_method,"ok":true,"count":data.as_array().map(Vec::len).unwrap_or(1)})),
                        Ok(Err(error))=>reports.push(canvas_probe_error(detail_method, &error)),
                        Err(_)=>reports.push(json!({"method":detail_method,"ok":false,"code":"Timeout"})),
                    }
                }
            }
            Ok(Err(error)) => reports.push(canvas_probe_error(method, &error)),
            Err(_) => reports.push(json!({"method":method,"ok":false,"code":"Timeout"})),
        }
        if started.elapsed() > Duration::from_secs(45) {
            break;
        }
    }
    let complete = reports
        .iter()
        .filter(|report| {
            report["method"] != "canvas.page.read" && report["method"] != "canvas.module_items.sync"
        })
        .count()
        == 6;
    let passed = reports.iter().filter(|report| report["ok"] == true).count();
    Json(json!({"probe":"canvas_content","ok":complete && passed==reports.len(),"elapsed_ms":started.elapsed().as_millis(),
        "summary":{"count":passed,"message":"只记录各内容接口结果；不输出课程名称、正文或资源标识。"},
        "result":{"course_index":index,"course_count":courses.len(),"complete":complete,"coverage":"collections_and_first_available_details","checks":reports}})).into_response()
}

// Fixed read-only requests through Core. Raw HTML, cookies, headers and values
// stay in-process; even the control caller only receives a structural summary.
async fn academic_diagnostic(State(state): State<Arc<Lab>>, headers: HeaderMap) -> Response {
    if !state.is_control(&headers) {
        return failure(
            StatusCode::FORBIDDEN,
            "ControlRequired",
            "此诊断仅供本机脚本使用。",
        );
    }
    let Ok(_slot) = state.probe_slots.try_acquire() else {
        return failure(
            StatusCode::TOO_MANY_REQUESTS,
            "Busy",
            "已有测试进行中，请稍候。",
        );
    };
    let account = match state.active_account().await {
        Ok(v) => v,
        Err(e) => return core_failure(e),
    };
    let mut reports = Vec::new();
    for (case, path, accept) in [
        (
            "course_table_connector_accept",
            "/student/for-std/course-table",
            "application/json, text/html",
        ),
        (
            "course_table_html_accept",
            "/student/for-std/course-table",
            "text/html",
        ),
        (
            "course_table_default_accept",
            "/student/for-std/course-table",
            "*/*",
        ),
        (
            "lesson_search_html_accept",
            "/student/for-all/lesson-search",
            "text/html",
        ),
    ] {
        let result=state.core("http.request",json!({"url":format!("https://fdjwgl.fudan.edu.cn{path}"),"method":"GET","account_id":account,"headers":{"Accept":accept},"follow_redirects":false,"timeout_ms":15000})).await;
        match result {
            Ok(response) => {
                reports.push(json!({"case":case,"shape":academic_response_shape(&response)}))
            }
            Err(error) => reports.push(json!({"case":case,"error_code":error.code})),
        }
    }
    Json(json!({"ok":true,"reports":reports})).into_response()
}

fn academic_response_shape(response: &Value) -> Value {
    use scraper::{Html, Selector};
    let body = response["body"].as_str().unwrap_or_default();
    let document = Html::parse_document(body);
    let count = |selector: &str| {
        document
            .select(&Selector::parse(selector).expect("static selector"))
            .count()
    };
    let semesters = has_semester_script(body);
    let content_type = response["headers"]["content-type"]
        .as_str()
        .and_then(|value| value.split(';').next())
        .filter(|value| matches!(*value, "text/html" | "application/json" | "text/plain"));
    let error_markers = [
        "NullPointerException",
        "HttpMediaTypeNotAcceptableException",
        "HttpMessageNotWritableException",
        "No converter",
        "Whitelabel Error Page",
        "ClassCastException",
        "Internal Server Error",
        "系统异常",
        "系统错误",
    ];
    json!({"http_status":response["status"],"body_bytes":body.len(),
        "content_type":content_type,
        "semester_option_count":count("#allSemesters option"),"lesson_semester_option_count":count("select#semester option[name=semesterAssoc]"),
        "password_input_count":count("input[type=password]"),"semester_script":semesters,
        "error_markers":error_markers.into_iter().filter(|marker|body.contains(marker)).collect::<Vec<_>>()})
}

// These are the two reference-backed GETs made by fudan.rooms, kept separate
// here so a failed first stage does not hide the second stage's actual status.
async fn rooms_diagnostic(State(state): State<Arc<Lab>>, headers: HeaderMap) -> Response {
    if !state.is_control(&headers) {
        return failure(
            StatusCode::FORBIDDEN,
            "ControlRequired",
            "此诊断仅供本机脚本使用。",
        );
    }
    let Ok(_slot) = state.probe_slots.try_acquire() else {
        return failure(
            StatusCode::TOO_MANY_REQUESTS,
            "Busy",
            "已有测试进行中，请稍候。",
        );
    };
    let account = match state.active_account().await {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let routes = match state
        .core("http.routes.get", json!({"account_id":account}))
        .await
    {
        Ok(value) => value,
        Err(error) => return core_failure(error),
    };
    let configured_mode = routes["routes"]
        .as_array()
        .and_then(|routes| {
            routes
                .iter()
                .find(|route| route["origin"] == "http://10.64.130.6")
        })
        .and_then(|route| route["mode"].as_str())
        .filter(|mode| matches!(*mode, "direct" | "gateway" | "auto"));
    let day = (chrono::Utc::now() + chrono::Duration::hours(8)).date_naive();
    let mut reports = Vec::new();
    for (case, path) in [
        ("rooms_status", format!("/daystatus.asp?b=HGD&day={day}")),
        ("rooms_detail", format!("/?b=HGD&c=&p=&day={day}")),
    ] {
        let response = state.core("http.request",json!({"account_id":account,"url":format!("http://10.64.130.6{path}"),"method":"GET","follow_redirects":false,"timeout_ms":15000})).await;
        reports.push(match response {
            Ok(value) => json!({"case":case,"shape":rooms_response_shape(&value)}),
            Err(error) => json!({"case":case,"error_code":error.code}),
        });
    }
    let ok = reports.iter().all(|report| {
        report["shape"]["http_status"]
            .as_u64()
            .is_some_and(|status| (200..300).contains(&status))
    });
    Json(json!({"ok":ok,"complete":true,"configured_route_mode":configured_mode,"actual_route":null,"reports":reports})).into_response()
}

fn rooms_response_shape(response: &Value) -> Value {
    use scraper::{Html, Selector};
    let body = response["body"].as_str().unwrap_or_default();
    let document = Html::parse_document(body);
    let content_type = response["headers"]["content-type"]
        .as_str()
        .and_then(|value| value.split(';').next())
        .filter(|value| matches!(*value, "text/html" | "application/json" | "text/plain"));
    let markers = [
        "Microsoft VBScript",
        "ADODB.Connection",
        "Microsoft OLE DB Provider",
        "Internal Server Error",
        "WebVPN",
    ];
    json!({"http_status":response["status"],"body_bytes":body.len(),"content_type":content_type,
        "room_row_count":document.select(&Selector::parse("tr[id^=r]").expect("static selector")).count(),
        "status_array_marker":body.contains("\"status\":["),
        "error_markers":markers.into_iter().filter(|marker|body.contains(marker)).collect::<Vec<_>>()})
}

fn has_semester_script(body: &str) -> bool {
    body.contains("var semesters")
        || body.contains("let semesters")
        || body.contains("const semesters")
}

#[cfg(test)]
mod diagnostic_tests {
    use super::*;
    #[test]
    fn room_diagnostics_never_export_sql_errors_headers_or_room_identifiers() {
        let response = json!({"status":500,"headers":{"content-type":"text/html; charset=UTF-8","set-cookie":"SECRET_COOKIE"},"body":"<html><title>PRIVATE_TITLE</title>Microsoft OLE DB Provider Password=SECRET_PASSWORD<table><tr id=rPRIVATE_ROOM><td>PRIVATE_LESSON</td></tr></table></html>"});
        let report = rooms_response_shape(&response);
        assert_eq!(report["http_status"], 500);
        assert_eq!(report["room_row_count"], 1);
        assert_eq!(
            report["error_markers"],
            json!(["Microsoft OLE DB Provider"])
        );
        for secret in [
            "PRIVATE_TITLE",
            "SECRET_COOKIE",
            "SECRET_PASSWORD",
            "PRIVATE_ROOM",
            "PRIVATE_LESSON",
        ] {
            assert!(!report.to_string().contains(secret));
        }
    }
    #[test]
    fn canvas_diagnostics_only_export_valid_numeric_http_status() {
        let method = "canvas.pages.sync";
        let report = canvas_probe_error(method, &CoreError::new("SourceHttpError", "500"));
        assert_eq!(report["http_status"], 500);
        assert_eq!(report["ok"], false);
        for (code, message) in [
            ("SourceHttpError", "500 SECRET_BODY"),
            ("SourceHttpError", "SECRET_TOKEN"),
            ("SourceHttpError", "099"),
            ("SourceHttpError", "600"),
            ("SourceHttpError", "+500"),
            ("AuthenticationRequired", "401"),
        ] {
            let report = canvas_probe_error(method, &CoreError::new(code, message));
            assert!(report.get("http_status").is_none());
            assert!(!report.to_string().contains("SECRET"));
            assert!(report.get("message").is_none());
        }
    }

    #[test]
    fn token_identity_validation_requires_a_successful_canvas_profile() {
        let profile = json!({"id":"9007199254740993","login_id":"synthetic-student"});
        assert!(canvas_identity(&json!({"status":401,"body":profile.to_string()})).is_none());
        assert!(
            canvas_identity(&json!({"status":200,"body":"<html>login required</html>"})).is_none()
        );
        let identity = canvas_identity(&json!({"status":200,"body":profile.to_string()})).unwrap();
        assert_eq!(identity.0, "9007199254740993");
        assert_eq!(identity.1.as_deref(), Some("synthetic-student"));
    }
    #[test]
    fn academic_diagnostics_never_export_body_values_or_session_headers() {
        let response = json!({"status":500,"headers":{"content-type":"text/html; charset=UTF-8","set-cookie":"SECRET_COOKIE"},"body":"<html><title>PRIVATE_STUDENT</title><script>var semesters = [];</script><input type=password value=SECRET_PASSWORD><p>NullPointerException</p></html>"});
        let report = academic_response_shape(&response);
        assert_eq!(report["http_status"], 500);
        assert_eq!(report["password_input_count"], 1);
        assert_eq!(report["error_markers"], json!(["NullPointerException"]));
        for secret in ["PRIVATE_STUDENT", "SECRET_PASSWORD", "SECRET_COOKIE"] {
            assert!(!report.to_string().contains(secret));
        }
    }
}
