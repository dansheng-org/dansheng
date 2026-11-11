// SPDX-License-Identifier: GPL-3.0-or-later
//! Trusted bridge: official clients use the same permissions, sessions and data store as UI/MCP.
use crate::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, TransportAuth,
    canvas::{CanvasAccess, CanvasClient},
    fudan::{FudanTimetableClient, PostgraduateEndpoint},
    models::{Semester, SourceContext},
};
use async_trait::async_trait;
use chrono::Utc;
use dansheng_core::{
    api::{CoreError, CoreResult, Principal, required_string},
    network::{CredentialKind, HttpRequest, Network},
    platform::PlatformPort,
    policy::Grant,
    services::{CoreService, ServiceContext},
};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[cfg(test)]
#[path = "bridge_bytes_tests.rs"]
mod bridge_bytes_tests;

pub struct CampusService;
// Canvas serves same-origin file metadata, then redirects the download to this
// school storage origin. Network selects credentials again per origin on redirect.
#[cfg(feature = "login")]
const FUDAN_CANVAS_STORAGE: &str = "https://elearning.obs.fudan.edu.cn";
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
}

#[async_trait]
impl ConnectorTransport for BoundTransport<'_> {
    async fn execute(&self, input: ConnectorRequest) -> Result<ConnectorResponse, ConnectorError> {
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
            && !self
                .network
                .routes(self.account)
                .map_err(transport_error)?
                .iter()
                .any(|r| {
                    r.origin == "http://10.64.130.6"
                        && r.mode != dansheng_core::network_routes::RouteMode::Direct
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
                .map_err(|error| {
                    if error.code == "AuthenticationRequired" {
                        ConnectorError::AuthRequired(challenge.clone())
                    } else {
                        transport_error(error)
                    }
                })?;
            self.current_authority()?;
            if leased {
                self.check_native_lease(&challenge)?;
            }
            return Ok(ConnectorResponse {
                status: response.status,
                final_url: url::Url::parse(&response.url).map_err(|_| ConnectorError::UnsafeUrl)?,
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
        let response = isolated
            .as_ref()
            .unwrap_or(self.network)
            .request_with_credentials(
                self.principal,
                &io_grant,
                HttpRequest {
                    url: input.url.to_string(),
                    method: input.method.as_str().into(),
                    headers: input.headers.into_iter().collect::<BTreeMap<_, _>>(),
                    body: input
                        .body
                        .map(|b| String::from_utf8(b).map(Value::String))
                        .transpose()
                        .map_err(|_| {
                            ConnectorError::InvalidConfiguration("request body encoding")
                        })?,
                    account_id: account,
                    timeout_ms: Some(15000),
                    follow_redirects: false,
                },
                credential_kind,
            )
            .await
            .map_err(|error| {
                if error.code == "AuthenticationRequired" {
                    ConnectorError::AuthRequired(challenge.clone())
                } else {
                    transport_error(error)
                }
            })?;
        self.current_authority()?;
        if leased {
            self.check_native_lease(&challenge)?;
        }
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
            final_url: url::Url::parse(&response.url).map_err(|_| ConnectorError::UnsafeUrl)?,
            headers: response.headers.into_iter().collect(),
            body: response.body.into_bytes(),
        })
    }
}
fn transport_error(error: CoreError) -> ConnectorError {
    match error.code.as_str() {
        "PermissionDenied" => ConnectorError::PermissionDenied,
        "Timeout" => ConnectorError::Timeout,
        "CapabilityUnavailable" => ConnectorError::CapabilityUnavailable,
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
        ConnectorError::AuthRequired(_) => CoreError::new(
            "AuthenticationRequired",
            "complete this source's authentication through the host",
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

#[async_trait]
impl CoreService for CampusService {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        let mut methods = vec![
            ("fudan.semesters", "fudan.academic.read"),
            ("fudan.timetable.sync", "fudan.academic.read"),
            ("fudan.postgraduate.sync", "fudan.academic.read"),
            ("fudan.student_association", "fudan.academic.read"),
            ("fudan.exams", "fudan.academic.read"),
            ("fudan.grades", "fudan.academic.read"),
            ("fudan.gpa", "fudan.academic.read"),
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
            ("fudan.ecard.transactions", "fudan.card.read"),
            ("fudan.electricity", "fudan.life.read"),
            ("fudan.electricity.history", "fudan.life.read"),
            ("fudan.library.occupancy", "fudan.life.read"),
            ("fudan.dining.occupancy", "fudan.life.read"),
            ("fudan.rooms", "fudan.rooms.read"),
            ("fudan.pe", "fudan.pe.read"),
            ("fudan.bus", "fudan.life.read"),
            ("fudan.notices", "fudan.notices.read"),
            ("fudan.qr.status", "fudan.identity.read"),
            ("fudan.qr.present", "fudan.identity.present"),
            ("canvas.configure", "canvas.configure"),
            #[cfg(feature = "login")]
            ("canvas.token.bind", "canvas.login"),
            ("canvas.uis.login", "canvas.login"),
            ("canvas.courses.sync", "canvas.read"),
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
                crate::login::LoginTarget::Academic
            } else {
                crate::login::LoginTarget::Ecard
            };
            let session = crate::login::login(account, password, target)
                .await
                .map_err(|e| CoreError::new(e.code(), e.message()))?;
            context
                .network
                .set_session(account, &session.origin, None, session.cookies)?;
            #[cfg(feature = "webvpn")]
            if target == crate::login::LoginTarget::WebVpn {
                let saved = context.store.kv_get("core:network-routes", account)?;
                let mut routes: Vec<dansheng_core::network_routes::GatewayRoute> =
                    if saved.is_null() {
                        vec![]
                    } else {
                        serde_json::from_value(saved)?
                    };
                let room = crate::webvpn::gateway_route(
                    "http://10.64.130.6",
                    dansheng_core::network_routes::RouteMode::Gateway,
                )?;
                routes.retain(|r| r.origin != room.origin);
                routes.push(room);
                dansheng_core::network_routes::validate_routes(&routes)?;
                context.store.kv_set(
                    "core:network-routes",
                    account,
                    &serde_json::to_value(&routes)?,
                )?;
                context.network.set_routes(account, routes)?;
            }
            return Ok(json!({"account_id":account,"session_imported":true}));
        }
        if matches!(
            method,
            "community.tea.login"
                | "community.tea.search"
                | "community.tea.publish"
                | "community.tea.reply"
                | "community.tea.reconcile"
                | "community.tea.pinned"
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
            let session = crate::login::login(
                account,
                required_string(&params, "password")?,
                crate::login::LoginTarget::Canvas,
            )
            .await
            .map_err(|e| CoreError::new(e.code(), e.message()))?;
            if session.origin != origin {
                return Err(CoreError::new(
                    "UnsafeRedirect",
                    "unexpected Canvas session origin",
                ));
            }
            let trial = Network::default();
            trial.set_session(account, origin, None, session.cookies.clone())?;
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
            context
                .network
                .set_session(account, origin, None, session.cookies)?;
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
            let response = client
                .get(format!("{origin}/api/v1/users/self/profile"))
                .bearer_auth(token)
                .send()
                .await
                .map_err(|_| CoreError::new("NetworkError", "Canvas profile unavailable"))?;
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
        // Only statically defined, read-only campus clients use this bridge. Some
        // source query protocols use POST; this does not grant raw plugin HTTP writes.
        if method.starts_with("fudan.") {
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
                        .unwrap_or(20)
                        .clamp(1, 100) as u16;
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
}
