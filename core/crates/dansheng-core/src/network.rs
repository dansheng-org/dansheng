use crate::{
    api::{CoreError, CoreResult, Principal},
    network_routes::{
        GatewayRoute, RouteMode, decode_link_header, decode_location, validate_routes,
    },
    policy::Grant,
};
use reqwest::{
    Method,
    cookie::CookieStore as ReqwestCookieStore,
    header::{HeaderMap, HeaderName, HeaderValue},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    net::{IpAddr, SocketAddr},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Semaphore;
use url::Url;

#[cfg(test)]
#[path = "network_csrf_tests.rs"]
mod csrf_tests;

/// Per-service authority and dispatch state. Scoped to the calling future, never
/// shared with unrelated requests or serialized into HTTP/IPC.
pub(crate) struct WriteDispatch {
    check: Box<dyn Fn() -> CoreResult<()> + Send + Sync>,
    dispatched: AtomicBool,
}

tokio::task_local! {
    static WRITE_DISPATCH: Arc<WriteDispatch>;
    static OWNER_PRIVATE_READ: OwnerPrivateRead;
}

struct OwnerPrivateRead {
    principal_id: String,
    account_id: String,
    origin: String,
}

impl WriteDispatch {
    pub(crate) fn new(check: impl Fn() -> CoreResult<()> + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            check: Box::new(check),
            dispatched: AtomicBool::new(false),
        })
    }

    pub(crate) async fn scope<F: std::future::Future>(self: &Arc<Self>, future: F) -> F::Output {
        WRITE_DISPATCH.scope(self.clone(), future).await
    }

    pub(crate) fn was_dispatched(&self) -> bool {
        self.dispatched.load(Ordering::Acquire)
    }

    pub(crate) fn finish<T>(&self, result: CoreResult<T>) -> CoreResult<T> {
        if let Err(error) = (self.check)() {
            // Do not mask uncertainty reported by another trusted transport.
            if self.was_dispatched()
                || result
                    .as_ref()
                    .is_err_and(|e| e.code == "NeedsReconciliation")
            {
                return Err(CoreError::new(
                    "NeedsReconciliation",
                    "write authority changed after dispatch",
                ));
            }
            return Err(error);
        }
        result
    }
}

#[cfg(test)]
#[derive(Default)]
struct TestDispatchPause {
    reached: tokio::sync::Notify,
    resume: tokio::sync::Notify,
}

#[cfg(test)]
impl TestDispatchPause {
    async fn pause(&self) {
        self.reached.notify_one();
        self.resume.notified().await;
    }
}

#[derive(Clone, Deserialize, Serialize)]
pub struct HttpRequest {
    pub url: String,
    #[serde(default = "default_method")]
    pub method: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub body: Option<Value>,
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    #[serde(default = "follow_redirects_by_default")]
    pub follow_redirects: bool,
}
fn follow_redirects_by_default() -> bool {
    true
}
fn default_method() -> String {
    "GET".into()
}
impl Default for HttpRequest {
    fn default() -> Self {
        Self {
            url: String::new(),
            method: default_method(),
            headers: BTreeMap::new(),
            body: None,
            account_id: None,
            timeout_ms: None,
            follow_redirects: true,
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct HttpResponse {
    pub status: u16,
    pub url: String,
    pub headers: BTreeMap<String, String>,
    pub body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub download: Option<DownloadReceipt>,
}

/// Bounded native HTTP bytes for trusted Rust adapters. This is not a text IPC
/// response: credentials are mediated by the same policy as normal requests.
/// Raw bytes deliberately have no revealing Debug or automatic serialization.
#[derive(Clone)]
pub struct BinaryHttpResponse {
    pub status: u16,
    pub url: String,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

struct WireResponse {
    status: u16,
    url: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
    download: Option<DownloadReceipt>,
    max_bytes: u64,
    mutating_request: bool,
}

impl WireResponse {
    fn into_text(self) -> CoreResult<HttpResponse> {
        let body = decode_text(&self.body, &self.headers, self.max_bytes).map_err(|error| {
            if self.mutating_request {
                CoreError::new("NeedsReconciliation", "write response could not be decoded")
            } else {
                error
            }
        })?;
        Ok(HttpResponse {
            status: self.status,
            url: self.url,
            headers: self.headers,
            body,
            download: self.download,
        })
    }

    fn into_binary(self) -> BinaryHttpResponse {
        BinaryHttpResponse {
            status: self.status,
            url: self.url,
            headers: self.headers,
            body: self.body,
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct DownloadReceipt {
    pub status: u16,
    pub headers: BTreeMap<String, String>,
    pub size: u64,
    pub sha256: String,
}

struct SessionJar(Mutex<cookie_store::CookieStore>);
impl ReqwestCookieStore for SessionJar {
    fn set_cookies(&self, headers: &mut dyn Iterator<Item = &HeaderValue>, url: &Url) {
        if let Ok(mut store) = self.0.lock() {
            for header in headers {
                if let Ok(text) = header.to_str() {
                    let _ = store.parse(text, url);
                }
            }
        }
    }
    fn cookies(&self, url: &Url) -> Option<HeaderValue> {
        let store = self.0.lock().ok()?;
        let mut cookies = store.matches(url);
        cookies.sort_by_key(|cookie| std::cmp::Reverse(cookie.path.len()));
        let values = cookies
            .into_iter()
            .map(|cookie| format!("{}={}", cookie.name(), cookie.value()))
            .collect::<Vec<_>>()
            .join("; ");
        if values.is_empty() {
            None
        } else {
            HeaderValue::from_str(&values).ok()
        }
    }
}
struct Session {
    origin: String,
    generation: String,
    bearer: Option<String>,
    secret_headers: BTreeMap<String, String>,
    jar: Arc<SessionJar>,
}

/// Policy supplied by a trusted native adapter, never by serialized HTTP/IPC.
/// No credentials are carried in this policy or returned to the adapter.
#[derive(Clone)]
pub struct CookieCsrf {
    pub origin: String,
    pub cookie_name: String,
    pub header_name: String,
}

fn csrf_required() -> CoreError {
    CoreError::new(
        "CsrfRequired",
        "the HTTP session needs a valid CSRF cookie before sending",
    )
}

fn validate_cookie_csrf_request(
    principal: &Principal,
    grant: &Grant,
    input: &HttpRequest,
    policy: &CookieCsrf,
) -> CoreResult<()> {
    grant.check(principal, "http.request")?;
    grant.check(principal, "http.write")?;
    grant.check_account(principal, input.account_id.as_deref())?;
    let url = Url::parse(&input.url).map_err(|_| CoreError::invalid("invalid request URL"))?;
    validate_url(&url, principal, grant)?;
    let name = HeaderName::from_bytes(policy.header_name.as_bytes())
        .map_err(|_| CoreError::invalid("invalid CSRF header name"))?;
    validate_secret_headers([(name.to_string(), "validation".into())].into())?;
    if url.scheme() != "https"
        || url.origin().ascii_serialization() != policy.origin
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || input.method != "POST"
        || input.follow_redirects
        || input.account_id.as_deref().is_none_or(str::is_empty)
        || policy.cookie_name.is_empty()
        || policy.cookie_name.len() > 128
        || !policy
            .cookie_name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
        || matches!(
            name.as_str(),
            "origin" | "referer" | "content-type" | "accept"
        )
        || input.headers.keys().any(|key| {
            key.eq_ignore_ascii_case(name.as_str())
                || matches!(
                    key.to_ascii_lowercase().as_str(),
                    "origin"
                        | "referer"
                        | "host"
                        | "cookie"
                        | "cookie2"
                        | "authorization"
                        | "proxy-authorization"
                )
        })
    {
        return Err(CoreError::new(
            "PermissionDenied",
            "unsupported cookie-CSRF request",
        ));
    }
    Ok(())
}

/// Decode exactly once like decodeURIComponent, not form decoding: '+' stays '+'.
/// The result never leaves this module or enters HttpRequest/IPC/logs.
fn cookie_csrf_header(jar: &SessionJar, url: &Url, cookie_name: &str) -> CoreResult<HeaderValue> {
    let store = jar.0.lock().map_err(|_| csrf_required())?;
    let matches = store.matches(url);
    let mut tokens = matches.iter().filter(|cookie| cookie.name() == cookie_name);
    let raw = tokens.next().ok_or_else(csrf_required)?.value();
    if tokens.next().is_some() || raw.is_empty() || raw.len() > 8192 {
        return Err(csrf_required());
    }
    let mut decoded = Vec::with_capacity(raw.len());
    let mut bytes = raw.bytes();
    while let Some(byte) = bytes.next() {
        let byte = if byte == b'%' {
            let high = bytes.next().and_then(|b| (b as char).to_digit(16));
            let low = bytes.next().and_then(|b| (b as char).to_digit(16));
            match (high, low) {
                (Some(high), Some(low)) => (high * 16 + low) as u8,
                _ => return Err(csrf_required()),
            }
        } else {
            byte
        };
        if !(0x21..=0x7e).contains(&byte) {
            return Err(csrf_required());
        }
        decoded.push(byte);
    }
    let mut value = HeaderValue::from_bytes(&decoded).map_err(|_| csrf_required())?;
    value.set_sensitive(true);
    Ok(value)
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CredentialKind {
    #[default]
    Any,
    Cookie,
    Bearer,
    /// Explicitly selected, origin-bound nonstandard credentials. Any never sends them.
    SecretHeaders,
    /// No backend credentials. The account may still own gateway authentication.
    Anonymous,
}
/// Marks an authorization slot that holds HTTP Basic credentials. Bearer
/// tokens never contain whitespace, so the two cannot be confused.
const BASIC_PREFIX: &str = "Basic ";

type SessionCopy = (
    String,
    Option<String>,
    Arc<SessionJar>,
    BTreeMap<String, String>,
);

fn validate_secret_headers(
    values: BTreeMap<String, String>,
) -> CoreResult<BTreeMap<String, String>> {
    if values.len() > 16 {
        return Err(CoreError::invalid("too many secret headers"));
    }
    let mut validated = BTreeMap::new();
    let mut bytes = 0usize;
    for (name, value) in values {
        if name.len() > 128 {
            return Err(CoreError::invalid("invalid secret header name"));
        }
        let name = HeaderName::from_bytes(name.as_bytes())
            .map_err(|_| CoreError::invalid("invalid secret header name"))?
            .as_str()
            .to_owned();
        if matches!(
            name.as_str(),
            "authorization"
                | "cookie"
                | "cookie2"
                | "set-cookie"
                | "set-cookie2"
                | "www-authenticate"
                | "host"
                | "content-length"
                | "connection"
                | "keep-alive"
                | "transfer-encoding"
                | "te"
                | "trailer"
                | "upgrade"
                | "expect"
                | "forwarded"
                | "via"
        ) || name.starts_with("proxy-")
            || name.starts_with("x-forwarded-")
        {
            return Err(CoreError::invalid("reserved secret header name"));
        }
        bytes = bytes.saturating_add(name.len()).saturating_add(value.len());
        if value.trim().is_empty()
            || value.len() > 8192
            || bytes > 32768
            || value.bytes().any(|b| !matches!(b, 0x20..=0x7e))
            || HeaderValue::from_str(&value).is_err()
        {
            return Err(CoreError::invalid("invalid secret header value or size"));
        }
        if validated.insert(name, value).is_some() {
            return Err(CoreError::invalid("duplicate secret header name"));
        }
    }
    Ok(validated)
}

fn reject_secret_header_collision(
    headers: &HeaderMap,
    session: Option<&SessionCopy>,
) -> CoreResult<()> {
    if session.is_some_and(|(_, _, _, secret_headers)| {
        secret_headers.keys().any(|name| headers.contains_key(name))
    }) {
        return Err(CoreError::new(
            "PermissionDenied",
            "caller headers conflict with host credentials",
        ));
    }
    Ok(())
}

fn secret_header_value(value: &str) -> CoreResult<HeaderValue> {
    let mut value = HeaderValue::from_str(value)
        .map_err(|_| CoreError::new("SessionError", "invalid secret header"))?;
    value.set_sensitive(true);
    Ok(value)
}

pub(crate) fn secret_headers_from_value(
    value: Option<&Value>,
) -> CoreResult<BTreeMap<String, String>> {
    let Some(value) = value else {
        return Ok(BTreeMap::new());
    };
    let object = value
        .as_object()
        .ok_or_else(|| CoreError::invalid("secret headers must be an object"))?;
    if object.len() > 16 {
        return Err(CoreError::invalid("too many secret headers"));
    }
    let values = object
        .iter()
        .map(|(key, value)| {
            value
                .as_str()
                .map(|value| (key.clone(), value.to_owned()))
                .ok_or_else(|| CoreError::invalid("secret header values must be strings"))
        })
        .collect::<CoreResult<BTreeMap<_, _>>>()?;
    validate_secret_headers(values)
}
#[derive(Clone)]
struct Transfer {
    cookie_csrf: Option<CookieCsrf>,
    sink: Option<PathBuf>,
    max_bytes: u64,
    resume: bool,
    credentials: CredentialKind,
    gateway: bool,
    body_bytes: Option<Vec<u8>>,
}
impl Transfer {
    fn buffered(credentials: CredentialKind) -> Self {
        Self {
            cookie_csrf: None,
            sink: None,
            max_bytes: 8 * 1024 * 1024,
            resume: false,
            credentials,
            gateway: false,
            body_bytes: None,
        }
    }
}
pub struct Network {
    sessions: Mutex<HashMap<(String, String), Session>>,
    routes: Mutex<HashMap<String, Vec<GatewayRoute>>>,
    concurrency: Arc<Semaphore>,
    #[cfg(test)]
    test_roots: Vec<rustls::pki_types::CertificateDer<'static>>,
    #[cfg(test)]
    test_before_queue: Option<Arc<tokio::sync::Notify>>,
    #[cfg(test)]
    test_dns_pause: Option<Arc<TestDispatchPause>>,
}
impl Default for Network {
    fn default() -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
            routes: Mutex::new(HashMap::new()),
            concurrency: Arc::new(Semaphore::new(8)),
            #[cfg(test)]
            test_roots: Vec::new(),
            #[cfg(test)]
            test_before_queue: None,
            #[cfg(test)]
            test_dns_pause: None,
        }
    }
}
impl Network {
    /// Trusted adapters may preserve an owner's exact HTTPS LAN approval while
    /// downloading into a service-owned asset. This never changes the service's
    /// identity or grants. The exception is task-local, GET/HEAD-only, and bound
    /// to one service, account and physical origin; redirects cannot widen it.
    pub async fn with_owner_private_origin_read<T>(
        &self,
        owner: &Principal,
        grant: &Grant,
        delegate: &Principal,
        account: &str,
        origin: &str,
        future: impl std::future::Future<Output = CoreResult<T>>,
    ) -> CoreResult<T> {
        if !owner.is_owner()
            || !matches!(delegate.kind, crate::api::PrincipalKind::Client)
            || !grant.private_network_origins.contains(origin)
        {
            return future.await;
        }
        OWNER_PRIVATE_READ
            .scope(
                OwnerPrivateRead {
                    principal_id: delegate.id.clone(),
                    account_id: account.into(),
                    origin: origin.into(),
                },
                future,
            )
            .await
    }

    fn check_write_binding(
        &self,
        principal: &Principal,
        grant: &Grant,
        account: Option<&str>,
        identity: Option<&str>,
        authority: Option<&WriteDispatch>,
    ) -> CoreResult<()> {
        grant.check(principal, "http.write")?;
        grant.check_account(principal, account)?;
        if let Some(authority) = authority {
            (authority.check)()?;
        }
        if let Some(expected) = identity
            && self.session_fingerprint(account)? != expected
        {
            return Err(CoreError::new(
                "AuthenticationRequired",
                "HTTP session changed before dispatch",
            ));
        }
        Ok(())
    }

    pub fn set_routes(&self, account: &str, routes: Vec<GatewayRoute>) -> CoreResult<()> {
        if account.is_empty() || account.len() > 256 || account.chars().any(char::is_control) {
            return Err(CoreError::invalid("invalid routing account"));
        }
        validate_routes(&routes)?;
        self.routes
            .lock()
            .map_err(|_| CoreError::new("RouteError", "routing registry unavailable"))?
            .insert(account.into(), routes);
        Ok(())
    }
    pub fn routes(&self, account: &str) -> CoreResult<Vec<GatewayRoute>> {
        Ok(self
            .routes
            .lock()
            .map_err(|_| CoreError::new("RouteError", "routing registry unavailable"))?
            .get(account)
            .cloned()
            .unwrap_or_default())
    }
    /// Trusted adapters use this for resource links carried inside a typed API
    /// response. It does not authorize the resulting URL or perform any request.
    pub fn logical_resource_url(&self, account: &str, url: &Url) -> CoreResult<Url> {
        let routes = self.routes(account)?;
        for route in &routes {
            if let Some(logical) = route.decode(url)? {
                return Ok(logical);
            }
        }
        if routes.iter().any(|route| {
            route
                .gateway_origin()
                .is_ok_and(|origin| origin == url.origin().ascii_serialization())
        }) {
            return Err(CoreError::new(
                "UnsafeRoute",
                "resource gateway path is not configured",
            ));
        }
        Ok(url.clone())
    }
    fn copy_session(&self, account: Option<&str>, origin: &str) -> CoreResult<Option<SessionCopy>> {
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?;
        Ok(account
            .and_then(|account| sessions.get(&(account.to_owned(), origin.to_owned())))
            .map(|s| {
                (
                    s.origin.clone(),
                    s.bearer.clone(),
                    s.jar.clone(),
                    s.secret_headers.clone(),
                )
            }))
    }
    fn session_matches(session: Option<&SessionCopy>, kind: CredentialKind) -> bool {
        if kind == CredentialKind::Anonymous {
            return true;
        }
        let Some((_, token, jar, secret_headers)) = session else {
            return false;
        };
        match kind {
            CredentialKind::Any => true,
            CredentialKind::Bearer => token.as_ref().is_some_and(|token| !token.trim().is_empty()),
            CredentialKind::SecretHeaders => !secret_headers.is_empty(),
            CredentialKind::Cookie => jar
                .0
                .lock()
                .is_ok_and(|jar| jar.iter_unexpired().next().is_some()),
            CredentialKind::Anonymous => true,
        }
    }
    pub fn credential_available(&self, account: &str, origin: &str, kind: CredentialKind) -> bool {
        if self
            .copy_session(Some(account), origin)
            .is_ok_and(|value| Self::session_matches(value.as_ref(), kind))
        {
            return true;
        }
        if matches!(kind, CredentialKind::Bearer | CredentialKind::SecretHeaders) {
            return false;
        }
        self.routes(account).is_ok_and(|routes| {
            routes.iter().any(|route| {
                route.origin == origin
                    && route.mode != RouteMode::Direct
                    && route.gateway_origin().is_ok_and(|gateway| {
                        self.copy_session(Some(account), &gateway)
                            .is_ok_and(|session| {
                                Self::session_matches(session.as_ref(), CredentialKind::Cookie)
                            })
                    })
            })
        })
    }
    pub fn set_session(
        &self,
        account: &str,
        origin: &str,
        bearer: Option<String>,
        cookies: Vec<String>,
    ) -> CoreResult<()> {
        self.set_session_with_headers(account, origin, bearer, cookies, BTreeMap::new())
    }
    /// HTTP Basic credentials for one exact origin (e.g. a WebDAV server). The
    /// header value is kept in the session's authorization slot and sent only to
    /// that origin, like a bearer token; it is never returned to callers.
    pub fn set_session_basic(
        &self,
        account: &str,
        origin: &str,
        username: &str,
        password: &str,
    ) -> CoreResult<()> {
        use base64::{Engine as _, engine::general_purpose::STANDARD};
        if !origin.starts_with("https://") {
            return Err(CoreError::invalid("basic credentials require HTTPS"));
        }
        if username.is_empty()
            || username.contains(':')
            || username.len() > 256
            || password.len() > 1024
            || username
                .chars()
                .chain(password.chars())
                .any(char::is_control)
        {
            return Err(CoreError::invalid("invalid basic credentials"));
        }
        let value = format!(
            "{BASIC_PREFIX}{}",
            STANDARD.encode(format!("{username}:{password}"))
        );
        self.insert_session(account, origin, Some(value), Vec::new(), BTreeMap::new())
    }
    pub fn set_session_with_headers(
        &self,
        account: &str,
        origin: &str,
        bearer: Option<String>,
        cookies: Vec<String>,
        secret_headers: BTreeMap<String, String>,
    ) -> CoreResult<()> {
        if bearer
            .as_deref()
            .is_some_and(|token| token.chars().any(char::is_whitespace))
        {
            // Only set_session_basic may store a non-bearer authorization value.
            return Err(CoreError::invalid("invalid bearer token"));
        }
        self.insert_session(account, origin, bearer, cookies, secret_headers)
    }
    fn insert_session(
        &self,
        account: &str,
        origin: &str,
        bearer: Option<String>,
        cookies: Vec<String>,
        secret_headers: BTreeMap<String, String>,
    ) -> CoreResult<()> {
        let secret_headers = validate_secret_headers(secret_headers)?;
        if !secret_headers.is_empty()
            && (account.is_empty() || account.len() > 256 || account.chars().any(char::is_control))
        {
            return Err(CoreError::invalid("invalid secret header account"));
        }
        let url = Url::parse(origin).map_err(|_| CoreError::invalid("invalid session origin"))?;
        if url.scheme() != "https" && url.scheme() != "http" {
            return Err(CoreError::invalid("invalid session scheme"));
        }
        if !secret_headers.is_empty()
            && (url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.path() != "/"
                || url.query().is_some()
                || url.fragment().is_some())
        {
            return Err(CoreError::invalid(
                "secret headers require an exact session origin",
            ));
        }
        let mut store = cookie_store::CookieStore::default();
        for cookie in cookies {
            store
                .parse(&cookie, &url)
                .map_err(|_| CoreError::invalid("invalid session cookie"))?;
        }
        let jar = Arc::new(SessionJar(Mutex::new(store)));
        let origin = url.origin().ascii_serialization();
        self.sessions
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?
            .insert(
                (account.into(), origin.clone()),
                Session {
                    origin,
                    generation: uuid::Uuid::new_v4().to_string(),
                    bearer,
                    secret_headers,
                    jar,
                },
            );
        Ok(())
    }
    pub fn clear_session(&self, account: &str) -> CoreResult<()> {
        self.sessions
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?
            .retain(|(a, _), _| a != account);
        Ok(())
    }
    pub fn has_session(&self, account: &str) -> bool {
        self.sessions
            .lock()
            .map(|s| {
                s.iter().any(|((a, _), session)| {
                    a == account
                        && (session
                            .bearer
                            .as_ref()
                            .is_some_and(|token| !token.trim().is_empty())
                            || !session.secret_headers.is_empty()
                            || session
                                .jar
                                .0
                                .lock()
                                .is_ok_and(|jar| jar.iter_unexpired().next().is_some()))
                })
            })
            .unwrap_or(false)
    }
    /// The unexpired cookies of one account/origin session as Set-Cookie
    /// strings. For trusted adapters that must continue a session outside the
    /// HTTP client (a gateway sign-in); never return these to plugins or UI.
    pub fn session_cookies(&self, account: &str, origin: &str) -> CoreResult<Vec<String>> {
        let Some((origin, _, jar, _)) = self.copy_session(Some(account), origin)? else {
            return Ok(Vec::new());
        };
        let url = Url::parse(&origin).map_err(|_| CoreError::invalid("invalid session origin"))?;
        let jar = jar
            .0
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?;
        Ok(jar
            .iter_unexpired()
            .filter(|cookie| cookie.domain.matches(&url))
            .map(|cookie| {
                let mut raw = std::ops::Deref::deref(cookie).clone();
                raw.set_path(cookie.path.as_ref().to_owned());
                raw.set_max_age(None);
                if let cookie_store::CookieExpiration::AtUtc(expiry) = cookie.expires {
                    raw.set_expires(expiry);
                }
                raw.to_string()
            })
            .collect())
    }
    pub fn has_session_for_origin(&self, account: &str, origin: &str) -> bool {
        self.credential_available(account, origin, CredentialKind::Cookie)
            || self.credential_available(account, origin, CredentialKind::Bearer)
            || self.credential_available(account, origin, CredentialKind::SecretHeaders)
    }
    pub fn session_fingerprint(&self, account: Option<&str>) -> CoreResult<String> {
        let Some(account) = account else {
            return Ok("anonymous".into());
        };
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?;
        let mut generations: Vec<_> = sessions
            .iter()
            .filter(|((a, _), _)| a == account)
            .map(|((_, origin), s)| (origin.clone(), s.generation.clone()))
            .collect();
        if generations.is_empty() {
            return Err(CoreError::new(
                "AuthenticationRequired",
                "account has no active session",
            ));
        }
        generations.sort();
        Ok(hex::encode(Sha256::digest(serde_json::to_vec(&(
            generations,
            self.routes(account)?,
        ))?)))
    }
    pub(crate) fn export_sessions(&self, account: &str) -> CoreResult<Value> {
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?;
        let mut values = Vec::new();
        for ((a, _), session) in sessions.iter() {
            if a != account {
                continue;
            }
            let mut bytes = Vec::new();
            let jar = session
                .jar
                .0
                .lock()
                .map_err(|_| CoreError::new("SessionError", "cookie lock poisoned"))?;
            cookie_store::serde::json::save_incl_expired_and_nonpersistent(&jar, &mut bytes)
                .map_err(|_| CoreError::new("SessionError", "cannot serialize cookie session"))?;
            let mut value = serde_json::json!({"origin":session.origin,"generation":session.generation,"bearer":session.bearer,"cookie_store":serde_json::from_slice::<Value>(&bytes)?});
            if !session.secret_headers.is_empty() {
                value["secret_headers"] = serde_json::to_value(&session.secret_headers)?;
            }
            values.push(value);
        }
        Ok(Value::Array(values))
    }
    pub(crate) fn restore_sessions(&self, account: &str, values: &Value) -> CoreResult<()> {
        let values = values
            .as_array()
            .ok_or_else(|| CoreError::new("SessionError", "invalid stored session"))?;
        let mut pending = Vec::new();
        let mut origins = std::collections::HashSet::new();
        for value in values {
            let origin = value["origin"]
                .as_str()
                .ok_or_else(|| CoreError::new("SessionError", "invalid session origin"))?;
            let url = Url::parse(origin)
                .map_err(|_| CoreError::new("SessionError", "invalid stored origin"))?;
            if !matches!(url.scheme(), "http" | "https")
                || url.origin().ascii_serialization() != origin
                || !origins.insert(origin.to_owned())
            {
                return Err(CoreError::new("SessionError", "invalid stored origin"));
            }
            let bytes = serde_json::to_vec(&value["cookie_store"])?;
            let secret_headers = secret_headers_from_value(value.get("secret_headers"))?;
            let store = cookie_store::serde::json::load(std::io::Cursor::new(bytes))
                .map_err(|_| CoreError::new("SessionError", "invalid stored cookies"))?;
            pending.push((
                (account.to_owned(), origin.to_owned()),
                Session {
                    origin: origin.into(),
                    generation: value["generation"]
                        .as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
                    bearer: value["bearer"].as_str().map(str::to_owned),
                    secret_headers,
                    jar: Arc::new(SessionJar(Mutex::new(store))),
                },
            ));
        }
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?;
        sessions.retain(|(a, _), _| a != account);
        for (key, value) in pending {
            sessions.insert(key, value);
        }
        Ok(())
    }

    pub async fn request(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
    ) -> CoreResult<HttpResponse> {
        self.execute(
            principal,
            grant,
            input,
            Transfer::buffered(CredentialKind::Any),
        )
        .await?
        .into_text()
    }
    pub async fn request_with_credentials(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
        kind: CredentialKind,
    ) -> CoreResult<HttpResponse> {
        self.execute(principal, grant, input, Transfer::buffered(kind))
            .await?
            .into_text()
    }

    /// Trusted Rust adapter only: no IPC selector and no cookie/token getter.
    /// One direct, origin/account-bound POST; redirects and gateways are rejected.
    /// All errors after dispatch have code NeedsReconciliation, including decoding.
    pub async fn request_with_cookie_csrf(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
        policy: CookieCsrf,
    ) -> CoreResult<HttpResponse> {
        validate_cookie_csrf_request(principal, grant, &input, &policy)?;
        let mut transfer = Transfer::buffered(CredentialKind::Cookie);
        transfer.cookie_csrf = Some(policy);
        self.execute(principal, grant, input, transfer)
            .await?
            .into_text()
    }

    /// Send an optional raw body and receive raw bytes, without UTF-8, JSON,
    /// charset or base64 conversion. The request and response buffer limit is
    /// 8 MiB. Text `input.body` is rejected to avoid two competing body sources.
    /// All credentials, grants, DNS/TLS checks, redirect handling and uncertain
    /// write outcomes use the same native execution path as text requests.
    pub async fn request_bytes(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
        body_bytes: Option<Vec<u8>>,
        kind: CredentialKind,
    ) -> CoreResult<BinaryHttpResponse> {
        if input.body.is_some() {
            return Err(CoreError::invalid(
                "binary requests use body_bytes, not text body",
            ));
        }
        let mut transfer = Transfer::buffered(kind);
        transfer.body_bytes = body_bytes;
        Ok(self
            .execute(principal, grant, input, transfer)
            .await?
            .into_binary())
    }
    pub async fn download(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
        path: PathBuf,
        max_bytes: u64,
        resume: bool,
    ) -> CoreResult<DownloadReceipt> {
        if input.method != "GET" {
            return Err(CoreError::invalid("managed downloads require GET"));
        }
        self.execute(
            principal,
            grant,
            input,
            Transfer {
                cookie_csrf: None,
                sink: Some(path),
                max_bytes,
                resume,
                credentials: CredentialKind::Any,
                gateway: false,
                body_bytes: None,
            },
        )
        .await?
        .into_text()?
        .download
        .ok_or_else(|| CoreError::new("InternalError", "download receipt missing"))
    }
    async fn execute(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
        mut transfer: Transfer,
    ) -> CoreResult<WireResponse> {
        grant.check(principal, "http.request")?;
        grant.check_account(principal, input.account_id.as_deref())?;
        if transfer
            .body_bytes
            .as_ref()
            .is_some_and(|body| body.len() as u64 > transfer.max_bytes)
        {
            return Err(CoreError::new(
                "RequestTooLarge",
                "request body exceeds buffer quota",
            ));
        }
        let url = Url::parse(&input.url).map_err(|_| CoreError::invalid("invalid request URL"))?;
        validate_url(&url, principal, grant)?;
        let routes = input
            .account_id
            .as_deref()
            .map(|account| self.routes(account))
            .transpose()?
            .unwrap_or_default();
        let route = routes
            .iter()
            .find(|route| route.origin == url.origin().ascii_serialization());
        let mode = route.map(|r| r.mode).unwrap_or(RouteMode::Direct);
        let native = self.copy_session(
            input.account_id.as_deref(),
            &url.origin().ascii_serialization(),
        )?;
        let private_literal = url
            .host_str()
            .and_then(|h| h.parse::<IpAddr>().ok())
            .is_some_and(|ip| !public_address(ip));
        transfer.gateway = mode == RouteMode::Gateway
            || (mode == RouteMode::Auto
                && ((!Self::session_matches(native.as_ref(), transfer.credentials)
                    && input.account_id.is_some())
                    || (private_literal && !grant.allow_private_network)));
        let safe_fallback = mode == RouteMode::Auto
            && !transfer.gateway
            && matches!(input.method.as_str(), "GET" | "HEAD");
        let started = tokio::time::Instant::now();
        let total_ms = input.timeout_ms.unwrap_or(if transfer.sink.is_some() {
            120000
        } else {
            15000
        });
        // A gateway can accept the connection and then never answer. A read
        // that got no response at all is sent once more on a fresh connection,
        // inside the same overall deadline. Writes and streamed downloads never.
        let gateway_read = (mode == RouteMode::Gateway || transfer.gateway)
            && matches!(input.method.as_str(), "GET" | "HEAD")
            && transfer.sink.is_none()
            && !transfer.resume;
        let mut first = input.clone();
        if gateway_read {
            first.timeout_ms = Some((total_ms / 2).clamp(2500, 5000).min(total_ms));
        } else if safe_fallback {
            first.timeout_ms = Some((total_ms / 3).clamp(2500, 4000).min(total_ms));
        }
        let mut result = self
            .execute_once(principal, grant, first, transfer.clone(), &routes)
            .await;
        if safe_fallback
            && result.as_ref().is_err_and(|e| {
                matches!(
                    e.code.as_str(),
                    "NetworkUnreachable" | "Timeout" | "NetworkError" | "PermissionDenied"
                )
            })
        {
            let remaining = total_ms
                .saturating_sub(started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64);
            if remaining >= 500 {
                transfer.gateway = true;
                let mut retry_input = input.clone();
                retry_input.timeout_ms = Some(remaining);
                result = self
                    .execute_once(principal, grant, retry_input, transfer.clone(), &routes)
                    .await;
            }
        }
        if gateway_read || (safe_fallback && transfer.gateway) {
            let mut retries = 0;
            while retries < 2
                && result.as_ref().is_err_and(|e| {
                    matches!(
                        e.code.as_str(),
                        "Timeout" | "NetworkUnreachable" | "NetworkError"
                    )
                })
            {
                let remaining = total_ms
                    .saturating_sub(started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64);
                if remaining < 1000 {
                    break;
                }
                retries += 1;
                let mut retry_input = input.clone();
                if retries == 1 && remaining > 5000 {
                    retry_input.timeout_ms = Some((remaining / 2).clamp(2500, 5000).min(remaining));
                } else {
                    retry_input.timeout_ms = Some(remaining);
                }
                result = self
                    .execute_once(principal, grant, retry_input, transfer.clone(), &routes)
                    .await;
            }
        }
        result
    }
    async fn execute_once(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
        transfer: Transfer,
        routes: &[GatewayRoute],
    ) -> CoreResult<WireResponse> {
        let Transfer {
            cookie_csrf,
            sink,
            max_bytes,
            resume,
            credentials,
            mut gateway,
            mut body_bytes,
        } = transfer;
        grant.check(principal, "http.request")?;
        grant.check_account(principal, input.account_id.as_deref())?;
        let mutating = !matches!(
            input.method.as_str(),
            "GET" | "HEAD" | "OPTIONS" | "PROPFIND"
        );
        let authority = mutating
            .then(|| WRITE_DISPATCH.try_with(Arc::clone).ok())
            .flatten();
        if let Some(authority) = &authority {
            (authority.check)()?;
        }
        // Bind before any queue/DNS await. A replacement must never silently
        // become the credential used by a pending write, even outside Engine.
        let identity = if mutating && credentials != CredentialKind::Anonymous {
            Some(self.session_fingerprint(input.account_id.as_deref())?)
        } else {
            None
        };
        #[cfg(test)]
        if let Some(notify) = &self.test_before_queue {
            notify.notify_one();
        }
        let _permit = self
            .concurrency
            .acquire()
            .await
            .map_err(|_| CoreError::new("Shutdown", "network unavailable"))?;
        if mutating {
            self.check_write_binding(
                principal,
                grant,
                input.account_id.as_deref(),
                identity.as_deref(),
                authority.as_deref(),
            )?;
        }
        let mut url =
            Url::parse(&input.url).map_err(|_| CoreError::invalid("invalid request URL"))?;
        let mut method = Method::from_bytes(input.method.as_bytes())
            .map_err(|_| CoreError::invalid("invalid HTTP method"))?;
        let propfind = Method::from_bytes(b"PROPFIND").expect("constant method");
        // PROPFIND only reads metadata; the other WebDAV methods change the remote.
        let mutating_request =
            !matches!(method, Method::GET | Method::HEAD | Method::OPTIONS) && method != propfind;
        if mutating_request {
            grant.check(principal, "http.write")?;
        }
        let webdav = ["PROPFIND", "MKCOL", "MOVE"]
            .map(|name| Method::from_bytes(name.as_bytes()).expect("constant method"));
        if ![
            Method::GET,
            Method::HEAD,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ]
        .contains(&method)
            && !webdav.contains(&method)
        {
            return Err(CoreError::invalid("unsupported HTTP method"));
        }
        let mut headers = HeaderMap::new();
        for (key, value) in input.headers {
            if matches!(
                key.to_ascii_lowercase().as_str(),
                "host" | "cookie" | "authorization" | "proxy-authorization"
            ) && !principal.is_owner()
            {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "credentials must be supplied by a host session",
                ));
            }
            headers.insert(
                HeaderName::from_bytes(key.as_bytes())
                    .map_err(|_| CoreError::invalid("invalid header"))?,
                HeaderValue::from_str(&value)
                    .map_err(|_| CoreError::invalid("invalid header value"))?,
            );
        }
        let mut body = input.body;
        if credentials == CredentialKind::Anonymous {
            headers.remove("authorization");
            headers.remove("cookie");
        }
        let mut hidden_headers = std::collections::BTreeSet::new();
        let deadline = tokio::time::Instant::now()
            + Duration::from_millis(
                input
                    .timeout_ms
                    .unwrap_or(if sink.is_some() { 120000 } else { 15000 })
                    .clamp(100, if sink.is_some() { 300000 } else { 30000 }),
            );
        for redirect in 0..=8 {
            validate_url(&url, principal, grant)?;
            if !principal.is_owner()
                && routes.iter().any(|route| {
                    route
                        .gateway_origin()
                        .is_ok_and(|origin| origin == url.origin().ascii_serialization())
                })
            {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "callers must request the authorized original origin, not a gateway URL",
                ));
            }
            let route = routes.iter().find(|route| {
                route.origin == url.origin().ascii_serialization()
                    && (route.mode == RouteMode::Gateway
                        || (gateway && route.mode == RouteMode::Auto))
            });
            let physical = route
                .map(|route| route.encode(&url))
                .transpose()?
                .unwrap_or_else(|| url.clone());
            if route.is_some() {
                gateway = true;
            }
            // The owner approved the transport gateway, but logical-origin/account
            // grants above still apply. Physical DNS and TLS validation remain on.
            validate_url(&physical, &Principal::owner(), grant)?;
            let native = self.copy_session(
                input.account_id.as_deref(),
                &url.origin().ascii_serialization(),
            )?;
            // CSRF and Cookie come from the same account/origin session snapshot.
            // Gateway cookie translation has no proven CSRF contract; fail closed.
            if let Some(policy) = &cookie_csrf {
                if route.is_some() {
                    return Err(CoreError::new(
                        "CapabilityUnavailable",
                        "cookie-CSRF writes require a direct route",
                    ));
                }
                let (_, _, jar, _) = native.as_ref().ok_or_else(csrf_required)?;
                let name = HeaderName::from_bytes(policy.header_name.as_bytes())
                    .map_err(|_| CoreError::invalid("invalid CSRF header name"))?;
                headers.insert(
                    name.clone(),
                    cookie_csrf_header(jar, &url, &policy.cookie_name)?,
                );
                headers.insert(
                    "origin",
                    HeaderValue::from_str(&policy.origin)
                        .map_err(|_| CoreError::invalid("invalid CSRF origin"))?,
                );
                hidden_headers.insert(name.to_string());
            }
            let session = if route.is_some() {
                self.copy_session(
                    input.account_id.as_deref(),
                    &physical.origin().ascii_serialization(),
                )?
            } else {
                native.clone()
            };
            reject_secret_header_collision(&headers, native.as_ref())?;
            reject_secret_header_collision(&headers, session.as_ref())?;
            for (_, _, _, values) in native.iter().chain(session.iter()) {
                hidden_headers.extend(values.keys().cloned());
            }
            // Every redirected origin must supply its own explicit credential.
            // Gateway cookies alone cannot satisfy backend secret headers.
            if credentials == CredentialKind::SecretHeaders
                && (input.account_id.is_none()
                    || !Self::session_matches(native.as_ref(), CredentialKind::SecretHeaders))
            {
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "account has no secret header credentials for this origin",
                ));
            }
            let session_kind = if route.is_some() {
                CredentialKind::Cookie
            } else {
                credentials
            };
            if (redirect == 0 || credentials == CredentialKind::SecretHeaders)
                && input.account_id.is_some()
                && (!Self::session_matches(session.as_ref(), session_kind)
                    || (credentials == CredentialKind::Bearer
                        && !Self::session_matches(native.as_ref(), CredentialKind::Bearer)))
            {
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "account has no credential of the required kind for this origin or gateway",
                ));
            }
            let host = physical
                .host_str()
                .ok_or_else(|| CoreError::invalid("URL has no host"))?
                .to_owned();
            let port = physical
                .port_or_known_default()
                .ok_or_else(|| CoreError::invalid("URL has no port"))?;
            let resolution = async {
                let result = tokio::net::lookup_host((host.as_str(), port)).await;
                #[cfg(test)]
                if let Some(pause) = &self.test_dns_pause {
                    pause.pause().await;
                }
                result
            };
            let addrs: Vec<SocketAddr> = tokio::time::timeout_at(deadline, resolution)
                .await
                .map_err(|_| {
                    CoreError::new("NetworkUnreachable", "DNS resolution deadline exceeded")
                })?
                .map_err(|_| CoreError::new("NetworkUnreachable", "DNS resolution failed"))?
                .collect();
            if addrs.is_empty() {
                return Err(CoreError::new(
                    "NetworkUnreachable",
                    "DNS returned no addresses",
                ));
            }
            if !grant.allow_private_network
                && addrs.iter().any(|addr| {
                    !public_address(addr.ip())
                        && !permitted_lan_address(
                            principal,
                            grant,
                            &physical,
                            addr.ip(),
                            delegated_private_read(
                                principal,
                                input.account_id.as_deref(),
                                &method,
                                &physical,
                            ),
                        )
                })
            {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "private or special-use network requires explicit permission",
                ));
            }
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return Err(CoreError::new("Timeout", "request deadline exceeded"));
            }
            let mut builder = reqwest::Client::builder()
                .user_agent(concat!("dansheng-core/", env!("CARGO_PKG_VERSION")))
                .retry(reqwest::retry::never())
                .tls_sslkeylogfile(false)
                .connection_verbose(false)
                .gzip(sink.is_none())
                .brotli(sink.is_none())
                .deflate(sink.is_none())
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(5))
                .timeout(remaining)
                .resolve_to_addrs(&host, &addrs);
            // A portable Mozilla root store avoids an implicit Android JVM verifier
            // dependency in a UI-independent Rust library. Never disable verification.
            let roots =
                rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            #[cfg(test)]
            let roots = {
                let mut roots = roots;
                for certificate in &self.test_roots {
                    roots
                        .add(certificate.clone())
                        .map_err(|_| CoreError::new("TlsError", "invalid test root"))?;
                }
                roots
            };
            let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .map_err(|_| CoreError::new("TlsError", "TLS initialization failed"))?
            .with_root_certificates(roots)
            .with_no_client_auth();
            builder = builder.tls_backend_preconfigured(tls);
            if let Some((_, _, jar, _)) = &session
                && (route.is_some()
                    || matches!(credentials, CredentialKind::Any | CredentialKind::Cookie))
            {
                builder = builder.cookie_provider(jar.clone());
            }
            let client = builder
                .build()
                .map_err(|_| CoreError::new("NetworkError", "HTTP client initialization failed"))?;
            let mut request = client
                .request(method.clone(), physical.clone())
                .headers(headers.clone());
            if sink.is_some() {
                request = request.header(reqwest::header::ACCEPT_ENCODING, "identity");
            }
            if let Some((origin, Some(token), _, _)) = &native
                && matches!(credentials, CredentialKind::Any | CredentialKind::Bearer)
                && *origin == url.origin().ascii_serialization()
            {
                request = match token.strip_prefix(BASIC_PREFIX) {
                    Some(basic) => request.header(
                        reqwest::header::AUTHORIZATION,
                        HeaderValue::from_str(&format!("Basic {basic}"))
                            .map_err(|_| CoreError::invalid("invalid basic credentials"))?,
                    ),
                    None => request.bearer_auth(token),
                };
            }
            if credentials == CredentialKind::SecretHeaders
                && let Some((_, _, _, values)) = &native
            {
                for (name, value) in values {
                    request = request.header(name, secret_header_value(value)?);
                }
            }
            if let Some(bytes) = &body_bytes {
                request = request.body(bytes.clone());
            } else if let Some(value) = &body {
                request = if let Some(text) = value.as_str() {
                    request.body(text.to_owned())
                } else {
                    request.json(value)
                };
            }
            // No await between the final checks and dispatch. The session used
            // to build this request must still be the one pinned before queuing.
            if mutating_request {
                self.check_write_binding(
                    principal,
                    grant,
                    input.account_id.as_deref(),
                    identity.as_deref(),
                    authority.as_deref(),
                )?;
                if let Some(authority) = &authority {
                    authority.dispatched.store(true, Ordering::Release);
                }
            }
            let mut response = request.send().await.map_err(|e| {
                let code = if mutating_request {
                    "NeedsReconciliation"
                } else if e.is_connect() {
                    "NetworkUnreachable"
                } else if e.is_timeout() {
                    "Timeout"
                } else {
                    "NetworkError"
                };
                CoreError::new(code, "request did not return a confirmed response")
            })?;
            let status = response.status();
            // A resource can return 401 while other APIs on the same origin remain
            // authorized (e.g. a closed Canvas course). Return the challenge to the
            // caller; only an explicit logout/replacement or expiry removes secrets.
            if mutating_request && (status.is_server_error() || status.as_u16() == 408) {
                return Err(CoreError::new(
                    "NeedsReconciliation",
                    "server did not confirm the outcome of a write",
                ));
            }
            if mutating_request && matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308) {
                return Err(CoreError::new(
                    "NeedsReconciliation",
                    "a write redirected; the core will not automatically resubmit it",
                ));
            }
            if input.follow_redirects && matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308) {
                if redirect == 8 {
                    return Err(CoreError::new("RedirectLimit", "too many redirects"));
                }
                let location = response
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|h| h.to_str().ok())
                    .ok_or_else(|| {
                        CoreError::new("InvalidResponse", "redirect has no valid location")
                    })?;
                let next = if route.is_some() {
                    decode_location(routes, &physical, location)?
                } else {
                    url.join(location)
                        .map_err(|_| CoreError::new("InvalidResponse", "invalid redirect target"))?
                };
                if next.origin() != url.origin() {
                    headers.remove("authorization");
                    headers.remove("cookie");
                }
                if status.as_u16() == 303
                    || ((status.as_u16() == 301 || status.as_u16() == 302)
                        && method == Method::POST)
                {
                    method = Method::GET;
                    body = None;
                    body_bytes = None;
                    headers.remove("content-type");
                }
                url = next;
                continue;
            }
            let mut safe_headers: BTreeMap<String, String> = response
                .headers()
                .iter()
                .filter(|(k, _)| {
                    !hidden_headers.contains(k.as_str())
                        && !matches!(
                            k.as_str(),
                            "set-cookie" | "authorization" | "proxy-authenticate"
                        )
                })
                .filter_map(|(k, v)| v.to_str().ok().map(|v| (k.to_string(), v.to_owned())))
                .collect();
            if route.is_some() {
                if let Some(location) = safe_headers.get("location").cloned() {
                    safe_headers.insert(
                        "location".into(),
                        decode_location(routes, &physical, &location)?.to_string(),
                    );
                }
                if let Some(link) = safe_headers.get("link").cloned() {
                    safe_headers
                        .insert("link".into(), decode_link_header(routes, &physical, &link)?);
                }
            }
            if sink.is_some() && !status.is_success() {
                return Err(CoreError::new(
                    "RemoteStatus",
                    format!("download returned HTTP {}", status.as_u16()),
                ));
            }
            if sink.is_some()
                && safe_headers
                    .get("content-encoding")
                    .is_some_and(|value| !value.eq_ignore_ascii_case("identity"))
            {
                return Err(CoreError::new(
                    "UnsupportedContent",
                    "managed download requires an identity representation",
                ));
            }
            let mut size = 0u64;
            let mut digest = Sha256::new();
            let mut output = if let Some(path) = &sink {
                let append = resume && status.as_u16() == 206;
                if append {
                    size = tokio::fs::metadata(path).await?.len();
                    let prefix = format!("bytes {size}-");
                    if !safe_headers
                        .get("content-range")
                        .is_some_and(|range| range.starts_with(&prefix))
                    {
                        return Err(CoreError::new(
                            "InvalidResponse",
                            "resume offset does not match Content-Range",
                        ));
                    }
                    if size > max_bytes {
                        return Err(CoreError::new(
                            "ResponseTooLarge",
                            "partial file exceeds quota",
                        ));
                    }
                    let mut existing = tokio::fs::File::open(path).await?;
                    let mut chunk = vec![0u8; 65536];
                    loop {
                        let n = existing.read(&mut chunk).await?;
                        if n == 0 {
                            break;
                        }
                        digest.update(&chunk[..n]);
                    }
                }
                Some(
                    tokio::fs::OpenOptions::new()
                        .create(true)
                        .write(true)
                        .append(append)
                        .truncate(!append)
                        .open(path)
                        .await?,
                )
            } else {
                None
            };
            if size.saturating_add(response.content_length().unwrap_or(0)) > max_bytes {
                return Err(CoreError::new(
                    if mutating_request {
                        "NeedsReconciliation"
                    } else {
                        "ResponseTooLarge"
                    },
                    "response exceeds download/buffer quota",
                ));
            }
            let mut bytes = Vec::new();
            loop {
                let chunk = tokio::time::timeout_at(deadline, response.chunk())
                    .await
                    .map_err(|_| {
                        CoreError::new(
                            if mutating_request {
                                "NeedsReconciliation"
                            } else {
                                "Timeout"
                            },
                            "response read deadline exceeded",
                        )
                    })?
                    .map_err(|error| {
                        CoreError::new(
                            if mutating_request {
                                "NeedsReconciliation"
                            } else if error.is_timeout() {
                                "Timeout"
                            } else {
                                "NetworkError"
                            },
                            "response stream interrupted",
                        )
                    })?;
                let Some(chunk) = chunk else { break };
                size += chunk.len() as u64;
                if size > max_bytes {
                    return Err(CoreError::new(
                        if mutating_request {
                            "NeedsReconciliation"
                        } else {
                            "ResponseTooLarge"
                        },
                        "response exceeds download/buffer quota",
                    ));
                }
                if let Some(output) = &mut output {
                    output.write_all(&chunk).await?;
                    digest.update(&chunk);
                } else {
                    bytes.extend_from_slice(&chunk);
                }
            }
            if let Some(output) = &mut output {
                output.flush().await?;
                output.sync_all().await?;
            }
            let download = sink.as_ref().map(|_| DownloadReceipt {
                status: status.as_u16(),
                headers: safe_headers.clone(),
                size,
                sha256: hex::encode(digest.finalize()),
            });
            return Ok(WireResponse {
                status: status.as_u16(),
                url: url.to_string(),
                headers: safe_headers,
                body: bytes,
                download,
                max_bytes,
                mutating_request,
            });
        }
        Err(CoreError::new("RedirectLimit", "too many redirects"))
    }
}

fn charset(content_type: &str) -> Option<&str> {
    content_type.split(';').skip(1).find_map(|part| {
        let (key, value) = part.split_once('=')?;
        key.trim()
            .eq_ignore_ascii_case("charset")
            .then(|| value.trim().trim_matches(['\'', '"']))
    })
}
fn decode_text(bytes: &[u8], headers: &BTreeMap<String, String>, limit: u64) -> CoreResult<String> {
    if bytes.is_empty() {
        return Ok(String::new());
    }
    let content_type = headers
        .get("content-type")
        .map(String::as_str)
        .unwrap_or("");
    let mut label = charset(content_type).map(str::to_owned);
    let html = content_type.to_ascii_lowercase().contains("text/html")
        || bytes.starts_with(b"<!DOCTYPE html")
        || bytes.starts_with(b"<html");
    if label.is_none() && html {
        let prefix = String::from_utf8_lossy(&bytes[..bytes.len().min(8192)]);
        let document = scraper::Html::parse_document(&prefix);
        for meta in document.select(&scraper::Selector::parse("meta").expect("static selector")) {
            if let Some(value) = meta.value().attr("charset") {
                label = Some(value.into());
                break;
            }
            if meta
                .value()
                .attr("http-equiv")
                .is_some_and(|value| value.eq_ignore_ascii_case("content-type"))
                && let Some(value) = meta.value().attr("content").and_then(charset)
            {
                label = Some(value.into());
                break;
            }
        }
    }
    let encoding = if let Some((encoding, _)) = encoding_rs::Encoding::for_bom(bytes) {
        encoding
    } else if let Some(label) = label {
        encoding_rs::Encoding::for_label(label.as_bytes()).ok_or_else(|| {
            CoreError::new("UnsupportedContent", "unsupported declared text charset")
        })?
    } else {
        encoding_rs::UTF_8
    };
    let (text, _, errors) = encoding.decode(bytes);
    if errors {
        return Err(CoreError::new(
            "UnsupportedContent",
            "response text decoding failed; binary responses require managed download",
        ));
    }
    if text.len() as u64 > limit {
        return Err(CoreError::new(
            "ResponseTooLarge",
            "decoded text exceeds buffer quota",
        ));
    }
    Ok(text.into_owned())
}
fn validate_url(url: &Url, principal: &Principal, grant: &Grant) -> CoreResult<()> {
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(CoreError::invalid(
            "only HTTP(S) URLs without embedded credentials are allowed",
        ));
    }
    if !principal.is_owner() && !grant.origins.contains(&url.origin().ascii_serialization()) {
        return Err(CoreError::new(
            "PermissionDenied",
            "request origin is outside the grant",
        ));
    }
    Ok(())
}
fn delegated_private_read(
    principal: &Principal,
    account: Option<&str>,
    method: &Method,
    target: &Url,
) -> bool {
    matches!(*method, Method::GET | Method::HEAD)
        && matches!(principal.kind, crate::api::PrincipalKind::Client)
        && OWNER_PRIVATE_READ
            .try_with(|binding| {
                binding.principal_id == principal.id
                    && account == Some(binding.account_id.as_str())
                    && binding.origin == target.origin().ascii_serialization()
            })
            .unwrap_or(false)
}

fn permitted_lan_address(
    principal: &Principal,
    grant: &Grant,
    target: &Url,
    ip: IpAddr,
    delegated_read: bool,
) -> bool {
    if (!principal.is_owner() && !delegated_read)
        || target.scheme() != "https"
        || !grant
            .private_network_origins
            .contains(&target.origin().ascii_serialization())
    {
        return false;
    }
    fn lan_v4(a: std::net::Ipv4Addr) -> bool {
        let [x, y, _, _] = a.octets();
        a.is_private()
            || (x == 100 && (64..=127).contains(&y))
            || (x == 198 && (18..=19).contains(&y))
    }
    match ip {
        IpAddr::V4(a) => lan_v4(a),
        IpAddr::V6(a) => a
            .to_ipv4_mapped()
            .map(lan_v4)
            .unwrap_or_else(|| a.is_unique_local()),
    }
}
fn public_address(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => {
            let o = a.octets();
            !a.is_private()
                && !a.is_loopback()
                && !a.is_link_local()
                && !a.is_unspecified()
                && !a.is_broadcast()
                && !a.is_documentation()
                && o[0] != 0
                && o[0] < 224
                && !(o[0] == 100 && (64..=127).contains(&o[1]))
                && !(o[0] == 198 && (18..=19).contains(&o[1]))
                && !(o[0] == 192 && o[1] == 0 && o[2] == 0)
                && !(o[0] == 192 && o[1] == 88 && o[2] == 99)
        }
        IpAddr::V6(a) => {
            if let Some(v4) = a.to_ipv4_mapped() {
                public_address(IpAddr::V4(v4))
            } else {
                let s = a.segments();
                (s[0] & 0xe000) == 0x2000
                    && s[0] != 0x2002
                    && !(s[0] == 0x2001 && s[1] < 0x0200)
                    && !(s[0] == 0x2001 && s[1] == 0xdb8)
                    && s[0] != 0x3fff
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn basic_credentials_are_https_only_and_cannot_be_forged_as_bearer() {
        let network = Network::default();
        let origin = "https://dav.example";
        assert!(
            network
                .set_session_basic("a", "http://dav.example", "u", "p")
                .is_err()
        );
        assert!(network.set_session_basic("a", origin, "u:x", "p").is_err());
        assert!(network.set_session_basic("a", origin, "", "p").is_err());
        assert!(network.set_session_basic("a", origin, "u", "p\n").is_err());
        // A caller-supplied bearer cannot smuggle in another authorization scheme.
        assert!(
            network
                .set_session("a", origin, Some("Basic dTpw".into()), Vec::new())
                .is_err()
        );
        network
            .set_session_basic("a", origin, "user", "pa ss:word")
            .unwrap();
        assert!(network.credential_available("a", origin, CredentialKind::Bearer));
        assert!(!network.credential_available("b", origin, CredentialKind::Bearer));
        let exported = network.export_sessions("a").unwrap();
        let restored = Network::default();
        restored.restore_sessions("a", &exported).unwrap();
        assert!(restored.credential_available("a", origin, CredentialKind::Bearer));
    }

    #[test]
    fn secret_header_validation_never_echoes_rejected_values() {
        let header = secret_header_value("SYNTHETIC-DO-NOT-ECHO").unwrap();
        assert!(header.is_sensitive());
        assert!(!format!("{header:?}").contains("SYNTHETIC-DO-NOT-ECHO"));
        for name in [
            "Authorization",
            "Cookie",
            "Host",
            "Content-Length",
            "Connection",
            "TE",
            "Transfer-Encoding",
            "Trailer",
            "Upgrade",
            "Keep-Alive",
            "Proxy-Authorization",
            "proxy-custom",
            "Forwarded",
            "X-Forwarded-For",
            "Set-Cookie",
            "WWW-Authenticate",
            "invalid name",
            "invalid\rname",
        ] {
            let error =
                validate_secret_headers([(name.into(), "SYNTHETIC-DO-NOT-ECHO".into())].into())
                    .unwrap_err();
            assert!(!format!("{error:?}").contains("SYNTHETIC-DO-NOT-ECHO"));
        }
        for value in [
            "",
            "   ",
            "synthetic\r\ninjection",
            "synthetic\tvalue",
            "synthetic\0value",
            "非ASCII",
        ] {
            let error = validate_secret_headers([("x-fixture-token".into(), value.into())].into())
                .unwrap_err();
            assert_eq!(error.code, "InvalidInput");
            if !value.is_empty() {
                assert!(!error.message.contains(value));
            }
        }
        assert!(
            validate_secret_headers([("x-fixture-token".into(), "s".repeat(8193))].into()).is_err()
        );
        assert!(validate_secret_headers([("x".repeat(129), "synthetic".into())].into()).is_err());
        assert!(
            validate_secret_headers(
                (0..17)
                    .map(|n| (format!("x-fixture-{n}"), "s".into()))
                    .collect()
            )
            .is_err()
        );
        assert!(
            validate_secret_headers(
                (0..5)
                    .map(|n| (format!("x-fixture-{n}"), "s".repeat(8192)))
                    .collect()
            )
            .is_err()
        );
        assert!(
            validate_secret_headers(
                [
                    ("X-Fixture-Token".into(), "one".into()),
                    ("x-fixture-token".into(), "two".into())
                ]
                .into()
            )
            .is_err()
        );
        let valid =
            validate_secret_headers([("X-Fixture-Token".into(), "synthetic".into())].into())
                .unwrap();
        assert!(valid.contains_key("x-fixture-token"));
        for value in [
            serde_json::json!(null),
            serde_json::json!([]),
            serde_json::json!({"x-fixture-token":123}),
        ] {
            assert!(secret_headers_from_value(Some(&value)).is_err());
        }
    }

    #[test]
    fn secret_header_import_is_atomic_account_scoped_and_legacy_compatible() {
        let network = Network::default();
        let origin = "https://service.example";
        network
            .set_session_with_headers(
                "a",
                origin,
                None,
                vec![],
                [("x-fixture-token".into(), "synthetic-a".into())].into(),
            )
            .unwrap();
        network
            .set_session_with_headers(
                "b",
                origin,
                None,
                vec![],
                [("x-fixture-token".into(), "synthetic-b".into())].into(),
            )
            .unwrap();
        let original = network.export_sessions("a").unwrap();
        let fingerprint = network.session_fingerprint(Some("a")).unwrap();
        let mut invalid = original.clone();
        let mut second = original[0].clone();
        second["origin"] = serde_json::json!("https://other.example");
        second["secret_headers"] = serde_json::json!({"authorization":"SYNTHETIC-REJECTED"});
        invalid.as_array_mut().unwrap().push(second);
        let error = network.restore_sessions("a", &invalid).unwrap_err();
        assert!(!format!("{error:?}").contains("SYNTHETIC-REJECTED"));
        assert_eq!(network.export_sessions("a").unwrap(), original);
        assert_eq!(network.session_fingerprint(Some("a")).unwrap(), fingerprint);
        assert!(!network.has_session_for_origin("a", "https://other.example"));
        assert!(network.credential_available("b", origin, CredentialKind::SecretHeaders));
        let duplicate = serde_json::json!([original[0], original[0]]);
        assert!(network.restore_sessions("a", &duplicate).is_err());
        assert_eq!(network.export_sessions("a").unwrap(), original);

        let restored = Network::default();
        restored.restore_sessions("a", &original).unwrap();
        assert_eq!(restored.export_sessions("a").unwrap(), original);
        assert!(restored.has_session("a"));
        assert!(!restored.credential_available("b", origin, CredentialKind::SecretHeaders));
        let mut legacy = original.clone();
        legacy[0].as_object_mut().unwrap().remove("secret_headers");
        legacy[0]["bearer"] = serde_json::json!("synthetic-legacy");
        restored.restore_sessions("a", &legacy).unwrap();
        assert_eq!(restored.export_sessions("a").unwrap(), legacy);
        assert!(!restored.credential_available("a", origin, CredentialKind::SecretHeaders));
        assert!(restored.credential_available("a", origin, CredentialKind::Bearer));
        network
            .restore_sessions("a", &serde_json::json!([]))
            .unwrap();
        assert!(!network.has_session("a"));
        assert!(network.has_session("b"));
    }

    #[test]
    fn secret_header_origin_replacement_and_gateway_binding_are_exact() {
        let network = Network::default();
        let headers = || [("x-fixture-token".into(), "synthetic".into())].into();
        for origin in [
            "https://service.example/path",
            "https://user@service.example",
            "https://service.example?key=synthetic",
            "https://service.example#part",
        ] {
            assert!(
                network
                    .set_session_with_headers("a", origin, None, vec![], headers())
                    .is_err()
            );
        }
        network
            .set_session_with_headers("a", "https://service.example", None, vec![], headers())
            .unwrap();
        for origin in [
            "http://service.example",
            "https://service.example:444",
            "https://sub.service.example",
            "https://service.example.evil",
        ] {
            assert!(!network.credential_available("a", origin, CredentialKind::SecretHeaders));
        }
        let before = network.session_fingerprint(Some("a")).unwrap();
        network
            .set_session(
                "a",
                "https://service.example",
                Some("synthetic-bearer".into()),
                vec![],
            )
            .unwrap();
        assert_ne!(before, network.session_fingerprint(Some("a")).unwrap());
        assert!(!network.credential_available(
            "a",
            "https://service.example",
            CredentialKind::SecretHeaders
        ));
        network
            .set_routes(
                "a",
                vec![GatewayRoute {
                    provider: "fixture".into(),
                    origin: "https://backend.example".into(),
                    gateway_prefix: "https://gateway.example/gate".into(),
                    mode: RouteMode::Gateway,
                }],
            )
            .unwrap();
        network
            .set_session_with_headers(
                "a",
                "https://gateway.example",
                None,
                vec!["GATEWAY=synthetic; Secure; Path=/".into()],
                headers(),
            )
            .unwrap();
        assert!(!network.credential_available(
            "a",
            "https://backend.example",
            CredentialKind::SecretHeaders
        ));
        network.clear_session("a").unwrap();
        assert!(!network.has_session("a"));
        assert_eq!(network.export_sessions("a").unwrap(), serde_json::json!([]));
    }
    #[test]
    fn scoped_lan_exception_requires_exact_owner_https_origin_and_routable_address() {
        use crate::api::PrincipalKind;
        let mut grant = Grant::default();
        grant
            .private_network_origins
            .insert("https://campus.example".into());
        let permitted = |who: &Principal, target: &str, addr: &str| {
            permitted_lan_address(
                who,
                &grant,
                &Url::parse(target).unwrap(),
                addr.parse().unwrap(),
                false,
            )
        };
        let owner = Principal::owner();
        for ip in ["10.1.2.3", "192.168.10.1", "198.18.1.5", "fd00::2"] {
            assert!(permitted(&owner, "https://campus.example/login", ip));
        }
        for ip in [
            "127.0.0.1",
            "169.254.169.254",
            "::1",
            "fe80::2",
            "224.0.0.1",
        ] {
            assert!(!permitted(&owner, "https://campus.example/login", ip));
        }
        assert!(!permitted(&owner, "http://campus.example/", "10.1.2.3"));
        assert!(!permitted(&owner, "https://redirect.example/", "10.1.2.3"));
        let plugin = Principal {
            id: "plugin:test".into(),
            kind: PrincipalKind::Plugin,
        };
        assert!(!permitted(&plugin, "https://campus.example/", "10.1.2.3"));
    }

    #[tokio::test]
    async fn owner_private_origin_read_is_bound_and_cannot_elevate_clients() {
        use crate::api::PrincipalKind;
        let network = Network::default();
        let owner = Principal::owner();
        let service = Principal {
            id: "service:webdav".into(),
            kind: PrincipalKind::Client,
        };
        let other = Principal {
            id: "service:other".into(),
            kind: PrincipalKind::Client,
        };
        let mcp = Principal {
            id: service.id.clone(),
            kind: PrincipalKind::Mcp,
        };
        let origin = "https://nas.example";
        let target = Url::parse(&format!("{origin}/files/a")).unwrap();
        let grant = Grant {
            private_network_origins: [origin.to_owned()].into(),
            ..Default::default()
        };
        let allowed = |who: &Principal, account: &str, method: &Method, url: &Url, ip: &str| {
            permitted_lan_address(
                who,
                &grant,
                url,
                ip.parse().unwrap(),
                delegated_private_read(who, Some(account), method, url),
            )
        };
        assert!(!allowed(&service, "a", &Method::GET, &target, "10.1.2.3"));
        network
            .with_owner_private_origin_read(&owner, &grant, &service, "a", origin, async {
                for method in [Method::GET, Method::HEAD] {
                    assert!(allowed(&service, "a", &method, &target, "10.1.2.3"));
                    assert!(allowed(&service, "a", &method, &target, "fd00::2"));
                }
                for ip in ["127.0.0.1", "169.254.169.254", "::1", "fe80::2"] {
                    assert!(!allowed(&service, "a", &Method::GET, &target, ip));
                }
                for method in [Method::POST, Method::PUT, Method::DELETE] {
                    assert!(!allowed(&service, "a", &method, &target, "10.1.2.3"));
                }
                assert!(!allowed(&other, "a", &Method::GET, &target, "10.1.2.3"));
                assert!(!allowed(&mcp, "a", &Method::GET, &target, "10.1.2.3"));
                assert!(!allowed(&service, "b", &Method::GET, &target, "10.1.2.3"));
                for url in [
                    "https://redirect.example/a",
                    "https://nas.example:444/a",
                    "http://nas.example/a",
                ] {
                    assert!(!allowed(
                        &service,
                        "a",
                        &Method::GET,
                        &Url::parse(url).unwrap(),
                        "10.1.2.3"
                    ));
                }
                // An unrelated spawned request cannot inherit the task-local scope.
                let p = service.clone();
                let u = target.clone();
                assert!(
                    !tokio::spawn(async move {
                        delegated_private_read(&p, Some("a"), &Method::GET, &u)
                    })
                    .await
                    .unwrap()
                );
                Ok(())
            })
            .await
            .unwrap();
        assert!(!allowed(&service, "a", &Method::GET, &target, "10.1.2.3"));
        // Merely placing an origin in a Client/MCP grant cannot mint owner authority.
        for caller in [&service, &mcp] {
            network
                .with_owner_private_origin_read(caller, &grant, &service, "a", origin, async {
                    assert!(!allowed(&service, "a", &Method::GET, &target, "10.1.2.3"));
                    Ok(())
                })
                .await
                .unwrap();
        }
        network
            .with_owner_private_origin_read(
                &owner,
                &Grant::default(),
                &service,
                "a",
                origin,
                async {
                    assert!(!allowed(&service, "a", &Method::GET, &target, "10.1.2.3"));
                    Ok(())
                },
            )
            .await
            .unwrap();
    }
    #[test]
    fn declared_legacy_text_encoding_is_decoded_without_guessing_binary_payloads() {
        let (gbk, _, errors) = encoding_rs::GBK.encode("教室与课程");
        assert!(!errors);
        let headers = [("content-type".into(), "text/html; charset=gb2312".into())].into();
        assert_eq!(decode_text(&gbk, &headers, 100).unwrap(), "教室与课程");
        assert!(decode_text(&[0xff, 0x00, 0xfe], &BTreeMap::new(), 100).is_err());
        assert_eq!(
            decode_text(&gbk, &headers, 2).unwrap_err().code,
            "ResponseTooLarge"
        );
        let html = "<html><head><meta charset=gbk></head><body>教室</body></html>";
        let (gbk, _, _) = encoding_rs::GBK.encode(html);
        assert_eq!(
            decode_text(
                &gbk,
                &[("content-type".into(), "text/html".into())].into(),
                1000
            )
            .unwrap(),
            html
        );
    }
    #[tokio::test]
    async fn one_resource_401_does_not_erase_an_origin_session() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            for status in [401, 200] {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = [0u8; 4096];
                let size = socket.read(&mut bytes).await.unwrap();
                assert!(String::from_utf8_lossy(&bytes[..size]).contains("SID=synthetic"));
                let reply = format!(
                    "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"
                );
                socket.write_all(reply.as_bytes()).await.unwrap();
            }
        });
        let network = Network::default();
        network
            .set_session("a", &origin, None, vec!["SID=synthetic; Path=/".into()])
            .unwrap();
        let grant = Grant {
            allow_private_network: true,
            ..Default::default()
        };
        for (path, status) in [("/restricted", 401), ("/allowed", 200)] {
            let response = network
                .request_with_credentials(
                    &Principal::owner(),
                    &grant,
                    HttpRequest {
                        url: format!("{origin}{path}"),
                        account_id: Some("a".into()),
                        ..Default::default()
                    },
                    CredentialKind::Cookie,
                )
                .await
                .unwrap();
            assert_eq!(response.status, status);
            assert!(network.credential_available("a", &origin, CredentialKind::Cookie));
        }
        server.await.unwrap();
    }
    async fn tls_gateway() -> (
        String,
        rustls::pki_types::CertificateDer<'static>,
        Arc<Mutex<Vec<String>>>,
        tokio::task::JoinHandle<()>,
    ) {
        tls_gateway_stalling(0).await
    }
    /// Like `tls_gateway`, but the first `stalls` requests are read and then
    /// never answered, as a stuck gateway does.
    async fn tls_gateway_stalling(
        stalls: usize,
    ) -> (
        String,
        rustls::pki_types::CertificateDer<'static>,
        Arc<Mutex<Vec<String>>>,
        tokio::task::JoinHandle<()>,
    ) {
        let cert = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let der = cert.cert.der().clone();
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(
            rustls::pki_types::PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der()),
        );
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![der.clone()], key)
        .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("https://{}", listener.local_addr().unwrap());
        let gateway = origin.clone();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let observed = requests.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((socket, _)) = listener.accept().await else {
                    break;
                };
                let Ok(mut stream) = acceptor.accept(socket).await else {
                    continue;
                };
                let mut data = Vec::new();
                let mut buffer = [0u8; 1024];
                while !data.windows(4).any(|w| w == b"\r\n\r\n") && data.len() < 16384 {
                    let n = stream.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    data.extend_from_slice(&buffer[..n]);
                }
                observed
                    .lock()
                    .unwrap()
                    .push(String::from_utf8(data).unwrap());
                if observed.lock().unwrap().len() <= stalls {
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                        drop(stream);
                    });
                    continue;
                }
                let body = r#"{"ok":true}"#;
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: REFRESH=synthetic; Path=/; Secure\r\nLink: <{gateway}/gate/resource/api/data?page=2>; rel=\"next\"\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).await.unwrap();
                let _ = stream.shutdown().await;
            }
        });
        (origin, der, requests, task)
    }
    #[tokio::test]
    async fn real_tls_gateway_keeps_logical_urls_and_uses_only_gateway_cookies() {
        let (gateway, cert, requests, task) = tls_gateway().await;
        let mut network = Network::default();
        network.test_roots.push(cert);
        network
            .set_routes(
                "a",
                vec![GatewayRoute {
                    provider: "fixture".into(),
                    origin: "https://campus.example".into(),
                    gateway_prefix: format!("{gateway}/gate/resource"),
                    mode: RouteMode::Gateway,
                }],
            )
            .unwrap();
        network
            .set_session(
                "a",
                "https://campus.example",
                Some("BACKEND-TOKEN".into()),
                vec!["ORIGINAL=must-not-forward; Path=/; Secure".into()],
            )
            .unwrap();
        network
            .set_session(
                "a",
                &gateway,
                None,
                vec!["VPN=synthetic; Path=/; Secure".into()],
            )
            .unwrap();
        let mut grant = Grant {
            allow_private_network: true,
            ..Default::default()
        };
        grant.capabilities.insert("http.request".into());
        grant.origins.insert("https://campus.example".into());
        grant.account_ids.insert("a".into());
        let reader = Principal {
            id: "reader".into(),
            kind: crate::PrincipalKind::Client,
        };
        let response = network
            .request_with_credentials(
                &reader,
                &grant,
                HttpRequest {
                    url: "https://campus.example/api/data?page=1".into(),
                    account_id: Some("a".into()),
                    ..Default::default()
                },
                CredentialKind::Cookie,
            )
            .await
            .unwrap();
        assert_eq!(response.url, "https://campus.example/api/data?page=1");
        assert_eq!(
            response.headers["link"],
            "<https://campus.example/api/data?page=2>; rel=\"next\""
        );
        assert!(!response.headers.contains_key("set-cookie"));
        let observed = requests.lock().unwrap();
        assert_eq!(observed.len(), 1);
        assert!(observed[0].starts_with("GET /gate/resource/api/data?page=1 "));
        assert!(observed[0].contains("VPN=synthetic"));
        assert!(!observed[0].contains("BACKEND-TOKEN"));
        assert!(!observed[0].contains("ORIGINAL="));
        drop(observed);
        task.abort();
    }
    #[tokio::test]
    async fn auto_gateway_retries_only_unreachable_reads_and_never_a_write() {
        let (gateway, cert, requests, task) = tls_gateway().await;
        let unavailable = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", unavailable.local_addr().unwrap());
        drop(unavailable);
        let mut network = Network::default();
        network.test_roots.push(cert);
        network
            .set_routes(
                "a",
                vec![GatewayRoute {
                    provider: "fixture".into(),
                    origin: origin.clone(),
                    gateway_prefix: format!("{gateway}/gate/resource"),
                    mode: RouteMode::Auto,
                }],
            )
            .unwrap();
        network
            .set_session("a", &origin, None, vec!["BACKEND=synthetic; Path=/".into()])
            .unwrap();
        network
            .set_session(
                "a",
                &gateway,
                None,
                vec!["VPN=synthetic; Path=/; Secure".into()],
            )
            .unwrap();
        let grant = Grant {
            allow_private_network: true,
            ..Default::default()
        };
        let request = HttpRequest {
            url: format!("{origin}/api/data"),
            account_id: Some("a".into()),
            timeout_ms: Some(5000),
            ..Default::default()
        };
        assert_eq!(
            network
                .request(&Principal::owner(), &grant, request.clone())
                .await
                .unwrap()
                .status,
            200
        );
        let mut write = request;
        write.method = "POST".into();
        write.body = Some(serde_json::json!({"synthetic":true}));
        assert_eq!(
            network
                .request(&Principal::owner(), &grant, write)
                .await
                .err()
                .unwrap()
                .code,
            "NeedsReconciliation"
        );
        assert_eq!(requests.lock().unwrap().len(), 1);
        task.abort();
    }
    #[tokio::test]
    async fn a_stalled_gateway_read_is_sent_once_more_but_never_a_write() {
        let (gateway, cert, requests, task) = tls_gateway_stalling(1).await;
        let origin = "https://campus.example".to_owned();
        let mut network = Network::default();
        network.test_roots.push(cert);
        network
            .set_routes(
                "a",
                vec![GatewayRoute {
                    provider: "fixture".into(),
                    origin: origin.clone(),
                    gateway_prefix: format!("{gateway}/gate/resource"),
                    mode: RouteMode::Gateway,
                }],
            )
            .unwrap();
        network
            .set_session(
                "a",
                &gateway,
                None,
                vec!["VPN=synthetic; Path=/; Secure".into()],
            )
            .unwrap();
        let grant = Grant {
            allow_private_network: true,
            ..Default::default()
        };
        let read = HttpRequest {
            url: format!("{origin}/api/data"),
            account_id: Some("a".into()),
            timeout_ms: Some(10000),
            ..Default::default()
        };
        let started = std::time::Instant::now();
        let response = network
            .request(&Principal::owner(), &grant, read.clone())
            .await
            .unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(requests.lock().unwrap().len(), 2);
        // The stalled attempt used about half of the deadline, not all of it.
        assert!(started.elapsed() < std::time::Duration::from_secs(9));
        task.abort();

        let (gateway, cert, requests, task) = tls_gateway_stalling(1).await;
        let mut network = Network::default();
        network.test_roots.push(cert);
        network
            .set_routes(
                "a",
                vec![GatewayRoute {
                    provider: "fixture".into(),
                    origin: origin.clone(),
                    gateway_prefix: format!("{gateway}/gate/resource"),
                    mode: RouteMode::Gateway,
                }],
            )
            .unwrap();
        network
            .set_session(
                "a",
                &gateway,
                None,
                vec!["VPN=synthetic; Path=/; Secure".into()],
            )
            .unwrap();
        let mut write = read;
        write.method = "POST".into();
        write.body = Some(serde_json::json!({"synthetic":true}));
        write.timeout_ms = Some(3000);
        assert_eq!(
            network
                .request(&Principal::owner(), &grant, write)
                .await
                .err()
                .unwrap()
                .code,
            "NeedsReconciliation"
        );
        assert_eq!(requests.lock().unwrap().len(), 1);
        task.abort();
    }
    #[tokio::test]
    async fn auto_gateway_does_not_hide_upstream_http_500() {
        let (gateway, cert, requests, task) = tls_gateway().await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let direct = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0u8; 4096];
            let _ = stream.read(&mut buffer).await.unwrap();
            stream.write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}").await.unwrap();
        });
        let mut network = Network::default();
        network.test_roots.push(cert);
        network
            .set_routes(
                "a",
                vec![GatewayRoute {
                    provider: "fixture".into(),
                    origin: origin.clone(),
                    gateway_prefix: format!("{gateway}/gate/resource"),
                    mode: RouteMode::Auto,
                }],
            )
            .unwrap();
        network
            .set_session("a", &origin, None, vec!["BACKEND=synthetic; Path=/".into()])
            .unwrap();
        network
            .set_session(
                "a",
                &gateway,
                None,
                vec!["VPN=synthetic; Path=/; Secure".into()],
            )
            .unwrap();
        let response = network
            .request(
                &Principal::owner(),
                &Grant {
                    allow_private_network: true,
                    ..Default::default()
                },
                HttpRequest {
                    url: format!("{origin}/api/data"),
                    account_id: Some("a".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(response.status, 500);
        assert!(requests.lock().unwrap().is_empty());
        direct.await.unwrap();
        task.abort();
    }
    #[test]
    fn cookie_paths_and_explicit_auth_modes_are_preserved() {
        let network = Network::default();
        network
            .set_session(
                "a",
                "https://campus.example",
                None,
                vec![
                    "SID=root; Path=/; Secure".into(),
                    "SID=specific; Path=/student; Secure".into(),
                ],
            )
            .unwrap();
        let session = network
            .copy_session(Some("a"), "https://campus.example")
            .unwrap()
            .unwrap();
        let cookie = session
            .2
            .cookies(&Url::parse("https://campus.example/student/data").unwrap())
            .unwrap();
        assert_eq!(cookie.to_str().unwrap(), "SID=specific; SID=root");
        assert!(network.credential_available(
            "a",
            "https://campus.example",
            CredentialKind::Cookie
        ));
        assert!(!network.credential_available(
            "a",
            "https://campus.example",
            CredentialKind::Bearer
        ));
        network
            .set_session(
                "b",
                "https://campus.example",
                Some("synthetic-token".into()),
                vec![],
            )
            .unwrap();
        assert!(network.credential_available(
            "b",
            "https://campus.example",
            CredentialKind::Bearer
        ));
        assert!(!network.credential_available(
            "b",
            "https://campus.example",
            CredentialKind::Cookie
        ));
    }
    #[test]
    fn gateway_sessions_are_account_scoped_and_never_substitute_a_bearer_token() {
        let network = Network::default();
        let rule = GatewayRoute {
            provider: "test".into(),
            origin: "https://campus.example".into(),
            gateway_prefix: "https://gateway.example/https/encoded".into(),
            mode: RouteMode::Gateway,
        };
        network.set_routes("a", vec![rule]).unwrap();
        network
            .set_session(
                "a",
                "https://gateway.example",
                None,
                vec!["GATEWAY=synthetic; Secure; Path=/".into()],
            )
            .unwrap();
        assert!(network.credential_available(
            "a",
            "https://campus.example",
            CredentialKind::Cookie
        ));
        assert!(!network.credential_available(
            "a",
            "https://campus.example",
            CredentialKind::Bearer
        ));
        assert!(!network.credential_available(
            "b",
            "https://campus.example",
            CredentialKind::Cookie
        ));
    }
    #[test]
    fn network_boundaries() {
        for ip in [
            "127.0.0.1",
            "10.0.0.1",
            "169.254.169.254",
            "100.64.1.2",
            "::1",
            "::ffff:127.0.0.1",
            "fd00::1",
        ] {
            assert!(!public_address(ip.parse().unwrap()), "{ip}");
        }
        assert!(public_address("8.8.8.8".parse().unwrap()));
    }
    #[test]
    fn exact_origin_checks() {
        let p = Principal {
            id: "plugin:x".into(),
            kind: crate::PrincipalKind::Plugin,
        };
        let mut g = Grant::default();
        g.origins.insert("https://example.com".into());
        assert!(validate_url(&Url::parse("https://example.com/a").unwrap(), &p, &g).is_ok());
        assert!(
            validate_url(
                &Url::parse("https://example.com.evil.test/a").unwrap(),
                &p,
                &g
            )
            .is_err()
        );
    }
}
