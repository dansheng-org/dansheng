// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol adaptation from DanXi-Dev; attribution and integration notes: login-NOTICE.md.
//! Bounded native HTTPS login for three fixed Fudan services.
//!
//! The returned cookies are an **unverified session candidate** for private Core
//! import. Only a subsequent service-specific private read can verify the account.
//! No browser/sports flow, password retry, credential persistence or logging lives here.

use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use cookie_store::{Cookie, CookieExpiration, CookieStore};
use reqwest::{
    Client, Method, StatusCode,
    header::{COOKIE, HeaderMap, HeaderValue, LOCATION, ORIGIN, SET_COOKIE},
};
use rsa::{
    Pkcs1v15Encrypt, RsaPublicKey, pkcs8::DecodePublicKey, rand_core::OsRng, traits::PublicKeyParts,
};
use scraper::{ElementRef, Html, Selector};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    fmt,
    ops::Deref,
    sync::{
        Arc,
        atomic::{AtomicU8, AtomicUsize, Ordering},
    },
    time::Duration,
};
use url::Url;

const ID: &str = "https://id.fudan.edu.cn";
const UIS: &str = "https://uis.fudan.edu.cn";
const MAX_REQUESTS: usize = 20;
const MAX_REDIRECTS: usize = 12;
const MAX_BODY: usize = 1024 * 1024;
const MAX_TOTAL_BODY: usize = 4 * MAX_BODY;
const MAX_URL: usize = 16 * 1024;
const MAX_COOKIES: usize = 128;
const MAX_COOKIE: usize = 8192;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const LOGIN_TIMEOUT: Duration = Duration::from_secs(45);

/// The only service origins that may receive a login ticket.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoginTarget {
    Academic,
    /// The postgraduate course system, which only serves plain HTTP.
    Postgraduate,
    Canvas,
    Ecard,
    Dorm,
    Bus,
    Dining,
    WebVpn,
    Fdurop,
}

impl LoginTarget {
    pub fn origin(self) -> &'static str {
        match self {
            Self::Academic => "https://fdjwgl.fudan.edu.cn",
            Self::Postgraduate => "http://yjsxk.fudan.edu.cn",
            Self::Canvas => "https://elearning.fudan.edu.cn",
            Self::Ecard => "https://ecard.fudan.edu.cn",
            Self::Dorm | Self::Bus => "https://zlapp.fudan.edu.cn",
            Self::Dining => "https://my.fudan.edu.cn",
            Self::WebVpn => "https://webvpn.fudan.edu.cn",
            Self::Fdurop => "https://paper.fudan.edu.cn",
        }
    }

    fn entry(self) -> &'static str {
        match self {
            Self::Academic => "https://fdjwgl.fudan.edu.cn/student/for-std/course-table",
            Self::Postgraduate => {
                "http://yjsxk.fudan.edu.cn/yjsxkapp/sys/xsxkappfudan/xsxkCourse/loadKbxx.do"
            }
            Self::Canvas => "https://elearning.fudan.edu.cn/login/cas",
            Self::Ecard => "https://ecard.fudan.edu.cn/epay",
            Self::Dorm => "https://zlapp.fudan.edu.cn/fudanelec/wap/default/info",
            Self::Bus => "https://zlapp.fudan.edu.cn/fudanbus/wap/default/lists",
            Self::Dining => "https://my.fudan.edu.cn/simple_list/stqk",
            Self::WebVpn => "https://webvpn.fudan.edu.cn/login?cas_login=true",
            Self::Fdurop => "https://paper.fudan.edu.cn/fdurop-service/jwt/cas/login",
        }
    }

    /// Only the target service itself may be reached over plain HTTP. Credentials
    /// always go to the HTTPS identity provider; the service gets a one-time ticket.
    fn plain_http(self) -> bool {
        self.origin().starts_with("http://")
    }
}

/// Sensitive import material. Intentionally implements neither Debug nor Serialize.
/// `cookies` contains Set-Cookie strings with effective paths/expiry, not a Cookie header.
/// This type is not proof of authentication and must never be returned to a browser/MCP.
pub struct LoginSession {
    pub origin: String,
    pub cookies: Vec<String>,
    pub token: Option<String>,
}
/// Safe stage telemetry. It stores no URL/query, identity, password or response.
#[derive(Clone, Default)]
pub struct LoginProgress {
    stage: Arc<AtomicU8>,
    requests: Arc<AtomicUsize>,
}
impl LoginProgress {
    pub fn snapshot(&self) -> Value {
        let stage = match self.stage.load(Ordering::Acquire) {
            1 => "open_service",
            2 => "auth_methods",
            3 => "public_key",
            4 => "submit_credentials",
            5 => "exchange_login_token",
            6 => "return_to_service",
            7 => "session_ready",
            _ => "not_started",
        };
        json!({"stage":stage,"requests_started":self.requests.load(Ordering::Acquire)})
    }
}

/// Closed, fixed-text failures. No upstream URL, body, cookie, credential or token is retained.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum LoginError {
    InvalidInput,
    InvalidCredentials,
    InteractiveLoginRequired,
    UnsafeRedirect,
    ProtocolChanged,
    NetworkError,
    Timeout,
    ResponseTooLarge,
    LimitExceeded,
    AuthenticationRejected,
    SessionUnavailable,
    ServiceUnavailable,
    CryptoError,
    /// The WebVPN session behind a gateway sign-in is missing or expired.
    GatewaySessionRequired,
}

impl LoginError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidInput => "InvalidInput",
            Self::InvalidCredentials => "InvalidCredentials",
            Self::InteractiveLoginRequired => "InteractiveLoginRequired",
            Self::UnsafeRedirect => "UnsafeRedirect",
            Self::ProtocolChanged => "ProtocolChanged",
            Self::NetworkError => "NetworkError",
            Self::Timeout => "Timeout",
            Self::ResponseTooLarge => "ResponseTooLarge",
            Self::LimitExceeded => "LimitExceeded",
            Self::AuthenticationRejected => "AuthenticationRejected",
            Self::SessionUnavailable => "SessionUnavailable",
            Self::ServiceUnavailable => "ServiceUnavailable",
            Self::CryptoError => "CryptoError",
            Self::GatewaySessionRequired => "WebVpnLoginRequired",
        }
    }

    pub fn message(&self) -> &'static str {
        match self {
            Self::InvalidInput => "The supplied login input is invalid or too large.",
            Self::InvalidCredentials => "The identity service rejected the credentials.",
            Self::InteractiveLoginRequired => {
                "Interactive verification or a password change is required."
            }
            Self::UnsafeRedirect => {
                "The login flow requested an unsafe destination or credential replay."
            }
            Self::ProtocolChanged => "The identity service returned an unsupported login protocol.",
            Self::NetworkError => "The HTTPS login request failed; no credential was resent.",
            Self::Timeout => "The login deadline expired; no credential was resent.",
            Self::ResponseTooLarge => "The login response exceeded the configured size limit.",
            Self::LimitExceeded => "The login flow exceeded the configured operation limit.",
            Self::AuthenticationRejected => {
                "The identity service did not complete the login exchange."
            }
            Self::SessionUnavailable => "No importable target-service session was obtained.",
            Self::ServiceUnavailable => "The identity service is unavailable or under maintenance.",
            Self::CryptoError => "The identity service public key could not be used safely.",
            Self::GatewaySessionRequired => {
                "Sign in to WebVPN before reaching this service through it."
            }
        }
    }
}

impl fmt::Display for LoginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}
impl std::error::Error for LoginError {}

/// Perform at most one password submission, chosen by the target's actual auth redirect.
/// A failure never falls back to the other protocol or retries a password.
pub async fn login(
    student_id: &str,
    password: &str,
    target: LoginTarget,
) -> Result<LoginSession, LoginError> {
    login_with_progress(student_id, password, target, LoginProgress::default()).await
}
/// Fixed HTTPS credential endpoints use the same verified roots on desktop and Android.
/// The default reqwest platform verifier needs JVM setup that the Rust Core does not own.
pub(crate) fn verified_login_client() -> Result<reqwest::ClientBuilder, LoginError> {
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|_| LoginError::CryptoError)?
    .with_root_certificates(roots)
    .with_no_client_auth();
    Ok(Client::builder()
        .tls_backend_preconfigured(tls)
        .tls_sslkeylogfile(false)
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .referer(false)
        .connection_verbose(false)
        .no_proxy()
        .connect_timeout(Duration::from_secs(5))
        .timeout(REQUEST_TIMEOUT)
        .user_agent(concat!("dansheng-core/", env!("CARGO_PKG_VERSION"))))
}
pub async fn login_with_progress(
    student_id: &str,
    password: &str,
    target: LoginTarget,
    progress: LoginProgress,
) -> Result<LoginSession, LoginError> {
    validate_input(student_id, password)?;
    let mut builder = verified_login_client()?.https_only(!target.plain_http());
    if target == LoginTarget::WebVpn {
        // Observed live: a WebVPN sign-in takes ~0.3 s, but about one in three
        // first requests never answers. A short deadline plus the flow's single
        // pre-credential retry on a fresh connection beats waiting longer.
        builder = builder.timeout(Duration::from_secs(6));
    }
    let client = builder.build().map_err(|_| LoginError::NetworkError)?;
    let mut flow = Flow::new(target, Https { client });
    flow.progress = progress.clone();
    let result = tokio::time::timeout(LOGIN_TIMEOUT, flow.run(student_id, password))
        .await
        .map_err(|_| LoginError::Timeout)?;
    if result.is_ok() {
        progress.stage.store(7, Ordering::Release);
    }
    result
}

fn validate_input(student_id: &str, password: &str) -> Result<(), LoginError> {
    if !(4..=64).contains(&student_id.len())
        || !student_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
        || password.is_empty()
        || password.len() > 512
        || password.chars().any(|c| matches!(c, '\0' | '\r' | '\n'))
    {
        return Err(LoginError::InvalidInput);
    }
    Ok(())
}

// None of these internal request/response types implements Debug or Serialize.
enum Body {
    Empty,
    Json(Value),
    NeoPassword(Value),
    UisPassword(Vec<(String, String)>),
    Token(Vec<(String, String)>),
}
impl Body {
    fn has_password(&self) -> bool {
        matches!(self, Self::NeoPassword(_) | Self::UisPassword(_))
    }
    fn method(&self) -> Method {
        if matches!(self, Self::Empty) {
            Method::GET
        } else {
            Method::POST
        }
    }
}
struct Request {
    url: Url,
    body: Body,
    cookies: Option<HeaderValue>,
}
struct Reply {
    status: StatusCode,
    headers: HeaderMap,
    body: String,
}
struct Page {
    url: Url,
    reply: Reply,
}
#[async_trait]
trait Transport: Send {
    async fn exchange(&mut self, request: Request) -> Result<Reply, LoginError>;
    /// A gateway transport keeps the site session on the gateway; its own
    /// cookies are the session to import instead of target-issued ones.
    fn gateway_session(&self) -> Option<LoginSession> {
        None
    }
}
struct Https {
    client: Client,
}
#[async_trait]
impl Transport for Https {
    async fn exchange(&mut self, request: Request) -> Result<Reply, LoginError> {
        let mut builder = self
            .client
            .request(request.body.method(), request.url.clone());
        if let Some(cookies) = request.cookies {
            builder = builder.header(COOKIE, cookies);
        }
        if !matches!(request.body, Body::Empty) {
            builder = builder.header(ORIGIN, request.url.origin().ascii_serialization());
        }
        builder = match request.body {
            Body::Empty => builder,
            Body::Json(value) | Body::NeoPassword(value) => builder.json(&value),
            Body::UisPassword(fields) | Body::Token(fields) => builder.form(&fields),
        };
        let mut response = builder.send().await.map_err(network_error)?;
        if response
            .content_length()
            .is_some_and(|n| n > MAX_BODY as u64)
        {
            return Err(LoginError::ResponseTooLarge);
        }
        let status = response.status();
        let headers = response.headers().clone();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(network_error)? {
            if chunk.len() > MAX_BODY - bytes.len() {
                return Err(LoginError::ResponseTooLarge);
            }
            bytes.extend_from_slice(&chunk);
        }
        let body = String::from_utf8(bytes).map_err(|_| LoginError::ProtocolChanged)?;
        Ok(Reply {
            status,
            headers,
            body,
        })
    }
}
/// Runs the same sign-in through WebVPN: every logical URL is rewritten to the
/// gateway, gateway cookies stay in this transport, and redirects are read
/// back as logical URLs so the flow's own destination checks still apply.
/// The site session then lives in the gateway session, which is exported.
#[cfg(feature = "webvpn")]
struct GatewayHttps {
    client: Client,
    jar: CookieStore,
    gateway: Url,
}
#[cfg(feature = "webvpn")]
#[async_trait]
impl Transport for GatewayHttps {
    async fn exchange(&mut self, request: Request) -> Result<Reply, LoginError> {
        let physical =
            crate::webvpn::encode_url(&request.url).map_err(|_| LoginError::UnsafeRedirect)?;
        let mut builder = self.client.request(request.body.method(), physical.clone());
        // The flow's own jar only ever holds logical-host cookies, which the
        // gateway keeps server-side; send the gateway's cookies instead.
        if let Some(cookies) = cookie_header(&self.jar, &physical)? {
            builder = builder.header(COOKIE, cookies);
        }
        if !matches!(request.body, Body::Empty) {
            builder = builder.header(ORIGIN, crate::webvpn::GATEWAY_ORIGIN);
        }
        builder = match request.body {
            Body::Empty => builder,
            Body::Json(value) | Body::NeoPassword(value) => builder.json(&value),
            Body::UisPassword(fields) | Body::Token(fields) => builder.form(&fields),
        };
        let mut response = builder.send().await.map_err(network_error)?;
        if response
            .content_length()
            .is_some_and(|n| n > MAX_BODY as u64)
        {
            return Err(LoginError::ResponseTooLarge);
        }
        let status = response.status();
        let mut headers = response.headers().clone();
        for header in headers.get_all(SET_COOKIE) {
            if header.len() > MAX_COOKIE {
                return Err(LoginError::ResponseTooLarge);
            }
            let text = header.to_str().map_err(|_| LoginError::ProtocolChanged)?;
            if let Ok(cookie) = Cookie::parse(text, &self.gateway)
                && cookie.domain.as_cow().as_deref() == self.gateway.host_str()
            {
                let _ = self.jar.insert(cookie.into_owned(), &self.gateway);
            }
        }
        if self.jar.iter_any().count() > MAX_COOKIES {
            return Err(LoginError::LimitExceeded);
        }
        headers.remove(SET_COOKIE);
        if let Some(location) = headers.get(LOCATION) {
            let text = location.to_str().map_err(|_| LoginError::ProtocolChanged)?;
            let next = physical
                .join(text)
                .map_err(|_| LoginError::UnsafeRedirect)?;
            let logical = if next.origin() == self.gateway.origin() {
                // The gateway's own pages (its sign-in) mean its session ended.
                crate::webvpn::decode_url(&next).ok_or(LoginError::GatewaySessionRequired)?
            } else {
                next
            };
            headers.insert(
                LOCATION,
                HeaderValue::from_str(logical.as_str()).map_err(|_| LoginError::ProtocolChanged)?,
            );
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(network_error)? {
            if chunk.len() > MAX_BODY - bytes.len() {
                return Err(LoginError::ResponseTooLarge);
            }
            bytes.extend_from_slice(&chunk);
        }
        let body = String::from_utf8(bytes).map_err(|_| LoginError::ProtocolChanged)?;
        // Ticket hand-off pages carry gateway-rewritten links; read them as
        // the site's own so the flow's destination checks apply unchanged.
        let body = crate::webvpn::decode_text(&body).into_owned();
        Ok(Reply {
            status,
            headers,
            body,
        })
    }

    fn gateway_session(&self) -> Option<LoginSession> {
        let cookies = self
            .jar
            .iter_unexpired()
            .filter(|cookie| cookie.domain.matches(&self.gateway))
            .map(|cookie| {
                let mut raw = cookie.deref().clone();
                raw.set_path(cookie.path.as_ref().to_owned());
                raw.set_max_age(None);
                if let CookieExpiration::AtUtc(expiry) = cookie.expires {
                    raw.set_expires(expiry);
                }
                raw.to_string()
            })
            .collect();
        Some(LoginSession {
            origin: crate::webvpn::GATEWAY_ORIGIN.into(),
            cookies,
            token: None,
        })
    }
}

/// Signs in to `target` through WebVPN, continuing the gateway session given
/// as Set-Cookie strings. Returns the updated gateway session to import for
/// [`crate::webvpn::GATEWAY_ORIGIN`]; no site cookie exists outside it.
/// `GatewaySessionRequired` means WebVPN itself needs a sign-in first.
#[cfg(feature = "webvpn")]
pub async fn login_via_gateway(
    student_id: &str,
    password: &str,
    target: LoginTarget,
    gateway_cookies: &[String],
) -> Result<LoginSession, LoginError> {
    validate_input(student_id, password)?;
    if target == LoginTarget::WebVpn {
        return Err(LoginError::InvalidInput);
    }
    let gateway =
        Url::parse(crate::webvpn::GATEWAY_ORIGIN).map_err(|_| LoginError::InvalidInput)?;
    let mut jar = CookieStore::default();
    for cookie in gateway_cookies {
        let _ = jar.parse(cookie, &gateway);
    }
    if jar.iter_unexpired().next().is_none() {
        return Err(LoginError::GatewaySessionRequired);
    }
    // Every hop is proxied by the gateway: allow a little more than a direct
    // hop; a stalled request before any credential gets one fresh retry.
    let client = verified_login_client()?
        .timeout(Duration::from_secs(12))
        .build()
        .map_err(|_| LoginError::NetworkError)?;
    let mut flow = Flow::new(
        target,
        GatewayHttps {
            client,
            jar,
            gateway,
        },
    );
    tokio::time::timeout(Duration::from_secs(60), flow.run(student_id, password))
        .await
        .map_err(|_| LoginError::Timeout)?
}

fn network_error(error: reqwest::Error) -> LoginError {
    if error.is_timeout() {
        LoginError::Timeout
    } else {
        LoginError::NetworkError
    }
}

type CookieKey = (String, String, String);
fn cookie_key(cookie: &Cookie<'_>) -> CookieKey {
    (
        String::from(&cookie.domain),
        String::from(&cookie.path),
        cookie.name().to_owned(),
    )
}
struct Flow<T> {
    target: LoginTarget,
    transport: T,
    jar: CookieStore,
    target_cookies: BTreeSet<CookieKey>,
    requests: usize,
    redirects: usize,
    total_body: usize,
    password_submitted: bool,
    ticket_consumed: bool,
    progress: LoginProgress,
}
impl<T: Transport> Flow<T> {
    fn new(target: LoginTarget, transport: T) -> Self {
        Self {
            target,
            transport,
            jar: CookieStore::default(),
            target_cookies: BTreeSet::new(),
            requests: 0,
            redirects: 0,
            total_body: 0,
            password_submitted: false,
            ticket_consumed: false,
            progress: LoginProgress::default(),
        }
    }

    async fn run(&mut self, student_id: &str, password: &str) -> Result<LoginSession, LoginError> {
        validate_input(student_id, password)?;
        let page = self
            .follow(
                self.target
                    .entry()
                    .parse()
                    .map_err(|_| LoginError::ProtocolChanged)?,
                Body::Empty,
            )
            .await?;
        match page.url.origin().ascii_serialization().as_str() {
            ID => {
                check_html_challenge(&page.reply.body)?;
                if ticket_url(&page, self.target)?.is_some() {
                    self.finish(page).await
                } else {
                    self.neo(page, student_id, password).await
                }
            }
            UIS => {
                check_html_challenge(&page.reply.body)?;
                self.legacy(page, student_id, password).await
            }
            _ => {
                // A public HTTP 200 (even with cookies) cannot establish a login exchange.
                check_html_challenge(&page.reply.body)?;
                Err(LoginError::SessionUnavailable)
            }
        }
    }

    async fn send(&mut self, url: Url, body: Body) -> Result<Page, LoginError> {
        validate_url(&url, self.target)?;
        validate_body_destination(&url, &body)?;
        if self.requests >= MAX_REQUESTS {
            return Err(LoginError::LimitExceeded);
        }
        if body.has_password() {
            if self.password_submitted {
                return Err(LoginError::AuthenticationRejected);
            }
            // Set before awaiting: even a timeout must not permit another submission.
            self.password_submitted = true;
        }
        self.requests += 1;
        let stage = match &body {
            Body::NeoPassword(_) | Body::UisPassword(_) => 4,
            Body::Token(_) => 5,
            Body::Json(_) if url.path() == "/idp/authn/queryAuthMethods" => 2,
            Body::Json(_) => 3,
            Body::Empty if self.password_submitted || self.ticket_consumed => 6,
            Body::Empty => 1,
        };
        self.progress.stage.store(stage, Ordering::Release);
        self.progress
            .requests
            .store(self.requests, Ordering::Release);
        let cookies = cookie_header(&self.jar, &url)?;
        let password_submitted = self.password_submitted;
        // A plain GET before any password or ticket has gone out carries no
        // credential and changes nothing, so a stalled one may be sent once
        // more on a fresh connection. Nothing after that point is ever resent.
        let resendable =
            matches!(body, Body::Empty) && !self.password_submitted && !self.ticket_consumed;
        let first = self
            .transport
            .exchange(Request {
                url: url.clone(),
                body,
                cookies: cookies.clone(),
            })
            .await;
        let reply = match first {
            Err(LoginError::Timeout | LoginError::NetworkError) if resendable => {
                self.transport
                    .exchange(Request {
                        url: url.clone(),
                        body: Body::Empty,
                        cookies,
                    })
                    .await
            }
            other => other,
        }
        .map_err(|error| match error {
            // Re-signing in to WebVPN and retrying is only safe while no
            // password has gone out in this flow.
            LoginError::GatewaySessionRequired if password_submitted => {
                LoginError::AuthenticationRejected
            }
            other => other,
        })?;
        if reply.body.len() > MAX_BODY || reply.body.len() > MAX_TOTAL_BODY - self.total_body {
            return Err(LoginError::ResponseTooLarge);
        }
        self.total_body += reply.body.len();
        if reply.headers.len() > 128
            || reply
                .headers
                .iter()
                .map(|(k, v)| k.as_str().len() + v.len())
                .sum::<usize>()
                > 64 * 1024
        {
            return Err(LoginError::ResponseTooLarge);
        }
        self.receive_cookies(&url, &reply.headers)?;
        Ok(Page { url, reply })
    }

    fn receive_cookies(&mut self, url: &Url, headers: &HeaderMap) -> Result<(), LoginError> {
        for header in headers.get_all(SET_COOKIE) {
            if header.len() > MAX_COOKIE {
                return Err(LoginError::ResponseTooLarge);
            }
            let text = header.to_str().map_err(|_| LoginError::ProtocolChanged)?;
            let Ok(cookie) = Cookie::parse(text, url) else {
                continue;
            };
            // No public-suffix database is bundled. Permit only the exact issuing host
            // or its known university parent, never .cn/.edu.cn or an unrelated host.
            let domain = cookie.domain.as_cow().ok_or(LoginError::ProtocolChanged)?;
            if domain != url.host_str().unwrap_or_default() && domain != "fudan.edu.cn" {
                continue;
            }
            if cookie.name().starts_with("__Secure-") && cookie.secure() != Some(true) {
                continue;
            }
            if cookie.name().starts_with("__Host-")
                && (cookie.secure() != Some(true)
                    || cookie.deref().domain().is_some()
                    || cookie.deref().path() != Some("/"))
            {
                continue;
            }
            let key = cookie_key(&cookie);
            // insert() does not call cookie_store's value-logging convenience API.
            if self.jar.insert(cookie.into_owned(), url).is_ok() {
                if url.origin().ascii_serialization() == self.target.origin() {
                    self.target_cookies.insert(key);
                } else {
                    // A parent-domain cookie may overwrite the same tuple later.
                    // Its latest issuer, not an old receipt, controls export scope.
                    self.target_cookies.remove(&key);
                }
            }
            if self.jar.iter_any().count() > MAX_COOKIES || self.target_cookies.len() > MAX_COOKIES
            {
                return Err(LoginError::LimitExceeded);
            }
        }
        Ok(())
    }

    async fn follow(&mut self, mut url: Url, mut body: Body) -> Result<Page, LoginError> {
        loop {
            let was_post = !matches!(body, Body::Empty);
            let page = self.send(url, body).await?;
            // Inspect errors before following redirects; a bad password ends this call.
            check_html_challenge(&page.reply.body)?;
            if !page.reply.status.is_redirection() {
                return Ok(page);
            }
            if !matches!(page.reply.status.as_u16(), 301 | 302 | 303 | 307 | 308) {
                return Err(LoginError::ProtocolChanged);
            }
            if was_post && matches!(page.reply.status.as_u16(), 307 | 308) {
                // Never replay a password/token body, including to a different auth URL.
                return Err(LoginError::UnsafeRedirect);
            }
            self.redirects += 1;
            if self.redirects > MAX_REDIRECTS {
                return Err(LoginError::LimitExceeded);
            }
            let location = single_location(&page.reply.headers)?;
            url = resolve_url(&page.url, location, self.target)?;
            body = Body::Empty;
        }
    }

    async fn api(&mut self, path: &str, body: Body) -> Result<Value, LoginError> {
        let url = Url::parse(&format!("{ID}{path}")).map_err(|_| LoginError::ProtocolChanged)?;
        let page = self.send(url, body).await?;
        // APIs must respond directly. Redirecting a JSON/credential POST is unsupported.
        if page.reply.status.is_redirection() {
            return Err(LoginError::UnsafeRedirect);
        }
        check_html_challenge(&page.reply.body)?;
        let value: Value =
            serde_json::from_str(&page.reply.body).map_err(|_| LoginError::ProtocolChanged)?;
        classify_neo(&value)?;
        if !page.reply.status.is_success() {
            return Err(LoginError::AuthenticationRejected);
        }
        Ok(value)
    }

    async fn neo(
        &mut self,
        page: Page,
        student_id: &str,
        password: &str,
    ) -> Result<LoginSession, LoginError> {
        require_success(page.reply.status)?;
        let (lck, entity_id) = neo_parameters(&page.url)?;
        let methods = self
            .api(
                "/idp/authn/queryAuthMethods",
                Body::Json(json!({"lck":lck,"entityId":entity_id})),
            )
            .await?;
        let chain = auth_chain(&methods)?;
        let key_response = self
            .api("/idp/authn/getJsPublicKey", Body::Json(json!({})))
            .await?;
        let key = parse_public_key(
            key_response
                .get("data")
                .and_then(Value::as_str)
                .ok_or(LoginError::ProtocolChanged)?,
        )?;
        let encrypted = encrypt_password(&key, password)?;
        let auth = self
            .api(
                "/idp/authn/authExecute",
                Body::NeoPassword(json!({
                    "authModuleCode":"userAndPwd", "authChainCode":chain,
                    "entityId":entity_id, "requestType":"chain_type", "lck":lck,
                    "authPara":{"loginName":student_id,"password":encrypted,"verifyCode":""}
                })),
            )
            .await?;
        let token = bounded_string(auth.get("loginToken"), 16 * 1024)
            .ok_or(LoginError::AuthenticationRejected)?;
        let engine = Url::parse(&format!("{ID}/idp/authCenter/authnEngine"))
            .map_err(|_| LoginError::ProtocolChanged)?;
        let page = self
            .follow(
                engine,
                Body::Token(vec![("loginToken".into(), token.into())]),
            )
            .await?;
        self.finish(page).await
    }

    async fn legacy(
        &mut self,
        page: Page,
        student_id: &str,
        password: &str,
    ) -> Result<LoginSession, LoginError> {
        require_success(page.reply.status)?;
        let (action, mut fields) = uis_form(&page, self.target)?;
        fields.push(("username".into(), student_id.into()));
        fields.push(("password".into(), password.into()));
        let page = self.follow(action, Body::UisPassword(fields)).await?;
        self.finish(page).await
    }

    async fn finish(&mut self, mut page: Page) -> Result<LoginSession, LoginError> {
        for _ in 0..3 {
            require_success(page.reply.status)?;
            check_html_challenge(&page.reply.body)?;
            if page.url.origin().ascii_serialization() == self.target.origin() {
                if !self.password_submitted && !self.ticket_consumed {
                    return Err(LoginError::SessionUnavailable);
                }
                let document = Html::parse_document(&page.reply.body);
                if document
                    .select(&selector("input[type=password]")?)
                    .next()
                    .is_some()
                {
                    return Err(LoginError::AuthenticationRejected);
                }
                return self.export_with_url(Some(&page.url));
            }
            if let Some(url) = ticket_url(&page, self.target)? {
                self.ticket_consumed = true;
                page = self.follow(url, Body::Empty).await?;
            } else {
                // No password replay, auto-submit of arbitrary forms, JS evaluation or
                // protocol fallback. Additional challenges need a separate user flow.
                return Err(LoginError::InteractiveLoginRequired);
            }
        }
        Err(LoginError::LimitExceeded)
    }

    #[allow(dead_code)]
    fn export(&self) -> Result<LoginSession, LoginError> {
        self.export_with_url(None)
    }

    fn export_with_url(&self, final_url: Option<&Url>) -> Result<LoginSession, LoginError> {
        if let Some(session) = self.transport.gateway_session() {
            return if session.cookies.is_empty() {
                Err(LoginError::SessionUnavailable)
            } else {
                Ok(session)
            };
        }
        let origin = Url::parse(self.target.origin()).map_err(|_| LoginError::ProtocolChanged)?;
        let mut cookies = Vec::new();
        for cookie in self.jar.iter_unexpired() {
            // Never export identity-provider-only cookies. Keep only target-issued
            // cookies, including path-scoped cookies that do not match the root path.
            if !cookie.domain.matches(&origin) || !self.target_cookies.contains(&cookie_key(cookie))
            {
                continue;
            }
            let mut raw = cookie.deref().clone();
            raw.set_path(cookie.path.as_ref().to_owned());
            // Preserve cookie identity so future Set-Cookie updates/deletions
            // replace the same entry. Core binds this jar to the selected origin.
            raw.set_secure(!self.target.plain_http());
            raw.set_max_age(None);
            if let CookieExpiration::AtUtc(expiry) = cookie.expires {
                raw.set_expires(expiry);
            }
            cookies.push(raw.to_string());
        }
        if cookies.is_empty() {
            return Err(LoginError::SessionUnavailable);
        }
        let token = final_url.and_then(extract_token_from_url);
        Ok(LoginSession {
            origin: self.target.origin().into(),
            cookies,
            token,
        })
    }
}

fn require_success(status: StatusCode) -> Result<(), LoginError> {
    if status.is_success() {
        Ok(())
    } else if status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
        Err(LoginError::ServiceUnavailable)
    } else {
        Err(LoginError::AuthenticationRejected)
    }
}

fn cookie_header(jar: &CookieStore, url: &Url) -> Result<Option<HeaderValue>, LoginError> {
    let mut cookies = jar.matches(url);
    // RFC6265: more specific paths precede less specific paths for same-name cookies.
    cookies.sort_by_key(|cookie| std::cmp::Reverse(cookie.path.len()));
    let text = cookies
        .into_iter()
        .map(|cookie| format!("{}={}", cookie.name(), cookie.value()))
        .collect::<Vec<_>>()
        .join("; ");
    if text.len() > 32 * 1024 {
        return Err(LoginError::LimitExceeded);
    }
    if text.is_empty() {
        Ok(None)
    } else {
        HeaderValue::from_str(&text)
            .map(Some)
            .map_err(|_| LoginError::ProtocolChanged)
    }
}

fn validate_url(url: &Url, target: LoginTarget) -> Result<(), LoginError> {
    validate_url_depth(url, target, 0)
}

fn validate_url_depth(url: &Url, target: LoginTarget, depth: usize) -> Result<(), LoginError> {
    if depth > 3 {
        return Err(LoginError::UnsafeRedirect);
    }
    if url.as_str().len() > MAX_URL
        || !((url.scheme() == "https" && url.port_or_known_default() == Some(443))
            || (target.plain_http()
                && url.scheme() == "http"
                && url.port_or_known_default() == Some(80)
                && url.origin().ascii_serialization() == target.origin()))
        || !url.username().is_empty()
        || url.password().is_some()
        || ![ID, UIS, target.origin()].contains(&url.origin().ascii_serialization().as_str())
    {
        return Err(LoginError::UnsafeRedirect);
    }
    for (name, value) in url.query_pairs() {
        let name = name.to_ascii_lowercase();
        if name == "ticket" && url.origin().ascii_serialization() != target.origin() {
            return Err(LoginError::UnsafeRedirect);
        }
        if [
            "password",
            "username",
            "loginname",
            "logintoken",
            "authpara",
        ]
        .contains(&name.as_str())
        {
            return Err(LoginError::UnsafeRedirect);
        }
        // Reject open-redirect destinations supplied in auth/service query strings.
        if [
            "service",
            "redirect_uri",
            "redirect",
            "redirecturl",
            "returnurl",
            "target",
        ]
        .contains(&name.as_str())
        {
            if value.is_empty() || value == "null" {
                continue;
            }
            if value.contains('\\') || value.chars().any(char::is_control) {
                return Err(LoginError::UnsafeRedirect);
            }
            let destination = Url::parse(&value).map_err(|_| LoginError::UnsafeRedirect)?;
            validate_url_depth(&destination, target, depth + 1)?;
        }
    }
    Ok(())
}

fn extract_token_from_url(url: &Url) -> Option<String> {
    for (k, v) in url.query_pairs() {
        if (k == "idToken" || k == "token") && !v.is_empty() {
            return Some(v.into_owned());
        }
    }
    if let Some(frag) = url.fragment() {
        let query = frag.split_once('?').map(|(_, q)| q).unwrap_or(frag);
        for (k, v) in url::form_urlencoded::parse(query.as_bytes()) {
            if (k == "idToken" || k == "token") && !v.is_empty() {
                return Some(v.into_owned());
            }
        }
    }
    None
}

fn resolve_url(base: &Url, location: &str, target: LoginTarget) -> Result<Url, LoginError> {
    if location.len() > MAX_URL
        || location.contains('\\')
        || location.chars().any(char::is_control)
        || location.trim() != location
    {
        return Err(LoginError::UnsafeRedirect);
    }
    let url = base
        .join(location)
        .map_err(|_| LoginError::UnsafeRedirect)?;
    validate_url(&url, target)?;
    Ok(url)
}

fn validate_body_destination(url: &Url, body: &Body) -> Result<(), LoginError> {
    let origin = url.origin().ascii_serialization();
    let allowed = match body {
        Body::Empty => true,
        Body::NeoPassword(_) => {
            origin == ID && url.path() == "/idp/authn/authExecute" && url.query().is_none()
        }
        Body::UisPassword(_) => origin == UIS && url.path() == "/authserver/login",
        Body::Json(_) => {
            origin == ID
                && ["/idp/authn/queryAuthMethods", "/idp/authn/getJsPublicKey"]
                    .contains(&url.path())
                && url.query().is_none()
        }
        Body::Token(_) => {
            origin == ID && url.path() == "/idp/authCenter/authnEngine" && url.query().is_none()
        }
    };
    if allowed {
        Ok(())
    } else {
        Err(LoginError::UnsafeRedirect)
    }
}

fn single_location(headers: &HeaderMap) -> Result<&str, LoginError> {
    let mut values = headers.get_all(LOCATION).iter();
    let location = values.next().ok_or(LoginError::ProtocolChanged)?;
    if values.next().is_some() {
        return Err(LoginError::ProtocolChanged);
    }
    location.to_str().map_err(|_| LoginError::UnsafeRedirect)
}

fn selector(value: &str) -> Result<Selector, LoginError> {
    Selector::parse(value).map_err(|_| LoginError::ProtocolChanged)
}

fn bounded_string(value: Option<&Value>, max: usize) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control))
}

fn neo_parameters(url: &Url) -> Result<(String, String), LoginError> {
    let fragment = url.fragment().ok_or(LoginError::ProtocolChanged)?;
    let query = fragment
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or(fragment);
    let pairs: Vec<_> = url::form_urlencoded::parse(query.as_bytes()).collect();
    let field = |name| -> Result<String, LoginError> {
        let mut values = pairs
            .iter()
            .filter(|(key, _)| key == name)
            .map(|(_, value)| value.as_ref());
        let value = values
            .next()
            .filter(|s| !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control))
            .ok_or(LoginError::ProtocolChanged)?;
        if values.next().is_some() {
            return Err(LoginError::ProtocolChanged);
        }
        Ok(value.into())
    };
    Ok((field("lck")?, field("entityId")?))
}

fn classify_neo(value: &Value) -> Result<(), LoginError> {
    let message = value
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if message.contains("用户名或密码错误")
        || message.contains("密码有误")
        || value.get("code").and_then(Value::as_i64) == Some(4020)
    {
        return Err(LoginError::InvalidCredentials);
    }
    if value
        .get("second")
        .is_some_and(|v| v == true || v == "true")
        || value.get("captchaRequired").is_some_and(|v| v == true)
        || message.contains("验证码")
        || message.contains("二次认证")
        || message.contains("动态口令")
        || message.contains("弱密码")
        || message.contains("修改密码")
    {
        return Err(LoginError::InteractiveLoginRequired);
    }
    if message.contains("维护") {
        return Err(LoginError::ServiceUnavailable);
    }
    Ok(())
}

fn auth_chain(value: &Value) -> Result<String, LoginError> {
    classify_neo(value)?;
    let methods = value
        .get("data")
        .and_then(Value::as_array)
        .filter(|v| v.len() <= 32)
        .ok_or(LoginError::ProtocolChanged)?;
    let mut choices = methods
        .iter()
        .filter(|method| method.get("moduleCode").and_then(Value::as_str) == Some("userAndPwd"));
    let method = choices.next().ok_or(LoginError::InteractiveLoginRequired)?;
    if choices.next().is_some() {
        return Err(LoginError::ProtocolChanged);
    }
    bounded_string(method.get("authChainCode"), 4096)
        .map(str::to_owned)
        .ok_or(LoginError::ProtocolChanged)
}

fn parse_public_key(encoded: &str) -> Result<RsaPublicKey, LoginError> {
    if encoded.len() > 8192 {
        return Err(LoginError::CryptoError);
    }
    let compact: String = encoded
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    let der = STANDARD
        .decode(compact)
        .map_err(|_| LoginError::CryptoError)?;
    let key = RsaPublicKey::from_public_key_der(&der).map_err(|_| LoginError::CryptoError)?;
    if !(2048..=4096).contains(&key.n().bits())
        || key.e().bits() > 32
        || key.e() < &rsa::BigUint::from(3u8)
    {
        return Err(LoginError::CryptoError);
    }
    Ok(key)
}

fn encrypt_password(key: &RsaPublicKey, password: &str) -> Result<String, LoginError> {
    if password.len() > key.size().saturating_sub(11) {
        return Err(LoginError::InvalidInput);
    }
    let ciphertext = key
        .encrypt(&mut OsRng, Pkcs1v15Encrypt, password.as_bytes())
        .map_err(|_| LoginError::CryptoError)?;
    Ok(STANDARD.encode(ciphertext))
}

fn check_html_challenge(body: &str) -> Result<(), LoginError> {
    // Do not classify JavaScript/template strings containing dormant error labels.
    if !body.contains('<') {
        return Ok(());
    }
    let document = Html::parse_document(body);
    let text = document
        .root_element()
        .descendants()
        .filter_map(|node| {
            let text = node.value().as_text()?;
            if node
                .ancestors()
                .filter_map(ElementRef::wrap)
                .any(|element| {
                    matches!(
                        element.value().name(),
                        "script" | "style" | "template" | "noscript"
                    )
                })
            {
                return None;
            }
            Some(text.text.as_ref())
        })
        .collect::<Vec<_>>()
        .join(" ");
    if text.contains("用户名或密码错误") || text.contains("密码有误") {
        return Err(LoginError::InvalidCredentials);
    }
    if text.contains("请输入验证码")
        || text.contains("弱密码提示")
        || text.contains("二次认证")
        || text.contains("动态口令")
    {
        return Err(LoginError::InteractiveLoginRequired);
    }
    if text.contains("网络维护中") || text.contains("Under Maintenance") {
        return Err(LoginError::ServiceUnavailable);
    }
    for element in document.select(&selector("input")?) {
        let name = element
            .value()
            .attr("name")
            .unwrap_or_default()
            .to_ascii_lowercase();
        let id = element.value().attr("id").unwrap_or_default();
        if id.eq_ignore_ascii_case("pwdEncryptSalt") || id.eq_ignore_ascii_case("encryptSalt") {
            return Err(LoginError::InteractiveLoginRequired);
        }
        if [
            "captcha",
            "verifycode",
            "otp",
            "smscode",
            "totp",
            "pwdencryptsalt",
        ]
        .contains(&name.as_str())
            && element.value().attr("disabled").is_none()
        {
            return Err(LoginError::InteractiveLoginRequired);
        }
    }
    Ok(())
}

fn uis_form(page: &Page, target: LoginTarget) -> Result<(Url, Vec<(String, String)>), LoginError> {
    if page.url.origin().ascii_serialization() != UIS {
        return Err(LoginError::UnsafeRedirect);
    }
    let document = Html::parse_document(&page.reply.body);
    let forms = selector("form")?;
    let password_selector = selector("input[name=password]")?;
    let mut candidates = document
        .select(&forms)
        .filter(|form| form.select(&password_selector).next().is_some());
    let form = candidates.next().ok_or(LoginError::ProtocolChanged)?;
    if candidates.next().is_some() {
        return Err(LoginError::ProtocolChanged);
    }
    if form
        .value()
        .attr("method")
        .is_some_and(|method| !method.eq_ignore_ascii_case("post"))
    {
        return Err(LoginError::UnsafeRedirect);
    }
    let action_text = form.value().attr("action").unwrap_or("");
    let action_url = resolve_url(&page.url, action_text, target)?;
    if action_url.origin().ascii_serialization() != UIS || action_url.path() != "/authserver/login"
    {
        return Err(LoginError::UnsafeRedirect);
    }
    let mut names = BTreeSet::new();
    let mut fields = Vec::new();
    let mut username = false;
    for input in form.select(&selector("input")?) {
        if input.value().attr("disabled").is_some() {
            continue;
        }
        let Some(name) = input.value().attr("name") else {
            continue;
        };
        if name == "username" {
            username = true;
            continue;
        }
        if name == "password" {
            continue;
        }
        if !input
            .value()
            .attr("type")
            .is_some_and(|kind| kind.eq_ignore_ascii_case("hidden"))
        {
            continue;
        }
        let value = input.value().attr("value").unwrap_or_default();
        if name.len() > 64
            || name.is_empty()
            || value.len() > 4096
            || fields.len() >= 32
            || !names.insert(name.to_owned())
        {
            return Err(LoginError::ProtocolChanged);
        }
        fields.push((name.to_owned(), value.to_owned()));
    }
    if !username
        || !fields
            .iter()
            .any(|(name, value)| name == "execution" && !value.is_empty())
    {
        return Err(LoginError::ProtocolChanged);
    }
    Ok((action_url, fields))
}

fn ticket_url(page: &Page, target: LoginTarget) -> Result<Option<Url>, LoginError> {
    if ![ID, UIS].contains(&page.url.origin().ascii_serialization().as_str()) {
        return Ok(None);
    }
    let document = Html::parse_document(&page.reply.body);
    let form_selector = selector("form#logon")?;
    let mut forms = document.select(&form_selector);
    let Some(form) = forms.next() else {
        return Ok(None);
    };
    if forms.next().is_some() {
        return Err(LoginError::ProtocolChanged);
    }
    let ticket_selector = selector("input#ticket")?;
    let mut tickets = form.select(&ticket_selector);
    let ticket = tickets
        .next()
        .and_then(|input: ElementRef<'_>| input.value().attr("value"))
        .filter(|s| !s.is_empty() && s.len() <= 8192 && !s.chars().any(char::is_control))
        .ok_or(LoginError::ProtocolChanged)?;
    if tickets.next().is_some() {
        return Err(LoginError::ProtocolChanged);
    }
    let action = form
        .value()
        .attr("action")
        .ok_or(LoginError::ProtocolChanged)?;
    let mut url = resolve_url(&page.url, action, target)?;
    if url.origin().ascii_serialization() != target.origin() || url.fragment().is_some() {
        return Err(LoginError::UnsafeRedirect);
    }
    if url
        .query_pairs()
        .any(|(key, _)| key.eq_ignore_ascii_case("ticket"))
    {
        return Err(LoginError::ProtocolChanged);
    }
    url.query_pairs_mut().append_pair("ticket", ticket);
    validate_url(&url, target)?;
    Ok(Some(url))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::{RsaPrivateKey, pkcs8::EncodePublicKey};
    use std::{collections::VecDeque, sync::OnceLock};

    const NEO_PAGE: &str =
        "https://id.fudan.edu.cn/ac/#/login?lck=fixture-lock&entityId=fixture-academic";
    const PASSWORD: &str = "offline-synthetic-password";

    struct Step {
        url: String,
        reply: Result<Reply, LoginError>,
    }
    struct Mock {
        steps: VecDeque<Step>,
        seen: Vec<Request>,
    }
    #[async_trait]
    impl Transport for Mock {
        async fn exchange(&mut self, request: Request) -> Result<Reply, LoginError> {
            let step = self.steps.pop_front().expect("unexpected offline request");
            assert_eq!(request.url.as_str(), step.url);
            self.seen.push(request);
            step.reply
        }
    }
    fn reply(status: u16, headers: &[(&str, &str)], body: &str) -> Reply {
        let mut map = HeaderMap::new();
        for (name, value) in headers {
            map.append(
                reqwest::header::HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
        Reply {
            status: StatusCode::from_u16(status).unwrap(),
            headers: map,
            body: body.into(),
        }
    }
    fn step(url: &str, reply: Reply) -> Step {
        Step {
            url: url.into(),
            reply: Ok(reply),
        }
    }
    fn mock(steps: Vec<Step>) -> Mock {
        Mock {
            steps: steps.into(),
            seen: Vec::new(),
        }
    }
    fn page(url: &str, body: &str) -> Page {
        Page {
            url: url.parse().unwrap(),
            reply: reply(200, &[], body),
        }
    }
    fn private_key() -> &'static RsaPrivateKey {
        static KEY: OnceLock<RsaPrivateKey> = OnceLock::new();
        KEY.get_or_init(|| RsaPrivateKey::new(&mut OsRng, 2048).unwrap())
    }
    fn public_key_data() -> String {
        STANDARD.encode(
            private_key()
                .to_public_key()
                .to_public_key_der()
                .unwrap()
                .as_bytes(),
        )
    }
    fn neo_steps(methods: Value, auth: Value) -> Vec<Step> {
        vec![
            step(
                LoginTarget::Academic.entry(),
                reply(302, &[("location", NEO_PAGE)], ""),
            ),
            step(
                NEO_PAGE,
                reply(
                    200,
                    &[("set-cookie", "ID_ONLY=synthetic; Path=/; Secure; HttpOnly")],
                    "<main>Sign in</main>",
                ),
            ),
            step(
                "https://id.fudan.edu.cn/idp/authn/queryAuthMethods",
                reply(200, &[], &methods.to_string()),
            ),
            step(
                "https://id.fudan.edu.cn/idp/authn/getJsPublicKey",
                reply(200, &[], &json!({"data":public_key_data()}).to_string()),
            ),
            step(
                "https://id.fudan.edu.cn/idp/authn/authExecute",
                reply(200, &[], &auth.to_string()),
            ),
            step(
                "https://id.fudan.edu.cn/idp/authCenter/authnEngine",
                reply(
                    200,
                    &[],
                    r#"<form id="logon" action="https://fdjwgl.fudan.edu.cn/student/sso"><input id="ticket" value="ST-offline-fixture"></form>"#,
                ),
            ),
            step(
                "https://fdjwgl.fudan.edu.cn/student/sso?ticket=ST-offline-fixture",
                reply(
                    200,
                    &[(
                        "set-cookie",
                        "JSESSIONID=target-fixture; Path=/student; Secure; HttpOnly",
                    )],
                    "<main>Service landing</main>",
                ),
            ),
        ]
    }
    fn methods() -> Value {
        json!({"second":false,"data":[{"moduleCode":"userAndPwd","authChainCode":"fixture-chain"}]})
    }
    fn uis_url() -> String {
        let mut url: Url = format!("{UIS}/authserver/login").parse().unwrap();
        url.query_pairs_mut()
            .append_pair("service", LoginTarget::Academic.entry());
        url.into()
    }
    fn uis_html() -> &'static str {
        r#"<form method="post" action=""><input name="username"><input name="password" type="password"><input type="hidden" name="lt" value="LT-offline"><input type="hidden" name="execution" value="e1s1"><input type="hidden" name="_eventId" value="submit"></form>"#
    }
    fn legacy_steps(post_reply: Reply) -> Vec<Step> {
        let url = uis_url();
        vec![
            step(
                LoginTarget::Academic.entry(),
                reply(302, &[("location", &url)], ""),
            ),
            step(
                &url,
                reply(
                    200,
                    &[("set-cookie", "UIS_ONLY=synthetic; Path=/authserver; Secure")],
                    uis_html(),
                ),
            ),
            step(&url, post_reply),
        ]
    }

    #[test]
    fn login_destination_policy_rejects_downgrade_unknown_and_other_targets() {
        for target in [
            LoginTarget::Academic,
            LoginTarget::Canvas,
            LoginTarget::Ecard,
        ] {
            for accepted in [target.entry(), ID, UIS] {
                assert!(validate_url(&accepted.parse().unwrap(), target).is_ok());
            }
            for denied in [
                "http://id.fudan.edu.cn/",
                "https://id.fudan.edu.cn.evil.test/",
                "https://id.fudan.edu.cn:444/",
                "https://id.fudan.edu.cn@evil.test/",
                "https://user@id.fudan.edu.cn/",
                "https://127.0.0.1/",
                "https://fudan.edu.cn/",
                "https://elife.fudan.edu.cn/",
                "https://uis.fudan.edu.cn/authserver/login?ticket=synthetic",
                "https://id.fudan.edu.cn/ac/?password=synthetic",
            ] {
                assert_eq!(
                    validate_url(&denied.parse().unwrap(), target),
                    Err(LoginError::UnsafeRedirect)
                );
            }
            let base: Url = target.entry().parse().unwrap();
            for denied in [
                "//evil.test/",
                "https:\\evil.test/",
                " /relative",
                "\n/relative",
            ] {
                assert_eq!(
                    resolve_url(&base, denied, target),
                    Err(LoginError::UnsafeRedirect)
                );
            }
        }
        assert_eq!(
            validate_url(
                &LoginTarget::Canvas.entry().parse().unwrap(),
                LoginTarget::Academic
            ),
            Err(LoginError::UnsafeRedirect)
        );
    }

    #[test]
    fn login_plain_http_is_limited_to_the_postgraduate_service() {
        let target = LoginTarget::Postgraduate;
        for accepted in [
            target.entry(),
            "http://yjsxk.fudan.edu.cn/yjsxkapp/sys/xsxkappfudan/xsxkCourse/loadKbxx.do?ticket=ST-1",
            "https://id.fudan.edu.cn/idp/authCenter/authenticate?service=http%3A%2F%2Fyjsxk.fudan.edu.cn%2Fyjsxkapp%2F",
        ] {
            assert!(
                validate_url(&accepted.parse().unwrap(), target).is_ok(),
                "{accepted}"
            );
        }
        for denied in [
            "http://id.fudan.edu.cn/",
            "http://uis.fudan.edu.cn/authserver/login",
            "http://yjsxk.fudan.edu.cn:8080/",
            "https://yjsxk.fudan.edu.cn/",
            "http://yjsxktest.fudan.sh.cn/",
            "http://fdjwgl.fudan.edu.cn/",
            "https://id.fudan.edu.cn/idp/authCenter/authenticate?service=http%3A%2F%2Fevil.test%2F",
        ] {
            assert_eq!(
                validate_url(&denied.parse().unwrap(), target),
                Err(LoginError::UnsafeRedirect),
                "{denied}"
            );
        }
        // Other targets keep HTTPS-only service origins.
        assert_eq!(
            validate_url(&target.entry().parse().unwrap(), LoginTarget::Academic),
            Err(LoginError::UnsafeRedirect)
        );
        let body = Body::NeoPassword(json!({}));
        let plain: Url = "http://yjsxk.fudan.edu.cn/idp/authn/authExecute"
            .parse()
            .unwrap();
        assert_eq!(
            validate_body_destination(&plain, &body),
            Err(LoginError::UnsafeRedirect)
        );
    }

    #[test]
    fn login_service_query_is_validated_before_credentials() {
        assert!(validate_url(&uis_url().parse().unwrap(), LoginTarget::Academic).is_ok());
        for service in [
            "http://fdjwgl.fudan.edu.cn/",
            "https://evil.test/",
            "https://ecard.fudan.edu.cn/",
            "//evil.test/",
        ] {
            let mut url: Url = format!("{UIS}/authserver/login").parse().unwrap();
            url.query_pairs_mut().append_pair("service", service);
            assert_eq!(
                validate_url(&url, LoginTarget::Academic),
                Err(LoginError::UnsafeRedirect)
            );
        }
        let mut inner: Url = format!("{ID}/ac/").parse().unwrap();
        inner
            .query_pairs_mut()
            .append_pair("service", "https://evil.test/");
        let mut outer: Url = format!("{UIS}/authserver/login").parse().unwrap();
        outer
            .query_pairs_mut()
            .append_pair("service", inner.as_str());
        assert_eq!(
            validate_url(&outer, LoginTarget::Academic),
            Err(LoginError::UnsafeRedirect)
        );
    }

    #[test]
    fn login_neo_fragment_and_auth_chain_fail_closed() {
        assert_eq!(
            neo_parameters(&NEO_PAGE.parse().unwrap()).unwrap(),
            ("fixture-lock".into(), "fixture-academic".into())
        );
        for url in [
            "https://id.fudan.edu.cn/ac/",
            "https://id.fudan.edu.cn/ac/#/login?lck=a&entityId=",
            "https://id.fudan.edu.cn/ac/#/login?lck=a&lck=b&entityId=c",
            "https://id.fudan.edu.cn/ac/#/login?lck=a&entityId=%0A",
        ] {
            assert_eq!(
                neo_parameters(&url.parse().unwrap()),
                Err(LoginError::ProtocolChanged)
            );
        }
        assert_eq!(auth_chain(&methods()).unwrap(), "fixture-chain");
        assert_eq!(
            auth_chain(&json!({"second":true,"data":[]})),
            Err(LoginError::InteractiveLoginRequired)
        );
        assert_eq!(
            auth_chain(&json!({"data":[{"moduleCode":"sms"}]})),
            Err(LoginError::InteractiveLoginRequired)
        );
        assert_eq!(
            auth_chain(&json!({"data":[{"moduleCode":"userAndPwd"}]})),
            Err(LoginError::ProtocolChanged)
        );
    }

    #[test]
    fn login_rsa_is_randomized_pkcs1v15_with_bounded_spki_key() {
        let key = parse_public_key(&public_key_data()).unwrap();
        let first = encrypt_password(&key, PASSWORD).unwrap();
        let second = encrypt_password(&key, PASSWORD).unwrap();
        assert_ne!(first, second);
        assert_eq!(
            private_key()
                .decrypt(Pkcs1v15Encrypt, &STANDARD.decode(first).unwrap())
                .unwrap(),
            PASSWORD.as_bytes()
        );
        assert_eq!(
            encrypt_password(&key, &"x".repeat(key.size() - 10)),
            Err(LoginError::InvalidInput)
        );
        assert!(matches!(
            parse_public_key("not a DER public key"),
            Err(LoginError::CryptoError)
        ));
        let wrapped = public_key_data()
            .as_bytes()
            .chunks(64)
            .map(|chunk| std::str::from_utf8(chunk).unwrap())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(parse_public_key(&wrapped).is_ok());
        let small =
            RsaPublicKey::new(rsa::BigUint::from(3233u32), rsa::BigUint::from(17u8)).unwrap();
        let data = STANDARD.encode(small.to_public_key_der().unwrap().as_bytes());
        assert!(matches!(
            parse_public_key(&data),
            Err(LoginError::CryptoError)
        ));
    }

    #[test]
    fn login_ticket_is_bound_to_selected_origin_and_exact_form() {
        let valid = page(
            ID,
            r#"<form id="logon" action="https://fdjwgl.fudan.edu.cn/student/sso?keep=1"><input id="ticket" value="ST-fixture&amp;x"></form>"#,
        );
        let url = ticket_url(&valid, LoginTarget::Academic).unwrap().unwrap();
        assert_eq!(
            url.query_pairs()
                .find(|(key, _)| key == "ticket")
                .unwrap()
                .1,
            "ST-fixture&x"
        );
        assert_eq!(
            ticket_url(&valid, LoginTarget::Canvas),
            Err(LoginError::UnsafeRedirect)
        );
        for action in [
            "http://fdjwgl.fudan.edu.cn/",
            "https://id.fudan.edu.cn/ticket",
            "https://evil.test/",
            "https://fdjwgl.fudan.edu.cn/sso#fragment",
        ] {
            let body = format!(
                r#"<form id="logon" action="{action}"><input id="ticket" value="ST-fixture"></form>"#
            );
            assert_eq!(
                ticket_url(&page(ID, &body), LoginTarget::Academic),
                Err(LoginError::UnsafeRedirect)
            );
        }
        assert_eq!(
            ticket_url(
                &page(ID, r#"<input id="ticket" value="outside-form">"#),
                LoginTarget::Academic
            ),
            Ok(None)
        );
        assert_eq!(
            ticket_url(
                &page(
                    ID,
                    r#"<form id="logon" action="https://fdjwgl.fudan.edu.cn/sso"><input id="ticket" value="a"><input id="ticket" value="b"></form>"#
                ),
                LoginTarget::Academic
            ),
            Err(LoginError::ProtocolChanged)
        );
    }

    #[test]
    fn login_uis_preserves_csrf_and_rejects_exfiltration_or_ambiguous_form() {
        let login_page = page(&uis_url(), uis_html());
        let (url, fields) = uis_form(&login_page, LoginTarget::Academic).unwrap();
        assert_eq!(url.as_str(), uis_url());
        assert!(fields.contains(&("execution".into(), "e1s1".into())));
        assert!(
            !fields
                .iter()
                .any(|(name, _)| name == "password" || name == "username")
        );
        for html in [
            uis_html().replace("action=\"\"", "action=\"https://evil.test/\""),
            uis_html().replace("method=\"post\"", "method=\"get\""),
            format!("{}{}", uis_html(), uis_html()),
            uis_html().replace("execution", "missingExecution"),
        ] {
            assert!(uis_form(&page(&uis_url(), &html), LoginTarget::Academic).is_err());
        }
    }

    #[test]
    fn login_cookies_obey_domain_path_expiry_and_export_scope() {
        let mut flow = Flow::new(LoginTarget::Academic, mock(vec![]));
        let source: Url = "https://fdjwgl.fudan.edu.cn/student/sso".parse().unwrap();
        let headers = reply(
            200,
            &[
                ("set-cookie", "SESSION=default-path; HttpOnly"),
                (
                    "set-cookie",
                    "WIDE=parent; Domain=.fudan.edu.cn; Path=/; Secure",
                ),
                ("set-cookie", "EVIL=no; Domain=evil.test; Path=/"),
                ("set-cookie", "SUFFIX=no; Domain=.edu.cn; Path=/"),
                ("set-cookie", "EXPIRED=no; Max-Age=0; Path=/"),
                ("set-cookie", "__Host-BROKEN=no; Secure"),
            ],
            "",
        )
        .headers;
        flow.receive_cookies(&source, &headers).unwrap();
        let auth: Url = format!("{ID}/ac/").parse().unwrap();
        flow.receive_cookies(
            &auth,
            &reply(
                200,
                &[("set-cookie", "ID_ONLY=no-export; Path=/; Secure")],
                "",
            )
            .headers,
        )
        .unwrap();
        let scoped = cookie_header(&flow.jar, &source).unwrap().unwrap();
        assert!(scoped.to_str().unwrap().contains("SESSION=default-path"));
        let root: Url = LoginTarget::Academic.origin().parse().unwrap();
        assert!(
            !cookie_header(&flow.jar, &root)
                .unwrap()
                .unwrap()
                .to_str()
                .unwrap()
                .contains("SESSION=")
        );
        let imported = flow.export().unwrap();
        assert_eq!(imported.cookies.len(), 2);
        assert!(
            imported
                .cookies
                .iter()
                .any(|cookie| cookie.contains("SESSION=default-path")
                    && cookie.contains("Path=/student"))
        );
        assert!(
            imported
                .cookies
                .iter()
                .all(|cookie| cookie.contains("Secure") && !cookie.contains("ID_ONLY"))
        );
        let mut restored = CookieStore::default();
        for cookie in &imported.cookies {
            restored.parse(cookie, &root).unwrap();
        }
        assert_eq!(restored.get_request_values(&source).count(), 2);
        let network = dansheng_core::network::Network::default();
        network
            .set_session("fixture", &imported.origin, None, imported.cookies)
            .unwrap();
        assert!(!network.credential_available(
            "fixture",
            auth.origin().ascii_serialization().as_str(),
            dansheng_core::network::CredentialKind::Cookie
        ));
    }

    #[test]
    fn login_cookie_domain_identity_survives_rotation_and_deletion_after_import() {
        let mut flow = Flow::new(LoginTarget::Canvas, mock(vec![]));
        let origin: Url = LoginTarget::Canvas.origin().parse().unwrap();
        flow.receive_cookies(
            &origin,
            &reply(
                200,
                &[(
                    "set-cookie",
                    "SID=old; Domain=.fudan.edu.cn; Path=/; Secure",
                )],
                "",
            )
            .headers,
        )
        .unwrap();
        let imported = flow.export().unwrap();
        let mut restored = CookieStore::default();
        for cookie in &imported.cookies {
            restored.parse(cookie, &origin).unwrap();
        }
        restored
            .parse("SID=rotated; Domain=.fudan.edu.cn; Path=/; Secure", &origin)
            .unwrap();
        assert_eq!(
            restored.get_request_values(&origin).collect::<Vec<_>>(),
            vec![("SID", "rotated")]
        );
        restored
            .parse(
                "SID=; Domain=.fudan.edu.cn; Path=/; Max-Age=0; Secure",
                &origin,
            )
            .unwrap();
        assert_eq!(restored.get_request_values(&origin).count(), 0);
    }

    #[test]
    fn login_cookie_export_uses_latest_issuer_and_preserves_absolute_expiration() {
        let mut flow = Flow::new(LoginTarget::Academic, mock(vec![]));
        let target: Url = LoginTarget::Academic.entry().parse().unwrap();
        let auth: Url = ID.parse().unwrap();
        flow.receive_cookies(
            &target,
            &reply(
                200,
                &[
                    (
                        "set-cookie",
                        "WIDE=target; Domain=.fudan.edu.cn; Path=/; Secure",
                    ),
                    (
                        "set-cookie",
                        "TTL=value; Max-Age=600; Path=/student; Secure",
                    ),
                ],
                "",
            )
            .headers,
        )
        .unwrap();
        flow.receive_cookies(
            &auth,
            &reply(
                200,
                &[(
                    "set-cookie",
                    "WIDE=id-provider; Domain=.fudan.edu.cn; Path=/; Secure",
                )],
                "",
            )
            .headers,
        )
        .unwrap();
        let session = flow.export().unwrap();
        assert_eq!(session.cookies.len(), 1);
        assert!(session.cookies[0].contains("TTL=value"));
        assert!(session.cookies[0].contains("Expires="));
        assert!(!session.cookies[0].contains("Max-Age="));
    }

    #[test]
    fn login_credentials_and_auth_tokens_have_separate_fixed_post_destinations() {
        for target in [
            LoginTarget::Academic,
            LoginTarget::Canvas,
            LoginTarget::Ecard,
        ] {
            assert_eq!(
                validate_body_destination(
                    &target.entry().parse().unwrap(),
                    &Body::NeoPassword(json!({}))
                ),
                Err(LoginError::UnsafeRedirect)
            );
            assert_eq!(
                validate_body_destination(
                    &target.entry().parse().unwrap(),
                    &Body::UisPassword(vec![])
                ),
                Err(LoginError::UnsafeRedirect)
            );
            assert_eq!(
                validate_body_destination(&target.entry().parse().unwrap(), &Body::Token(vec![])),
                Err(LoginError::UnsafeRedirect)
            );
        }
        assert!(
            validate_body_destination(
                &format!("{ID}/idp/authn/authExecute").parse().unwrap(),
                &Body::NeoPassword(json!({}))
            )
            .is_ok()
        );
        assert_eq!(
            validate_body_destination(
                &format!("{ID}/idp/authCenter/authnEngine").parse().unwrap(),
                &Body::NeoPassword(json!({}))
            ),
            Err(LoginError::UnsafeRedirect)
        );
    }

    #[tokio::test]
    async fn login_neo_offline_exchange_encrypts_once_and_exports_only_target_cookies() {
        let mut flow = Flow::new(
            LoginTarget::Academic,
            mock(neo_steps(methods(), json!({"loginToken":"offline-token"}))),
        );
        let session = flow.run("00000000", PASSWORD).await.unwrap();
        assert_eq!(session.origin, LoginTarget::Academic.origin());
        assert_eq!(session.cookies.len(), 1);
        assert!(session.cookies[0].contains("JSESSIONID=target-fixture"));
        assert_eq!(
            flow.transport
                .seen
                .iter()
                .filter(|request| request.body.has_password())
                .count(),
            1
        );
        let request = &flow.transport.seen[4];
        let Body::NeoPassword(value) = &request.body else {
            panic!("expected password exchange")
        };
        assert_eq!(value["authPara"]["loginName"], "00000000");
        let ciphertext = STANDARD
            .decode(value["authPara"]["password"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            private_key().decrypt(Pkcs1v15Encrypt, &ciphertext).unwrap(),
            PASSWORD.as_bytes()
        );
        assert!(flow.transport.seen.last().unwrap().cookies.is_none());
    }

    #[tokio::test]
    async fn login_neo_bad_password_stops_without_fallback_or_retry() {
        let mut steps = neo_steps(
            methods(),
            json!({"code":4020,"message":"用户名或密码错误 synthetic upstream details"}),
        );
        steps.truncate(5);
        let mut flow = Flow::new(LoginTarget::Academic, mock(steps));
        assert!(matches!(
            flow.run("00000000", PASSWORD).await,
            Err(LoginError::InvalidCredentials)
        ));
        assert_eq!(flow.transport.seen.len(), 5);
        assert_eq!(
            flow.transport
                .seen
                .iter()
                .filter(|request| request.body.has_password())
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn login_neo_second_factor_stops_before_password_submission() {
        let mut steps = neo_steps(json!({"second":true}), json!({}));
        steps.truncate(3);
        let mut flow = Flow::new(LoginTarget::Academic, mock(steps));
        assert!(matches!(
            flow.run("00000000", PASSWORD).await,
            Err(LoginError::InteractiveLoginRequired)
        ));
        assert!(!flow.password_submitted);
    }

    #[tokio::test]
    async fn login_legacy_offline_exchange_posts_form_once_and_retains_default_cookie_path() {
        let mut steps = legacy_steps(reply(
            303,
            &[(
                "location",
                "https://fdjwgl.fudan.edu.cn/student/home?ticket=ST-offline",
            )],
            "",
        ));
        steps.push(step(
            "https://fdjwgl.fudan.edu.cn/student/home?ticket=ST-offline",
            reply(
                200,
                &[("set-cookie", "SESSION=offline; HttpOnly")],
                "<main>Service landing</main>",
            ),
        ));
        let mut flow = Flow::new(LoginTarget::Academic, mock(steps));
        let session = flow.run("00000000", PASSWORD).await.unwrap();
        assert_eq!(session.cookies.len(), 1);
        assert!(session.cookies[0].contains("Path=/student"));
        let Body::UisPassword(fields) = &flow.transport.seen[2].body else {
            panic!("expected UIS form")
        };
        assert!(fields.contains(&("password".into(), PASSWORD.into())));
        assert!(fields.contains(&("_eventId".into(), "submit".into())));
        assert_eq!(
            flow.transport
                .seen
                .iter()
                .filter(|request| request.body.has_password())
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn login_legacy_bad_password_and_replay_redirect_stop_immediately() {
        for (response, error) in [
            (
                reply(200, &[], "<p>密码有误</p>"),
                LoginError::InvalidCredentials,
            ),
            (
                reply(307, &[("location", "/authserver/login")], ""),
                LoginError::UnsafeRedirect,
            ),
            (
                reply(
                    308,
                    &[("location", "https://id.fudan.edu.cn/idp/authn/authExecute")],
                    "",
                ),
                LoginError::UnsafeRedirect,
            ),
            (
                reply(200, &[], "<p>请输入验证码</p>"),
                LoginError::InteractiveLoginRequired,
            ),
        ] {
            let mut flow = Flow::new(LoginTarget::Academic, mock(legacy_steps(response)));
            assert!(matches!(flow.run("00000000", PASSWORD).await, Err(actual) if actual == error));
            assert_eq!(flow.transport.seen.len(), 3);
        }
    }

    #[tokio::test]
    async fn login_public_200_and_cookie_are_not_authentication_evidence() {
        let mut flow = Flow::new(
            LoginTarget::Academic,
            mock(vec![step(
                LoginTarget::Academic.entry(),
                reply(
                    200,
                    &[("set-cookie", "JSESSIONID=anonymous; Path=/; Secure")],
                    "<main>Public information</main>",
                ),
            )]),
        );
        assert!(matches!(
            flow.run("00000000", PASSWORD).await,
            Err(LoginError::SessionUnavailable)
        ));
        assert!(!flow.password_submitted);
    }

    #[tokio::test]
    async fn login_canvas_and_ecard_use_only_their_fixed_service_origin() {
        for target in [LoginTarget::Canvas, LoginTarget::Ecard] {
            let mut auth: Url = format!("{UIS}/authserver/login").parse().unwrap();
            auth.query_pairs_mut()
                .append_pair("service", target.entry());
            let destination = format!("{}/sso?ticket=ST-offline", target.origin());
            let steps = vec![
                step(
                    target.entry(),
                    reply(302, &[("location", auth.as_str())], ""),
                ),
                step(auth.as_str(), reply(200, &[], uis_html())),
                step(auth.as_str(), reply(302, &[("location", &destination)], "")),
                step(
                    &destination,
                    reply(
                        200,
                        &[("set-cookie", "SESSION=synthetic; Path=/; Secure")],
                        "<main>Service landing</main>",
                    ),
                ),
            ];
            let mut flow = Flow::new(target, mock(steps));
            let session = flow.run("00000000", PASSWORD).await.unwrap();
            assert_eq!(session.origin, target.origin());
            assert_eq!(session.cookies.len(), 1);
        }
    }

    #[tokio::test]
    async fn login_network_failure_after_password_is_never_retried() {
        let mut steps = legacy_steps(reply(200, &[], ""));
        steps[2].reply = Err(LoginError::Timeout);
        let mut flow = Flow::new(LoginTarget::Academic, mock(steps));
        assert!(matches!(
            flow.run("00000000", PASSWORD).await,
            Err(LoginError::Timeout)
        ));
        assert_eq!(flow.transport.seen.len(), 3);
        assert!(flow.password_submitted);
    }

    #[tokio::test]
    async fn login_redirect_and_response_limits_are_enforced_offline() {
        let steps = (0..=MAX_REDIRECTS)
            .map(|_| {
                step(
                    LoginTarget::Academic.entry(),
                    reply(302, &[("location", LoginTarget::Academic.entry())], ""),
                )
            })
            .collect();
        let mut flow = Flow::new(LoginTarget::Academic, mock(steps));
        assert!(matches!(
            flow.run("00000000", PASSWORD).await,
            Err(LoginError::LimitExceeded)
        ));
        assert_eq!(flow.transport.seen.len(), MAX_REDIRECTS + 1);
        let mut flow = Flow::new(
            LoginTarget::Academic,
            mock(vec![step(
                LoginTarget::Academic.entry(),
                reply(200, &[], &"x".repeat(MAX_BODY + 1)),
            )]),
        );
        assert!(matches!(
            flow.run("00000000", PASSWORD).await,
            Err(LoginError::ResponseTooLarge)
        ));
    }

    #[tokio::test]
    async fn login_aggregate_body_and_request_count_are_independently_bounded() {
        let target = LoginTarget::Academic;
        let steps = (0..5)
            .map(|_| step(target.entry(), reply(200, &[], &"x".repeat(MAX_BODY))))
            .collect();
        let mut flow = Flow::new(target, mock(steps));
        for _ in 0..4 {
            flow.send(target.entry().parse().unwrap(), Body::Empty)
                .await
                .unwrap();
        }
        assert!(matches!(
            flow.send(target.entry().parse().unwrap(), Body::Empty)
                .await,
            Err(LoginError::ResponseTooLarge)
        ));
        let steps = (0..MAX_REQUESTS)
            .map(|_| step(target.entry(), reply(200, &[], "")))
            .collect();
        let mut flow = Flow::new(target, mock(steps));
        for _ in 0..MAX_REQUESTS {
            flow.send(target.entry().parse().unwrap(), Body::Empty)
                .await
                .unwrap();
        }
        assert!(matches!(
            flow.send(target.entry().parse().unwrap(), Body::Empty)
                .await,
            Err(LoginError::LimitExceeded)
        ));
        assert_eq!(flow.transport.seen.len(), MAX_REQUESTS);
    }

    #[test]
    fn login_interactive_challenges_and_error_outputs_are_fixed() {
        for html in [
            "<p>请输入验证码</p>",
            "<p>二次认证</p>",
            "<input name=otp>",
            "<input name=pwdEncryptSalt type=hidden>",
            "<p>弱密码提示</p>",
            "<input type=hidden id=pwdEncryptSalt value=synthetic>",
        ] {
            assert_eq!(
                check_html_challenge(html),
                Err(LoginError::InteractiveLoginRequired)
            );
        }
        assert!(
            check_html_challenge("<script>const error='密码有误';</script><main>Sign in</main>")
                .is_ok()
        );
        for error in [
            LoginError::InvalidInput,
            LoginError::InvalidCredentials,
            LoginError::InteractiveLoginRequired,
            LoginError::UnsafeRedirect,
            LoginError::ProtocolChanged,
            LoginError::NetworkError,
            LoginError::Timeout,
            LoginError::ResponseTooLarge,
            LoginError::LimitExceeded,
            LoginError::AuthenticationRejected,
            LoginError::SessionUnavailable,
            LoginError::ServiceUnavailable,
            LoginError::CryptoError,
            LoginError::GatewaySessionRequired,
        ] {
            assert!(!error.message().contains(PASSWORD));
            assert!(!error.to_string().contains("http"));
            assert!(std::error::Error::source(&error).is_none());
            assert!(!error.code().is_empty());
        }
    }

    #[tokio::test]
    async fn only_a_stalled_credential_free_get_is_sent_once_more() {
        let entry = LoginTarget::WebVpn.entry();
        let stalled = |url: &str| Step {
            url: url.into(),
            reply: Err(LoginError::Timeout),
        };
        // Before any credential: one fresh retry, then the reply is used.
        let mut flow = Flow::new(
            LoginTarget::WebVpn,
            mock(vec![stalled(entry), step(entry, reply(200, &[], "ok"))]),
        );
        let page = flow
            .send(entry.parse().unwrap(), Body::Empty)
            .await
            .unwrap();
        assert_eq!(page.reply.status, 200);
        assert_eq!(flow.transport.seen.len(), 2);
        // Never twice in a row, and never anything carrying a body.
        let mut flow = Flow::new(
            LoginTarget::WebVpn,
            mock(vec![stalled(entry), stalled(entry)]),
        );
        assert_eq!(
            flow.send(entry.parse().unwrap(), Body::Empty).await.err(),
            Some(LoginError::Timeout)
        );
        let methods = "https://id.fudan.edu.cn/idp/authn/queryAuthMethods";
        let mut flow = Flow::new(LoginTarget::WebVpn, mock(vec![stalled(methods)]));
        assert_eq!(
            flow.send(methods.parse().unwrap(), Body::Json(json!({})))
                .await
                .err(),
            Some(LoginError::Timeout)
        );
        // After the password went out, even a plain GET is not resent.
        let mut flow = Flow::new(LoginTarget::WebVpn, mock(vec![stalled(entry)]));
        flow.password_submitted = true;
        assert_eq!(
            flow.send(entry.parse().unwrap(), Body::Empty).await.err(),
            Some(LoginError::Timeout)
        );
        assert_eq!(flow.transport.seen.len(), 1);
    }

    #[test]
    fn login_validates_input_and_can_run_in_a_send_host_task() {
        assert!(validate_input("00000000", PASSWORD).is_ok());
        for (student_id, password) in [
            ("a", PASSWORD),
            ("00000000\r\n", PASSWORD),
            ("00000000", ""),
            ("00000000", "abc\0xyz"),
        ] {
            assert_eq!(
                validate_input(student_id, password),
                Err(LoginError::InvalidInput)
            );
        }
        fn assert_send<T: Send>(_: T) {}
        assert_send(login("00000000", PASSWORD, LoginTarget::Academic));
    }
}
