// SPDX-License-Identifier: GPL-3.0-or-later
//! Trusted bridge: official clients use the same permissions, sessions and data store as UI/MCP.
use crate::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, TransportAuth,
    canvas::{CanvasAccess, CanvasClient, CanvasId, CanvasWriteError},
    fudan::{FudanTimetableClient, PostgraduateEndpoint},
    models::{Semester, SourceContext},
};
use async_trait::async_trait;
use chrono::Utc;
use dansheng_core::{
    api::{CoreError, CoreResult, Principal, required_string},
    network::{CookieCsrf, CredentialKind, HttpRequest, Network},
    platform::PlatformPort,
    policy::Grant,
    services::{CoreService, ServiceContext},
};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[cfg(test)]
#[path = "bridge_bytes_tests.rs"]
mod bridge_bytes_tests;

#[cfg(test)]
#[path = "drive_regression_tests.rs"]
mod drive_regression_tests;

pub struct CampusService;
// Canvas serves same-origin file metadata, then redirects the download to this
// school storage origin. Network selects credentials again per origin on redirect.
#[cfg(feature = "login")]
const FUDAN_CANVAS_STORAGE: &str = "https://elearning.obs.fudan.edu.cn";

#[cfg(feature = "webvpn")]
fn initialize_webvpn_routes(context: &ServiceContext<'_>, account: &str) -> CoreResult<()> {
    let saved = context.store.kv_get("core:network-routes", account)?;
    let mut routes: Vec<dansheng_core::network_routes::GatewayRoute> = if saved.is_null() {
        vec![]
    } else {
        serde_json::from_value(saved)?
    };
    // The Fudan switch's current setting decides new Fudan routes; the forum
    // stays on its own fallback mode.
    let mode = routes
        .iter()
        .find(|route| {
            route.provider == "fudan.webvpn" && crate::webvpn::is_fudan_origin(&route.origin)
        })
        .map(|route| route.mode)
        .unwrap_or(dansheng_core::network_routes::RouteMode::Auto);
    // Login fills missing defaults without deleting custom routes or overriding
    // explicit per-origin modes, including the owner's disabled (Direct) state.
    for origin in crate::webvpn::DEFAULT_ORIGINS {
        if !routes.iter().any(|route| route.origin == *origin) {
            routes.push(crate::webvpn::gateway_route(
                origin,
                crate::webvpn::default_mode(origin, mode),
            )?);
        }
    }
    dansheng_core::network_routes::validate_routes(&routes)?;
    context.store.kv_set(
        "core:network-routes",
        account,
        &serde_json::to_value(&routes)?,
    )?;
    context.network.set_routes(account, routes)
}

/// Whether `origin` is set to always go through WebVPN for this account.
#[cfg(feature = "webvpn")]
fn gateway_only(context: &ServiceContext<'_>, account: &str, origin: &str) -> bool {
    context.network.routes(account).is_ok_and(|routes| {
        routes.iter().any(|route| {
            route.origin == origin
                && route.mode == dansheng_core::network_routes::RouteMode::Gateway
        })
    })
}

/// Whether `origin` may fall back to WebVPN (not explicitly direct-only) for this account.
#[cfg(feature = "webvpn")]
fn gateway_fallback_allowed(context: &ServiceContext<'_>, account: &str, origin: &str) -> bool {
    context
        .network
        .routes(account)
        .map(|routes| {
            routes.is_empty()
                || routes.iter().any(|route| {
                    route.origin == origin
                        && route.mode != dansheng_core::network_routes::RouteMode::Direct
                })
        })
        .unwrap_or(true)
}

/// Signs in to one UIS service. With WebVPN switched on for the service the
/// sign-in itself runs through WebVPN (WebVPN is signed into first when its
/// session is missing), and the site session lives in the gateway session.
#[cfg(feature = "login")]
async fn uis_sign_in(
    context: &ServiceContext<'_>,
    account: &str,
    password: &str,
    target: crate::login::LoginTarget,
) -> CoreResult<()> {
    let fail = |e: crate::login::LoginError| CoreError::new(e.code(), e.message());
    #[cfg(feature = "webvpn")]
    if target != crate::login::LoginTarget::WebVpn
        && gateway_only(context, account, target.origin())
    {
        use crate::login::{LoginError, LoginTarget, login, login_via_gateway};
        let gateway = crate::webvpn::GATEWAY_ORIGIN;
        let cookies = context.network.session_cookies(account, gateway)?;
        let session = match login_via_gateway(account, password, target, &cookies).await {
            Err(LoginError::GatewaySessionRequired) => {
                let vpn = login(account, password, LoginTarget::WebVpn)
                    .await
                    .map_err(fail)?;
                context
                    .network
                    .set_session(account, gateway, None, vpn.cookies.clone())?;
                login_via_gateway(account, password, target, &vpn.cookies).await
            }
            other => other,
        }
        .map_err(fail)?;
        return context
            .network
            .set_session(account, gateway, None, session.cookies);
    }
    let direct_result = crate::login::login(account, password, target).await;
    #[cfg(feature = "webvpn")]
    let session = match direct_result {
        Ok(session) => session,
        Err(err)
            if target != crate::login::LoginTarget::WebVpn
                && matches!(
                    err,
                    crate::login::LoginError::NetworkError | crate::login::LoginError::Timeout
                )
                && gateway_fallback_allowed(context, account, target.origin()) =>
        {
            use crate::login::{LoginError, LoginTarget, login, login_via_gateway};
            let gateway = crate::webvpn::GATEWAY_ORIGIN;
            let cookies = context
                .network
                .session_cookies(account, gateway)
                .unwrap_or_default();
            let session = match login_via_gateway(account, password, target, &cookies).await {
                Err(LoginError::GatewaySessionRequired) => {
                    let vpn = login(account, password, LoginTarget::WebVpn)
                        .await
                        .map_err(fail)?;
                    context
                        .network
                        .set_session(account, gateway, None, vpn.cookies.clone())?;
                    login_via_gateway(account, password, target, &vpn.cookies).await
                }
                other => other,
            }
            .map_err(fail)?;
            return context
                .network
                .set_session(account, gateway, None, session.cookies);
        }
        Err(err) => return Err(fail(err)),
    };
    #[cfg(not(feature = "webvpn"))]
    let session = direct_result.map_err(fail)?;

    context
        .network
        .set_session(account, &session.origin, None, session.cookies)?;
    #[cfg(feature = "webvpn")]
    if target == crate::login::LoginTarget::WebVpn
        || context
            .network
            .routes(account)
            .map(|r| r.is_empty())
            .unwrap_or(true)
    {
        initialize_webvpn_routes(context, account)?;
    }
    Ok(())
}

pub(crate) struct BoundTransport<'a> {
    pub(crate) network: &'a Network,
    pub(crate) platform: &'a dyn PlatformPort,
    pub(crate) principal: &'a Principal,
    pub(crate) grant: &'a Grant,
    pub(crate) account: &'a str,
    pub(crate) store: &'a dansheng_core::store::Store,
    pub(crate) source_capability: &'a str,
    pub(crate) credential_lease: std::sync::Mutex<Option<String>>,
}

impl BoundTransport<'_> {
    fn current_authority(&self) -> Result<Grant, ConnectorError> {
        let current = self
            .store
            .grant(&self.principal.id)
            .map_err(transport_error)?;
        current
            .check(self.principal, self.source_capability)
            .map_err(|_| ConnectorError::PermissionDenied)?;
        current
            .check_account(self.principal, Some(self.account))
            .map_err(|_| ConnectorError::PermissionDenied)?;
        Ok(current)
    }
    pub(crate) fn pin_credential_identity(
        &self,
        identity: String,
        challenge: &crate::AuthChallenge,
    ) -> Result<(), ConnectorError> {
        let mut lease = self
            .credential_lease
            .lock()
            .map_err(|_| ConnectorError::TransportUnavailable)?;
        if lease.as_ref().is_some_and(|expected| expected != &identity) {
            return Err(ConnectorError::AuthRequired(challenge.clone()));
        }
        if lease.is_none() {
            *lease = Some(identity);
        }
        Ok(())
    }
    fn check_native_lease(&self, challenge: &crate::AuthChallenge) -> Result<(), ConnectorError> {
        let identity = self
            .network
            .session_fingerprint(Some(self.account))
            .map_err(|error| {
                if error.code == "AuthenticationRequired" {
                    ConnectorError::AuthRequired(challenge.clone())
                } else {
                    transport_error(error)
                }
            })?;
        self.pin_credential_identity(format!("native:{identity}"), challenge)
    }

    fn check_after_response(
        &self,
        challenge: &crate::AuthChallenge,
        leased: bool,
        mutating: bool,
    ) -> Result<(), ConnectorError> {
        let result = self.current_authority().and_then(|_| {
            if leased {
                self.check_native_lease(challenge)?;
            }
            Ok(())
        });
        result.map_err(|error| {
            if mutating {
                ConnectorError::NeedsReconciliation
            } else {
                error
            }
        })
    }
}

#[async_trait]
impl ConnectorTransport for BoundTransport<'_> {
    async fn execute_canvas_session_write(
        &self,
        input: ConnectorRequest,
    ) -> Result<ConnectorResponse, CanvasWriteError> {
        if self.source_capability != "canvas.write"
            || input.method != crate::HttpMethod::Post
            || !matches!(&input.auth, TransportAuth::HostSession { account_id } if account_id == self.account)
        {
            return Err(ConnectorError::PermissionDenied.into());
        }
        let reply_id = input
            .url
            .path()
            .strip_prefix("/api/v1/conversations/")
            .and_then(|tail| tail.strip_suffix("/add_message"));
        let endpoint = input.url.path() == "/api/v1/conversations"
            || reply_id.is_some_and(|id| {
                !id.is_empty() && id.len() <= 32 && id.bytes().all(|b| b.is_ascii_digit())
            });
        if input.url.origin().ascii_serialization() != "https://elearning.fudan.edu.cn"
            || !input.url.username().is_empty()
            || input.url.password().is_some()
            || input.url.query().is_some()
            || input.url.fragment().is_some()
            || !endpoint
            || input.headers.iter().any(|(key, _)| {
                !matches!(key.to_ascii_lowercase().as_str(), "accept" | "content-type")
            })
            || !input.headers.iter().any(|(key, value)| {
                key.eq_ignore_ascii_case("content-type")
                    && value == "application/x-www-form-urlencoded"
            })
        {
            return Err(ConnectorError::PermissionDenied.into());
        }
        let current = self.current_authority()?;
        let mut io_grant = self.grant.clone();
        io_grant.allow_private_network &= current.allow_private_network;
        io_grant.expires_at = current.expires_at;
        let challenge = crate::AuthChallenge {
            connector: "canvas".into(),
            origin: input.url.origin().ascii_serialization(),
            account_id: self.account.into(),
            mode: crate::AuthMode::HttpSession,
        };
        self.check_native_lease(&challenge)?;
        let mut request = HttpRequest {
            url: input.url.to_string(),
            method: "POST".into(),
            headers: input.headers.into_iter().collect(),
            body: input
                .body
                .map(|bytes| String::from_utf8(bytes).map(Value::String))
                .transpose()
                .map_err(|_| ConnectorError::InvalidConfiguration("request body encoding"))?,
            account_id: Some(self.account.into()),
            timeout_ms: Some(15000),
            follow_redirects: false,
        };
        request
            .headers
            .insert("X-Requested-With".into(), "XMLHttpRequest".into());
        let response = self
            .network
            .request_with_cookie_csrf(
                self.principal,
                &io_grant,
                request,
                CookieCsrf {
                    origin: "https://elearning.fudan.edu.cn".into(),
                    cookie_name: "_csrf_token".into(),
                    header_name: "X-CSRF-Token".into(),
                },
            )
            .await
            .map_err(|error| {
                // The dedicated native method has no downloads/gateways/redirects.
                // Every failure after send() is classified by Network as uncertain.
                if error.code == "NeedsReconciliation" {
                    CanvasWriteError::NeedsReconciliation
                } else if error.code == "AuthenticationRequired" {
                    ConnectorError::AuthRequired(challenge.clone()).into()
                } else {
                    transport_error(error).into()
                }
            })?;
        // Revocation/replacement after dispatch must never become a safe retry.
        self.current_authority()
            .map_err(|_| CanvasWriteError::NeedsReconciliation)?;
        self.check_native_lease(&challenge)
            .map_err(|_| CanvasWriteError::NeedsReconciliation)?;
        Ok(ConnectorResponse {
            status: response.status,
            final_url: url::Url::parse(&response.url)
                .map_err(|_| CanvasWriteError::NeedsReconciliation)?,
            headers: response.headers.into_iter().collect(),
            body: response.body.into_bytes(),
        })
    }
    async fn execute(&self, input: ConnectorRequest) -> Result<ConnectorResponse, ConnectorError> {
        let mutating = input.method.is_mutating() && self.source_capability.ends_with(".write");
        if self.source_capability == "canvas.write"
            && input.method == crate::HttpMethod::Post
            && matches!(input.auth, TransportAuth::HostSession { .. })
        {
            return self
                .execute_canvas_session_write(input)
                .await
                .map_err(|error| match error {
                    CanvasWriteError::Rejected(error) => error,
                    CanvasWriteError::NeedsReconciliation => ConnectorError::NeedsReconciliation,
                });
        }
        let current = self.current_authority()?;
        if match &input.auth {
            TransportAuth::Anonymous => false,
            TransportAuth::HostToken { account_id }
            | TransportAuth::HostHeaders { account_id }
            | TransportAuth::HostSession { account_id }
            | TransportAuth::OptionalSession { account_id }
            | TransportAuth::BrowserSession { account_id } => account_id != self.account,
        } {
            return Err(ConnectorError::PermissionDenied);
        }
        let mut io_grant = self.grant.clone();
        io_grant.allow_private_network &= current.allow_private_network;
        // DanXi's room directory is an anonymous, fixed intranet HTTP service. An
        // isolated transport has neither vault sessions nor mutable gateway routes.
        // Explicit WebVPN routes still use the normal account-scoped transport.
        let direct_rooms = self.principal.is_owner()
            && self.source_capability == "fudan.rooms.read"
            && input.method == crate::HttpMethod::Get
            && input.body.is_none()
            && matches!(input.auth, TransportAuth::Anonymous)
            && input.url.origin().ascii_serialization() == "http://10.64.130.6"
            && matches!(input.url.path(), "/" | "/daystatus.asp")
            && self
                .network
                .routes(self.account)
                .map_err(transport_error)?
                .iter()
                .any(|r| {
                    r.origin == "http://10.64.130.6"
                        && r.mode == dansheng_core::network_routes::RouteMode::Direct
                });
        let isolated = direct_rooms.then(Network::default);
        if direct_rooms {
            io_grant.allow_private_network = true;
        }
        io_grant.expires_at = current.expires_at.clone();
        let credential_kind = match &input.auth {
            TransportAuth::HostToken { .. } => CredentialKind::Bearer,
            TransportAuth::HostHeaders { .. } => CredentialKind::SecretHeaders,
            TransportAuth::HostSession { .. } | TransportAuth::BrowserSession { .. } => {
                CredentialKind::Cookie
            }
            _ => CredentialKind::Any,
        };
        let optional_without_session = matches!(&input.auth,TransportAuth::OptionalSession {account_id}
            if !self.network.has_session_for_origin(account_id,&input.url.origin().ascii_serialization()));
        let credential_kind =
            if matches!(input.auth, TransportAuth::Anonymous) || optional_without_session {
                CredentialKind::Anonymous
            } else {
                credential_kind
            };
        let (account, browser) = match &input.auth {
            TransportAuth::Anonymous => (Some(self.account.to_owned()), false),
            TransportAuth::HostToken { account_id }
            | TransportAuth::HostHeaders { account_id }
            | TransportAuth::HostSession { account_id } => (Some(account_id.clone()), false),
            // Keep the account to select its gateway; an optional unauthenticated
            // logical origin must not lose the account-scoped WebVPN cookie.
            TransportAuth::OptionalSession { account_id } => (Some(account_id.clone()), false),
            TransportAuth::BrowserSession { account_id } => (Some(account_id.clone()), true),
        };
        self.grant
            .check_account(self.principal, account.as_deref())
            .map_err(|_| ConnectorError::PermissionDenied)?;
        if browser {
            // The platform supplies an account/origin-bound live page handle.
            // This branch never imports cookies or invokes the native network.
            return crate::page_transport::execute(self, input).await;
        }
        let challenge = crate::AuthChallenge {
            connector: "official-campus".into(),
            origin: input.url.origin().ascii_serialization(),
            account_id: account.clone().unwrap_or_default(),
            mode: match &input.auth {
                TransportAuth::HostToken { .. } => crate::AuthMode::Token,
                TransportAuth::HostHeaders { .. } => crate::AuthMode::SecretHeaders,
                _ => crate::AuthMode::HttpSession,
            },
        };
        let leased = credential_kind != CredentialKind::Anonymous;
        if leased {
            self.check_native_lease(&challenge)?;
        }
        // The forum signs in on its own, outside WebVPN. When its token is
        // present and a read is still refused, the missing session is the
        // gateway's; a forum sign-in would not repair it. Fudan services keep
        // AuthRequired: their sign-in runs through the gateway and restores it.
        #[cfg(feature = "webvpn")]
        let gateway_session_missing = !mutating
            && credential_kind == CredentialKind::Bearer
            && crate::webvpn::FORUM_ORIGINS.contains(&challenge.origin.as_str())
            && self.network.credential_available(
                self.account,
                &challenge.origin,
                CredentialKind::Bearer,
            );
        #[cfg(not(feature = "webvpn"))]
        let gateway_session_missing = false;
        let request_error = |error: CoreError| {
            if error.code != "AuthenticationRequired" {
                transport_error(error)
            } else if gateway_session_missing {
                ConnectorError::GatewaySessionRequired
            } else {
                ConnectorError::AuthRequired(challenge.clone())
            }
        };
        // Bytes are an explicit connector contract. Proto/octet-stream requests
        // use the bounded byte API; page transport was selected above and can
        // never reach this native branch as a fallback.
        let binary = input.headers.iter().any(|(name, value)| {
            (name.eq_ignore_ascii_case("accept") || name.eq_ignore_ascii_case("content-type"))
                && value.split([',', ';']).any(|mime| {
                    matches!(
                        mime.trim().to_ascii_lowercase().as_str(),
                        "application/x-protobuf"
                            | "application/protobuf"
                            | "application/octet-stream"
                    )
                })
        }) || input
            .body
            .as_ref()
            .is_some_and(|body| std::str::from_utf8(body).is_err());
        if binary {
            let response = isolated
                .as_ref()
                .unwrap_or(self.network)
                .request_bytes(
                    self.principal,
                    &io_grant,
                    HttpRequest {
                        url: input.url.to_string(),
                        method: input.method.as_str().into(),
                        headers: input.headers.into_iter().collect(),
                        account_id: account,
                        timeout_ms: Some(15000),
                        follow_redirects: false,
                        ..Default::default()
                    },
                    input.body,
                    credential_kind,
                )
                .await
                .map_err(request_error)?;
            self.check_after_response(&challenge, leased, mutating)?;
            return Ok(ConnectorResponse {
                status: response.status,
                final_url: url::Url::parse(&response.url).map_err(|_| {
                    if mutating {
                        ConnectorError::NeedsReconciliation
                    } else {
                        ConnectorError::UnsafeUrl
                    }
                })?,
                headers: response.headers.into_iter().collect(),
                body: response.body,
            });
        }
        let canvas_course_read = matches!(
            input.auth,
            TransportAuth::HostToken { .. } | TransportAuth::HostSession { .. }
        ) && input.method == crate::HttpMethod::Get
            && input.url.origin().ascii_serialization() == "https://elearning.fudan.edu.cn"
            && input.url.path().starts_with("/api/v1/courses/");
        let request = HttpRequest {
            url: input.url.to_string(),
            method: input.method.as_str().into(),
            headers: input.headers.into_iter().collect::<BTreeMap<_, _>>(),
            body: input
                .body
                .map(|b| String::from_utf8(b).map(Value::String))
                .transpose()
                .map_err(|_| ConnectorError::InvalidConfiguration("request body encoding"))?,
            account_id: account,
            timeout_ms: Some(15000),
            follow_redirects: false,
        };
        let response = isolated
            .as_ref()
            .unwrap_or(self.network)
            .request_with_credentials(self.principal, &io_grant, request, credential_kind)
            .await
            .map_err(request_error)?;
        self.check_after_response(&challenge, leased, mutating)?;
        if canvas_course_read && matches!(response.status, 401 | 403) {
            let check = self
                .network
                .request_with_credentials(
                    self.principal,
                    &io_grant,
                    HttpRequest {
                        url: "https://elearning.fudan.edu.cn/api/v1/users/self/profile".into(),
                        account_id: Some(self.account.to_owned()),
                        timeout_ms: Some(8000),
                        follow_redirects: false,
                        ..Default::default()
                    },
                    credential_kind,
                )
                .await;
            self.current_authority()?;
            if leased {
                self.check_native_lease(&challenge)?;
            }
            if check.is_ok_and(|r| {
                r.status == 200
                    && serde_json::from_str::<Value>(&r.body).is_ok_and(|p| !p["id"].is_null())
            }) {
                return Err(ConnectorError::CourseAccessDenied);
            }
        }
        Ok(ConnectorResponse {
            status: response.status,
            final_url: url::Url::parse(&response.url).map_err(|_| {
                if mutating {
                    ConnectorError::NeedsReconciliation
                } else {
                    ConnectorError::UnsafeUrl
                }
            })?,
            headers: response.headers.into_iter().collect(),
            body: response.body.into_bytes(),
        })
    }
}
fn transport_error(error: CoreError) -> ConnectorError {
    match error.code.as_str() {
        "NeedsReconciliation" => ConnectorError::NeedsReconciliation,
        "PermissionDenied" => ConnectorError::PermissionDenied,
        "Timeout" => ConnectorError::Timeout,
        "CapabilityUnavailable" => ConnectorError::CapabilityUnavailable,
        "CsrfRequired" => ConnectorError::CanvasCsrfRequired,
        "UnsupportedContent" => ConnectorError::Parse {
            source_name: "HTTP transport",
            field: "text encoding",
        },
        "UnsafeRoute" => ConnectorError::UnsafeUrl,
        "ResponseTooLarge" => ConnectorError::LimitExceeded,
        _ => ConnectorError::TransportUnavailable,
    }
}
pub(crate) fn source_error(error: ConnectorError) -> CoreError {
    match error {
        ConnectorError::NeedsReconciliation => {
            canvas_write_error(CanvasWriteError::NeedsReconciliation)
        }
        ConnectorError::Rejected(code) => {
            CoreError::new(code, "the remote service rejected this operation")
        }
        ConnectorError::AuthRequired(_) => CoreError::new(
            "AuthenticationRequired",
            "complete this source's authentication through the host",
        ),
        ConnectorError::GatewaySessionRequired => CoreError::new(
            "WebVpnLoginRequired",
            "sign in to WebVPN to reach this source through it",
        ),
        ConnectorError::CourseAccessDenied => CoreError::new(
            "CourseAccessDenied",
            "this Canvas course does not expose this resource",
        ),
        ConnectorError::PermissionDenied => {
            CoreError::new("PermissionDenied", "source access denied")
        }
        ConnectorError::CapabilityUnavailable => {
            CoreError::new("CapabilityUnavailable", "source transport unavailable")
        }
        ConnectorError::CanvasCsrfRequired => CoreError::new(
            "CanvasCsrfRequired",
            "refresh the Canvas HTTP session before explicitly sending again",
        ),
        ConnectorError::Timeout => CoreError::new("Timeout", "source request timed out"),
        ConnectorError::Parse { source_name, field } => {
            CoreError::new("SourceSchemaChanged", format!("{source_name}.{field}"))
        }
        ConnectorError::HttpStatus(status) => CoreError::new("SourceHttpError", status.to_string()),
        ConnectorError::TransportUnavailable => {
            CoreError::new("SourceTransportUnavailable", "source transport unavailable")
        }
        other => CoreError::new("SourceError", other.to_string()),
    }
}

fn canvas_write_error(error: CanvasWriteError) -> CoreError {
    match error {
        CanvasWriteError::Rejected(ConnectorError::InvalidConfiguration(_)) => {
            CoreError::invalid("invalid Canvas conversation input")
        }
        CanvasWriteError::Rejected(error) => source_error(error),
        CanvasWriteError::NeedsReconciliation => CoreError::new(
            "NeedsReconciliation",
            "Canvas send outcome is unknown; refresh the conversation before sending again",
        ),
    }
}

#[async_trait]
impl CoreService for CampusService {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        let mut methods = vec![
            ("fudan.semesters", "fudan.academic.read"),
            ("fudan.postgraduate.semester", "fudan.catalog.read"),
            ("fudan.timetable.sync", "fudan.academic.read"),
            ("fudan.postgraduate.sync", "fudan.academic.read"),
            ("fudan.student_association", "fudan.academic.read"),
            ("fudan.exams", "fudan.academic.read"),
            ("fudan.grades", "fudan.academic.read"),
            ("fudan.gpa", "fudan.academic.read"),
            ("fudan.cloud.roots", "fudan.cloud.read"),
            ("fudan.cloud.list", "fudan.cloud.read"),
            ("fudan.cloud.download", "fudan.cloud.read"),
            ("fudan.cloud.mkdir", "fudan.cloud.write"),
            ("fudan.cloud.rename", "fudan.cloud.write"),
            ("fudan.cloud.delete", "fudan.cloud.write"),
            ("fudan.cloud.upload", "fudan.cloud.write"),
            ("fudan.cloud.share", "fudan.cloud.write"),
            ("fudan.cloud.unshare", "fudan.cloud.write"),
            ("webdav.servers", "webdav.read"),
            ("webdav.list", "webdav.read"),
            ("webdav.download", "webdav.read"),
            ("webdav.server.add", "webdav.configure"),
            ("webdav.server.remove", "webdav.configure"),
            ("webdav.login", "webdav.configure"),
            ("webdav.mkdir", "webdav.write"),
            ("webdav.rename", "webdav.write"),
            ("webdav.delete", "webdav.write"),
            ("webdav.upload", "webdav.write"),
            #[cfg(feature = "login")]
            ("fudan.cloud.login", "fudan.cloud.login"),
            ("fudan.ecard.balance", "fudan.card.read"),
            #[cfg(feature = "login")]
            ("fudan.ecard.login", "fudan.card.login"),
            #[cfg(feature = "login")]
            ("fudan.academic.login", "fudan.academic.login"),
            #[cfg(feature = "login")]
            ("fudan.life.login", "fudan.life.login"),
            ("fudan.portal.bind", "fudan.life.login"),
            #[cfg(feature = "login")]
            ("fudan.ecard.session", "fudan.card.login"),
            #[cfg(feature = "webvpn")]
            ("fudan.webvpn.status", "fudan.academic.read"),
            #[cfg(feature = "webvpn")]
            ("fudan.webvpn.configure", "fudan.academic.read"),
            #[cfg(all(feature = "webvpn", feature = "login"))]
            ("fudan.webvpn.login", "fudan.academic.login"),
            ("fudan.ecard.transactions", "fudan.card.read"),
            ("fudan.ecard.statement", "fudan.card.read"),
            ("fudan.ecard.statistics", "fudan.card.read"),
            ("fudan.electricity", "fudan.life.read"),
            ("fudan.electricity.history", "fudan.life.read"),
            ("fudan.electricity.statistics", "fudan.life.read"),
            ("fudan.electricity.alert.get", "fudan.life.read"),
            ("fudan.electricity.alert.set", "fudan.life.read"),
            ("fudan.electricity.alert.check", "fudan.life.read"),
            ("fudan.electricity.alert.ack", "fudan.life.read"),
            ("fudan.library.occupancy", "fudan.life.read"),
            ("fudan.dining.occupancy", "fudan.life.read"),
            ("fudan.rooms", "fudan.rooms.read"),
            ("fudan.pe", "fudan.pe.read"),
            ("fudan.bus", "fudan.life.read"),
            ("fudan.notices", "fudan.notices.read"),
            ("fudan.notice.attachments", "fudan.notices.read"),
            ("fudan.notice.attachment.download", "fudan.notices.read"),
            ("fudan.qr.status", "fudan.identity.read"),
            ("fudan.qr.present", "fudan.identity.present"),
            ("canvas.configure", "canvas.configure"),
            #[cfg(feature = "login")]
            ("canvas.token.bind", "canvas.login"),
            ("canvas.uis.login", "canvas.login"),
            ("canvas.courses.sync", "canvas.read"),
            ("canvas.conversations.sync", "canvas.read"),
            ("canvas.conversation.read", "canvas.read"),
            ("canvas.recipients.search", "canvas.read"),
            ("canvas.course_users.sync", "canvas.read"),
            ("canvas.conversation.reply", "canvas.write"),
            ("canvas.conversation.create", "canvas.write"),
            ("canvas.assignments.sync", "canvas.read"),
            ("canvas.materials.sync", "canvas.read"),
            ("canvas.material.download", "canvas.read"),
            ("canvas.folders.sync", "canvas.read"),
            ("canvas.modules.sync", "canvas.read"),
            ("canvas.module_items.sync", "canvas.read"),
            ("canvas.pages.sync", "canvas.read"),
            ("canvas.page.read", "canvas.read"),
            ("canvas.announcements.sync", "canvas.read"),
            ("canvas.quizzes.sync", "canvas.read"),
            ("canvas.quiz.read", "canvas.read"),
            ("canvas.discussions.sync", "canvas.read"),
            ("canvas.discussion.read", "canvas.read"),
            ("canvas.discussion.view", "canvas.read"),
            ("canvas.assignment_groups.sync", "canvas.read"),
            ("canvas.submission.self", "canvas.read"),
            ("canvas.enrollments.self", "canvas.read"),
            ("canvas.grades.self", "canvas.read"),
            ("community.tea.divisions", "community.read"),
            ("community.tea.login", "community.login"),
            ("community.tea.search", "community.read"),
            ("community.tea.publish", "community.write"),
            ("community.tea.reply", "community.write"),
            ("community.tea.reconcile", "community.write"),
            ("community.tea.holes", "community.read"),
            ("community.tea.hole", "community.read"),
            ("community.tea.floors", "community.read"),
            ("community.tea.pinned", "community.read"),
            ("community.tea.favorites", "community.read"),
            ("community.tea.favorite", "community.write"),
            ("community.danke.search", "community.read"),
            ("community.danke.group", "community.read"),
            ("community.danke.reviews", "community.read"),
        ];
        methods.extend(crate::expanded_services::METHODS);
        methods
    }
    async fn call(
        &self,
        context: ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> CoreResult<Value> {
        let capability = self
            .methods()
            .into_iter()
            .find(|(name, _)| *name == method)
            .ok_or_else(|| CoreError::new("MethodNotFound", "unknown campus method"))?
            .1;
        grant.check(principal, capability)?;
        let account = required_string(&params, "account_id")?;
        if crate::expanded_services::handles(method) {
            return crate::expanded_services::call(context, principal, grant, method, &params)
                .await;
        }
        grant.check_account(principal, Some(account))?;
        if method.starts_with("webdav.") {
            return webdav_call(
                context, principal, grant, capability, method, &params, account,
            )
            .await;
        }
        if method == "fudan.postgraduate.semester" {
            let mut io_grant = grant.clone();
            io_grant.capabilities.insert("http.request".into());
            io_grant
                .origins
                .insert(crate::academic_catalog::CATALOG_ORIGIN.into());
            let source = SourceContext {
                account_id: account.into(),
                source_id: "official.fudan.postgraduate.semester".into(),
                observed_at: Utc::now(),
            };
            let client = crate::academic_catalog::FudanAcademicCatalogClient::new(BoundTransport {
                account,
                store: context.store,
                source_capability: capability,
                credential_lease: Default::default(),
                network: context.network,
                platform: context.platform,
                principal,
                grant: &io_grant,
            });
            let semester = crate::postgraduate_calendar::current_semester(&client, &source).await
                .map_err(|error| match error {
                    crate::postgraduate_calendar::PostgraduateCalendarError::Source(error) => campus_error(error),
                    crate::postgraduate_calendar::PostgraduateCalendarError::SemesterCalendarUnavailable =>
                        CoreError::new("SemesterCalendarUnavailable", "this postgraduate semester has no verified calendar"),
                })?;
            return Ok(serde_json::to_value(semester)?);
        }
        if method.starts_with("fudan.electricity.alert.") {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "electricity reminders require the local owner",
                ));
            }
            use crate::electricity_alert as alert;
            match method {
                "fudan.electricity.alert.get" => {
                    return Ok(serde_json::to_value(alert::get(context.store, account)?)?);
                }
                "fudan.electricity.alert.set" => {
                    let enabled = params["enabled"]
                        .as_bool()
                        .ok_or_else(|| CoreError::invalid("enabled must be a boolean"))?;
                    let threshold = params["threshold_kwh"]
                        .as_f64()
                        .ok_or_else(|| CoreError::invalid("threshold_kwh must be a number"))?;
                    return Ok(serde_json::to_value(alert::configure(
                        context.store,
                        account,
                        enabled,
                        threshold,
                    )?)?);
                }
                "fudan.electricity.alert.ack" => {
                    return Ok(serde_json::to_value(alert::acknowledge(
                        context.store,
                        account,
                        required_string(&params, "delivery_key")?,
                        chrono::Utc::now().timestamp_millis(),
                    )?)?);
                }
                _ => {}
            }
        }
        #[cfg(feature = "login")]
        if method == "fudan.portal.bind" {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "only the local user may complete a campus verification",
                ));
            }
            let portal = "https://my.fudan.edu.cn";
            let identity = "https://elearning.fudan.edu.cn";
            let cookies = |field: &str| -> CoreResult<Vec<String>> {
                let header = required_string(&params, field)?;
                if header.len() > 16384 || header.chars().any(char::is_control) {
                    return Err(CoreError::invalid("invalid campus cookies"));
                }
                let rows: Vec<_> = header
                    .split(';')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(|s| {
                        if s.split_once('=').is_none_or(|(name, _)| {
                            name.is_empty()
                                || !name.bytes().all(|b| {
                                    b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b)
                                })
                        }) {
                            return Err(CoreError::invalid("invalid campus cookie"));
                        }
                        Ok(format!("{s}; Path=/; Secure; HttpOnly"))
                    })
                    .collect::<CoreResult<_>>()?;
                if rows.is_empty() || rows.len() > 96 {
                    return Err(CoreError::invalid("invalid campus cookies"));
                }
                Ok(rows)
            };
            let target_cookies = cookies("portal")?;
            let trial = Network::default();
            trial.set_session(account, identity, None, cookies("identity")?)?;
            trial.set_session(account, portal, None, target_cookies.clone())?;
            let mut g = grant.clone();
            g.capabilities.insert("http.request".into());
            g.origins.extend([identity.to_owned(), portal.to_owned()]);
            let get = |url: &str| HttpRequest {
                url: url.into(),
                account_id: Some(account.into()),
                timeout_ms: Some(12000),
                follow_redirects: false,
                ..Default::default()
            };
            let profile = trial
                .request_with_credentials(
                    principal,
                    &g,
                    get("https://elearning.fudan.edu.cn/api/v1/users/self/profile"),
                    CredentialKind::Cookie,
                )
                .await?;
            if profile.status != 200 {
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "campus identity could not be verified",
                ));
            }
            let identity: Value = serde_json::from_str(&profile.body)
                .map_err(|_| CoreError::new("AuthenticationRequired", "missing campus identity"))?;
            if !["login_id", "sis_user_id"].iter().any(|key| {
                identity[*key].as_str().is_some_and(|s| {
                    s == account
                        || ["@fudan.edu.cn", "@m.fudan.edu.cn"]
                            .iter()
                            .any(|suffix| s.strip_suffix(suffix) == Some(account))
                })
            }) {
                return Err(CoreError::new(
                    "AccountMismatch",
                    "selected campus account differs from verified login",
                ));
            }
            if params["service"] == "power_history" {
                g.capabilities.insert("http.write".into()); // fixed, read-only DataTables POST
                let history =
                    crate::energy_history::ElectricityHistoryClient::new(BoundTransport {
                        network: &trial,
                        platform: context.platform,
                        principal,
                        grant: &g,
                        account,
                        store: context.store,
                        source_capability: capability,
                        credential_lease: Default::default(),
                    });
                history
                    .electricity_history(
                        &SourceContext {
                            source_id: "official.fudan.portal.verify".into(),
                            account_id: account.into(),
                            observed_at: Utc::now(),
                        },
                        crate::campus::PageWindow { offset: 0, size: 1 },
                    )
                    .await
                    .map_err(campus_error)?;
            } else {
                let target = trial
                    .request_with_credentials(
                        principal,
                        &g,
                        get("https://my.fudan.edu.cn/simple_list/stqk"),
                        CredentialKind::Cookie,
                    )
                    .await?;
                if target.status != 200
                    || !matches!(
                        crate::campus::parse_dining_occupancy(target.body.as_bytes(), 0),
                        Ok(_) | Err(crate::campus::CampusError::OutsideReportingHours)
                    )
                {
                    return Err(CoreError::new(
                        "InteractiveLoginRequired",
                        "the campus portal still requires verification",
                    ));
                }
            }
            context
                .network
                .set_session(account, portal, None, target_cookies)?;
            context
                .store
                .kv_set("core:session-policy", account, &json!(true))?;
            return Ok(json!({"connected":true}));
        }
        #[cfg(feature = "login")]
        if method == "fudan.cloud.login" {
            // The drive has its own password, entered on this device by its
            // owner. One attempt per call: the drive locks after failures.
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "cloud drive login requires the profile owner",
                ));
            }
            let password = required_string(&params, "password")?;
            // With WebVPN on, the drive is signed into through it. The drive
            // password is not the UIS one, so a missing WebVPN session is
            // reported (WebVpnLoginRequired) for the host to sign in first.
            #[cfg(feature = "webvpn")]
            if gateway_only(&context, account, crate::fudan_cloud::ORIGIN) {
                let gateway = crate::webvpn::GATEWAY_ORIGIN;
                let cookies = context.network.session_cookies(account, gateway)?;
                let session = crate::fudan_cloud::login_via_gateway(account, password, &cookies)
                    .await
                    .map_err(|e| CoreError::new(e.code(), e.message()))?;
                context
                    .network
                    .set_session(account, gateway, None, session.cookies)?;
                return Ok(json!({"account_id":account,"session_imported":true}));
            }
            let direct_result = crate::fudan_cloud::login(account, password).await;
            #[cfg(feature = "webvpn")]
            let session = match direct_result {
                Ok(session) => session,
                Err(err)
                    if matches!(
                        err,
                        crate::login::LoginError::NetworkError | crate::login::LoginError::Timeout
                    ) && gateway_fallback_allowed(
                        &context,
                        account,
                        crate::fudan_cloud::ORIGIN,
                    ) =>
                {
                    let gateway = crate::webvpn::GATEWAY_ORIGIN;
                    let cookies = context.network.session_cookies(account, gateway)?;
                    let session =
                        crate::fudan_cloud::login_via_gateway(account, password, &cookies)
                            .await
                            .map_err(|e| CoreError::new(e.code(), e.message()))?;
                    context
                        .network
                        .set_session(account, gateway, None, session.cookies)?;
                    return Ok(json!({"account_id":account,"session_imported":true}));
                }
                Err(err) => return Err(CoreError::new(err.code(), err.message())),
            };
            #[cfg(not(feature = "webvpn"))]
            let session = direct_result.map_err(|e| CoreError::new(e.code(), e.message()))?;
            context.network.set_session(
                account,
                crate::fudan_cloud::ORIGIN,
                None,
                session.cookies,
            )?;
            return Ok(json!({"account_id":account,"session_imported":true}));
        }
        #[cfg(all(feature = "webvpn", feature = "login"))]
        if method == "fudan.webvpn.login" {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "webvpn login requires the profile owner",
                ));
            }
            let password = required_string(&params, "password")?;
            uis_sign_in(
                &context,
                account,
                password,
                crate::login::LoginTarget::WebVpn,
            )
            .await?;
            let routes_count = context
                .network
                .routes(account)?
                .iter()
                .filter(|r| r.provider == "fudan.webvpn")
                .count();
            return Ok(json!({
                "account_id": account,
                "session_imported": true,
                "routes_count": routes_count,
            }));
        }
        #[cfg(feature = "login")]
        if matches!(
            method,
            "fudan.ecard.login"
                | "fudan.ecard.session"
                | "fudan.academic.login"
                | "fudan.life.login"
        ) {
            // A local trusted host can establish a card session. This is never a
            // plugin action or a scheduled job, and no credentials leave the service.
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "card login requires the profile owner",
                ));
            }
            if method == "fudan.ecard.session" {
                return Ok(json!({
                    "has_session": context.network.has_session_for_origin(account, "https://ecard.fudan.edu.cn")
                }));
            }
            let password = required_string(&params, "password")?;
            let target = if method == "fudan.life.login" {
                match params["service"].as_str() {
                    Some("power") => crate::login::LoginTarget::Dorm,
                    Some("bus") => crate::login::LoginTarget::Bus,
                    Some("dining") => crate::login::LoginTarget::Dining,
                    #[cfg(feature = "webvpn")]
                    Some("webvpn") => crate::login::LoginTarget::WebVpn,
                    _ => return Err(CoreError::invalid("unknown campus service")),
                }
            } else if method == "fudan.academic.login" {
                match params["service"].as_str() {
                    None | Some("undergraduate") => crate::login::LoginTarget::Academic,
                    Some("postgraduate") => crate::login::LoginTarget::Postgraduate,
                    _ => return Err(CoreError::invalid("unknown academic service")),
                }
            } else {
                crate::login::LoginTarget::Ecard
            };
            uis_sign_in(&context, account, password, target).await?;
            return Ok(json!({"account_id":account,"session_imported":true}));
        }
        #[cfg(feature = "webvpn")]
        if method == "fudan.webvpn.status" {
            let has_session = context
                .network
                .has_session_for_origin(account, crate::webvpn::GATEWAY_ORIGIN);
            let routes = context.network.routes(account)?;
            let vpn_routes: Vec<_> = routes
                .iter()
                .filter(|r| {
                    r.provider == "fudan.webvpn" && crate::webvpn::is_fudan_origin(&r.origin)
                })
                .collect();
            let first_mode = vpn_routes
                .first()
                .map(|route| route.mode)
                .unwrap_or_default();
            let mode = if vpn_routes.iter().any(|route| route.mode != first_mode) {
                "mixed"
            } else {
                match first_mode {
                    dansheng_core::network_routes::RouteMode::Direct => "direct",
                    dansheng_core::network_routes::RouteMode::Gateway => "gateway",
                    dansheng_core::network_routes::RouteMode::Auto => "auto",
                }
            };
            let origins: Vec<String> = vpn_routes.iter().map(|r| r.origin.clone()).collect();
            return Ok(json!({
                "account_id": account,
                "has_session": has_session,
                "mode": mode,
                "enabled": vpn_routes.iter().any(|route| route.mode != dansheng_core::network_routes::RouteMode::Direct),
                "routes_count": vpn_routes.len(),
                "origins": origins,
            }));
        }
        #[cfg(feature = "webvpn")]
        if method == "fudan.webvpn.configure" {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "webvpn configuration requires the profile owner",
                ));
            }
            if account.len() > 256 || account.chars().any(char::is_control) {
                return Err(CoreError::invalid("invalid routing account"));
            }
            let mode_str = match params.get("mode") {
                None => "auto",
                Some(value) => value
                    .as_str()
                    .ok_or_else(|| CoreError::invalid("webvpn mode must be a string"))?,
            };
            let route_mode = match mode_str {
                "auto" => dansheng_core::network_routes::RouteMode::Auto,
                "gateway" | "always" => dansheng_core::network_routes::RouteMode::Gateway,
                "direct" | "off" | "disabled" => dansheng_core::network_routes::RouteMode::Direct,
                _ => {
                    return Err(CoreError::invalid(
                        "invalid webvpn mode (expected auto, gateway, or direct)",
                    ));
                }
            };
            let origins: Vec<String> = match params.get("origins") {
                Some(value) => serde_json::from_value(value.clone()).map_err(|_| {
                    CoreError::invalid("webvpn origins must be an array of strings")
                })?,
                None => crate::webvpn::DEFAULT_ORIGINS
                    .iter()
                    .map(|s| s.to_string())
                    .collect(),
            };
            if origins.is_empty() {
                return Err(CoreError::invalid("webvpn origins must not be empty"));
            }
            // Defaults: the switch sets every Fudan route; the forum keeps WebVPN
            // as a fallback only. An explicit origin list takes the mode as is.
            let vpn_routes = if params.get("origins").is_some() {
                crate::webvpn::gateway_routes(&origins, route_mode)?
            } else {
                let routes = origins
                    .iter()
                    .map(|origin| {
                        crate::webvpn::gateway_route(
                            origin,
                            crate::webvpn::default_mode(origin, route_mode),
                        )
                    })
                    .collect::<CoreResult<Vec<_>>>()?;
                dansheng_core::network_routes::validate_routes(&routes)?;
                routes
            };

            let saved = context.store.kv_get("core:network-routes", account)?;
            let mut existing_routes: Vec<dansheng_core::network_routes::GatewayRoute> =
                if saved.is_null() {
                    vec![]
                } else {
                    serde_json::from_value(saved)?
                };

            existing_routes.retain(|r| r.provider != "fudan.webvpn");
            // Direct mappings retain the explicit mode across login/restart.
            // routes_count counts configured mappings, including disabled ones.
            existing_routes.extend(vpn_routes);
            dansheng_core::network_routes::validate_routes(&existing_routes)?;
            context.store.kv_set(
                "core:network-routes",
                account,
                &serde_json::to_value(&existing_routes)?,
            )?;
            context
                .network
                .set_routes(account, existing_routes.clone())?;

            let has_session = context
                .network
                .has_session_for_origin(account, crate::webvpn::GATEWAY_ORIGIN);

            return Ok(json!({
                "account_id": account,
                "configured": true,
                "mode": route_mode,
                "has_session": has_session,
                "routes_count": existing_routes.iter().filter(|r| r.provider == "fudan.webvpn").count(),
                "origins": origins,
            }));
        }
        if matches!(
            method,
            "community.tea.login"
                | "community.tea.search"
                | "community.tea.publish"
                | "community.tea.reply"
                | "community.tea.reconcile"
                | "community.tea.pinned"
                | "community.tea.favorites"
                | "community.tea.favorite"
        ) {
            return crate::forum_actions::call(&context, principal, grant, method, &params).await;
        }
        #[cfg(feature = "login")]
        if method == "canvas.uis.login" {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "only the profile owner may sign in to Canvas",
                ));
            }
            let origin = "https://elearning.fudan.edu.cn";
            let password = required_string(&params, "password")?;
            // With WebVPN on, the sign-in and the check run through it and the
            // Canvas session lives in the gateway session.
            #[cfg(feature = "webvpn")]
            let via_gateway = gateway_only(&context, account, origin);
            #[cfg(not(feature = "webvpn"))]
            let via_gateway = false;
            let trial = Network::default();
            let session = if via_gateway {
                #[cfg(feature = "webvpn")]
                {
                    use crate::login::{LoginError, LoginTarget, login, login_via_gateway};
                    let fail = |e: LoginError| CoreError::new(e.code(), e.message());
                    let gateway = crate::webvpn::GATEWAY_ORIGIN;
                    let mut cookies = context.network.session_cookies(account, gateway)?;
                    let mut first =
                        login_via_gateway(account, password, LoginTarget::Canvas, &cookies).await;
                    if matches!(first, Err(LoginError::GatewaySessionRequired)) {
                        cookies = login(account, password, LoginTarget::WebVpn)
                            .await
                            .map_err(fail)?
                            .cookies;
                        context
                            .network
                            .set_session(account, gateway, None, cookies.clone())?;
                        first = login_via_gateway(account, password, LoginTarget::Canvas, &cookies)
                            .await;
                    }
                    let session = first.map_err(fail)?;
                    trial.set_routes(account, context.network.routes(account)?)?;
                    trial.set_session(account, gateway, None, session.cookies.clone())?;
                    session
                }
                #[cfg(not(feature = "webvpn"))]
                unreachable!()
            } else {
                let direct_result =
                    crate::login::login(account, password, crate::login::LoginTarget::Canvas).await;
                #[cfg(feature = "webvpn")]
                let session = match direct_result {
                    Ok(session) => session,
                    Err(err)
                        if matches!(
                            err,
                            crate::login::LoginError::NetworkError
                                | crate::login::LoginError::Timeout
                        ) && gateway_fallback_allowed(&context, account, origin) =>
                    {
                        use crate::login::{LoginError, LoginTarget, login, login_via_gateway};
                        let fail = |e: LoginError| CoreError::new(e.code(), e.message());
                        let gateway = crate::webvpn::GATEWAY_ORIGIN;
                        let mut cookies = context.network.session_cookies(account, gateway)?;
                        let mut first =
                            login_via_gateway(account, password, LoginTarget::Canvas, &cookies)
                                .await;
                        if matches!(first, Err(LoginError::GatewaySessionRequired)) {
                            cookies = login(account, password, LoginTarget::WebVpn)
                                .await
                                .map_err(fail)?
                                .cookies;
                            context
                                .network
                                .set_session(account, gateway, None, cookies.clone())?;
                            first =
                                login_via_gateway(account, password, LoginTarget::Canvas, &cookies)
                                    .await;
                        }
                        first.map_err(fail)?
                    }
                    Err(err) => return Err(CoreError::new(err.code(), err.message())),
                };
                #[cfg(not(feature = "webvpn"))]
                let session = direct_result.map_err(|e| CoreError::new(e.code(), e.message()))?;
                if session.origin != origin && session.origin != crate::webvpn::GATEWAY_ORIGIN {
                    return Err(CoreError::new(
                        "UnsafeRedirect",
                        "unexpected Canvas session origin",
                    ));
                }
                trial.set_routes(account, context.network.routes(account)?)?;
                trial.set_session(account, &session.origin, None, session.cookies.clone())?;
                session
            };
            let mut g = grant.clone();
            g.origins.insert(origin.to_owned());
            g.capabilities.insert("http.request".into());
            let profile = trial
                .request_with_credentials(
                    principal,
                    &g,
                    HttpRequest {
                        url: format!("{origin}/api/v1/users/self/profile"),
                        account_id: Some(account.into()),
                        timeout_ms: Some(12000),
                        ..Default::default()
                    },
                    CredentialKind::Cookie,
                )
                .await?;
            if profile.status != 200 {
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "Canvas session is not authorized",
                ));
            }
            let identity: Value = serde_json::from_str(&profile.body).map_err(|_| {
                CoreError::new("AuthenticationRequired", "Canvas profile unavailable")
            })?;
            verify_canvas_account(&identity, account)?;
            // `session.origin` is the gateway when the sign-in ran through it.
            context
                .network
                .set_session(account, &session.origin, None, session.cookies)?;
            #[cfg(feature = "webvpn")]
            if context
                .network
                .routes(account)
                .map(|r| r.is_empty())
                .unwrap_or(true)
            {
                initialize_webvpn_routes(&context, account)?;
            }
            context.store.kv_set(
                "service:canvas",
                account,
                &json!({"origin":origin,"access":"host_session","download_origins":[origin,FUDAN_CANVAS_STORAGE]}),
            )?;
            return Ok(json!({"connected":true}));
        }
        #[cfg(feature = "login")]
        if method == "canvas.token.bind" {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "only the profile owner may link Canvas",
                ));
            }
            let token = required_string(&params, "token")?;
            if token.len() > 8192 || token.chars().any(char::is_control) {
                return Err(CoreError::invalid("invalid Canvas credential"));
            }
            let origin = "https://elearning.fudan.edu.cn";
            let client = crate::login::verified_login_client()
                .map_err(|e| CoreError::new(e.code(), e.message()))?
                .timeout(std::time::Duration::from_secs(15))
                .build()
                .map_err(|_| CoreError::new("NetworkError", "cannot initialize Canvas login"))?;
            let mut request = client
                .get(format!("{origin}/api/v1/users/self/profile"))
                .bearer_auth(token);
            #[cfg(feature = "webvpn")]
            let via_gateway = gateway_only(&context, account, origin);
            #[cfg(not(feature = "webvpn"))]
            let via_gateway = false;
            #[cfg(feature = "webvpn")]
            if via_gateway {
                // Checked through WebVPN like every later Canvas read.
                let cookies = context
                    .network
                    .session_cookies(account, crate::webvpn::GATEWAY_ORIGIN)?;
                if cookies.is_empty() {
                    return Err(CoreError::new(
                        "WebVpnLoginRequired",
                        "sign in to WebVPN before linking Canvas through it",
                    ));
                }
                let header = cookies
                    .iter()
                    .filter_map(|c| c.split(';').next())
                    .collect::<Vec<_>>()
                    .join("; ");
                let url = crate::webvpn::encode_url(
                    &url::Url::parse(&format!("{origin}/api/v1/users/self/profile"))
                        .map_err(|_| CoreError::invalid("invalid Canvas address"))?,
                )?;
                request = client
                    .get(url)
                    .bearer_auth(token)
                    .header(reqwest::header::COOKIE, header);
            }
            let response = match request.send().await {
                Ok(r) => r,
                #[cfg(feature = "webvpn")]
                Err(err)
                    if (err.is_timeout() || err.is_connect())
                        && gateway_fallback_allowed(&context, account, origin) =>
                {
                    let cookies = context
                        .network
                        .session_cookies(account, crate::webvpn::GATEWAY_ORIGIN)?;
                    if cookies.is_empty() {
                        return Err(CoreError::new(
                            "WebVpnLoginRequired",
                            "sign in to WebVPN before linking Canvas through it",
                        ));
                    }
                    let header = cookies
                        .iter()
                        .filter_map(|c| c.split(';').next())
                        .collect::<Vec<_>>()
                        .join("; ");
                    let url = crate::webvpn::encode_url(
                        &url::Url::parse(&format!("{origin}/api/v1/users/self/profile"))
                            .map_err(|_| CoreError::invalid("invalid Canvas address"))?,
                    )?;
                    let vpn_resp = client
                        .get(url)
                        .bearer_auth(token)
                        .header(reqwest::header::COOKIE, header)
                        .send()
                        .await
                        .map_err(|_| {
                            CoreError::new("NetworkError", "Canvas profile unavailable")
                        })?;
                    if vpn_resp.status().is_redirection() {
                        return Err(CoreError::new(
                            "WebVpnLoginRequired",
                            "the WebVPN session has expired",
                        ));
                    }
                    vpn_resp
                }
                Err(_) => {
                    return Err(CoreError::new("NetworkError", "Canvas profile unavailable"));
                }
            };
            if via_gateway && response.status().is_redirection() {
                return Err(CoreError::new(
                    "WebVpnLoginRequired",
                    "the WebVPN session has expired",
                ));
            }
            if response.status().as_u16() != 200 {
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "Canvas did not accept the credential",
                ));
            }
            let mut response = response;
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| CoreError::new("NetworkError", "Canvas profile unavailable"))?
            {
                if bytes.len() + chunk.len() > 128 * 1024 {
                    return Err(CoreError::invalid("unexpected Canvas profile"));
                }
                bytes.extend_from_slice(&chunk);
            }
            let profile: Value = serde_json::from_slice(&bytes).map_err(|_| {
                CoreError::new("AuthenticationRequired", "Canvas profile unavailable")
            })?;
            verify_canvas_account(&profile, account)?;
            context
                .network
                .set_session(account, origin, Some(token.to_owned()), vec![])?;
            context.store.kv_set(
                "service:canvas",
                account,
                &json!({"origin":origin,"access":"host_token","download_origins":[origin,FUDAN_CANVAS_STORAGE]}),
            )?;
            if params["persist"] == true
                && context
                    .platform
                    .capabilities()
                    .contains(&"vault.set".to_string())
            {
                context
                    .store
                    .kv_set("core:session-policy", account, &json!(true))?;
            }
            return Ok(json!({"connected":true}));
        }
        if method == "fudan.qr.present" {
            let mut io_grant = grant.clone();
            io_grant.capabilities.insert("http.request".into());
            io_grant.origins.insert(crate::campus::QR_ORIGIN.into());
            let transport = BoundTransport {
                network: context.network,
                platform: context.platform,
                principal,
                grant: &io_grant,
                account,
                store: context.store,
                source_capability: capability,
                credential_lease: Default::default(),
            };
            // Return before source labels, snapshots, checkpoints or caches are touched.
            return present_qr(context, principal, grant, account, transport).await;
        }
        if method == "canvas.configure" {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "only the owner can bind a Canvas origin",
                ));
            }
            let origin = params["origin"]
                .as_str()
                .unwrap_or("https://elearning.fudan.edu.cn");
            let url =
                url::Url::parse(origin).map_err(|_| CoreError::invalid("invalid Canvas origin"))?;
            if url.scheme() != "https" || url.origin().ascii_serialization() != origin {
                return Err(CoreError::invalid(
                    "Canvas origin must be HTTPS without a path/query",
                ));
            }
            let access = params["access"].as_str().unwrap_or("host_session");
            let mode: CanvasAccess = serde_json::from_value(json!(access))?;
            if mode == CanvasAccess::BrowserSession {
                crate::page_transport::verify(
                    &BoundTransport {
                        account,
                        store: context.store,
                        source_capability: capability,
                        credential_lease: Default::default(),
                        network: context.network,
                        platform: context.platform,
                        principal,
                        grant,
                    },
                    &url,
                )
                .await
                .map_err(source_error)?;
            }
            let mut download_origins = std::collections::BTreeSet::from([origin.to_owned()]);
            if let Some(values) = params.get("download_origins") {
                let values = values.as_array().filter(|v| v.len() <= 16).ok_or_else(|| {
                    CoreError::invalid("download_origins must contain at most 16 HTTPS origins")
                })?;
                for value in values {
                    let value = value
                        .as_str()
                        .ok_or_else(|| CoreError::invalid("invalid download origin"))?;
                    let parsed = url::Url::parse(value)
                        .map_err(|_| CoreError::invalid("invalid download origin"))?;
                    if parsed.scheme() != "https" || parsed.origin().ascii_serialization() != value
                    {
                        return Err(CoreError::invalid(
                            "download origin must be a canonical HTTPS origin",
                        ));
                    }
                    download_origins.insert(value.to_owned());
                }
            }
            let config = json!({"origin":origin,"access":mode,"download_origins":download_origins});
            context.store.kv_set("service:canvas", account, &config)?;
            return Ok(config);
        }
        let mut io_grant = grant.clone();
        io_grant.capabilities.insert("http.request".into());
        // Typed capabilities delegate only fixed protocol operations. Canvas
        // sends require their own capability; reads never acquire http.write.
        if method.starts_with("fudan.") || capability == "canvas.write" {
            io_grant.capabilities.insert("http.write".into());
        }
        // Typed source capabilities delegate only their built-in/configured origin,
        // not arbitrary plugin HTTP access. Private network access is never implied.
        if method.starts_with("fudan.") {
            for origin in [
                crate::fudan::UNDERGRADUATE_ORIGIN,
                crate::fudan::POSTGRADUATE_PRIMARY,
                crate::fudan::POSTGRADUATE_SECONDARY,
            ] {
                io_grant.origins.insert(origin.into());
            }
            for origin in [
                "https://ecard.fudan.edu.cn",
                "https://my.fudan.edu.cn",
                "https://zlapp.fudan.edu.cn",
                "https://yzsfwapp.fudan.edu.cn",
                "https://mlibrary.fudan.edu.cn",
                "http://10.64.130.6",
                "https://fdtyjw.fudan.edu.cn",
                "https://jwc.fudan.edu.cn",
                "https://gs.fudan.edu.cn",
            ] {
                io_grant.origins.insert(origin.into());
            }
        }
        let source = SourceContext {
            account_id: account.into(),
            source_id: source_partition(method, &params)?,
            observed_at: Utc::now(),
        };
        let owner = if method.starts_with("fudan.") {
            "service:fudan"
        } else if method.starts_with("canvas.") {
            "service:canvas"
        } else {
            "service:community"
        };
        context.store.require_source_capabilities(
            owner,
            &source.source_id,
            &[capability.to_owned()].into_iter().collect(),
        )?;
        if method == "fudan.notice.attachment.download" {
            return download_notice_attachment(context, principal, grant, account, &params).await;
        }
        if method.starts_with("fudan.cloud.") {
            // Listings carry private file names; they are returned to the
            // caller only and never written to shared records or search.
            io_grant.origins.insert(crate::fudan_cloud::ORIGIN.into());
            let client = crate::fudan_cloud::FudanCloudClient::new(BoundTransport {
                account,
                store: context.store,
                source_capability: capability,
                credential_lease: Default::default(),
                network: context.network,
                platform: context.platform,
                principal,
                grant: &io_grant,
            });
            return match method {
                "fudan.cloud.roots" => Ok(serde_json::to_value(
                    client.roots(&source).await.map_err(source_error)?,
                )?),
                "fudan.cloud.list" => Ok(serde_json::to_value(
                    client
                        .list(&source, required_string(&params, "path")?)
                        .await
                        .map_err(source_error)?,
                )?),
                "fudan.cloud.download" => {
                    // A cheap private read first: an expired session must
                    // surface as sign-in, not as a saved login page.
                    let session = DriveDownloadSession::capture(context.network, account)?;
                    client.user_root(&source).await.map_err(source_error)?;
                    session.check()?;
                    download_cloud_file(context, principal, grant, account, &params, &session).await
                }
                "fudan.cloud.mkdir" => Ok(json!({"path": client
                    .create_folder(
                        &source,
                        required_string(&params, "path")?,
                        required_string(&params, "name")?,
                    )
                    .await
                    .map_err(source_error)?})),
                "fudan.cloud.rename" => {
                    client
                        .rename(
                            &source,
                            required_string(&params, "path")?,
                            required_string(&params, "name")?,
                        )
                        .await
                        .map_err(source_error)?;
                    Ok(json!({"renamed": true}))
                }
                "fudan.cloud.delete" => {
                    client
                        .delete(&source, required_string(&params, "path")?)
                        .await
                        .map_err(source_error)?;
                    Ok(json!({"deleted": true, "recycled": true}))
                }
                "fudan.cloud.upload" => {
                    let file = upload_source(
                        context,
                        principal,
                        grant,
                        account,
                        &params,
                        crate::fudan_cloud::MAX_UPLOAD,
                    )?;
                    let path = client
                        .upload(
                            &source,
                            required_string(&params, "path")?,
                            &file.name,
                            &file.bytes,
                            &file.mime,
                            Utc::now().timestamp_millis().max(0) as u64,
                        )
                        .await
                        .map_err(source_error)?;
                    Ok(json!({"path": path, "size": file.bytes.len()}))
                }
                "fudan.cloud.share" => Ok(serde_json::to_value(
                    client
                        .share(
                            &source,
                            required_string(&params, "path")?,
                            params
                                .get("days")
                                .and_then(Value::as_u64)
                                .unwrap_or(7)
                                .min(365) as u32,
                            params
                                .get("with_code")
                                .and_then(Value::as_bool)
                                .unwrap_or(true),
                        )
                        .await
                        .map_err(source_error)?,
                )?),
                "fudan.cloud.unshare" => {
                    client
                        .revoke_share(&source, required_string(&params, "batch_link")?)
                        .await
                        .map_err(source_error)?;
                    Ok(json!({"revoked": true}))
                }
                _ => Err(CoreError::new("MethodNotFound", "unknown cloud method")),
            };
        }
        if method.starts_with("community.") {
            io_grant.origins.extend([
                crate::community::TEA_ORIGIN.into(),
                crate::community::DANKE_ORIGIN.into(),
            ]);
            let client = crate::community::CommunityClient::new(BoundTransport {
                account,
                store: context.store,
                source_capability: capability,
                credential_lease: Default::default(),
                network: context.network,
                platform: context.platform,
                principal,
                grant: &io_grant,
            });
            let value = match method {
                "community.tea.divisions" => serde_json::to_value(
                    client.tea_divisions(&source).await.map_err(campus_error)?,
                )?,
                "community.tea.hole" => serde_json::to_value(
                    client
                        .tea_hole(&source, number(&params, "hole_id", None, u64::MAX)?)
                        .await
                        .map_err(campus_error)?,
                )?,
                "community.tea.holes" => {
                    let division_id = params
                        .get("division_id")
                        .or_else(|| params.get("division"))
                        .and_then(Value::as_u64);
                    let order_str = params.get("order").and_then(Value::as_str).unwrap_or("");
                    let order = match order_str {
                        "created" | "time_created" | "last_created" => {
                            crate::community::TeaOrder::LastCreated
                        }
                        _ => crate::community::TeaOrder::LastReplied,
                    };
                    let tag = params.get("tag").and_then(Value::as_str);
                    let page_size = params
                        .get("page_size")
                        .or_else(|| params.get("length"))
                        .or_else(|| params.get("size"))
                        .and_then(Value::as_u64)
                        .unwrap_or(u64::from(crate::community::TEA_HOLES_PAGE_SIZE))
                        .clamp(1, u64::from(crate::community::TEA_HOLES_PAGE_SIZE))
                        as u16;
                    serde_json::to_value(
                        client
                            .tea_holes_with_tag(
                                &source,
                                division_id,
                                params
                                    .get("before")
                                    .or_else(|| params.get("start_time"))
                                    .and_then(Value::as_str)
                                    .map(|s| {
                                        chrono::DateTime::parse_from_rfc3339(s)
                                            .map(|d| d.with_timezone(&Utc))
                                    })
                                    .transpose()
                                    .map_err(|_| CoreError::invalid("invalid before timestamp"))?
                                    .unwrap_or_else(Utc::now),
                                page_size,
                                order,
                                tag,
                            )
                            .await
                            .map_err(campus_error)?,
                    )?
                }
                "community.tea.floors" => serde_json::to_value(
                    client
                        .tea_floors(
                            &source,
                            number(&params, "hole_id", None, u64::MAX)?,
                            page_window(&params)?,
                        )
                        .await
                        .map_err(campus_error)?,
                )?,
                "community.danke.search" => serde_json::to_value(
                    client
                        .danke_search(
                            &source,
                            required_string(&params, "query")?,
                            number(&params, "page", Some(1), 10000)? as u32,
                            number(&params, "page_size", Some(20), 100)? as u16,
                        )
                        .await
                        .map_err(campus_error)?,
                )?,
                "community.danke.group" => serde_json::to_value(
                    client
                        .danke_group(&source, number(&params, "group_id", None, u64::MAX)?)
                        .await
                        .map_err(campus_error)?,
                )?,
                "community.danke.reviews" => serde_json::to_value(
                    client
                        .danke_reviews(&source, number(&params, "course_id", None, u64::MAX)?)
                        .await
                        .map_err(campus_error)?,
                )?,
                _ => return Err(CoreError::new("MethodNotFound", "unknown community method")),
            };
            publish_value(context.store, owner, &source, method, &value)?;
            return Ok(value);
        }
        if method.starts_with("fudan.")
            && !matches!(
                method,
                "fudan.semesters" | "fudan.timetable.sync" | "fudan.postgraduate.sync"
            )
        {
            let client = crate::campus::FudanCampusClient::new(BoundTransport {
                account,
                store: context.store,
                source_capability: capability,
                credential_lease: Default::default(),
                network: context.network,
                platform: context.platform,
                principal,
                grant: &io_grant,
            });
            let value = match method {
                "fudan.student_association" => serde_json::to_value(
                    client
                        .student_association(&source, required_string(&params, "semester_id")?)
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.exams" => serde_json::to_value(
                    client
                        .exams(
                            &source,
                            required_string(&params, "student_association")?,
                            params["include_finished"].as_bool().unwrap_or(false),
                        )
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.grades" => match params["level"].as_str().unwrap_or("undergraduate") {
                    "undergraduate" => serde_json::to_value(
                        client
                            .undergraduate_grades(
                                &source,
                                required_string(&params, "student_association")?,
                                required_string(&params, "semester_id")?,
                            )
                            .await
                            .map_err(campus_error)?,
                    )?,
                    "graduate" => serde_json::to_value(
                        client
                            .graduate_grades(&source)
                            .await
                            .map_err(campus_error)?,
                    )?,
                    "data_center" => serde_json::to_value(
                        client
                            .data_center_grades(&source, page_window(&params)?)
                            .await
                            .map_err(campus_error)?,
                    )?,
                    _ => return Err(CoreError::invalid("invalid grade level")),
                },
                "fudan.gpa" => serde_json::to_value(
                    client
                        .gpa(&source, required_string(&params, "student_association")?)
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.ecard.balance" => serde_json::to_value(
                    client.ecard_balance(&source).await.map_err(campus_error)?,
                )?,
                "fudan.ecard.statement" => serde_json::to_value(
                    client
                        .ecard_statement(&source, date(&params, "from")?, date(&params, "to")?)
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.ecard.statistics" => {
                    let period: crate::campus_statistics::Period =
                        serde_json::from_value(params["period"].clone())
                            .map_err(|_| CoreError::invalid("invalid statistics period"))?;
                    let anchor = date(&params, "date")?;
                    let (from, to) = period.bounds(anchor).map_err(campus_error)?;
                    let batch = client
                        .ecard_statement(&source, from, to)
                        .await
                        .map_err(campus_error)?;
                    let summary =
                        crate::campus_statistics::card_statistics(&batch.records, period, anchor)
                            .map_err(campus_error)?;
                    serde_json::to_value(source.record(
                        format!("ecard-statistics:{from}:{to}"),
                        None,
                        summary,
                    ))?
                }
                "fudan.ecard.transactions" => serde_json::to_value(
                    client
                        .ecard_transactions(
                            &source,
                            date(&params, "from")?,
                            date(&params, "to")?,
                            number(&params, "page", Some(1), 10000)? as u32,
                        )
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.electricity" => {
                    serde_json::to_value(client.electricity(&source).await.map_err(campus_error)?)?
                }
                "fudan.electricity.alert.check" => {
                    let before = crate::electricity_alert::get(context.store, account)?;
                    if !before.enabled {
                        return Ok(serde_json::to_value(before)?);
                    }
                    let sample = client
                        .electricity(&source)
                        .await
                        .map(|r| r.payload.remaining_kwh)
                        .map_err(campus_error);
                    return Ok(serde_json::to_value(crate::electricity_alert::observe(
                        context.store,
                        account,
                        before.revision,
                        sample,
                        chrono::Utc::now().timestamp_millis(),
                    )?)?);
                }
                "fudan.electricity.statistics" => {
                    let period: crate::campus_statistics::Period =
                        serde_json::from_value(params["period"].clone())
                            .map_err(|_| CoreError::invalid("invalid statistics period"))?;
                    let history =
                        crate::energy_history::ElectricityHistoryClient::new(BoundTransport {
                            account,
                            store: context.store,
                            source_capability: capability,
                            credential_lease: Default::default(),
                            network: context.network,
                            platform: context.platform,
                            principal,
                            grant: &io_grant,
                        });
                    let summary = history
                        .statistics(&source, period)
                        .await
                        .map_err(campus_error)?;
                    serde_json::to_value(source.record(
                        format!("electricity-statistics:{period:?}"),
                        None,
                        summary,
                    ))?
                }
                "fudan.electricity.history" => {
                    let history_client =
                        crate::energy_history::ElectricityHistoryClient::new(BoundTransport {
                            account,
                            store: context.store,
                            source_capability: capability,
                            credential_lease: Default::default(),
                            network: context.network,
                            platform: context.platform,
                            principal,
                            grant: &io_grant,
                        });
                    serde_json::to_value(
                        history_client
                            .electricity_history(&source, page_window(&params)?)
                            .await
                            .map_err(campus_error)?,
                    )?
                }
                "fudan.library.occupancy" => serde_json::to_value(
                    client
                        .library_occupancy(&source)
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.dining.occupancy" => serde_json::to_value(
                    client
                        .dining_occupancy(&source, number(&params, "area_code", Some(0), 15)? as u8)
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.rooms" => serde_json::to_value(
                    client
                        .empty_classrooms(
                            &source,
                            required_string(&params, "building")?,
                            date(&params, "date")?,
                        )
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.pe" => {
                    serde_json::to_value(client.pe_records(&source).await.map_err(campus_error)?)?
                }
                "fudan.bus" => serde_json::to_value(
                    client
                        .bus(&source, params["holiday"].as_bool().unwrap_or(false))
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.notices" => serde_json::to_value(
                    client
                        .aao_notices(
                            &source,
                            if params["level"] == "graduate" {
                                crate::campus::AaoKind::Postgraduate
                            } else {
                                crate::campus::AaoKind::Undergraduate
                            },
                            number(&params, "page", Some(1), 1000)? as u32,
                        )
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.notice.attachments" => serde_json::to_value(
                    client
                        .notice_attachments(&source, required_string(&params, "url")?)
                        .await
                        .map_err(campus_error)?,
                )?,
                "fudan.qr.status" => {
                    serde_json::to_value(client.qr_state(&source).await.map_err(campus_error)?)?
                }
                _ => return Err(CoreError::new("MethodNotFound", "unknown campus query")),
            };
            publish_value(context.store, owner, &source, method, &value)?;
            return Ok(value);
        }
        if method.starts_with("fudan.") {
            let transport = BoundTransport {
                account,
                store: context.store,
                source_capability: capability,
                credential_lease: Default::default(),
                network: context.network,
                platform: context.platform,
                principal,
                grant: &io_grant,
            };
            let client = FudanTimetableClient::new(transport);
            if method == "fudan.semesters" {
                return Ok(serde_json::to_value(
                    client
                        .undergraduate_semesters(&source)
                        .await
                        .map_err(source_error)?,
                )?);
            }
            let table = if method == "fudan.timetable.sync" {
                let semester: Option<Semester> = params
                    .get("semester")
                    .cloned()
                    .map(serde_json::from_value)
                    .transpose()?;
                client
                    .undergraduate(source, semester)
                    .await
                    .map_err(source_error)?
            } else {
                let semester: Semester = serde_json::from_value(params["semester"].clone())?;
                let endpoint = match params["endpoint"].as_str().unwrap_or("primary") {
                    "primary" => PostgraduateEndpoint::Primary,
                    "secondary" => PostgraduateEndpoint::Secondary,
                    _ => return Err(CoreError::invalid("invalid postgraduate endpoint")),
                };
                client
                    .postgraduate(source, semester, endpoint)
                    .await
                    .map_err(source_error)?
            };
            let rows = table
                .courses
                .iter()
                .map(|row| Ok((row.external_id.clone(), serde_json::to_value(&row.payload)?)))
                .collect::<CoreResult<Vec<_>>>()?;
            context.store.commit_source(
                "service:fudan",
                account,
                &table.source.source_id,
                "academic_course",
                &rows,
                &json!({"observed_at":table.source.observed_at}),
            )?;
            let dated = dated_occurrences(&table)?;
            context.store.require_source_capabilities(
                "service:fudan",
                &format!("{}.occurrences", table.source.source_id),
                &[capability.to_owned()].into_iter().collect(),
            )?;
            context.store.commit_source(
                "service:fudan",
                account,
                &format!("{}.occurrences", table.source.source_id),
                "timetable",
                &dated,
                &json!({"observed_at":table.source.observed_at}),
            )?;
            context.store.kv_set(
                "service:fudan:last_sync",
                account,
                &json!(table.source.observed_at),
            )?;
            return Ok(serde_json::to_value(table)?);
        }
        let config = context.store.kv_get("service:canvas", account)?;
        if config.is_null() {
            return Err(CoreError::new(
                "ConfigurationRequired",
                "bind this account's Canvas origin first",
            ));
        }
        let origin = required_string(&config, "origin")?;
        io_grant.origins.insert(origin.into());
        let access: CanvasAccess = serde_json::from_value(config["access"].clone())?;
        if capability == "canvas.write" && access == CanvasAccess::BrowserSession {
            return Err(CoreError::new(
                "CapabilityUnavailable",
                "Canvas page sessions cannot send without a trusted CSRF facility",
            ));
        }
        if capability == "canvas.write"
            && access == CanvasAccess::HostToken
            && !context
                .network
                .credential_available(account, origin, CredentialKind::Bearer)
        {
            return Err(CoreError::new(
                "AuthenticationRequired",
                "bind an active Canvas token before sending",
            ));
        }
        if method == "canvas.material.download" {
            return download_canvas_material(context, principal, grant, account, &config, &params)
                .await;
        }
        let client = CanvasClient::new(
            BoundTransport {
                account,
                store: context.store,
                source_capability: capability,
                credential_lease: Default::default(),
                network: context.network,
                platform: context.platform,
                principal,
                grant: &io_grant,
            },
            origin,
            access,
        )
        .map_err(source_error)?;
        // Sends return the confirmed response directly, without a fallible local
        // cache write that could mask success. Search terms/results are not cached.
        match method {
            "canvas.conversation.reply" => {
                let row = client
                    .reply_conversation(
                        &source,
                        required_string(&params, "conversation_id")?,
                        required_string(&params, "body")?,
                    )
                    .await
                    .map_err(canvas_write_error)?;
                return serde_json::to_value(row)
                    .map_err(|_| canvas_write_error(CanvasWriteError::NeedsReconciliation));
            }
            "canvas.conversation.create" => {
                let recipients: Vec<CanvasId> =
                    serde_json::from_value(params["recipients"].clone()).map_err(|_| {
                        CoreError::invalid("recipients must be an array of Canvas user IDs")
                    })?;
                let rows = client
                    .create_conversation(
                        &source,
                        required_string(&params, "course_id")?,
                        &recipients,
                        required_string(&params, "subject")?,
                        required_string(&params, "body")?,
                    )
                    .await
                    .map_err(canvas_write_error)?;
                return serde_json::to_value(rows)
                    .map_err(|_| canvas_write_error(CanvasWriteError::NeedsReconciliation));
            }
            "canvas.course_users.sync" => {
                let search = match params.get("search") {
                    None | Some(Value::Null) => None,
                    Some(Value::String(value)) => Some(value.as_str()),
                    _ => return Err(CoreError::invalid("search must be a string")),
                };
                return Ok(serde_json::to_value(
                    client
                        .course_users(&source, required_string(&params, "course_id")?, search)
                        .await
                        .map_err(source_error)?,
                )?);
            }
            "canvas.recipients.search" => {
                return Ok(serde_json::to_value(
                    client
                        .recipients(
                            &source,
                            required_string(&params, "course_id")?,
                            params
                                .get("search")
                                .and_then(Value::as_str)
                                .ok_or_else(|| CoreError::invalid("search must be a string"))?,
                        )
                        .await
                        .map_err(source_error)?,
                )?);
            }
            "canvas.conversation.read" => {
                return Ok(serde_json::to_value(
                    client
                        .conversation(&source, required_string(&params, "conversation_id")?)
                        .await
                        .map_err(source_error)?,
                )?);
            }
            _ => {}
        }
        if method == "canvas.page.read" {
            let row = client
                .page(
                    &source,
                    required_string(&params, "course_id")?,
                    required_string(&params, "page_slug")?,
                )
                .await
                .map_err(source_error)?;
            context.store.record_upsert(
                "service:canvas",
                account,
                &source.source_id,
                &row.external_id,
                "lms_page",
                &serde_json::to_value(&row.payload)?,
            )?;
            return Ok(serde_json::to_value(row)?);
        }
        let (kind, records) = match method {
            "canvas.conversations.sync" => (
                "lms_conversation",
                serde_json::to_value(
                    client
                        .conversations(
                            &source,
                            params
                                .get("course_id")
                                .map(|_| required_string(&params, "course_id"))
                                .transpose()?,
                        )
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.courses.sync" => (
                "lms_course",
                serde_json::to_value(client.courses(&source).await.map_err(source_error)?)?,
            ),
            "canvas.assignments.sync" => (
                "assignment",
                serde_json::to_value(
                    client
                        .assignments(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.materials.sync" => (
                "course_material",
                serde_json::to_value(
                    client
                        .materials(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.folders.sync" => (
                "lms_folder",
                serde_json::to_value(
                    client
                        .folders(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.modules.sync" => (
                "lms_module",
                serde_json::to_value(
                    client
                        .modules(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.module_items.sync" => (
                "lms_module_item",
                serde_json::to_value(
                    client
                        .module_items(
                            &source,
                            required_string(&params, "course_id")?,
                            required_string(&params, "module_id")?,
                        )
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.pages.sync" => (
                "lms_page_summary",
                serde_json::to_value(
                    client
                        .pages(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.announcements.sync" => (
                "lms_announcement",
                serde_json::to_value(
                    client
                        .announcements(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.quizzes.sync" => (
                "lms_quiz",
                serde_json::to_value(
                    client
                        .quizzes(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.quiz.read" => (
                "lms_quiz",
                serde_json::to_value(vec![
                    client
                        .quiz(
                            &source,
                            required_string(&params, "course_id")?,
                            required_string(&params, "quiz_id")?,
                        )
                        .await
                        .map_err(source_error)?,
                ])?,
            ),
            "canvas.discussions.sync" => (
                "lms_discussion_topic",
                serde_json::to_value(
                    client
                        .discussion_topics(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.discussion.read" => (
                "lms_discussion_topic",
                serde_json::to_value(vec![
                    client
                        .discussion_topic(
                            &source,
                            required_string(&params, "course_id")?,
                            required_string(&params, "topic_id")?,
                        )
                        .await
                        .map_err(source_error)?,
                ])?,
            ),
            "canvas.discussion.view" => (
                "lms_discussion_view",
                serde_json::to_value(vec![
                    client
                        .discussion_view(
                            &source,
                            required_string(&params, "course_id")?,
                            required_string(&params, "topic_id")?,
                        )
                        .await
                        .map_err(source_error)?,
                ])?,
            ),
            "canvas.assignment_groups.sync" => (
                "lms_assignment_group",
                serde_json::to_value(
                    client
                        .assignment_groups(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.submission.self" => (
                "lms_self_submission",
                serde_json::to_value(vec![
                    client
                        .self_submission(
                            &source,
                            required_string(&params, "course_id")?,
                            required_string(&params, "assignment_id")?,
                        )
                        .await
                        .map_err(source_error)?,
                ])?,
            ),
            "canvas.enrollments.self" => (
                "lms_self_enrollment",
                serde_json::to_value(
                    client
                        .self_enrollments(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            "canvas.grades.self" => (
                "lms_grade_summary",
                serde_json::to_value(
                    client
                        .self_grade_summary(&source, required_string(&params, "course_id")?)
                        .await
                        .map_err(source_error)?,
                )?,
            ),
            _ => return Err(CoreError::new("MethodNotFound", "unknown Canvas method")),
        };
        let rows = records
            .as_array()
            .ok_or_else(|| CoreError::new("SourceError", "invalid connector records"))?
            .iter()
            .map(|row| {
                Ok((
                    required_string(row, "external_id")?.to_owned(),
                    row["payload"].clone(),
                ))
            })
            .collect::<CoreResult<Vec<_>>>()?;
        context.store.commit_source(
            "service:canvas",
            account,
            &source.source_id,
            kind,
            &rows,
            &json!({"observed_at":source.observed_at}),
        )?;
        context.store.kv_set(
            "service:canvas:last_sync",
            account,
            &json!(source.observed_at),
        )?;
        Ok(records)
    }
}

#[cfg(feature = "login")]
fn verify_canvas_account(profile: &Value, account: &str) -> CoreResult<()> {
    if !profile["id"].as_u64().is_some_and(|id| id > 0) {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "Canvas profile identity missing",
        ));
    }
    if account.bytes().all(|b| b.is_ascii_digit())
        && !["login_id", "sis_user_id"].iter().any(|field| {
            profile[*field].as_str().is_some_and(|v| {
                v == account
                    || ["@fudan.edu.cn", "@m.fudan.edu.cn"]
                        .iter()
                        .any(|s| v.strip_suffix(s) == Some(account))
            })
        })
    {
        return Err(CoreError::new(
            "AccountMismatch",
            "Canvas profile does not match this campus account",
        ));
    }
    Ok(())
}

async fn present_qr(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    account: &str,
    transport: impl ConnectorTransport,
) -> CoreResult<Value> {
    if !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "only the owner can present a credential",
        ));
    }
    if !context
        .platform
        .capabilities()
        .iter()
        .any(|c| c == "credentials.present")
    {
        return Err(CoreError::new(
            "CapabilityUnavailable",
            "trusted credential presenter unavailable",
        ));
    }
    // One business-level GET; use the existing account routing policy, including
    // Network's pre-connection Auto fallback. No QR-specific retry loop.
    let source = SourceContext {
        account_id: account.into(),
        source_id: "official.fudan.qr.present".into(),
        observed_at: Utc::now(),
    };
    let credential = crate::campus::FudanCampusClient::new(transport)
        .qr_presentation(&source)
        .await
        .map_err(campus_error)?;
    // Only this private boundary serializes the secret. Never return the host's
    // arbitrary response/error: even its error code could contain the payload.
    let request = json!({"principal":principal,"grant":grant,"input":{
        "kind":"qr", "account_id":account, "origin":crate::campus::QR_ORIGIN,
        "payload":credential.into_payload(), "display_for_ms":30000
    }});
    let reply = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        context.platform.call("credentials.present", request),
    )
    .await
    .map_err(|_| CoreError::new("PresentationTimeout", "credential presenter timed out"))?
    .map_err(|_| CoreError::new("PresentationFailed", "credential presenter failed"))?;
    let presented = reply
        .get("presented")
        .and_then(Value::as_bool)
        .ok_or_else(|| {
            CoreError::new("PresentationFailed", "invalid credential presenter receipt")
        })?;
    Ok(json!({"presented":presented,"kind":"qr","display_for_ms":30000}))
}

pub(crate) fn campus_error(error: crate::campus::CampusError) -> CoreError {
    match error {
        crate::campus::CampusError::TermsNotAccepted => CoreError::new(
            "TermsNotAccepted",
            "QR terms require explicit action in the trusted host",
        ),
        crate::campus::CampusError::Transport(error) => source_error(error),
        crate::campus::CampusError::SchemaChanged { domain, field } => {
            CoreError::new("SourceSchemaChanged", format!("{domain}.{field}"))
        }
        other => CoreError::new("SourceError", other.to_string()),
    }
}

#[cfg(test)]
mod qr_presentation_tests {
    use super::*;
    use dansheng_core::{Engine, PrincipalKind, Request, Response};
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    const SECRET: &str = "SYNTHETIC-QR-NOT-A-REAL-CREDENTIAL";
    const METHOD: &str = "fudan.qr.present";

    struct OfflineFetch {
        body: Vec<u8>,
        fail: bool,
        calls: AtomicUsize,
    }
    #[async_trait]
    impl ConnectorTransport for OfflineFetch {
        async fn execute(
            &self,
            request: ConnectorRequest,
        ) -> Result<ConnectorResponse, ConnectorError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(request.method, crate::HttpMethod::Get);
            assert_eq!(
                request.url.as_str(),
                "https://ecard.fudan.edu.cn/epay/wxpage/fudan/zfm/qrcode"
            );
            assert!(request.body.is_none());
            assert_eq!(
                request.auth,
                TransportAuth::HostSession {
                    account_id: "fixture-account".into()
                }
            );
            if self.fail {
                return Err(ConnectorError::Timeout);
            }
            Ok(ConnectorResponse {
                status: 200,
                final_url: request.url,
                headers: vec![],
                body: self.body.clone(),
            })
        }
    }
    struct Presenter {
        advertised: bool,
        mode: u8,
        calls: AtomicUsize,
        dropped: AtomicUsize,
        entered: tokio::sync::Notify,
    }
    struct DropReceipt<'a>(&'a AtomicUsize);
    impl Drop for DropReceipt<'_> {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    #[async_trait]
    impl PlatformPort for Presenter {
        fn capabilities(&self) -> Vec<String> {
            if self.advertised {
                vec!["credentials.present".into()]
            } else {
                vec![]
            }
        }
        async fn call(&self, method: &str, value: Value) -> CoreResult<Value> {
            assert_eq!(method, "credentials.present");
            self.calls.fetch_add(1, Ordering::SeqCst);
            let _receipt = DropReceipt(&self.dropped);
            assert_eq!(value["principal"]["id"], "owner");
            assert_eq!(value["principal"]["kind"], "owner");
            assert!(value["grant"].is_object());
            let input = &value["input"];
            assert_eq!(input.as_object().unwrap().len(), 5);
            assert_eq!(input["kind"], "qr");
            assert_eq!(input["account_id"], "fixture-account");
            assert_eq!(input["origin"], crate::campus::QR_ORIGIN);
            assert_eq!(input["payload"], SECRET);
            assert_eq!(input["display_for_ms"], 30000);
            self.entered.notify_one();
            match self.mode {
                1 => Err(CoreError::new(SECRET, format!("provider echoed {SECRET}"))),
                2 => Ok(json!({"presented":false,"payload":SECRET})),
                3 => Ok(json!({"presented":SECRET,"message":SECRET})),
                4 => std::future::pending().await,
                _ => Ok(json!({"presented":true,"payload":SECRET,"message":SECRET})),
            }
        }
    }
    // Substitute only the network boundary. Exercise the production private
    // handoff + actual official GET/parser through Engine (including its audit).
    struct OfflineService(Arc<OfflineFetch>);
    #[async_trait]
    impl CoreService for OfflineService {
        fn methods(&self) -> Vec<(&'static str, &'static str)> {
            CampusService.methods()
        }
        async fn call(
            &self,
            context: ServiceContext<'_>,
            principal: &Principal,
            grant: &Grant,
            method: &str,
            params: Value,
        ) -> CoreResult<Value> {
            assert_eq!(method, METHOD);
            present_qr(
                context,
                principal,
                grant,
                required_string(&params, "account_id")?,
                self.0.clone(),
            )
            .await
        }
    }
    struct Harness {
        directory: tempfile::TempDir,
        engine: Arc<Engine>,
        fetch: Arc<OfflineFetch>,
        presenter: Arc<Presenter>,
    }
    impl Harness {
        fn new(body: Vec<u8>, advertised: bool, mode: u8, fail: bool) -> Self {
            let directory = tempfile::tempdir().unwrap();
            let presenter = Arc::new(Presenter {
                advertised,
                mode,
                calls: AtomicUsize::new(0),
                dropped: AtomicUsize::new(0),
                entered: tokio::sync::Notify::new(),
            });
            let engine = Engine::open(directory.path(), presenter.clone()).unwrap();
            let fetch = Arc::new(OfflineFetch {
                body,
                fail,
                calls: AtomicUsize::new(0),
            });
            engine
                .register_service(Arc::new(OfflineService(fetch.clone())))
                .unwrap();
            Self {
                directory,
                engine,
                fetch,
                presenter,
            }
        }
        async fn run(&self) -> Response {
            invoke(
                &self.engine,
                Principal::owner(),
                METHOD,
                json!({"account_id":"fixture-account"}),
            )
            .await
        }
        fn counts(&self, fetch: usize, present: usize) {
            assert_eq!(self.fetch.calls.load(Ordering::SeqCst), fetch);
            assert_eq!(self.presenter.calls.load(Ordering::SeqCst), present);
        }
        fn assert_no_persistent_secret(self) {
            let rows = self
                .engine
                .store
                .records(&Principal::owner(), &Grant::default(), &json!({}), None)
                .unwrap();
            assert!(rows.is_empty());
            assert!(self.engine.store.jobs().unwrap().is_empty());
            let events = self.engine.store.events(0).unwrap();
            assert!(!serde_json::to_string(&events).unwrap().contains(SECRET));
            // Close SQLite and its Windows byte-range locks before inspecting
            // the synthetic profile on disk (including any retained journals).
            drop(self.engine);
            for file in std::fs::read_dir(self.directory.path()).unwrap() {
                let file = file.unwrap();
                if file.file_type().unwrap().is_file() {
                    let bytes = std::fs::read(file.path()).unwrap();
                    assert!(
                        !bytes
                            .windows(SECRET.len())
                            .any(|part| part == SECRET.as_bytes())
                    );
                }
            }
        }
    }
    fn ready() -> Vec<u8> {
        format!("<html><input id='myText' value='{SECRET}'></html>").into_bytes()
    }
    async fn invoke(
        engine: &Arc<Engine>,
        principal: Principal,
        method: &str,
        params: Value,
    ) -> Response {
        engine
            .handle(
                principal,
                Request {
                    id: "qr-fixture".into(),
                    method: method.into(),
                    params,
                },
            )
            .await
    }

    #[tokio::test]
    async fn qr_official_fetch_hands_off_once_and_engine_audit_storage_never_receive_payload() {
        let h = Harness::new(
            String::from_utf8(ready())
                .unwrap()
                .replace('-', "&#45;")
                .into_bytes(),
            true,
            0,
            false,
        );
        let response = h.run().await;
        assert!(response.error.is_none());
        assert_eq!(
            response.result.unwrap(),
            json!({"presented":true,"kind":"qr","display_for_ms":30000})
        );
        h.counts(1, 1);
        assert_eq!(
            h.engine
                .store
                .events(0)
                .unwrap()
                .iter()
                .filter(|e| e.kind == "audit")
                .count(),
            1
        );
        h.assert_no_persistent_secret();
    }

    #[tokio::test]
    async fn qr_preflight_rejects_even_granted_nonowners_and_missing_provider_before_fetch() {
        let h = Harness::new(ready(), false, 0, false);
        assert_eq!(h.run().await.error.unwrap().code, "CapabilityUnavailable");
        h.counts(0, 0);
        let h = Harness::new(ready(), true, 0, false);
        for (id, kind) in [
            ("client", PrincipalKind::Client),
            ("mcp", PrincipalKind::Mcp),
            ("plugin:x", PrincipalKind::Plugin),
            ("not-owner", PrincipalKind::Owner),
            ("owner", PrincipalKind::Client),
        ] {
            let mut grant = Grant::default();
            grant.capabilities.insert("fudan.identity.present".into());
            grant.account_ids.insert("fixture-account".into());
            h.engine.store.set_grant(id, &grant).unwrap();
            let response = invoke(
                &h.engine,
                Principal {
                    id: id.into(),
                    kind,
                },
                METHOD,
                json!({"account_id":"fixture-account"}),
            )
            .await;
            assert_eq!(response.error.unwrap().code, "PermissionDenied");
        }
        h.counts(0, 0);
        h.assert_no_persistent_secret();
    }

    #[tokio::test]
    async fn qr_terms_ambiguous_empty_invalid_and_oversized_pages_fail_closed_without_retry() {
        let cases = vec![
            b"<button id='btn-agree-ok'>terms</button>".to_vec(),
            [
                ready(),
                b"<button id='btn-agree-ok'>terms</button>".to_vec(),
            ]
            .concat(),
            [ready(), ready()].concat(),
            b"<input id='myText' value='   '>".to_vec(),
            b"<input id='myText'>".to_vec(),
            b"<input id='myText' value='line&#10;break'>".to_vec(),
            format!("<input id='myText' value='{}'>", "x".repeat(4097)).into_bytes(),
            vec![b' '; 256 * 1024 + 1],
            vec![0xff],
            b"{\"unexpected\":\"json\"}".to_vec(),
        ];
        for (i, body) in cases.into_iter().enumerate() {
            let h = Harness::new(body, true, 0, false);
            let response = h.run().await;
            let error = response.error.unwrap();
            if i < 2 {
                assert_eq!(error.code, "TermsNotAccepted");
            }
            assert!(!serde_json::to_string(&error).unwrap().contains(SECRET));
            h.counts(1, 0);
            h.assert_no_persistent_secret();
        }
    }

    #[tokio::test]
    async fn qr_provider_receipts_and_errors_are_whitelisted_and_never_retried() {
        for mode in [1, 2, 3] {
            let h = Harness::new(ready(), true, mode, false);
            let response = h.run().await;
            assert!(!serde_json::to_string(&response).unwrap().contains(SECRET));
            if mode == 2 {
                assert_eq!(response.result.unwrap()["presented"], false);
            } else {
                assert_eq!(response.error.unwrap().code, "PresentationFailed");
            }
            h.counts(1, 1);
            h.assert_no_persistent_secret();
        }
        let h = Harness::new(ready(), true, 0, true);
        assert_eq!(h.run().await.error.unwrap().code, "Timeout");
        h.counts(1, 0);
        h.assert_no_persistent_secret();
    }

    #[tokio::test]
    async fn qr_cancelling_handoff_drops_provider_future_without_jobs_or_retry() {
        let h = Harness::new(ready(), true, 4, false);
        let engine = h.engine.clone();
        let task = tokio::spawn(async move {
            invoke(
                &engine,
                Principal::owner(),
                METHOD,
                json!({"account_id":"fixture-account"}),
            )
            .await
        });
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            h.presenter.entered.notified(),
        )
        .await
        .unwrap();
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert_eq!(h.presenter.dropped.load(Ordering::SeqCst), 1);
        h.counts(1, 1);
        h.assert_no_persistent_secret();
    }

    #[tokio::test]
    async fn qr_auto_route_preserves_the_single_client_fetch_and_handoff() {
        let h = Harness::new(ready(), true, 0, false);
        let routed = invoke(&h.engine, Principal::owner(), "http.routes.set", json!({"account_id":"fixture-account", "routes":[{
            "provider":"fixture","origin":crate::campus::QR_ORIGIN,"gateway_prefix":"https://gateway.invalid/https/fixture","mode":"auto"
        }]})).await;
        assert!(routed.error.is_none());
        assert_eq!(h.run().await.result.unwrap()["presented"], true);
        h.counts(1, 1);
        h.assert_no_persistent_secret();
    }
}
fn source_partition(method: &str, params: &Value) -> CoreResult<String> {
    let mut source = format!("official.{}", method.trim_end_matches(".sync"));
    if matches!(
        method,
        "canvas.conversation.read" | "canvas.conversation.reply"
    ) {
        let id = required_string(params, "conversation_id")?;
        if id.is_empty() || id.len() > 32 || !id.bytes().all(|b| b.is_ascii_digit()) {
            return Err(CoreError::invalid("invalid Canvas conversation id"));
        }
        return Ok(format!("{source}:{id}"));
    }
    if method == "canvas.conversations.sync"
        && !params
            .as_object()
            .is_some_and(|p| p.contains_key("course_id"))
    {
        return Ok(format!("{source}:all"));
    }
    if method.starts_with("canvas.")
        && method != "canvas.courses.sync"
        && method != "canvas.material.download"
    {
        let course = required_string(params, "course_id")?;
        if course.is_empty() || course.len() > 32 || !course.bytes().all(|b| b.is_ascii_digit()) {
            return Err(CoreError::invalid("invalid Canvas course id"));
        }
        source.push(':');
        source.push_str(course);
        if method == "canvas.module_items.sync" {
            let module = required_string(params, "module_id")?;
            if module.is_empty() || module.len() > 32 || !module.bytes().all(|b| b.is_ascii_digit())
            {
                return Err(CoreError::invalid("invalid Canvas module id"));
            }
            source.push(':');
            source.push_str(module);
        }
        let detail_key = match method {
            "canvas.quiz.read" => Some("quiz_id"),
            "canvas.discussion.read" | "canvas.discussion.view" => Some("topic_id"),
            "canvas.submission.self" => Some("assignment_id"),
            _ => None,
        };
        if let Some(key) = detail_key {
            let detail = required_string(params, key)?;
            if detail.is_empty() || detail.len() > 32 || !detail.bytes().all(|b| b.is_ascii_digit())
            {
                return Err(CoreError::invalid("invalid Canvas resource id"));
            }
            source.push(':');
            source.push_str(detail);
        }
    }
    Ok(source)
}
fn number(params: &Value, key: &str, default: Option<u64>, max: u64) -> CoreResult<u64> {
    let value = if params.get(key).is_some() {
        params[key].as_u64()
    } else {
        default
    };
    value
        .filter(|v| *v <= max)
        .ok_or_else(|| CoreError::invalid(format!("invalid {key}")))
}
fn page_window(params: &Value) -> CoreResult<crate::campus::PageWindow> {
    let size = if params.get("size").is_some() {
        number(params, "size", Some(20), 100)?
    } else {
        number(params, "page_size", Some(20), 100)?
    } as u16;
    Ok(crate::campus::PageWindow {
        offset: number(params, "offset", Some(0), 1000000)? as u32,
        size,
    })
}
fn date(params: &Value, key: &str) -> CoreResult<chrono::NaiveDate> {
    chrono::NaiveDate::parse_from_str(required_string(params, key)?, "%Y-%m-%d")
        .map_err(|_| CoreError::invalid(format!("invalid {key} date")))
}
pub(crate) fn publish_value(
    store: &dansheng_core::store::Store,
    owner: &str,
    source: &SourceContext,
    kind: &str,
    value: &Value,
) -> CoreResult<()> {
    let batch = value.get("batch").unwrap_or(value);
    let records = batch["records"]
        .as_array()
        .cloned()
        .unwrap_or_else(|| vec![batch.clone()]);
    let rows = records
        .into_iter()
        .map(|row| {
            Ok((
                required_string(&row, "external_id")?.to_owned(),
                row["payload"].clone(),
            ))
        })
        .collect::<CoreResult<Vec<_>>>()?;
    store.commit_source(
        owner,
        &source.account_id,
        &source.source_id,
        kind,
        &rows,
        &json!({
            "observed_at":source.observed_at,
            "coverage":batch.get("coverage").or_else(||batch.pointer("/payload/coverage"))
                .or_else(||batch.pointer("/payload/text_coverage")),
            "source_revision":batch["source_revision"],
            "complete":value["complete"],"stop":value["stop"],
            "protocol_live_validated":value["protocol_live_validated"],
            "identity_state":value["identity"]
        }),
    )
}

/// Slot starts and 45-minute duration follow DanXi 3c1f5f0 time_table.dart.
/// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
fn dated_occurrences(table: &crate::models::Timetable) -> CoreResult<Vec<(String, Value)>> {
    use chrono::TimeZone;
    const STARTS: [(u32, u32); 15] = [
        (8, 0),
        (8, 55),
        (9, 55),
        (10, 50),
        (11, 45),
        (13, 30),
        (14, 25),
        (15, 25),
        (16, 20),
        (17, 15),
        (18, 30),
        (19, 25),
        (20, 20),
        (21, 15),
        (22, 10),
    ];
    let zone = chrono::FixedOffset::east_opt(8 * 3600).expect("fixed school offset");
    let mut rows = Vec::new();
    for record in &table.courses {
        let c = &record.payload;
        let start = STARTS
            .get(c.start_unit.saturating_sub(1) as usize)
            .ok_or_else(|| CoreError::new("SourceError", "unknown start teaching unit"))?;
        let end = STARTS
            .get(c.end_unit.saturating_sub(1) as usize)
            .ok_or_else(|| CoreError::new("SourceError", "unknown end teaching unit"))?;
        for week in &c.weeks {
            if rows.len() >= 10000 {
                return Err(CoreError::new(
                    "SourceError",
                    "timetable occurrence limit exceeded",
                ));
            }
            let day = table
                .semester
                .starts_on
                .checked_add_signed(chrono::Duration::days(
                    (i64::from(*week) - 1) * 7 + i64::from(c.weekday) - 1,
                ))
                .ok_or_else(|| CoreError::new("SourceError", "timetable date overflow"))?;
            let start = zone
                .from_local_datetime(
                    &day.and_hms_opt(start.0, start.1, 0)
                        .expect("constant clock"),
                )
                .single()
                .expect("fixed offset")
                .with_timezone(&Utc);
            let end = zone
                .from_local_datetime(&day.and_hms_opt(end.0, end.1, 0).expect("constant clock"))
                .single()
                .expect("fixed offset")
                .with_timezone(&Utc)
                + chrono::Duration::minutes(45);
            rows.push((format!("{}:{}:{}",record.external_id,table.semester.external_id,week),json!({"title":c.name,"location":c.room,"teachers":c.teachers,"course_code":c.course_code,"start_at":start,"end_at":end,"timezone":"Asia/Shanghai","academic_source_id":record.source_id,"academic_external_id":record.external_id})));
        }
    }
    Ok(rows)
}
// Canvas's metadata -> same-origin download -> approved storage redirect follows
// Dela e82da12f src/main/canvas/api.ts. Signed URLs never leave this trusted bridge.
async fn download_canvas_material(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    account: &str,
    config: &Value,
    params: &Value,
) -> CoreResult<Value> {
    use dansheng_core::{PrincipalKind, assets};
    use sha2::{Digest, Sha256};
    grant.check(principal, "files.download")?;
    let origin = required_string(config, "origin")?;
    let base = url::Url::parse(origin).map_err(|_| CoreError::invalid("invalid Canvas origin"))?;
    if base.scheme() != "https" || base.origin().ascii_serialization() != origin {
        return Err(CoreError::invalid("invalid stored Canvas origin"));
    }
    if config["access"] == "browser_session" {
        return Err(CoreError::new(
            "CapabilityUnavailable",
            "browser-only Canvas downloads require a browser provider",
        ));
    }
    let file_id = required_string(params, "file_id")?;
    if file_id.len() > 32 || !file_id.bytes().all(|b| b.is_ascii_digit()) {
        return Err(CoreError::invalid("invalid Canvas file id"));
    }
    let mut delegated = grant.clone();
    delegated.account_ids.insert(account.into());
    delegated.origins = std::collections::BTreeSet::from([origin.into()]);
    for value in config["download_origins"].as_array().into_iter().flatten() {
        let value = value
            .as_str()
            .ok_or_else(|| CoreError::invalid("invalid stored download origin"))?;
        let url = url::Url::parse(value)
            .map_err(|_| CoreError::invalid("invalid stored download origin"))?;
        if url.scheme() != "https" || url.origin().ascii_serialization() != value {
            return Err(CoreError::invalid("invalid stored download origin"));
        }
        delegated.origins.insert(value.into());
    }
    delegated.capabilities.extend(
        [
            "canvas.read",
            "http.request",
            "files.download",
            "files.export",
            "files.delete",
        ]
        .map(str::to_owned),
    );
    let service = Principal {
        id: "service:canvas".into(),
        kind: PrincipalKind::Client,
    };
    let credential_kind = match config["access"].as_str() {
        Some("host_token") => CredentialKind::Bearer,
        _ => CredentialKind::Cookie,
    };
    let metadata_response = context
        .network
        .request_with_credentials(
            &service,
            &delegated,
            HttpRequest {
                url: base
                    .join(&format!("/api/v1/files/{file_id}"))
                    .map_err(|_| CoreError::invalid("invalid Canvas file path"))?
                    .to_string(),
                account_id: Some(account.into()),
                follow_redirects: false,
                ..Default::default()
            },
            credential_kind,
        )
        .await?;
    if metadata_response.status == 401 || (300..400).contains(&metadata_response.status) {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "Canvas file authentication is required",
        ));
    }
    if metadata_response.status != 200 {
        return Err(CoreError::new(
            "SourceError",
            format!(
                "Canvas file metadata returned HTTP {}",
                metadata_response.status
            ),
        ));
    }
    let mut metadata: Value = serde_json::from_str(&metadata_response.body)?;
    if let Some(value) = metadata["url"].as_str() {
        let candidate = base
            .join(value)
            .map_err(|_| CoreError::new("SourceError", "invalid Canvas download address"))?;
        metadata["url"] = json!(
            context
                .network
                .logical_resource_url(account, &candidate)?
                .to_string()
        );
    }
    let url = canvas_download_url(&base, file_id, &metadata)?;
    let expected = metadata["size"].as_u64();
    if expected.is_some_and(|n| n > assets::MAX_FILE_BYTES) {
        return Err(CoreError::new(
            "AssetTooLarge",
            "Canvas file exceeds the managed file limit",
        ));
    }
    let key = hex_string(&Sha256::digest(serde_json::to_vec(&json!([
        account,
        origin,
        file_id,
        metadata["updated_at"],
        metadata["size"]
    ]))?));
    let namespace = format!("service:canvas:files:{account}");
    context.store.require_source_capabilities(
        "service:canvas",
        "official.canvas.materials",
        &["canvas.read".to_owned()].into_iter().collect(),
    )?;
    let cached = context.store.kv_get(&namespace, &key)?;
    if let Some(id) = cached["asset_id"].as_str()
        && assets::export_descriptor(
            context.store,
            &service,
            &delegated,
            json!({"asset_id":id,"account_id":account}),
        )
        .is_ok()
    {
        return Ok(cached);
    }
    let name = metadata["display_name"]
        .as_str()
        .or(metadata["filename"].as_str())
        .unwrap_or("course-material")
        .chars()
        .filter(|c| !c.is_control())
        .take(64)
        .collect::<String>();
    let mime = metadata["content-type"]
        .as_str()
        .unwrap_or("application/octet-stream");
    let downloaded=assets::dispatch(context.store,context.network,&service,&delegated,"files.download",json!({"url":url.to_string(),"account_id":account,"source_id":"official.canvas.materials","name":if name.is_empty(){"course-material"}else{&name},"mime_type":mime,"max_bytes":assets::MAX_FILE_BYTES})).await?;
    if expected.is_some_and(|n| downloaded["size"].as_u64() != Some(n)) {
        let _ = assets::dispatch(
            context.store,
            context.network,
            &service,
            &delegated,
            "files.delete",
            json!({"asset_id":downloaded["asset_id"],"account_id":account}),
        )
        .await;
        return Err(CoreError::new(
            "IntegrityMismatch",
            "Canvas download size differs from its metadata",
        ));
    }
    context.store.kv_set(&namespace, &key, &downloaded)?;
    context.store.record_upsert("service:canvas",account,"official.canvas.materials",&format!("download:{file_id}"),"course_material",&json!({"file_id":file_id,"asset_id":downloaded["asset_id"],"name":downloaded["name"],"size":downloaded["size"],"mime_type":downloaded["mime_type"]}))?;
    Ok(downloaded)
}
/// WebDAV drives configured by the owner. Server addresses (not secrets) are
/// kept per account; credentials live only in the network session of each
/// server's origin and are provided by the trusted host on sign-in.
async fn webdav_call(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    capability: &str,
    method: &str,
    params: &Value,
    account: &str,
) -> CoreResult<Value> {
    use crate::webdav_drive::{WebDavClient, validate_base};
    use sha2::{Digest, Sha256};
    const NAMESPACE: &str = "service:webdav";
    let owner_only = || {
        if principal.is_owner() {
            Ok(())
        } else {
            Err(CoreError::new(
                "PermissionDenied",
                "WebDAV servers are managed by the profile owner",
            ))
        }
    };
    let mut servers: Vec<Value> = context
        .store
        .kv_get(NAMESPACE, account)?
        .as_array()
        .cloned()
        .unwrap_or_default();
    let origin_of = |server: &Value| -> CoreResult<url::Url> {
        validate_base(server["url"].as_str().unwrap_or("")).map_err(source_error)
    };
    match method {
        "webdav.servers" => {
            let mut out = Vec::new();
            for server in &servers {
                let base = origin_of(server)?;
                out.push(json!({
                    "id": server["id"],
                    "name": server["name"],
                    "url": base.as_str(),
                    "connected": context.network.credential_available(
                        account,
                        &base.origin().ascii_serialization(),
                        CredentialKind::Bearer,
                    ),
                }));
            }
            return Ok(Value::Array(out));
        }
        "webdav.server.add" => {
            owner_only()?;
            let base = validate_base(required_string(params, "url")?).map_err(source_error)?;
            let name = params
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| base.host_str().unwrap_or("WebDAV"))
                .chars()
                .filter(|c| !c.is_control())
                .take(60)
                .collect::<String>();
            let id = hex_string(&Sha256::digest(base.as_str().as_bytes()))[..12].to_owned();
            if servers.len() >= 20 && !servers.iter().any(|s| s["id"] == id) {
                return Err(CoreError::new("LimitExceeded", "too many WebDAV servers"));
            }
            servers.retain(|s| s["id"] != id);
            let server = json!({"id": id, "name": name, "url": base.as_str()});
            servers.push(server.clone());
            context
                .store
                .kv_set(NAMESPACE, account, &Value::Array(servers))?;
            return Ok(server);
        }
        "webdav.server.remove" => {
            owner_only()?;
            let id = required_string(params, "id")?;
            let removed: Vec<Value> = servers.iter().filter(|s| s["id"] == id).cloned().collect();
            servers.retain(|s| s["id"] != id);
            for server in removed {
                let origin = origin_of(&server)?.origin().ascii_serialization();
                if !servers
                    .iter()
                    .any(|s| origin_of(s).is_ok_and(|b| b.origin().ascii_serialization() == origin))
                {
                    // Replace the credentials with an empty session.
                    context
                        .network
                        .set_session(account, &origin, None, Vec::new())?;
                }
            }
            context
                .store
                .kv_set(NAMESPACE, account, &Value::Array(servers))?;
            return Ok(json!({"removed": true}));
        }
        _ => {}
    }
    let id = required_string(params, "id")?;
    let server = servers
        .iter()
        .find(|s| s["id"] == id)
        .cloned()
        .ok_or_else(|| CoreError::new("NotFound", "this WebDAV server is not configured"))?;
    let base = origin_of(&server)?;
    let origin = base.origin().ascii_serialization();
    let mut io_grant = grant.clone();
    io_grant.capabilities.insert("http.request".into());
    if method != "webdav.list" && method != "webdav.download" {
        io_grant.capabilities.insert("http.write".into());
    }
    io_grant.origins.insert(origin.clone());
    let source = SourceContext {
        account_id: account.into(),
        source_id: format!("official.webdav.{id}"),
        observed_at: Utc::now(),
    };
    let client = WebDavClient::new(
        BoundTransport {
            account,
            store: context.store,
            source_capability: capability,
            credential_lease: Default::default(),
            network: context.network,
            platform: context.platform,
            principal,
            grant: &io_grant,
        },
        base.clone(),
    );
    let path = || required_string(params, "path");
    let is_folder = params
        .get("is_folder")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    match method {
        "webdav.login" => {
            owner_only()?;
            context.network.set_session_basic(
                account,
                &origin,
                required_string(params, "username")?,
                required_string(params, "password")?,
            )?;
            if let Err(error) = client.verify(&source).await {
                context
                    .network
                    .set_session(account, &origin, None, Vec::new())?;
                return Err(match error {
                    ConnectorError::AuthRequired(_) => CoreError::new(
                        "InvalidCredentials",
                        "the WebDAV server rejected these credentials",
                    ),
                    other => source_error(other),
                });
            }
            Ok(json!({"connected": true}))
        }
        "webdav.list" => Ok(serde_json::to_value(
            client.list(&source, path()?).await.map_err(source_error)?,
        )?),
        "webdav.mkdir" => Ok(json!({"path": client
            .create_folder(&source, path()?, required_string(params, "name")?)
            .await
            .map_err(source_error)?})),
        "webdav.rename" => Ok(json!({"path": client
            .rename(&source, path()?, required_string(params, "name")?, is_folder)
            .await
            .map_err(source_error)?})),
        "webdav.delete" => {
            client
                .delete(&source, path()?, is_folder)
                .await
                .map_err(source_error)?;
            Ok(json!({"deleted": true}))
        }
        "webdav.upload" => {
            let file = upload_source(
                context,
                principal,
                grant,
                account,
                params,
                crate::webdav_drive::MAX_UPLOAD,
            )?;
            let saved = client
                .upload(&source, path()?, &file.name, &file.bytes, &file.mime)
                .await
                .map_err(source_error)?;
            Ok(json!({"path": saved, "size": file.bytes.len()}))
        }
        "webdav.download" => {
            grant.check(principal, "files.download")?;
            let session = DriveDownloadSession::capture(context.network, account)?;
            // Pin before verification: a replacement during the probe must not
            // bind a new identity to an older download/cache request.
            client.verify(&source).await.map_err(source_error)?;
            session.check()?;
            download_webdav_file(
                context, principal, grant, account, id, &base, params, &session,
            )
            .await
        }
        _ => Err(CoreError::new("MethodNotFound", "unknown WebDAV method")),
    }
}

/// A real authenticated session captured before the private verification read.
/// The opaque generation/route fingerprint never comes from request parameters.
struct DriveDownloadSession<'a> {
    network: &'a Network,
    account: &'a str,
    fingerprint: String,
}

impl<'a> DriveDownloadSession<'a> {
    fn capture(network: &'a Network, account: &'a str) -> CoreResult<Self> {
        Ok(Self {
            network,
            account,
            fingerprint: network.session_fingerprint(Some(account))?,
        })
    }

    fn check(&self) -> CoreResult<()> {
        if self.network.session_fingerprint(Some(self.account))? != self.fingerprint {
            return Err(CoreError::new(
                "AuthenticationRequired",
                "drive session changed during the download request",
            ));
        }
        Ok(())
    }

    async fn finish(
        &self,
        context: &ServiceContext<'_>,
        service: &Principal,
        grant: &Grant,
        result: CoreResult<Value>,
    ) -> CoreResult<Value> {
        if let Err(error) = self.check() {
            if let Ok(ref downloaded) = result {
                let _ = dansheng_core::assets::dispatch(
                    context.store,
                    context.network,
                    service,
                    grant,
                    "files.delete",
                    json!({"asset_id": downloaded["asset_id"], "account_id": self.account}),
                )
                .await;
            }
            return Err(error);
        }
        result
    }
}

#[allow(clippy::too_many_arguments)]
async fn download_webdav_file(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    account: &str,
    id: &str,
    base: &url::Url,
    params: &Value,
    session: &DriveDownloadSession<'_>,
) -> CoreResult<Value> {
    use dansheng_core::{PrincipalKind, assets};
    use sha2::{Digest, Sha256};
    session.check()?;
    let origin = base.origin().ascii_serialization();
    let file_path = required_string(params, "path")?;
    let url = crate::webdav_drive::resource_url(base, file_path, false).map_err(source_error)?;
    let name = file_path
        .rsplit('/')
        .next()
        .filter(|n| !n.is_empty())
        .unwrap_or("webdav-file")
        .chars()
        .filter(|c| !c.is_control())
        .take(96)
        .collect::<String>();
    let mut delegated = grant.clone();
    delegated.account_ids.insert(account.into());
    delegated.origins = std::collections::BTreeSet::from([origin.clone()]);
    delegated.capabilities.extend(
        [
            "webdav.read",
            "http.request",
            "files.download",
            "files.export",
            "files.delete",
        ]
        .map(str::to_owned),
    );
    let service = Principal {
        id: "service:webdav".into(),
        kind: PrincipalKind::Client,
    };
    let source_id = format!("official.webdav.{id}.files");
    context.store.require_source_capabilities(
        "service:webdav",
        &source_id,
        &["webdav.read".to_owned()].into_iter().collect(),
    )?;
    let size = params.get("size").and_then(Value::as_u64);
    let key = hex_string(&Sha256::digest(serde_json::to_vec(&json!([
        session.fingerprint,
        account,
        id,
        file_path,
        params.get("modified_at"),
        size
    ]))?));
    let namespace = format!("service:webdav:files:{account}");
    let cached = context.store.kv_get(&namespace, &key)?;
    if let Some(asset) = cached["asset_id"].as_str()
        && assets::export_descriptor(
            context.store,
            &service,
            &delegated,
            json!({"asset_id": asset, "account_id": account}),
        )
        .is_ok()
    {
        session.check()?;
        return Ok(cached);
    }
    let downloaded = context
        .network
        .with_owner_private_origin_read(
            principal,
            grant,
            &service,
            account,
            &origin,
            assets::dispatch(
                context.store,
                context.network,
                &service,
                &delegated,
                "files.download",
                json!({
                    "url": url.to_string(),
                    "account_id": account,
                    "source_id": source_id,
                    "name": name,
                    "max_bytes": assets::MAX_FILE_BYTES,
                }),
            ),
        )
        .await;
    let downloaded = session
        .finish(&context, &service, &delegated, downloaded)
        .await?;
    if size.is_some_and(|n| downloaded["size"].as_u64() != Some(n)) {
        let _ = assets::dispatch(
            context.store,
            context.network,
            &service,
            &delegated,
            "files.delete",
            json!({"asset_id": downloaded["asset_id"], "account_id": account}),
        )
        .await;
        return Err(CoreError::new(
            "IntegrityMismatch",
            "WebDAV download differs from its listing",
        ));
    }
    session.check()?;
    context.store.kv_set(&namespace, &key, &downloaded)?;
    session.check()?;
    Ok(downloaded)
}

/// Saves one public notice attachment as a managed asset, so it can be opened
/// or uploaded to a drive. Only files under the notice site's CMS file store.
async fn download_notice_attachment(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    account: &str,
    params: &Value,
) -> CoreResult<Value> {
    use dansheng_core::{PrincipalKind, assets};
    grant.check(principal, "files.download")?;
    let url = crate::campus::notice_attachment_url(required_string(params, "url")?)
        .map_err(campus_error)?;
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .chars()
        .filter(|c| !c.is_control() && !matches!(c, '/' | '\\'))
        .take(120)
        .collect::<String>();
    let name = if name.trim().is_empty() {
        "附件".to_owned()
    } else {
        name
    };
    let mut delegated = grant.clone();
    delegated.account_ids.insert(account.into());
    delegated.origins = std::collections::BTreeSet::from([url.origin().ascii_serialization()]);
    delegated.capabilities.extend(
        [
            "fudan.notices.read",
            "http.request",
            "files.download",
            "files.export",
            "files.delete",
        ]
        .map(str::to_owned),
    );
    let service = Principal {
        id: "service:fudan".into(),
        kind: PrincipalKind::Client,
    };
    context.store.require_source_capabilities(
        "service:fudan",
        "official.fudan.notice.attachments",
        &["fudan.notices.read".to_owned()].into_iter().collect(),
    )?;
    let downloaded = assets::dispatch(
        context.store,
        context.network,
        &service,
        &delegated,
        "files.download",
        json!({
            "url": url.to_string(),
            "account_id": account,
            "source_id": "official.fudan.notice.attachments",
            "name": name,
            "max_bytes": assets::MAX_FILE_BYTES,
        }),
    )
    .await?;
    if downloaded["mime_type"]
        .as_str()
        .is_some_and(|m| m.starts_with("text/html"))
    {
        // A login or error page instead of the file.
        let _ = assets::dispatch(
            context.store,
            context.network,
            &service,
            &delegated,
            "files.delete",
            json!({"asset_id": downloaded["asset_id"], "account_id": account}),
        )
        .await;
        return Err(CoreError::new(
            "AuthenticationRequired",
            "this attachment requires the campus sign-in page",
        ));
    }
    Ok(downloaded)
}

/// Bytes to upload to a drive.
struct UploadFile {
    name: String,
    mime: String,
    bytes: Vec<u8>,
}

/// The file an upload sends: a managed asset (`asset_id`, e.g. a downloaded
/// notice attachment or course file) or bytes the trusted host read from a
/// file the person picked (`data_base64`). `name` overrides the asset name.
fn upload_source(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    account: &str,
    params: &Value,
    max: usize,
) -> CoreResult<UploadFile> {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let override_name = params
        .get("name")
        .and_then(Value::as_str)
        .filter(|n| !n.trim().is_empty());
    let too_large = || CoreError::new("AssetTooLarge", "file exceeds the upload limit");
    if let Some(id) = params.get("asset_id").and_then(Value::as_str) {
        let descriptor = dansheng_core::assets::export_descriptor(
            context.store,
            principal,
            grant,
            json!({"asset_id": id, "account_id": account}),
        )?;
        if descriptor["size"].as_u64().is_none_or(|n| n as usize > max) {
            return Err(too_large());
        }
        let path = required_string(&descriptor, "path")?;
        let bytes = std::fs::read(path)?;
        if bytes.len() > max {
            return Err(too_large());
        }
        return Ok(UploadFile {
            name: override_name
                .or(descriptor["name"].as_str())
                .unwrap_or("file")
                .to_owned(),
            mime: descriptor["mime_type"]
                .as_str()
                .unwrap_or("application/octet-stream")
                .to_owned(),
            bytes,
        });
    }
    if !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "raw upload bytes are accepted only from the trusted host",
        ));
    }
    let data = required_string(params, "data_base64")?;
    if data.len() > max / 3 * 4 + 8 {
        return Err(too_large());
    }
    let bytes = STANDARD
        .decode(data)
        .map_err(|_| CoreError::invalid("data_base64 must be base64"))?;
    if bytes.len() > max {
        return Err(too_large());
    }
    Ok(UploadFile {
        name: override_name
            .ok_or_else(|| CoreError::invalid("name is required"))?
            .to_owned(),
        mime: params
            .get("content_type")
            .and_then(Value::as_str)
            .filter(|m| m.len() <= 100 && m.contains('/') && !m.chars().any(char::is_control))
            .unwrap_or("application/octet-stream")
            .to_owned(),
        bytes,
    })
}

/// Saves one cloud drive file as a managed asset. `path` comes from a listing;
/// `size` and `modified_at` from the same listing key the local cache, so a
/// changed file is fetched again.
async fn download_cloud_file(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    account: &str,
    params: &Value,
    session: &DriveDownloadSession<'_>,
) -> CoreResult<Value> {
    use dansheng_core::{PrincipalKind, assets};
    use sha2::{Digest, Sha256};
    grant.check(principal, "files.download")?;
    session.check()?;
    let path = required_string(params, "path")?;
    let url = crate::fudan_cloud::download_url(path).map_err(source_error)?;
    let size = params.get("size").and_then(Value::as_u64);
    if size.is_some_and(|n| n > assets::MAX_FILE_BYTES) {
        return Err(CoreError::new(
            "AssetTooLarge",
            "cloud file exceeds the managed file limit",
        ));
    }
    let name = path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .chars()
        .filter(|c| !c.is_control())
        .take(96)
        .collect::<String>();
    let name = if name.trim().is_empty() {
        "cloud-file".to_owned()
    } else {
        name
    };
    let mime = params
        .get("content_type")
        .and_then(Value::as_str)
        .filter(|m| {
            m.len() <= 100
                && m.split_once('/').is_some_and(|(a, b)| {
                    !a.is_empty()
                        && !b.is_empty()
                        && m.bytes()
                            .all(|c| c.is_ascii_alphanumeric() || b"/.+-_".contains(&c))
                })
        })
        .unwrap_or("application/octet-stream");
    let mut delegated = grant.clone();
    delegated.account_ids.insert(account.into());
    delegated.origins = std::collections::BTreeSet::from([crate::fudan_cloud::ORIGIN.into()]);
    delegated.capabilities.extend(
        [
            "fudan.cloud.read",
            "http.request",
            "files.download",
            "files.export",
            "files.delete",
        ]
        .map(str::to_owned),
    );
    let service = Principal {
        id: "service:fudan-cloud".into(),
        kind: PrincipalKind::Client,
    };
    let key = hex_string(&Sha256::digest(serde_json::to_vec(&json!([
        session.fingerprint,
        account,
        path,
        params.get("modified_at"),
        size
    ]))?));
    let namespace = format!("service:fudan-cloud:files:{account}");
    context.store.require_source_capabilities(
        "service:fudan-cloud",
        "official.fudan.cloud.files",
        &["fudan.cloud.read".to_owned()].into_iter().collect(),
    )?;
    let cached = context.store.kv_get(&namespace, &key)?;
    if let Some(id) = cached["asset_id"].as_str()
        && assets::export_descriptor(
            context.store,
            &service,
            &delegated,
            json!({"asset_id":id,"account_id":account}),
        )
        .is_ok()
    {
        session.check()?;
        return Ok(cached);
    }
    // The drive resolves to a campus address; keep the owner's named LAN
    // approval for this one GET, as WebDAV downloads do.
    let downloaded = context
        .network
        .with_owner_private_origin_read(
            principal,
            grant,
            &service,
            account,
            crate::fudan_cloud::ORIGIN,
            assets::dispatch(
                context.store,
                context.network,
                &service,
                &delegated,
                "files.download",
                json!({
                    "url": url.to_string(),
                    "account_id": account,
                    "source_id": "official.fudan.cloud.files",
                    "name": name,
                    "mime_type": mime,
                    "max_bytes": assets::MAX_FILE_BYTES,
                }),
            ),
        )
        .await;
    let downloaded = session
        .finish(&context, &service, &delegated, downloaded)
        .await?;
    if size.is_some_and(|n| downloaded["size"].as_u64() != Some(n)) {
        // A login or error page instead of the file has a different size.
        let _ = assets::dispatch(
            context.store,
            context.network,
            &service,
            &delegated,
            "files.delete",
            json!({"asset_id":downloaded["asset_id"],"account_id":account}),
        )
        .await;
        return Err(CoreError::new(
            "IntegrityMismatch",
            "cloud download differs from its listing",
        ));
    }
    session.check()?;
    context.store.kv_set(&namespace, &key, &downloaded)?;
    session.check()?;
    Ok(downloaded)
}
fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn canvas_download_url(origin: &url::Url, file_id: &str, metadata: &Value) -> CoreResult<url::Url> {
    let actual = metadata["id"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| metadata["id"].as_u64().map(|n| n.to_string()));
    if actual.as_deref() != Some(file_id) {
        return Err(CoreError::new("SourceError", "Canvas file id mismatch"));
    }
    let value = required_string(metadata, "url")?;
    if value.len() > 8192 {
        return Err(CoreError::new(
            "SourceError",
            "Canvas download address exceeds limit",
        ));
    }
    let url = origin
        .join(value)
        .map_err(|_| CoreError::new("SourceError", "invalid Canvas download address"))?;
    if url.scheme() != "https"
        || url.origin() != origin.origin()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(CoreError::new(
            "PermissionDenied",
            "Canvas must provide a same-origin download address; storage redirects require a configured origin",
        ));
    }
    Ok(url)
}

#[cfg(test)]
mod adapter_tests {
    #[cfg(feature = "login")]
    #[test]
    fn canvas_profile_is_bound_to_the_campus_identity_not_just_any_valid_token() {
        use super::verify_canvas_account;
        use serde_json::json;
        assert!(
            verify_canvas_account(&json!({"id":7,"login_id":"22001@m.fudan.edu.cn"}), "22001")
                .is_ok()
        );
        assert_eq!(
            verify_canvas_account(&json!({"id":7,"login_id":"22002"}), "22001")
                .unwrap_err()
                .code,
            "AccountMismatch"
        );
        assert!(verify_canvas_account(&json!({"id":7}), "22001").is_err());
        assert!(verify_canvas_account(&json!({}), "22001").is_err());
    }
    use super::*;
    #[tokio::test]
    async fn a_delegated_transport_rechecks_source_grants_between_requests() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = [0u8; 4096];
            let _ = socket.read(&mut bytes).await.unwrap();
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
                .await
                .unwrap();
        });
        let temp = tempfile::tempdir().unwrap();
        let store = dansheng_core::store::Store::open(temp.path()).unwrap();
        let principal = Principal {
            id: "reader".into(),
            kind: dansheng_core::PrincipalKind::Client,
        };
        let mut current = Grant {
            allow_private_network: true,
            ..Default::default()
        };
        current.account_ids.insert("a".into());
        current.capabilities.insert("fudan.notices.read".into());
        store.set_grant(&principal.id, &current).unwrap();
        let mut delegated = current.clone();
        delegated.capabilities.insert("http.request".into());
        delegated.origins.insert(origin.clone());
        let network = Network::default();
        let platform = dansheng_core::UnavailablePlatform;
        let transport = BoundTransport {
            network: &network,
            platform: &platform,
            principal: &principal,
            grant: &delegated,
            account: "a",
            store: &store,
            source_capability: "fudan.notices.read",
            credential_lease: Default::default(),
        };
        let request = ConnectorRequest {
            method: crate::HttpMethod::Get,
            url: url::Url::parse(&format!("{origin}/data")).unwrap(),
            headers: vec![],
            body: None,
            auth: TransportAuth::Anonymous,
        };
        assert_eq!(
            transport.execute(request.clone()).await.unwrap().status,
            200
        );
        current.capabilities.clear();
        store.set_grant(&principal.id, &current).unwrap();
        assert_eq!(
            transport.execute(request).await.err().unwrap(),
            ConnectorError::PermissionDenied
        );
        server.await.unwrap();
    }
    #[test]
    fn course_and_module_snapshots_have_distinct_source_partitions() {
        let a = source_partition("canvas.assignments.sync", &json!({"course_id":"11"})).unwrap();
        let b = source_partition("canvas.assignments.sync", &json!({"course_id":"12"})).unwrap();
        assert_ne!(a, b);
        let a = source_partition(
            "canvas.module_items.sync",
            &json!({"course_id":"11","module_id":"4"}),
        )
        .unwrap();
        let b = source_partition(
            "canvas.module_items.sync",
            &json!({"course_id":"11","module_id":"5"}),
        )
        .unwrap();
        assert_ne!(a, b);
        assert!(source_partition("canvas.pages.sync", &json!({"course_id":"../12"})).is_err());
    }
    #[test]
    fn file_tickets_are_bound_to_identity_and_origin_without_exporting_signed_urls() {
        let origin = url::Url::parse("https://canvas.example").unwrap();
        let good = json!({"id":42,"url":"/files/42/download?verifier=synthetic"});
        assert_eq!(
            canvas_download_url(&origin, "42", &good)
                .unwrap()
                .host_str(),
            Some("canvas.example")
        );
        for bad in [
            json!({"id":43,"url":"/files/42"}),
            json!({"id":42,"url":"https://outside.invalid/secret"}),
            json!({"id":42,"url":"http://canvas.example/secret"}),
            json!({"id":42,"url":"https://user:synthetic@canvas.example/secret"}),
        ] {
            assert!(canvas_download_url(&origin, "42", &bad).is_err());
        }
    }
    #[cfg(feature = "webvpn")]
    #[tokio::test]
    async fn webvpn_configure_and_status_manages_account_routes() {
        let temp = tempfile::tempdir().unwrap();
        let store = dansheng_core::store::Store::open(temp.path()).unwrap();
        let network = Network::default();
        let platform = dansheng_core::UnavailablePlatform;
        let ctx = || ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = Grant {
            capabilities: ["fudan.academic.read".into()].into(),
            account_ids: ["test-user".into()].into(),
            allow_private_network: true,
            ..Default::default()
        };

        let status = CampusService
            .call(
                ctx(),
                &owner,
                &grant,
                "fudan.webvpn.status",
                json!({"account_id": "test-user"}),
            )
            .await
            .unwrap();
        assert_eq!(status["has_session"], false);
        assert_eq!(status["mode"], "direct");
        assert_eq!(status["enabled"], false);
        assert_eq!(status["routes_count"], 0);

        let configured = CampusService
            .call(
                ctx(),
                &owner,
                &grant,
                "fudan.webvpn.configure",
                json!({"account_id": "test-user", "mode": "auto"}),
            )
            .await
            .unwrap();
        assert_eq!(configured["configured"], true);
        assert_eq!(configured["mode"], "auto");
        assert_eq!(configured["origins"], json!(crate::webvpn::DEFAULT_ORIGINS));
        assert_eq!(
            configured["routes_count"],
            crate::webvpn::DEFAULT_ORIGINS.len()
        );

        let status = CampusService
            .call(
                ctx(),
                &owner,
                &grant,
                "fudan.webvpn.status",
                json!({"account_id": "test-user"}),
            )
            .await
            .unwrap();
        assert_eq!(status["mode"], "auto");
        assert_eq!(status["enabled"], true);
        assert!(status["routes_count"].as_u64().unwrap() > 0);

        let client = Principal {
            id: "client-app".into(),
            kind: dansheng_core::PrincipalKind::Client,
        };
        let client_status = CampusService
            .call(
                ctx(),
                &client,
                &grant,
                "fudan.webvpn.status",
                json!({"account_id": "test-user"}),
            )
            .await
            .unwrap();
        assert_eq!(client_status, status);
        let denied_account = CampusService
            .call(
                ctx(),
                &client,
                &grant,
                "fudan.webvpn.status",
                json!({"account_id": "another-user"}),
            )
            .await
            .unwrap_err();
        assert_eq!(denied_account.code, "PermissionDenied");
        let denied = CampusService
            .call(
                ctx(),
                &client,
                &grant,
                "fudan.webvpn.configure",
                json!({"account_id": "test-user", "mode": "direct"}),
            )
            .await;
        assert_eq!(denied.unwrap_err().code, "PermissionDenied");

        let disabled = CampusService
            .call(
                ctx(),
                &owner,
                &grant,
                "fudan.webvpn.configure",
                json!({"account_id": "test-user", "mode": "direct"}),
            )
            .await
            .unwrap();
        assert_eq!(disabled["mode"], "direct");
        assert_eq!(
            disabled["routes_count"],
            crate::webvpn::DEFAULT_ORIGINS.len()
        );
        // Simulate a fresh in-memory route cache before the post-login step.
        network.set_routes("test-user", vec![]).unwrap();
        initialize_webvpn_routes(&ctx(), "test-user").unwrap();
        let status = CampusService
            .call(
                ctx(),
                &owner,
                &grant,
                "fudan.webvpn.status",
                json!({"account_id": "test-user"}),
            )
            .await
            .unwrap();
        assert_eq!(status["mode"], "direct");
        assert_eq!(status["enabled"], false);
        // Status describes the Fudan switch; the forum routes are not part of it.
        assert_eq!(status["origins"], json!(crate::webvpn::FUDAN_ORIGINS));
        assert!(
            network
                .routes("test-user")
                .unwrap()
                .iter()
                .all(|route| route.mode == dansheng_core::network_routes::RouteMode::Direct)
        );
        assert!(network.routes("another-user").unwrap().is_empty());
    }

    #[cfg(feature = "webvpn")]
    #[tokio::test]
    async fn webvpn_configuration_validates_before_mutating_and_preserves_other_routes() {
        use dansheng_core::network_routes::{GatewayRoute, RouteMode};
        let temp = tempfile::tempdir().unwrap();
        let store = dansheng_core::store::Store::open(temp.path()).unwrap();
        let network = Network::default();
        let platform = dansheng_core::UnavailablePlatform;
        let ctx = || ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = Grant::default();
        let other = GatewayRoute {
            provider: "other.gateway".into(),
            origin: "https://other.example".into(),
            gateway_prefix: "https://gateway.example/encoded".into(),
            mode: RouteMode::Gateway,
        };
        store
            .kv_set("core:network-routes", "test-user", &json!([other]))
            .unwrap();
        network
            .set_routes("test-user", vec![other.clone()])
            .unwrap();
        let configured = CampusService
            .call(ctx(), &owner, &grant, "fudan.webvpn.configure", json!({
                "account_id": "test-user", "mode": "always", "origins": ["https://ecard.fudan.edu.cn"]
            }))
            .await
            .unwrap();
        assert_eq!(configured["mode"], "gateway");
        assert_eq!(configured["routes_count"], 1);
        let saved = store.kv_get("core:network-routes", "test-user").unwrap();
        let routes = network.routes("test-user").unwrap();
        assert!(routes.contains(&other));
        for invalid in [
            json!({"mode": false}),
            json!({"mode": null}),
            json!({"mode": "unknown"}),
            json!({"origins": "https://ecard.fudan.edu.cn"}),
            json!({"origins": null}),
            json!({"origins": [42]}),
            json!({"origins": ["https://ecard.fudan.edu.cn", 42]}),
            json!({"origins": []}),
            json!({"origins": ["https://ecard.fudan.edu.cn", "https://ecard.fudan.edu.cn"]}),
            json!({"origins": ["https://evil.example"]}),
            json!({"mode": "direct", "origins": ["https://evil.example"]}),
        ] {
            let mut params = invalid;
            params["account_id"] = json!("test-user");
            assert!(
                CampusService
                    .call(ctx(), &owner, &grant, "fudan.webvpn.configure", params)
                    .await
                    .is_err()
            );
            assert_eq!(
                store.kv_get("core:network-routes", "test-user").unwrap(),
                saved
            );
            assert_eq!(network.routes("test-user").unwrap(), routes);
        }
        for alias in ["off", "disabled"] {
            let disabled = CampusService
                .call(
                    ctx(),
                    &owner,
                    &grant,
                    "fudan.webvpn.configure",
                    json!({"account_id": "test-user", "mode": alias}),
                )
                .await
                .unwrap();
            assert_eq!(disabled["mode"], "direct");
            assert!(network.routes("test-user").unwrap().contains(&other));
        }
        for account in ["a".repeat(257), "invalid\naccount".into()] {
            let error = CampusService
                .call(
                    ctx(),
                    &owner,
                    &grant,
                    "fudan.webvpn.configure",
                    json!({"account_id": account}),
                )
                .await
                .unwrap_err();
            assert_eq!(error.code, "InvalidInput");
            assert!(
                store
                    .kv_get("core:network-routes", &account)
                    .unwrap()
                    .is_null()
            );
            assert!(network.routes(&account).unwrap().is_empty());
        }
    }

    #[cfg(feature = "webvpn")]
    #[tokio::test]
    async fn webvpn_login_initializes_defaults_and_preserves_custom_routes_and_modes() {
        use dansheng_core::network_routes::RouteMode;
        let temp = tempfile::tempdir().unwrap();
        let store = dansheng_core::store::Store::open(temp.path()).unwrap();
        let network = Network::default();
        let platform = dansheng_core::UnavailablePlatform;
        let ctx = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        initialize_webvpn_routes(&ctx, "new-user").unwrap();
        let defaults = network.routes("new-user").unwrap();
        assert_eq!(defaults.len(), crate::webvpn::DEFAULT_ORIGINS.len());
        assert!(defaults.iter().all(|route| route.mode == RouteMode::Auto));
        assert!(
            crate::webvpn::DEFAULT_ORIGINS
                .iter()
                .all(|origin| defaults.iter().any(|route| route.origin == *origin))
        );

        let custom =
            crate::webvpn::gateway_route("https://library.fudan.edu.cn", RouteMode::Gateway)
                .unwrap();
        let direct =
            crate::webvpn::gateway_route("https://ecard.fudan.edu.cn", RouteMode::Direct).unwrap();
        let mut other =
            crate::webvpn::gateway_route("https://my.fudan.edu.cn", RouteMode::Direct).unwrap();
        other.provider = "other.gateway".into();
        store
            .kv_set(
                "core:network-routes",
                "existing-user",
                &json!([custom, direct, other]),
            )
            .unwrap();
        initialize_webvpn_routes(&ctx, "existing-user").unwrap();
        let routes = network.routes("existing-user").unwrap();
        // library, ecard and my are already present (my under another provider).
        assert_eq!(routes.len(), crate::webvpn::DEFAULT_ORIGINS.len());
        assert!(routes.contains(&custom));
        assert!(routes.contains(&direct));
        assert!(routes.contains(&other));
        assert!(
            routes
                .iter()
                .filter(|route| route.origin != direct.origin && route.origin != other.origin)
                .all(|route| route.mode
                    == if crate::webvpn::is_fudan_origin(&route.origin) {
                        RouteMode::Gateway
                    } else {
                        RouteMode::Auto
                    })
        );
        initialize_webvpn_routes(&ctx, "existing-user").unwrap();
        assert_eq!(network.routes("existing-user").unwrap(), routes);
        assert_eq!(
            store
                .kv_get("core:network-routes", "existing-user")
                .unwrap(),
            json!(routes)
        );
        assert_eq!(network.routes("new-user").unwrap(), defaults);
        let status = CampusService
            .call(
                ctx,
                &Principal::owner(),
                &Grant::default(),
                "fudan.webvpn.status",
                json!({"account_id": "existing-user"}),
            )
            .await
            .unwrap();
        assert_eq!(status["mode"], "mixed");
        assert_eq!(status["enabled"], true);
        assert_eq!(
            status["routes_count"],
            crate::webvpn::FUDAN_ORIGINS.len() - 1
        );
    }

    #[cfg(all(feature = "webvpn", feature = "login"))]
    #[tokio::test]
    async fn webvpn_login_requires_owner_and_password() {
        let dir = tempfile::tempdir().unwrap();
        let store = dansheng_core::store::Store::open(dir.path()).unwrap();
        let network = Network::default();
        let platform = dansheng_core::UnavailablePlatform;
        let ctx = || ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let client = Principal {
            id: "client-app".into(),
            kind: dansheng_core::PrincipalKind::Client,
        };
        let owner = Principal::owner();
        let grant = Grant::default();

        let denied = CampusService
            .call(
                ctx(),
                &client,
                &grant,
                "fudan.webvpn.login",
                json!({"account_id": "test-user", "password": "pwd"}),
            )
            .await
            .unwrap_err();
        assert_eq!(denied.code, "PermissionDenied");

        let missing_pwd = CampusService
            .call(
                ctx(),
                &owner,
                &grant,
                "fudan.webvpn.login",
                json!({"account_id": "test-user"}),
            )
            .await
            .unwrap_err();
        assert_eq!(missing_pwd.code, "InvalidInput");
    }
}
