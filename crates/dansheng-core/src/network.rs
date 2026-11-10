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
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Semaphore;
use url::Url;

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
    jar: Arc<SessionJar>,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CredentialKind {
    #[default]
    Any,
    Cookie,
    Bearer,
    /// No backend credentials. The account may still own gateway authentication.
    Anonymous,
}
type SessionCopy = (String, Option<String>, Arc<SessionJar>);
#[derive(Clone)]
struct Transfer {
    sink: Option<PathBuf>,
    max_bytes: u64,
    resume: bool,
    credentials: CredentialKind,
    gateway: bool,
}
impl Transfer {
    fn buffered(credentials: CredentialKind) -> Self {
        Self {
            sink: None,
            max_bytes: 8 * 1024 * 1024,
            resume: false,
            credentials,
            gateway: false,
        }
    }
}
pub struct Network {
    sessions: Mutex<HashMap<(String, String), Session>>,
    routes: Mutex<HashMap<String, Vec<GatewayRoute>>>,
    concurrency: Arc<Semaphore>,
    #[cfg(test)]
    test_roots: Vec<rustls::pki_types::CertificateDer<'static>>,
}
impl Default for Network {
    fn default() -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
            routes: Mutex::new(HashMap::new()),
            concurrency: Arc::new(Semaphore::new(8)),
            #[cfg(test)]
            test_roots: Vec::new(),
        }
    }
}
impl Network {
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
            .map(|s| (s.origin.clone(), s.bearer.clone(), s.jar.clone())))
    }
    fn session_matches(session: Option<&SessionCopy>, kind: CredentialKind) -> bool {
        if kind == CredentialKind::Anonymous {
            return true;
        }
        let Some((_, token, jar)) = session else {
            return false;
        };
        match kind {
            CredentialKind::Any => true,
            CredentialKind::Bearer => token.as_ref().is_some_and(|token| !token.trim().is_empty()),
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
        if kind == CredentialKind::Bearer {
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
        let url = Url::parse(origin).map_err(|_| CoreError::invalid("invalid session origin"))?;
        if url.scheme() != "https" && url.scheme() != "http" {
            return Err(CoreError::invalid("invalid session scheme"));
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
                            || session
                                .jar
                                .0
                                .lock()
                                .is_ok_and(|jar| jar.iter_unexpired().next().is_some()))
                })
            })
            .unwrap_or(false)
    }
    pub fn has_session_for_origin(&self, account: &str, origin: &str) -> bool {
        self.credential_available(account, origin, CredentialKind::Cookie)
            || self.credential_available(account, origin, CredentialKind::Bearer)
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
            values.push(serde_json::json!({"origin":session.origin,"generation":session.generation,"bearer":session.bearer,"cookie_store":serde_json::from_slice::<Value>(&bytes)?}));
        }
        Ok(Value::Array(values))
    }
    pub(crate) fn restore_sessions(&self, account: &str, values: &Value) -> CoreResult<()> {
        let values = values
            .as_array()
            .ok_or_else(|| CoreError::new("SessionError", "invalid stored session"))?;
        let mut pending = Vec::new();
        for value in values {
            let origin = value["origin"]
                .as_str()
                .ok_or_else(|| CoreError::new("SessionError", "invalid session origin"))?;
            let url = Url::parse(origin)
                .map_err(|_| CoreError::new("SessionError", "invalid stored origin"))?;
            if !matches!(url.scheme(), "http" | "https")
                || url.origin().ascii_serialization() != origin
            {
                return Err(CoreError::new("SessionError", "invalid stored origin"));
            }
            let bytes = serde_json::to_vec(&value["cookie_store"])?;
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
                    jar: Arc::new(SessionJar(Mutex::new(store))),
                },
            ));
        }
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::new("SessionError", "session lock poisoned"))?;
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
        .await
    }
    pub async fn request_with_credentials(
        &self,
        principal: &Principal,
        grant: &Grant,
        input: HttpRequest,
        kind: CredentialKind,
    ) -> CoreResult<HttpResponse> {
        self.execute(principal, grant, input, Transfer::buffered(kind))
            .await
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
                sink: Some(path),
                max_bytes,
                resume,
                credentials: CredentialKind::Any,
                gateway: false,
            },
        )
        .await?
        .download
        .ok_or_else(|| CoreError::new("InternalError", "download receipt missing"))
    }
    async fn execute(
        &self,
        principal: &Principal,
        grant: &Grant,
        mut input: HttpRequest,
        mut transfer: Transfer,
    ) -> CoreResult<HttpResponse> {
        grant.check(principal, "http.request")?;
        grant.check_account(principal, input.account_id.as_deref())?;
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
        let result = self
            .execute_once(principal, grant, input.clone(), transfer.clone(), &routes)
            .await;
        if safe_fallback
            && result
                .as_ref()
                .is_err_and(|e| e.code == "NetworkUnreachable")
        {
            let remaining = total_ms
                .saturating_sub(started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64);
            if remaining < 100 {
                return result;
            }
            transfer.gateway = true;
            input.timeout_ms = Some(remaining);
            return self
                .execute_once(principal, grant, input, transfer, &routes)
                .await;
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
    ) -> CoreResult<HttpResponse> {
        let Transfer {
            sink,
            max_bytes,
            resume,
            credentials,
            mut gateway,
        } = transfer;
        grant.check(principal, "http.request")?;
        grant.check_account(principal, input.account_id.as_deref())?;
        let _permit = self
            .concurrency
            .acquire()
            .await
            .map_err(|_| CoreError::new("Shutdown", "network unavailable"))?;
        let mut url =
            Url::parse(&input.url).map_err(|_| CoreError::invalid("invalid request URL"))?;
        let mut method = Method::from_bytes(input.method.as_bytes())
            .map_err(|_| CoreError::invalid("invalid HTTP method"))?;
        let mutating_request = !matches!(method, Method::GET | Method::HEAD | Method::OPTIONS);
        if mutating_request {
            grant.check(principal, "http.write")?;
        }
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
            let host = physical
                .host_str()
                .ok_or_else(|| CoreError::invalid("URL has no host"))?
                .to_owned();
            let port = physical
                .port_or_known_default()
                .ok_or_else(|| CoreError::invalid("URL has no port"))?;
            let addrs: Vec<SocketAddr> =
                tokio::time::timeout_at(deadline, tokio::net::lookup_host((host.as_str(), port)))
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
                        && !permitted_lan_address(principal, grant, &physical, addr.ip())
                })
            {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "private or special-use network requires explicit permission",
                ));
            }
            let native = self.copy_session(
                input.account_id.as_deref(),
                &url.origin().ascii_serialization(),
            )?;
            let session = if route.is_some() {
                self.copy_session(
                    input.account_id.as_deref(),
                    &physical.origin().ascii_serialization(),
                )?
            } else {
                native.clone()
            };
            let session_kind = if route.is_some() {
                CredentialKind::Cookie
            } else {
                credentials
            };
            if redirect == 0
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
            if let Some((_, _, jar)) = &session
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
            if let Some((origin, Some(token), _)) = &native
                && matches!(credentials, CredentialKind::Any | CredentialKind::Bearer)
                && *origin == url.origin().ascii_serialization()
            {
                request = request.bearer_auth(token);
            }
            if let Some(value) = &body {
                request = if let Some(text) = value.as_str() {
                    request.body(text.to_owned())
                } else {
                    request.json(value)
                };
            }
            let mut response = request.send().await.map_err(|e| {
                let code = if !matches!(method, Method::GET | Method::HEAD | Method::OPTIONS) {
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
                    headers.remove("content-type");
                }
                url = next;
                continue;
            }
            let mut safe_headers: BTreeMap<String, String> = response
                .headers()
                .iter()
                .filter(|(k, _)| {
                    !matches!(
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
                    .map_err(|_| {
                        CoreError::new(
                            if mutating_request {
                                "NeedsReconciliation"
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
            let body = decode_text(&bytes, &safe_headers, max_bytes).map_err(|error| {
                if mutating_request {
                    CoreError::new("NeedsReconciliation", "write response could not be decoded")
                } else {
                    error
                }
            })?;
            return Ok(HttpResponse {
                status: status.as_u16(),
                url: url.to_string(),
                headers: safe_headers,
                body,
                download,
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
fn permitted_lan_address(principal: &Principal, grant: &Grant, target: &Url, ip: IpAddr) -> bool {
    if !principal.is_owner()
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
