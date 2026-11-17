// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2021-2023 DanXi-Dev; Rust adaptation (C) 2026 dansheng-core contributors.
//! Official forum capability expansion: login, search, publish, reply, and reconciliation.
//!
//! Grounded in DanXi reference implementations:
//! - lib/repository/forum/forum_repository.dart
//! - lib/model/forum/jwt.dart
//! - lib/model/forum/floor.dart
//! - lib/model/forum/hole.dart
//! - lib/model/forum/tag.dart
//! - lib/common/constant.dart
//!
//! # Authentication and Secret Scoping
//! - `community.tea.login`: Authenticates with email and password at the auth service.
//!   The resulting JWT access token is imported directly into the host `Network` session
//!   store scoped to the target origin and account. No secrets (passwords or JWT tokens)
//!   are ever returned in the response payload or logged.
//! - `community.tea.search`, `publish`, `reply`: Execute mediated HTTP requests via
//!   `Network::request_with_credentials` using `CredentialKind::Bearer`.
//!
//! # Transactional Single Dispatch and Uncertainty
//! - Mutex-protected single dispatch prevents concurrent duplicate posting for identical
//!   canonical actions `(account, action, target_id, content_hash)`.
//! - External write timeouts or connection interruptions are treated as UNCERTAIN.
//!   Blind retries are strictly prohibited.
//! - Unresolved writes are saved with `GuardStatus::Uncertain` in durable KV storage.
//!   Reconciliation requires verifying the submission against authoritative own-user history
//!   (`/api/users/me/floors` or `/api/users/me/holes`) with target, content, and post-start
//!   timestamp verification. Matching someone else's reply in the same hole is not accepted.
//!   User-supplied boolean approval flags are never accepted as authority to resolve writes.

use chrono::{DateTime, Utc};
use dansheng_core::{
    api::{CoreError, CoreResult, Principal, required_string},
    network::{CredentialKind, HttpRequest, HttpResponse},
    network_routes::{GatewayRoute, RouteMode},
    policy::Grant,
    services::ServiceContext,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Mutex,
};
use url::Url;

/// Default forum API origin matching DanXi `Constant.FORUM_BASE_URL`.
pub const TEA_ORIGIN: &str = "https://forum.fduhole.com";

/// Default forum auth API origin matching DanXi `Constant.AUTH_BASE_URL`.
pub const AUTH_ORIGIN: &str = "https://auth.fduhole.com";

/// Default tag name when no tags are provided, matching DanXi `KEY_NO_TAG`.
pub const KEY_NO_TAG: &str = "默认";

/// KV storage namespace for durable forum dispatch guards.
pub const GUARDS_NAMESPACE: &str = "community.tea.guards";

/// In-flight single-dispatch lock to prevent concurrent identical writes.
static IN_FLIGHT: Mutex<Option<BTreeSet<String>>> = Mutex::new(None);

/// RAII guard releasing an in-flight dispatch key upon completion or drop.
struct DispatchGuard {
    key: String,
}

impl Drop for DispatchGuard {
    fn drop(&mut self) {
        if let Ok(mut lock) = IN_FLIGHT.lock()
            && let Some(set) = lock.as_mut()
        {
            set.remove(&self.key);
        }
    }
}

fn try_acquire_dispatch(key: &str) -> CoreResult<DispatchGuard> {
    let mut lock = IN_FLIGHT
        .lock()
        .map_err(|_| CoreError::new("InternalError", "dispatch lock poisoned"))?;
    let set = lock.get_or_insert_with(BTreeSet::new);
    if set.contains(key) {
        return Err(CoreError::new(
            "Conflict",
            "an identical forum write is already in progress",
        ));
    }
    set.insert(key.to_string());
    Ok(DispatchGuard {
        key: key.to_string(),
    })
}

/// Safe, normalized floor representation matching DanXi `OTFloor` without internal leaks.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SafeFloor {
    pub floor_id: u64,
    pub hole_id: u64,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub anonyname: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_created: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_updated: Option<String>,
    pub deleted: bool,
    pub like: u64,
    pub dislike: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fold: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub special_tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modified: Option<u64>,
    /// The floor was written by the signed-in account (DanXi `is_me`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_me: bool,
}

/// Durable guard status for single dispatch and uncertain timeouts.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GuardStatus {
    Pending,
    Committed,
    Uncertain,
    Failed,
}

/// Durable guard record stored in SQLite KV.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GuardRecord {
    pub account_id: String,
    pub action: String,
    pub target_id: u64,
    pub content_hash: String,
    pub status: GuardStatus,
    pub created_at: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<Value>,
}

struct ReconcileTarget<'a> {
    account: &'a str,
    tea_origin: &'a str,
    target_id: u64,
    content: &'a str,
    canonical_key: &'a str,
}

/// Compute SHA-256 hex string for canonical content hashing.
pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let result = hasher.finalize();
    let mut s = String::with_capacity(64);
    for byte in result {
        use std::fmt::Write;
        let _ = write!(s, "{:02x}", byte);
    }
    s
}

fn parse_timestamp(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn validate_account(account: &str) -> CoreResult<()> {
    if account.is_empty() || account.len() > 128 || account.chars().any(char::is_control) {
        return Err(CoreError::invalid("invalid or bounded account_id required"));
    }
    Ok(())
}

fn validate_email(email: &str) -> CoreResult<()> {
    let trimmed = email.trim();
    if trimmed.len() < 3
        || trimmed.len() > 128
        || trimmed.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return Err(CoreError::invalid("invalid email format or length"));
    }
    let mut parts = trimmed.split('@');
    let user = parts.next().unwrap_or("");
    let domain = parts.next().unwrap_or("");
    if user.is_empty() || domain.is_empty() || !domain.contains('.') || parts.next().is_some() {
        return Err(CoreError::invalid("invalid email domain format"));
    }
    Ok(())
}

fn validate_password(password: &str) -> CoreResult<()> {
    if password.is_empty() || password.len() > 256 || password.chars().any(char::is_control) {
        return Err(CoreError::invalid("invalid password length or characters"));
    }
    Ok(())
}

fn validate_content(content: &str) -> CoreResult<&str> {
    let trimmed = content.trim();
    if trimmed.is_empty() || trimmed.len() > 20_000 {
        return Err(CoreError::invalid(
            "content must be between 1 and 20000 characters",
        ));
    }
    Ok(trimmed)
}

fn validate_query(query: &str) -> CoreResult<&str> {
    let trimmed = query.trim();
    if trimmed.is_empty() || trimmed.len() > 200 || trimmed.chars().any(char::is_control) {
        return Err(CoreError::invalid(
            "search query must be between 1 and 200 characters",
        ));
    }
    Ok(trimmed)
}

fn validate_positive_id(val: u64, name: &str) -> CoreResult<u64> {
    if val == 0 {
        return Err(CoreError::invalid(format!(
            "{name} must be greater than zero"
        )));
    }
    Ok(val)
}

fn make_io_grant(grant: &Grant, origin: &str, account: &str, mutating: bool) -> Grant {
    let mut io = grant.clone();
    io.capabilities.insert("http.request".into());
    if mutating {
        io.capabilities.insert("http.write".into());
    }
    io.origins.insert(origin.to_string());
    io.account_ids.insert(account.to_string());
    io.allow_private_network = grant.allow_private_network;
    io
}

/// A sign-in demand from the transport itself. Callers confirm the forum
/// token first (and signing in needs none), so what is missing is the session
/// of the WebVPN gateway the request was routed through. Reporting it as a
/// forum sign-in would make the host discard working forum credentials.
fn gateway_sign_in(e: CoreError) -> CoreError {
    if e.code == "AuthenticationRequired" {
        CoreError::new(
            "WebVpnLoginRequired",
            "sign in to WebVPN to reach the forum through it",
        )
    } else {
        e
    }
}

/// Signs in through the forum's WebVPN route. The gateway answers a request
/// without a live session with a redirect, which a POST can only report as an
/// unconfirmed write, so the session is checked with a GET first.
async fn login_through_gateway(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    account: &str,
    route: &GatewayRoute,
    mut request: HttpRequest,
) -> CoreResult<HttpResponse> {
    let logical = Url::parse(&request.url).map_err(|_| CoreError::invalid("invalid login URL"))?;
    let physical = route.encode(&logical)?.to_string();
    let io_grant = make_io_grant(grant, &route.gateway_origin()?, account, true);
    let probe = context
        .network
        .request_with_credentials(
            principal,
            &io_grant,
            HttpRequest {
                url: physical.clone(),
                method: "GET".into(),
                headers: BTreeMap::new(),
                body: None,
                account_id: Some(account.to_string()),
                timeout_ms: Some(8000),
                follow_redirects: false,
            },
            CredentialKind::Cookie,
        )
        .await
        .map_err(gateway_sign_in)?;
    if (300..400).contains(&probe.status) {
        return Err(CoreError::new(
            "WebVpnLoginRequired",
            "the WebVPN session has expired",
        ));
    }
    request.url = physical;
    context
        .network
        .request_with_credentials(principal, &io_grant, request, CredentialKind::Cookie)
        .await
        .map_err(gateway_sign_in)
}

fn is_uncertain_error(e: &CoreError) -> bool {
    matches!(
        e.code.as_str(),
        "Timeout" | "NeedsReconciliation" | "NetworkUnreachable" | "NetworkError"
    )
}

fn update_guard_status(
    context: &ServiceContext<'_>,
    key: &str,
    status: GuardStatus,
    error_code: Option<&str>,
    outcome: Option<&Value>,
) -> CoreResult<()> {
    let raw = context.store.kv_get(GUARDS_NAMESPACE, key)?;
    if let Ok(mut guard) = serde_json::from_value::<GuardRecord>(raw) {
        guard.status = status;
        guard.updated_at = Utc::now().to_rfc3339();
        guard.error_code = error_code.map(str::to_string);
        guard.outcome = outcome.cloned();
        context
            .store
            .kv_set(GUARDS_NAMESPACE, key, &serde_json::to_value(&guard)?)?;
    }
    Ok(())
}

fn parse_safe_floor(v: &Value) -> Option<SafeFloor> {
    let floor_id = v.get("floor_id").and_then(Value::as_u64)?;
    let hole_id = v.get("hole_id").and_then(Value::as_u64)?;
    let content = v
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let anonyname = v
        .get("anonyname")
        .and_then(Value::as_str)
        .map(str::to_string);
    let time_created = v
        .get("time_created")
        .and_then(Value::as_str)
        .map(str::to_string);
    let time_updated = v
        .get("time_updated")
        .and_then(Value::as_str)
        .map(str::to_string);
    let deleted = v.get("deleted").and_then(Value::as_bool).unwrap_or(false);
    let like = v.get("like").and_then(Value::as_u64).unwrap_or(0);
    let dislike = v.get("dislike").and_then(Value::as_u64).unwrap_or(0);
    let fold = v
        .get("fold")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    let special_tag = v
        .get("special_tag")
        .and_then(Value::as_str)
        .map(str::to_string);
    let modified = v.get("modified").and_then(Value::as_u64);
    let is_me = v.get("is_me").and_then(Value::as_bool).unwrap_or(false);

    Some(SafeFloor {
        floor_id,
        hole_id,
        content,
        anonyname,
        time_created,
        time_updated,
        deleted,
        like,
        dislike,
        fold,
        special_tag,
        modified,
        is_me,
    })
}

/// Main public entry point for official forum operations.
/// In production, endpoints are strictly pinned to official constants (no wire parameters override origins).
pub async fn call(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    method: &str,
    params: &Value,
) -> CoreResult<Value> {
    call_with_origins(
        context,
        principal,
        grant,
        method,
        params,
        TEA_ORIGIN,
        AUTH_ORIGIN,
    )
    .await
}

/// Core implementation supporting injected origins for unit tests without exposing wire origin parameters.
pub(crate) async fn call_with_origins(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    method: &str,
    params: &Value,
    tea_origin: &str,
    auth_origin: &str,
) -> CoreResult<Value> {
    match method {
        "community.tea.login" => {
            tea_login(context, principal, grant, params, tea_origin, auth_origin).await
        }
        "community.tea.search" => tea_search(context, principal, grant, params, tea_origin).await,
        "community.tea.divisions" => {
            tea_divisions(context, principal, grant, params, tea_origin).await
        }
        "community.tea.pinned" => tea_pinned(context, principal, grant, params, tea_origin).await,
        "community.tea.favorites" => {
            tea_favorites(context, principal, grant, params, tea_origin).await
        }
        "community.tea.favorite" => {
            tea_set_favorite(context, principal, grant, params, tea_origin).await
        }
        "community.tea.hole" => tea_hole(context, principal, grant, params, tea_origin).await,
        "community.tea.holes" => tea_holes(context, principal, grant, params, tea_origin).await,
        "community.tea.floors" => tea_floors(context, principal, grant, params, tea_origin).await,
        "community.tea.publish" => tea_publish(context, principal, grant, params, tea_origin).await,
        "community.tea.reply" => tea_reply(context, principal, grant, params, tea_origin).await,
        "community.tea.floor.modify" => {
            tea_modify_floor(context, principal, grant, params, tea_origin).await
        }
        "community.tea.floor.delete" => {
            tea_delete_floor(context, principal, grant, params, tea_origin).await
        }
        "community.tea.report" => tea_report(context, principal, grant, params, tea_origin).await,
        "community.tea.reconcile" => {
            tea_reconcile(context, principal, grant, params, tea_origin).await
        }
        other => Err(CoreError::new(
            "MethodNotFound",
            format!("unknown forum action method: {other}"),
        )),
    }
}

/// Login with email/password, import JWT access token into Network session, return no secrets.
async fn tea_login(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
    auth_origin: &str,
) -> CoreResult<Value> {
    if !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum login requires the profile owner",
        ));
    }
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.login")?;

    let email = required_string(params, "email")?;
    validate_email(email)?;
    let password = required_string(params, "password")?;
    validate_password(password)?;

    let login_url = format!("{auth_origin}/api/login");
    let io_grant = make_io_grant(grant, auth_origin, account, true);

    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());
    headers.insert("content-type".into(), "application/json".into());

    let req = HttpRequest {
        url: login_url,
        method: "POST".into(),
        headers,
        body: Some(json!({
            "email": email,
            "password": password
        })),
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    // WebVPN is the forum's fallback route. The transport never resends a
    // write on another route, but a sign-in changes nothing remotely, so it
    // may follow the reads there when the direct path gives no answer.
    let route = context
        .network
        .routes(account)?
        .into_iter()
        .find(|route| route.origin == auth_origin && route.mode != RouteMode::Direct);
    let direct = if route.as_ref().is_some_and(|r| r.mode == RouteMode::Gateway) {
        Err(CoreError::new("NetworkUnreachable", "gateway-only route"))
    } else {
        context
            .network
            .request_with_credentials(principal, &io_grant, req.clone(), CredentialKind::Anonymous)
            .await
    };
    let response = match (direct, route) {
        (Ok(response), _) => Ok(response),
        (Err(e), Some(route))
            if matches!(
                e.code.as_str(),
                "NeedsReconciliation" | "Timeout" | "NetworkUnreachable" | "NetworkError"
            ) =>
        {
            login_through_gateway(context, principal, grant, account, &route, req).await
        }
        (Err(e), _) => Err(gateway_sign_in(e)),
    }
    .map_err(|e| match e.code.as_str() {
        "Timeout" => CoreError::new("Timeout", "forum login timed out"),
        "NetworkUnreachable" => CoreError::new("NetworkUnreachable", "auth service unreachable"),
        // Nothing was written: an unanswered sign-in is a plain network failure.
        "NeedsReconciliation" => CoreError::new("NetworkError", "forum login got no answer"),
        _ => e,
    })?;

    if response.status == 401 || response.status == 400 {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "invalid forum login credentials",
        ));
    }
    if response.status == 403 {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum account login forbidden",
        ));
    }
    if !(200..300).contains(&response.status) {
        return Err(CoreError::new(
            "SourceHttpError",
            format!("auth service returned status {}", response.status),
        ));
    }

    let parsed: Value = serde_json::from_str(&response.body).map_err(|_| {
        CoreError::new(
            "SourceSchemaChanged",
            "invalid JSON response from auth service",
        )
    })?;

    // DanXi JWToken wire fields are "access" and "refresh" (lib/model/forum/jwt.dart).
    // Support both flat {"access": "...", "refresh": "..."} and envelope {"data": {"access": "...", "refresh": "..."}}.
    let token_obj = if parsed.get("access").is_some() {
        &parsed
    } else if let Some(data) = parsed.get("data").filter(|d| d.is_object()) {
        data
    } else {
        &parsed
    };

    let access = token_obj
        .get("access")
        .and_then(Value::as_str)
        .filter(|t| !t.trim().is_empty())
        .ok_or_else(|| {
            CoreError::new(
                "SourceSchemaChanged",
                "login response missing JWT access token",
            )
        })?;

    let _refresh = token_obj
        .get("refresh")
        .and_then(Value::as_str)
        .filter(|t| !t.trim().is_empty())
        .ok_or_else(|| {
            CoreError::new(
                "SourceSchemaChanged",
                "login response missing JWT refresh token",
            )
        })?;

    // Store the access token for the services DanXi sends it to: the forum
    // (forum.fduhole.com) and its course reviews (danke.fduhole.com, DanXi's
    // CurriculumBoardRepository). auth.fduhole.com never receives it.
    context
        .network
        .set_session(account, tea_origin, Some(access.to_string()), vec![])?;
    context.network.set_session(
        account,
        crate::community::DANKE_ORIGIN,
        Some(access.to_string()),
        vec![],
    )?;

    Ok(json!({
        "account_id": account,
        "session_imported": true
    }))
}

/// Search forum floors with query and offset, returning safe normalized floor array.
/// Parameters and preferred algorithms mirror DanXi `loadSearchResults`:
/// - `query`: search keyword (required)
/// - `offset`: floor offset index (default 0)
/// - `size`: page size (default 20 matching DanXi Constant.POST_COUNT_PER_PAGE, max 50)
/// - `accurate`: exact match boolean (default false)
/// - `start_time` / `end_time`: Unix epoch seconds or RFC3339 strings
async fn tea_search(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.read")?;

    let query_str = required_string(params, "query")?;
    let query = validate_query(query_str)?;

    let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0);
    if offset > 1_000_000 {
        return Err(CoreError::invalid(
            "offset exceeds maximum allowed (1000000)",
        ));
    }
    // DanXi Constant.POST_COUNT_PER_PAGE defaults to 20
    let size = params
        .get("size")
        .or_else(|| params.get("page_size"))
        .or_else(|| params.get("length"))
        .and_then(Value::as_u64)
        .unwrap_or(20)
        .clamp(1, 50);

    let accurate = params
        .get("accurate")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let parse_time_param = |key: &str| -> CoreResult<Option<i64>> {
        if let Some(v) = params.get(key) {
            if let Some(num) = v.as_i64() {
                Ok(Some(num))
            } else if let Some(s) = v.as_str() {
                if let Ok(ts) = s.parse::<i64>() {
                    Ok(Some(ts))
                } else if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
                    Ok(Some(dt.timestamp()))
                } else {
                    Err(CoreError::invalid(format!(
                        "invalid {key} timestamp format"
                    )))
                }
            } else {
                Err(CoreError::invalid(format!("invalid {key} type")))
            }
        } else {
            Ok(None)
        }
    };

    let start_time = parse_time_param("start_time")?;
    let end_time = parse_time_param("end_time")?;

    // Ensure account already has established Bearer session before network execution
    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }

    let mut url = Url::parse(&format!("{tea_origin}/api/floors/search"))
        .map_err(|_| CoreError::invalid("invalid search URL"))?;
    url.query_pairs_mut()
        .append_pair("search", query)
        .append_pair("offset", &offset.to_string())
        .append_pair("size", &size.to_string())
        .append_pair("accurate", if accurate { "true" } else { "false" });

    if let Some(st) = start_time {
        url.query_pairs_mut()
            .append_pair("start_time", &st.to_string());
    }
    if let Some(et) = end_time {
        url.query_pairs_mut()
            .append_pair("end_time", &et.to_string());
    }

    let io_grant = make_io_grant(grant, tea_origin, account, false);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());

    let req = HttpRequest {
        url: url.to_string(),
        method: "GET".into(),
        headers,
        body: None,
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let response = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await
        .map_err(gateway_sign_in)?;

    if response.status == 401 {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "forum token rejected by server",
        ));
    }
    if response.status == 403 {
        return Err(CoreError::new("PermissionDenied", "forum search forbidden"));
    }
    if !(200..300).contains(&response.status) {
        return Err(CoreError::new(
            "SourceHttpError",
            format!("forum search returned status {}", response.status),
        ));
    }

    let raw_items: Vec<Value> = serde_json::from_str(&response.body).map_err(|_| {
        CoreError::new(
            "SourceSchemaChanged",
            "search response is not a valid JSON array",
        )
    })?;

    let mut items = Vec::new();
    for v in raw_items {
        if let Some(floor) = parse_safe_floor(&v) {
            items.push(floor);
        }
    }

    Ok(json!({
        "items": items,
        "offset": offset,
        "count": items.len()
    }))
}

/// Retrieve forum divisions matching DanXi `loadDivisions` (`GET /api/divisions`).
async fn tea_divisions(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.read")?;

    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }

    let io_grant = make_io_grant(grant, tea_origin, account, false);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());

    let req = HttpRequest {
        url: format!("{tea_origin}/api/divisions"),
        method: "GET".into(),
        headers,
        body: None,
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let response = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await
        .map_err(gateway_sign_in)?;

    if response.status == 401 {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "forum token rejected by server",
        ));
    }
    if response.status == 403 {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum divisions forbidden",
        ));
    }
    if !(200..300).contains(&response.status) {
        return Err(CoreError::new(
            "SourceHttpError",
            format!("forum divisions returned status {}", response.status),
        ));
    }

    let divisions: Value = serde_json::from_str(&response.body).map_err(|_| {
        CoreError::new(
            "SourceSchemaChanged",
            "divisions response is not valid JSON",
        )
    })?;
    Ok(divisions)
}

/// Retrieve pinned holes for a division, matching DanXi `getPinned(division)`.
async fn tea_pinned(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let division_id = params
        .get("division_id")
        .or_else(|| params.get("division"))
        .and_then(Value::as_u64)
        .ok_or_else(|| CoreError::invalid("missing or invalid division_id"))?;
    validate_positive_id(division_id, "division_id")?;

    let divisions_val = tea_divisions(context, principal, grant, params, tea_origin).await?;
    let divisions = divisions_val.as_array().ok_or_else(|| {
        CoreError::new("SourceSchemaChanged", "divisions response is not an array")
    })?;

    // DanXi getPinned(division) retrieves division.pinned ?? [] from the divisions list
    for div in divisions {
        if div.get("division_id").and_then(Value::as_u64) == Some(division_id) {
            let pinned = div.get("pinned").cloned().unwrap_or_else(|| json!([]));
            return Ok(pinned);
        }
    }
    Ok(json!([]))
}

/// One request to `/api/user/favorites`, shared by the list and its changes.
async fn favorites_request(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
    method: &str,
    body: Option<Value>,
) -> CoreResult<Value> {
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(
        principal,
        if body.is_some() {
            "community.write"
        } else {
            "community.read"
        },
    )?;
    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }
    let io_grant = make_io_grant(grant, tea_origin, account, body.is_some());
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());
    if body.is_some() {
        headers.insert("content-type".into(), "application/json".into());
    }
    let response = context
        .network
        .request_with_credentials(
            principal,
            &io_grant,
            HttpRequest {
                url: format!("{tea_origin}/api/user/favorites"),
                method: method.into(),
                headers,
                body,
                account_id: Some(account.to_string()),
                timeout_ms: Some(15000),
                follow_redirects: false,
            },
            CredentialKind::Bearer,
        )
        .await
        .map_err(gateway_sign_in)?;
    match response.status {
        401 => Err(CoreError::new(
            "AuthenticationRequired",
            "forum token rejected by server",
        )),
        403 => Err(CoreError::new(
            "PermissionDenied",
            "forum favorites forbidden",
        )),
        status if !(200..300).contains(&status) => Err(CoreError::new(
            "SourceHttpError",
            format!("forum favorites returned status {status}"),
        )),
        _ => serde_json::from_str(&response.body).map_err(|_| {
            CoreError::new(
                "SourceSchemaChanged",
                "favorites response is not valid JSON",
            )
        }),
    }
}

/// The account's favourite holes, matching DanXi `getFavoriteHoles`
/// (`GET /api/user/favorites`).
async fn tea_favorites(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let holes =
        favorites_request(context, principal, grant, params, tea_origin, "GET", None).await?;
    if !holes.is_array() {
        return Err(CoreError::new(
            "SourceSchemaChanged",
            "favorites response is not an array",
        ));
    }
    Ok(holes)
}

/// Adds or removes one favourite, matching DanXi `setFavorite`
/// (`POST`/`DELETE /api/user/favorites` with `{hole_id}`). Setting the state
/// it already has changes nothing, so an unanswered request may be repeated.
async fn tea_set_favorite(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let hole_id = params
        .get("hole_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| CoreError::invalid("missing or invalid hole_id"))?;
    validate_positive_id(hole_id, "hole_id")?;
    let favorite = params
        .get("favorite")
        .and_then(Value::as_bool)
        .ok_or_else(|| CoreError::invalid("favorite must be a boolean"))?;
    let answer = favorites_request(
        context,
        principal,
        grant,
        params,
        tea_origin,
        if favorite { "POST" } else { "DELETE" },
        Some(json!({ "hole_id": hole_id })),
    )
    .await
    .map_err(|e| {
        if e.code == "NeedsReconciliation" {
            CoreError::new("NetworkError", "favorite change got no answer")
        } else {
            e
        }
    })?;
    // The answer carries the account's favourite ids after the change.
    let ids = answer
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::new("SourceSchemaChanged", "favorite answer has no id list"))?;
    Ok(json!({ "hole_id": hole_id, "favorite": favorite, "favorites": ids }))
}

/// One authenticated write to the forum on a floor the person picked.
async fn floor_write(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
    request: (&str, String, Option<Value>),
) -> CoreResult<Value> {
    let (method, path, body) = request;
    if !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum floor changes require the profile owner",
        ));
    }
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.write")?;
    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }
    let io_grant = make_io_grant(grant, tea_origin, account, true);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());
    if body.is_some() {
        headers.insert("content-type".into(), "application/json".into());
    }
    let response = context
        .network
        .request_with_credentials(
            principal,
            &io_grant,
            HttpRequest {
                url: format!("{tea_origin}{path}"),
                method: method.into(),
                headers,
                body,
                account_id: Some(account.to_string()),
                timeout_ms: Some(15000),
                follow_redirects: false,
            },
            CredentialKind::Bearer,
        )
        .await
        .map_err(gateway_sign_in)?;
    match response.status {
        401 => Err(CoreError::new(
            "AuthenticationRequired",
            "forum token rejected by server",
        )),
        403 => Err(CoreError::new(
            "PermissionDenied",
            "the forum refused this change",
        )),
        404 => Err(CoreError::new(
            "FileUnavailable",
            "the floor no longer exists",
        )),
        status if !(200..300).contains(&status) => Err(CoreError::new(
            "SourceHttpError",
            format!("forum returned status {status}"),
        )),
        _ => Ok(serde_json::from_str(&response.body).unwrap_or(Value::Null)),
    }
}

fn floor_id(params: &Value) -> CoreResult<u64> {
    let id = params
        .get("floor_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| CoreError::invalid("missing or invalid floor_id"))?;
    validate_positive_id(id, "floor_id")
}

/// Replaces the text of one of the account's own floors, matching DanXi
/// `modifyFloor` (`PATCH /api/floors/{id}/_webvpn` with `{content}`). Writing the
/// same text again changes nothing, so an unanswered edit may be repeated.
async fn tea_modify_floor(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let id = floor_id(params)?;
    let content = validate_content(required_string(params, "content")?)?;
    let answer = floor_write(
        context,
        principal,
        grant,
        params,
        tea_origin,
        (
            "PATCH",
            format!("/api/floors/{id}/_webvpn"),
            Some(json!({ "content": content })),
        ),
    )
    .await
    .map_err(|e| {
        if e.code == "NeedsReconciliation" {
            CoreError::new("NetworkError", "floor edit got no answer")
        } else {
            e
        }
    })?;
    Ok(json!({
        "floor_id": id,
        "floor": parse_safe_floor(&answer),
    }))
}

/// Deletes one of the account's own floors, matching DanXi `deleteFloor`
/// (`DELETE /api/floors/{id}`). Deleting it again changes nothing.
async fn tea_delete_floor(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let id = floor_id(params)?;
    let answer = floor_write(
        context,
        principal,
        grant,
        params,
        tea_origin,
        ("DELETE", format!("/api/floors/{id}"), None),
    )
    .await
    .map_err(|e| {
        if e.code == "NeedsReconciliation" {
            CoreError::new("NetworkError", "floor deletion got no answer")
        } else {
            e
        }
    })?;
    Ok(json!({
        "floor_id": id,
        "deleted": true,
        "floor": parse_safe_floor(&answer),
    }))
}

/// Reports a floor to the moderators, matching DanXi `reportPost`
/// (`POST /api/reports` with `{floor_id, reason}`). A second report would be a
/// second report, so an unanswered one stays NeedsReconciliation.
async fn tea_report(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let id = floor_id(params)?;
    let reason = required_string(params, "reason")?.trim();
    if reason.is_empty() || reason.chars().count() > 500 {
        return Err(CoreError::invalid(
            "report reason must be 1 to 500 characters",
        ));
    }
    floor_write(
        context,
        principal,
        grant,
        params,
        tea_origin,
        (
            "POST",
            "/api/reports".into(),
            Some(json!({ "floor_id": id, "reason": reason })),
        ),
    )
    .await?;
    Ok(json!({ "floor_id": id, "reported": true }))
}

/// Retrieve a single forum hole by ID matching DanXi `loadHoleById` (`GET /api/holes/{hole_id}`).
async fn tea_hole(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.read")?;

    let hole_id = params
        .get("hole_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| CoreError::invalid("missing or invalid hole_id"))?;
    validate_positive_id(hole_id, "hole_id")?;

    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }

    let io_grant = make_io_grant(grant, tea_origin, account, false);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());

    let req = HttpRequest {
        url: format!("{tea_origin}/api/holes/{hole_id}"),
        method: "GET".into(),
        headers,
        body: None,
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let response = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await
        .map_err(gateway_sign_in)?;

    if response.status == 401 {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "forum token rejected by server",
        ));
    }
    if response.status == 403 {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum hole access forbidden",
        ));
    }
    if !(200..300).contains(&response.status) {
        return Err(CoreError::new(
            "SourceHttpError",
            format!("forum hole returned status {}", response.status),
        ));
    }

    let hole: Value = serde_json::from_str(&response.body)
        .map_err(|_| CoreError::new("SourceSchemaChanged", "hole response is not valid JSON"))?;
    Ok(hole)
}

/// Retrieve a window of forum holes matching DanXi `loadHoles` (`GET /api/holes`).
/// Supports start_time, division_id, length, tag, and preferred order (default "time_updated").
async fn tea_holes(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.read")?;

    let division_id = params
        .get("division_id")
        .or_else(|| params.get("division"))
        .and_then(Value::as_u64);
    if let Some(id) = division_id {
        validate_positive_id(id, "division_id")?;
    }

    let start_time = params
        .get("start_time")
        .or_else(|| params.get("before"))
        .and_then(Value::as_str)
        .map(|s| {
            DateTime::parse_from_rfc3339(s)
                .map(|d| d.with_timezone(&Utc))
                .map_err(|_| CoreError::invalid("invalid start_time timestamp"))
        })
        .transpose()?
        .unwrap_or_else(Utc::now);

    let length = params
        .get("length")
        .or_else(|| params.get("size"))
        .or_else(|| params.get("page_size"))
        .and_then(Value::as_u64)
        .unwrap_or(u64::from(crate::community::TEA_HOLES_PAGE_SIZE))
        .clamp(1, u64::from(crate::community::TEA_HOLES_PAGE_SIZE));

    // Preferred algorithm: DanXi defaults to LAST_REPLIED ("time_updated")
    let order_raw = params
        .get("order")
        .and_then(Value::as_str)
        .unwrap_or("time_updated");
    let order = match order_raw {
        "created" | "time_created" | "last_created" => "time_created",
        _ => "time_updated",
    };

    let tag = params
        .get("tag")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());

    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }

    let mut url = Url::parse(&format!("{tea_origin}/api/holes"))
        .map_err(|_| CoreError::invalid("invalid holes URL"))?;
    url.query_pairs_mut()
        .append_pair("start_time", &start_time.to_rfc3339())
        .append_pair("size", &length.to_string())
        .append_pair("length", &length.to_string())
        .append_pair("order", order);

    if let Some(id) = division_id {
        url.query_pairs_mut()
            .append_pair("division_id", &id.to_string());
    }
    if let Some(t) = tag {
        url.query_pairs_mut().append_pair("tag", t);
    }

    let io_grant = make_io_grant(grant, tea_origin, account, false);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());

    let req = HttpRequest {
        url: url.to_string(),
        method: "GET".into(),
        headers,
        body: None,
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let response = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await
        .map_err(gateway_sign_in)?;

    if response.status == 401 {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "forum token rejected by server",
        ));
    }
    if response.status == 403 {
        return Err(CoreError::new("PermissionDenied", "forum holes forbidden"));
    }
    if !(200..300).contains(&response.status) {
        return Err(CoreError::new(
            "SourceHttpError",
            format!("forum holes returned status {}", response.status),
        ));
    }

    let holes: Value = serde_json::from_str(&response.body)
        .map_err(|_| CoreError::new("SourceSchemaChanged", "holes response is not valid JSON"))?;
    Ok(holes)
}

/// Retrieve floors for a forum hole matching DanXi `loadFloors` (`GET /api/holes/{hole_id}/floors`).
async fn tea_floors(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.read")?;

    let hole_id = params
        .get("hole_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| CoreError::invalid("missing or invalid hole_id"))?;
    validate_positive_id(hole_id, "hole_id")?;

    let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0);
    if offset > 1_000_000 {
        return Err(CoreError::invalid(
            "offset exceeds maximum allowed (1000000)",
        ));
    }
    let size = params
        .get("size")
        .or_else(|| params.get("length"))
        .or_else(|| params.get("page_size"))
        .and_then(Value::as_u64)
        .unwrap_or(20)
        .clamp(1, 50);

    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }

    let url_str = format!("{tea_origin}/api/holes/{hole_id}/floors?offset={offset}&size={size}");
    let io_grant = make_io_grant(grant, tea_origin, account, false);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());

    let req = HttpRequest {
        url: url_str,
        method: "GET".into(),
        headers,
        body: None,
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let response = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await
        .map_err(gateway_sign_in)?;

    if response.status == 401 {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "forum token rejected by server",
        ));
    }
    if response.status == 403 {
        return Err(CoreError::new("PermissionDenied", "forum floors forbidden"));
    }
    if !(200..300).contains(&response.status) {
        return Err(CoreError::new(
            "SourceHttpError",
            format!("forum floors returned status {}", response.status),
        ));
    }

    let raw_items: Vec<Value> = serde_json::from_str(&response.body).map_err(|_| {
        CoreError::new(
            "SourceSchemaChanged",
            "floors response is not a valid JSON array",
        )
    })?;

    let mut items = Vec::new();
    for v in raw_items {
        if let Some(floor) = parse_safe_floor(&v) {
            items.push(floor);
        }
    }

    Ok(json!({
        "hole_id": hole_id,
        "items": items,
        "offset": offset,
        "count": items.len()
    }))
}

/// Publish a new forum hole with division_id, content, and tags formatted as label list.
async fn tea_publish(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    if !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum publish requires the profile owner",
        ));
    }
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.write")?;

    let division_id = params
        .get("division_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| CoreError::invalid("missing or invalid division_id"))?;
    validate_positive_id(division_id, "division_id")?;

    let content_raw = required_string(params, "content")?;
    let content = validate_content(content_raw)?;

    // Parse and validate tag label list matching DanXi OTTag wire shape {tag_id, temperature, name}
    let mut tag_labels: Vec<String> = Vec::new();
    if let Some(tags_val) = params.get("tags")
        && let Some(arr) = tags_val.as_array()
    {
        if arr.len() > 10 {
            return Err(CoreError::invalid("tags list exceeds maximum of 10 items"));
        }
        for item in arr {
            let name = if let Some(s) = item.as_str() {
                s.trim()
            } else if let Some(s) = item.get("name").and_then(Value::as_str) {
                s.trim()
            } else {
                return Err(CoreError::invalid(
                    "tag must be a string or object with name",
                ));
            };
            if name.is_empty() || name.len() > 32 || name.chars().any(char::is_control) {
                return Err(CoreError::invalid(
                    "tag length must be between 1 and 32 characters",
                ));
            }
            tag_labels.push(name.to_string());
        }
    }
    // Default to DanXi reference KEY_NO_TAG ("默认") when tag list is empty
    if tag_labels.is_empty() {
        tag_labels.push(KEY_NO_TAG.to_string());
    }
    let tags_payload: Vec<Value> = tag_labels
        .iter()
        .map(|name| {
            json!({
                "name": name,
                "tag_id": 0,
                "temperature": 0
            })
        })
        .collect();

    let content_hash = sha256_hex(content.as_bytes());
    let canonical_key = format!("publish:{account}:{division_id}:{content_hash}");

    // Mutex single dispatch
    let _dispatch_guard = try_acquire_dispatch(&canonical_key)?;

    // Check durable guard
    let guard_raw = context.store.kv_get(GUARDS_NAMESPACE, &canonical_key)?;
    if let Ok(guard) = serde_json::from_value::<GuardRecord>(guard_raw) {
        match guard.status {
            GuardStatus::Committed => {
                return Ok(json!({
                    "status": "committed",
                    "duplicate": true,
                    "division_id": division_id,
                    "content_hash": content_hash,
                    "outcome": guard.outcome
                }));
            }
            GuardStatus::Uncertain => {
                // Authoritative own-user history reconciliation only; never clear on bool flag
                return reconcile_publish(
                    context,
                    principal,
                    grant,
                    ReconcileTarget {
                        account,
                        tea_origin,
                        target_id: division_id,
                        content,
                        canonical_key: &canonical_key,
                    },
                )
                .await;
            }
            _ => {}
        }
    }

    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }

    // Record pending guard with original dispatch start timestamp
    let now = Utc::now().to_rfc3339();
    let pending_guard = GuardRecord {
        account_id: account.to_string(),
        action: "publish".to_string(),
        target_id: division_id,
        content_hash: content_hash.clone(),
        status: GuardStatus::Pending,
        created_at: now.clone(),
        updated_at: now,
        error_code: None,
        outcome: None,
    };
    context.store.kv_set(
        GUARDS_NAMESPACE,
        &canonical_key,
        &serde_json::to_value(&pending_guard)?,
    )?;

    // Perform HTTP write
    let io_grant = make_io_grant(grant, tea_origin, account, true);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());
    headers.insert("content-type".into(), "application/json".into());

    let req = HttpRequest {
        url: format!("{tea_origin}/api/divisions/{division_id}/holes"),
        method: "POST".into(),
        headers,
        body: Some(json!({
            "content": content,
            "tags": tags_payload
        })),
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let post_result = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await;

    match post_result {
        Ok(response) => {
            if response.status == 401 {
                update_guard_status(
                    context,
                    &canonical_key,
                    GuardStatus::Failed,
                    Some("AuthenticationRequired"),
                    None,
                )?;
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "forum token invalid",
                ));
            }
            if response.status == 403 {
                update_guard_status(
                    context,
                    &canonical_key,
                    GuardStatus::Failed,
                    Some("PermissionDenied"),
                    None,
                )?;
                return Err(CoreError::new(
                    "PermissionDenied",
                    "forum publishing forbidden",
                ));
            }
            if !(200..300).contains(&response.status) {
                update_guard_status(
                    context,
                    &canonical_key,
                    GuardStatus::Failed,
                    Some("SourceHttpError"),
                    None,
                )?;
                return Err(CoreError::new(
                    "SourceHttpError",
                    format!("publish failed with status {}", response.status),
                ));
            }
            let outcome_json: Value = serde_json::from_str(&response.body)
                .unwrap_or_else(|_| json!({ "status": response.status }));
            let final_outcome = json!({
                "status": "committed",
                "division_id": division_id,
                "content_hash": content_hash,
                "response": outcome_json
            });
            update_guard_status(
                context,
                &canonical_key,
                GuardStatus::Committed,
                None,
                Some(&final_outcome),
            )?;
            Ok(final_outcome)
        }
        Err(e) if is_uncertain_error(&e) => {
            // Mark UNCERTAIN! Never blind retry!
            update_guard_status(
                context,
                &canonical_key,
                GuardStatus::Uncertain,
                Some(&e.code),
                None,
            )?;
            Err(CoreError::new(
                "NeedsReconciliation",
                "external write timeout or network interruption; outcome is uncertain and must be reconciled against own-user history",
            ))
        }
        Err(e) => {
            update_guard_status(
                context,
                &canonical_key,
                GuardStatus::Failed,
                Some(&e.code),
                None,
            )?;
            Err(e)
        }
    }
}

/// Reply to an existing forum hole.
async fn tea_reply(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    if !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum reply requires the profile owner",
        ));
    }
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.write")?;

    let hole_id = params
        .get("hole_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| CoreError::invalid("missing or invalid hole_id"))?;
    validate_positive_id(hole_id, "hole_id")?;

    let content_raw = required_string(params, "content")?;
    let content = validate_content(content_raw)?;

    let content_hash = sha256_hex(content.as_bytes());
    let canonical_key = format!("reply:{account}:{hole_id}:{content_hash}");

    // Mutex single dispatch
    let _dispatch_guard = try_acquire_dispatch(&canonical_key)?;

    // Check durable guard
    let guard_raw = context.store.kv_get(GUARDS_NAMESPACE, &canonical_key)?;
    if let Ok(guard) = serde_json::from_value::<GuardRecord>(guard_raw) {
        match guard.status {
            GuardStatus::Committed => {
                return Ok(json!({
                    "status": "committed",
                    "duplicate": true,
                    "hole_id": hole_id,
                    "content_hash": content_hash,
                    "outcome": guard.outcome
                }));
            }
            GuardStatus::Uncertain => {
                // Authoritative own-user history reconciliation only; never clear on bool flag
                return reconcile_reply(
                    context,
                    principal,
                    grant,
                    ReconcileTarget {
                        account,
                        tea_origin,
                        target_id: hole_id,
                        content,
                        canonical_key: &canonical_key,
                    },
                )
                .await;
            }
            _ => {}
        }
    }

    if !context
        .network
        .credential_available(account, tea_origin, CredentialKind::Bearer)
    {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "account has no forum credentials; please login first",
        ));
    }

    // Record pending guard with original dispatch start timestamp
    let now = Utc::now().to_rfc3339();
    let pending_guard = GuardRecord {
        account_id: account.to_string(),
        action: "reply".to_string(),
        target_id: hole_id,
        content_hash: content_hash.clone(),
        status: GuardStatus::Pending,
        created_at: now.clone(),
        updated_at: now,
        error_code: None,
        outcome: None,
    };
    context.store.kv_set(
        GUARDS_NAMESPACE,
        &canonical_key,
        &serde_json::to_value(&pending_guard)?,
    )?;

    // Perform HTTP write
    let io_grant = make_io_grant(grant, tea_origin, account, true);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());
    headers.insert("content-type".into(), "application/json".into());

    let req = HttpRequest {
        url: format!("{tea_origin}/api/holes/{hole_id}/floors"),
        method: "POST".into(),
        headers,
        body: Some(json!({
            "content": content
        })),
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let post_result = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await;

    match post_result {
        Ok(response) => {
            if response.status == 401 {
                update_guard_status(
                    context,
                    &canonical_key,
                    GuardStatus::Failed,
                    Some("AuthenticationRequired"),
                    None,
                )?;
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "forum token invalid",
                ));
            }
            if response.status == 403 {
                update_guard_status(
                    context,
                    &canonical_key,
                    GuardStatus::Failed,
                    Some("PermissionDenied"),
                    None,
                )?;
                return Err(CoreError::new("PermissionDenied", "forum reply forbidden"));
            }
            if !(200..300).contains(&response.status) {
                update_guard_status(
                    context,
                    &canonical_key,
                    GuardStatus::Failed,
                    Some("SourceHttpError"),
                    None,
                )?;
                return Err(CoreError::new(
                    "SourceHttpError",
                    format!("reply failed with status {}", response.status),
                ));
            }
            let outcome_json: Value = serde_json::from_str(&response.body)
                .unwrap_or_else(|_| json!({ "status": response.status }));
            let final_outcome = json!({
                "status": "committed",
                "hole_id": hole_id,
                "content_hash": content_hash,
                "response": outcome_json
            });
            update_guard_status(
                context,
                &canonical_key,
                GuardStatus::Committed,
                None,
                Some(&final_outcome),
            )?;
            Ok(final_outcome)
        }
        Err(e) if is_uncertain_error(&e) => {
            // Mark UNCERTAIN! Never blind retry!
            update_guard_status(
                context,
                &canonical_key,
                GuardStatus::Uncertain,
                Some(&e.code),
                None,
            )?;
            Err(CoreError::new(
                "NeedsReconciliation",
                "external write timeout or network interruption; outcome is uncertain and must be reconciled against own-user history",
            ))
        }
        Err(e) => {
            update_guard_status(
                context,
                &canonical_key,
                GuardStatus::Failed,
                Some(&e.code),
                None,
            )?;
            Err(e)
        }
    }
}

/// Explicit reconciliation dispatcher for publish or reply.
/// Wire contract:
/// - `account_id`: string (required)
/// - `action`: "publish" | "reply" (required)
/// - `content`: string (required)
/// - `hole_id` / `target_id`: u64 (required if action is reply)
/// - `division_id` / `target_id`: u64 (required if action is publish)
async fn tea_reconcile(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    params: &Value,
    tea_origin: &str,
) -> CoreResult<Value> {
    if !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "forum reconciliation requires the profile owner",
        ));
    }
    let account = required_string(params, "account_id")?;
    validate_account(account)?;
    grant.check_account(principal, Some(account))?;
    grant.check(principal, "community.write")?;

    let action = required_string(params, "action")?;
    let content_raw = required_string(params, "content")?;
    let content = validate_content(content_raw)?;

    match action {
        "publish" => {
            let division_id = params
                .get("division_id")
                .or_else(|| params.get("target_id"))
                .and_then(Value::as_u64)
                .ok_or_else(|| CoreError::invalid("missing or invalid division_id / target_id"))?;
            validate_positive_id(division_id, "division_id")?;
            let content_hash = sha256_hex(content.as_bytes());
            let canonical_key = format!("publish:{account}:{division_id}:{content_hash}");
            reconcile_publish(
                context,
                principal,
                grant,
                ReconcileTarget {
                    account,
                    tea_origin,
                    target_id: division_id,
                    content,
                    canonical_key: &canonical_key,
                },
            )
            .await
        }
        "reply" => {
            let hole_id = params
                .get("hole_id")
                .or_else(|| params.get("target_id"))
                .and_then(Value::as_u64)
                .ok_or_else(|| CoreError::invalid("missing or invalid hole_id / target_id"))?;
            validate_positive_id(hole_id, "hole_id")?;
            let content_hash = sha256_hex(content.as_bytes());
            let canonical_key = format!("reply:{account}:{hole_id}:{content_hash}");
            reconcile_reply(
                context,
                principal,
                grant,
                ReconcileTarget {
                    account,
                    tea_origin,
                    target_id: hole_id,
                    content,
                    canonical_key: &canonical_key,
                },
            )
            .await
        }
        other => Err(CoreError::invalid(format!(
            "unknown forum action to reconcile: {other}"
        ))),
    }
}

/// Authoritative own-user history reconciliation for hole publish.
/// Checks user's own hole history (/api/users/me/holes) with division_id, content, and post-start timestamp.
async fn reconcile_publish(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    target: ReconcileTarget<'_>,
) -> CoreResult<Value> {
    let ReconcileTarget {
        account,
        tea_origin,
        target_id: division_id,
        content,
        canonical_key,
    } = target;

    // Determine dispatch start timestamp from existing guard to avoid matching older pre-existing holes
    let guard_raw = context.store.kv_get(GUARDS_NAMESPACE, canonical_key)?;
    let start_time = if let Ok(guard) = serde_json::from_value::<GuardRecord>(guard_raw) {
        parse_timestamp(&guard.created_at).unwrap_or_else(Utc::now) - chrono::Duration::seconds(30)
    } else {
        Utc::now() - chrono::Duration::hours(24)
    };

    let io_grant = make_io_grant(grant, tea_origin, account, false);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());

    let req = HttpRequest {
        url: format!("{tea_origin}/api/users/me/holes?size=20&order=time_updated"),
        method: "GET".into(),
        headers,
        body: None,
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let response = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await
        .map_err(|_| {
            CoreError::new(
                "NeedsReconciliation",
                "unable to query own-user hole history for reconciliation; status remains uncertain",
            )
        })?;

    if (200..300).contains(&response.status) {
        let holes: Vec<Value> = serde_json::from_str(&response.body).map_err(|_| {
            CoreError::new(
                "NeedsReconciliation",
                "invalid JSON in own-user hole history; status remains uncertain",
            )
        })?;

        // Empty list is NOT proof of completion
        if holes.is_empty() {
            return Err(CoreError::new(
                "NeedsReconciliation",
                "own-user hole history is empty; outcome remains uncertain",
            ));
        }

        for hole in &holes {
            let h_division = hole.get("division_id").and_then(Value::as_u64);
            let first_floor = hole
                .get("floors")
                .and_then(|f| f.get("first_floor"))
                .or_else(|| hole.get("first_floor"));
            let h_content = first_floor
                .and_then(|ff| ff.get("content"))
                .and_then(Value::as_str)
                .map(str::trim);
            let h_time = hole
                .get("time_created")
                .and_then(Value::as_str)
                .and_then(parse_timestamp);

            if h_division == Some(division_id)
                && h_content == Some(content.trim())
                && h_time.is_some_and(|t| t >= start_time)
            {
                let hole_id = hole.get("hole_id").and_then(Value::as_u64).unwrap_or(0);
                let outcome = json!({
                    "status": "committed",
                    "reconciled": true,
                    "division_id": division_id,
                    "hole_id": hole_id
                });
                update_guard_status(
                    context,
                    canonical_key,
                    GuardStatus::Committed,
                    None,
                    Some(&outcome),
                )?;
                return Ok(outcome);
            }
        }
    }

    // Not confirmed in authoritative own history: leave unresolved
    Err(CoreError::new(
        "NeedsReconciliation",
        "write outcome unresolved: own-user hole history does not confirm hole creation",
    ))
}

/// Authoritative own-user history reconciliation for floor reply.
/// Checks user's own floor history (/api/users/me/floors) with hole_id, content, and post-start timestamp.
async fn reconcile_reply(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    target: ReconcileTarget<'_>,
) -> CoreResult<Value> {
    let ReconcileTarget {
        account,
        tea_origin,
        target_id: hole_id,
        content,
        canonical_key,
    } = target;

    let guard_raw = context.store.kv_get(GUARDS_NAMESPACE, canonical_key)?;
    let start_time = if let Ok(guard) = serde_json::from_value::<GuardRecord>(guard_raw) {
        parse_timestamp(&guard.created_at).unwrap_or_else(Utc::now) - chrono::Duration::seconds(30)
    } else {
        Utc::now() - chrono::Duration::hours(24)
    };

    let io_grant = make_io_grant(grant, tea_origin, account, false);
    let mut headers = BTreeMap::new();
    headers.insert("accept".into(), "application/json".into());

    let req = HttpRequest {
        url: format!("{tea_origin}/api/users/me/floors?offset=0&size=20&sort=desc"),
        method: "GET".into(),
        headers,
        body: None,
        account_id: Some(account.to_string()),
        timeout_ms: Some(15000),
        follow_redirects: false,
    };

    let response = context
        .network
        .request_with_credentials(principal, &io_grant, req, CredentialKind::Bearer)
        .await
        .map_err(|_| {
            CoreError::new(
                "NeedsReconciliation",
                "unable to query own-user floor history for reconciliation; status remains uncertain",
            )
        })?;

    if (200..300).contains(&response.status) {
        let floors: Vec<Value> = serde_json::from_str(&response.body).map_err(|_| {
            CoreError::new(
                "NeedsReconciliation",
                "invalid JSON in own-user floor history; status remains uncertain",
            )
        })?;

        // Empty list is NOT proof of completion
        if floors.is_empty() {
            return Err(CoreError::new(
                "NeedsReconciliation",
                "own-user floor history is empty; outcome remains uncertain",
            ));
        }

        for floor in &floors {
            let f_hole = floor.get("hole_id").and_then(Value::as_u64);
            let f_content = floor.get("content").and_then(Value::as_str).map(str::trim);
            let f_time = floor
                .get("time_created")
                .and_then(Value::as_str)
                .and_then(parse_timestamp);

            if f_hole == Some(hole_id)
                && f_content == Some(content.trim())
                && f_time.is_some_and(|t| t >= start_time)
            {
                let floor_id = floor.get("floor_id").and_then(Value::as_u64).unwrap_or(0);
                let outcome = json!({
                    "status": "committed",
                    "reconciled": true,
                    "hole_id": hole_id,
                    "floor_id": floor_id
                });
                update_guard_status(
                    context,
                    canonical_key,
                    GuardStatus::Committed,
                    None,
                    Some(&outcome),
                )?;
                return Ok(outcome);
            }
        }
    }

    // Not confirmed in authoritative own history: leave unresolved
    Err(CoreError::new(
        "NeedsReconciliation",
        "write outcome unresolved: own-user floor history does not confirm floor reply",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use dansheng_core::{platform::UnavailablePlatform, store::Store};
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    fn owner_grant_for(account: &str) -> Grant {
        let mut grant = Grant::default();
        grant.account_ids.insert(account.to_string());
        grant.capabilities.insert("community.login".to_string());
        grant.capabilities.insert("community.read".to_string());
        grant.capabilities.insert("community.write".to_string());
        grant.allow_private_network = true;
        grant
    }

    async fn spawn_mock_server<F>(handler: F) -> (String, tokio::task::JoinHandle<()>)
    where
        F: Fn(String, String, Option<Value>) -> (u16, String) + Send + Sync + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let origin = format!("http://{addr}");
        let handler = Arc::new(handler);

        let handle = tokio::spawn(async move {
            loop {
                let (mut socket, _) = match listener.accept().await {
                    Ok(conn) => conn,
                    Err(_) => break,
                };
                let handler = handler.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 16384];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    let raw = String::from_utf8_lossy(&buf[..n]);
                    let mut lines = raw.lines();
                    let req_line = lines.next().unwrap_or("");
                    let mut parts = req_line.split_whitespace();
                    let method = parts.next().unwrap_or("GET").to_string();
                    let path = parts.next().unwrap_or("/").to_string();

                    let body = if let Some(idx) = raw.find("\r\n\r\n") {
                        let body_str = &raw[idx + 4..];
                        serde_json::from_str::<Value>(body_str).ok()
                    } else {
                        None
                    };

                    let (status, resp_body) = handler(method, path, body);
                    let response = format!(
                        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{resp_body}",
                        resp_body.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });

        (origin, handle)
    }

    #[tokio::test]
    async fn test_unit_login_imports_token_no_secrets() {
        let (auth_origin, _srv) = spawn_mock_server(|method, path, body| {
            assert_eq!(method, "POST");
            assert_eq!(path, "/api/login");
            let b = body.unwrap();
            assert_eq!(b["email"], "test@fudan.edu.cn");
            assert_eq!(b["password"], "pwd123");
            (
                200,
                json!({
                    "access": "jwt_token_test_123",
                    "refresh": "jwt_refresh_456"
                })
                .to_string(),
            )
        })
        .await;

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };

        let owner = Principal::owner();
        let grant = owner_grant_for("acc_unit");
        let params = json!({
            "account_id": "acc_unit",
            "email": "test@fudan.edu.cn",
            "password": "pwd123"
        });

        let res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.login",
            &params,
            "http://127.0.0.1:9999",
            &auth_origin,
        )
        .await
        .unwrap();

        assert_eq!(res["account_id"], "acc_unit");
        assert_eq!(res["session_imported"], true);
        assert_eq!(res.get("access"), None);
        assert_eq!(res.get("refresh"), None);
        assert!(network.has_session("acc_unit"));
        assert!(network.has_session_for_origin("acc_unit", "http://127.0.0.1:9999"));
        // DanXi sends the same token to its course reviews (旦课).
        assert!(network.has_session_for_origin("acc_unit", crate::community::DANKE_ORIGIN));
        // Strictly dedicated origin: no cross-origin bearer set on auth_origin
        assert!(!network.has_session_for_origin("acc_unit", &auth_origin));
    }

    /// Routed through WebVPN without a WebVPN session, neither a sign-in nor a
    /// read may claim that the forum account needs signing in: the host would
    /// drop the saved forum password and ask for it again.
    #[tokio::test]
    async fn test_unit_missing_gateway_session_is_not_a_forum_sign_in() {
        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let seen = hits.clone();
        let (origin, _srv) = spawn_mock_server(move |_, _, _| {
            seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            (
                200,
                json!({"access": "token_a", "refresh": "token_r"}).to_string(),
            )
        })
        .await;
        // Nothing listens here: the direct path gives no answer.
        let dead = "http://127.0.0.1:9";

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("acc_vpn");
        let login = json!({"account_id": "acc_vpn", "email": "a@fudan.edu.cn", "password": "pwd"});
        let route = |origin: &str, name: &str, mode| GatewayRoute {
            provider: "fixture".into(),
            origin: origin.into(),
            gateway_prefix: format!("https://gateway.invalid/http/{name}"),
            mode,
        };

        // Gateway-only: the auth service is never contacted directly.
        network
            .set_routes("acc_vpn", vec![route(&origin, "live", RouteMode::Gateway)])
            .unwrap();
        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.login",
            &login,
            &origin,
            &origin,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "WebVpnLoginRequired");
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 0);

        // Fallback: an unanswered direct sign-in moves to WebVPN.
        network
            .set_routes("acc_vpn", vec![route(dead, "dead", RouteMode::Auto)])
            .unwrap();
        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.login",
            &login,
            &origin,
            dead,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "WebVpnLoginRequired");

        // Without a WebVPN route an unanswered sign-in is a network failure,
        // never an unconfirmed write.
        network.set_routes("acc_vpn", vec![]).unwrap();
        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.login",
            &login,
            &origin,
            dead,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "NetworkError");

        // With the fallback route present, a reachable direct path is used.
        network
            .set_routes("acc_vpn", vec![route(&origin, "live", RouteMode::Auto)])
            .unwrap();
        call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.login",
            &login,
            &origin,
            &origin,
        )
        .await
        .unwrap();
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);

        // Signed in to the forum, read routed through WebVPN.
        network
            .set_routes("acc_vpn", vec![route(&origin, "live", RouteMode::Gateway)])
            .unwrap();
        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.search",
            &json!({"account_id": "acc_vpn", "query": "x"}),
            &origin,
            &origin,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "WebVpnLoginRequired");
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_unit_login_jwt_envelope_and_refresh_validation() {
        // 1. Nested envelope {"data": {"access": "...", "refresh": "..."}} succeeds
        let (auth_origin, _srv) = spawn_mock_server(|method, path, _| {
            assert_eq!(method, "POST");
            assert_eq!(path, "/api/login");
            (
                200,
                json!({
                    "data": {
                        "access": "enveloped_access_tok",
                        "refresh": "enveloped_refresh_tok"
                    }
                })
                .to_string(),
            )
        })
        .await;

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("acc_env");
        let params = json!({
            "account_id": "acc_env",
            "email": "env@fudan.edu.cn",
            "password": "pwd"
        });

        let res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.login",
            &params,
            "http://127.0.0.1:8888",
            &auth_origin,
        )
        .await
        .unwrap();
        assert_eq!(res["session_imported"], true);
        assert!(network.has_session_for_origin("acc_env", "http://127.0.0.1:8888"));
        assert!(!network.has_session_for_origin("acc_env", &auth_origin));

        // 2. Missing refresh token fails with SourceSchemaChanged (parity with JWToken.fromJsonWithVerification)
        let (auth_origin2, _srv2) = spawn_mock_server(|_, _, _| {
            (
                200,
                json!({
                    "access": "only_access_token"
                })
                .to_string(),
            )
        })
        .await;

        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.login",
            &params,
            "http://127.0.0.1:8888",
            &auth_origin2,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "SourceSchemaChanged");
    }

    #[tokio::test]
    async fn test_unit_favorites_list_and_change() {
        let (tea_origin, _srv) = spawn_mock_server(|method, path, body| {
            assert_eq!(path, "/api/user/favorites");
            match method.as_str() {
                "GET" => (200, json!([{"hole_id": 7, "division_id": 1}]).to_string()),
                "POST" => {
                    assert_eq!(body.unwrap(), json!({"hole_id": 9}));
                    (201, json!({"message": "ok", "data": [7, 9]}).to_string())
                }
                "DELETE" => {
                    assert_eq!(body.unwrap(), json!({"hole_id": 7}));
                    (200, json!({"message": "ok", "data": [9]}).to_string())
                }
                other => panic!("unexpected method {other}"),
            }
        })
        .await;
        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("acc_fav");
        let list = json!({"account_id": "acc_fav"});

        // Signed out: asked to sign in before anything is sent.
        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.favorites",
            &list,
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "AuthenticationRequired");

        network
            .set_session("acc_fav", &tea_origin, Some("token".into()), vec![])
            .unwrap();
        let holes = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.favorites",
            &list,
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        assert_eq!(holes[0]["hole_id"], 7);

        for (hole_id, favorite, left) in [(9, true, json!([7, 9])), (7, false, json!([9]))] {
            let answer = call_with_origins(
                &context,
                &owner,
                &grant,
                "community.tea.favorite",
                &json!({"account_id": "acc_fav", "hole_id": hole_id, "favorite": favorite}),
                &tea_origin,
                &tea_origin,
            )
            .await
            .unwrap();
            assert_eq!(answer["favorite"], favorite);
            assert_eq!(answer["favorites"], left);
        }

        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.favorite",
            &json!({"account_id": "acc_fav", "hole_id": 0, "favorite": true}),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "InvalidInput");
    }

    #[tokio::test]
    async fn test_unit_own_floor_edit_delete_and_report() {
        let floor = |content: &str, deleted: bool| json!({"floor_id": 5, "hole_id": 3, "content": content, "deleted": deleted, "is_me": true});
        let (tea_origin, _srv) =
            spawn_mock_server(
                move |method, path, body| match (method.as_str(), path.as_str()) {
                    ("PATCH", "/api/floors/5/_webvpn") => {
                        assert_eq!(body.unwrap(), json!({"content": "edited"}));
                        (200, floor("edited", false).to_string())
                    }
                    ("DELETE", "/api/floors/5") => {
                        assert!(body.is_none());
                        (200, floor("", true).to_string())
                    }
                    ("POST", "/api/reports") => {
                        assert_eq!(body.unwrap(), json!({"floor_id": 5, "reason": "spam"}));
                        (201, "{}".to_string())
                    }
                    ("DELETE", "/api/floors/6") => (403, "{}".to_string()),
                    other => panic!("unexpected request {other:?}"),
                },
            )
            .await;
        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("acc_floor");
        network
            .set_session("acc_floor", &tea_origin, Some("token".into()), vec![])
            .unwrap();
        let run = |method: &'static str, params: Value| {
            let (context, owner, grant, tea_origin) = (&context, &owner, &grant, &tea_origin);
            async move {
                call_with_origins(
                    context, owner, grant, method, &params, tea_origin, tea_origin,
                )
                .await
            }
        };

        let edited = run(
            "community.tea.floor.modify",
            json!({"account_id": "acc_floor", "floor_id": 5, "content": " edited "}),
        )
        .await
        .unwrap();
        assert_eq!(edited["floor"]["content"], "edited");
        assert_eq!(edited["floor"]["is_me"], true);

        let deleted = run(
            "community.tea.floor.delete",
            json!({"account_id": "acc_floor", "floor_id": 5}),
        )
        .await
        .unwrap();
        assert_eq!(deleted["floor"]["deleted"], true);

        let reported = run(
            "community.tea.report",
            json!({"account_id": "acc_floor", "floor_id": 5, "reason": "spam"}),
        )
        .await
        .unwrap();
        assert_eq!(reported["reported"], true);

        // Someone else's floor: the forum's refusal is reported as such.
        let refused = run(
            "community.tea.floor.delete",
            json!({"account_id": "acc_floor", "floor_id": 6}),
        )
        .await
        .unwrap_err();
        assert_eq!(refused.code, "PermissionDenied");

        let empty = run(
            "community.tea.report",
            json!({"account_id": "acc_floor", "floor_id": 5, "reason": "  "}),
        )
        .await
        .unwrap_err();
        assert_eq!(empty.code, "InvalidInput");

        // Only the profile owner changes floors.
        let plugin = Principal {
            id: "plugin".into(),
            kind: dansheng_core::PrincipalKind::Plugin,
        };
        let err = call_with_origins(
            &context,
            &plugin,
            &grant,
            "community.tea.floor.delete",
            &json!({"account_id": "acc_floor", "floor_id": 5}),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "PermissionDenied");
    }

    #[tokio::test]
    async fn test_unit_search_normalizes_floors() {
        let (tea_origin, _srv) = spawn_mock_server(|method, path, _| {
            assert_eq!(method, "GET");
            assert!(path.starts_with("/api/floors/search"));
            assert!(path.contains("search=search+query"));
            assert!(path.contains("accurate=true"));
            assert!(path.contains("start_time=1762500000"));
            assert!(path.contains("end_time=1762600000"));
            (
                200,
                json!([
                    {
                        "floor_id": 101,
                        "hole_id": 50,
                        "content": "First search result floor",
                        "anonyname": "Carol",
                        "time_created": "2026-11-08T10:00:00Z",
                        "time_updated": "2026-11-08T10:05:00Z",
                        "deleted": false,
                        "like": 12,
                        "dislike": 1,
                        "fold": ["tag_spoiler"],
                        "special_tag": "精品",
                        "modified": 2
                    }
                ])
                .to_string(),
            )
        })
        .await;

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("search_unit");

        network
            .set_session("search_unit", &tea_origin, Some("tok".into()), vec![])
            .unwrap();

        let params = json!({
            "account_id": "search_unit",
            "query": "search query",
            "offset": 0,
            "size": 20,
            "accurate": true,
            "start_time": 1762500000,
            "end_time": 1762600000
        });

        let res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.search",
            &params,
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();

        assert_eq!(res["count"], 1);
        let items = res["items"].as_array().unwrap();
        assert_eq!(items[0]["floor_id"], 101);
        assert_eq!(items[0]["anonyname"], "Carol");
        assert_eq!(items[0]["like"], 12);
        assert_eq!(items[0]["fold"][0], "tag_spoiler");
        assert_eq!(items[0]["special_tag"], "精品");
        assert_eq!(items[0]["modified"], 2);
    }

    #[tokio::test]
    async fn test_unit_divisions_and_pinned_resolution() {
        let (tea_origin, _srv) = spawn_mock_server(|method, path, _| {
            assert_eq!(method, "GET");
            assert_eq!(path, "/api/divisions");
            (
                200,
                json!([
                    {
                        "division_id": 1,
                        "name": "General",
                        "description": "General discussions",
                        "pinned": [
                            {
                                "hole_id": 1001,
                                "division_id": 1,
                                "time_created": "2026-11-08T00:00:00Z",
                                "time_updated": "2026-11-08T01:00:00Z"
                            }
                        ]
                    },
                    {
                        "division_id": 2,
                        "name": "Academics",
                        "description": "Study help",
                        "pinned": []
                    }
                ])
                .to_string(),
            )
        })
        .await;

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("div_user");

        network
            .set_session("div_user", &tea_origin, Some("tok".into()), vec![])
            .unwrap();

        // 1. community.tea.divisions returns all divisions
        let div_res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.divisions",
            &json!({"account_id": "div_user"}),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        let divs = div_res.as_array().unwrap();
        assert_eq!(divs.len(), 2);
        assert_eq!(divs[0]["name"], "General");

        // 2. community.tea.pinned extracts pinned for division 1
        let pin_res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.pinned",
            &json!({"account_id": "div_user", "division_id": 1}),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        let pinned = pin_res.as_array().unwrap();
        assert_eq!(pinned.len(), 1);
        assert_eq!(pinned[0]["hole_id"], 1001);

        // 3. community.tea.pinned for division 2 returns empty list
        let pin_res2 = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.pinned",
            &json!({"account_id": "div_user", "division_id": 2}),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        assert!(pin_res2.as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn test_unit_holes_and_floors() {
        let (tea_origin, _srv) = spawn_mock_server(|method, path, _| {
            assert_eq!(method, "GET");
            if path.starts_with("/api/holes/42/floors") {
                assert!(path.contains("offset=0"));
                assert!(path.contains("size=20"));
                (
                    200,
                    json!([
                        {
                            "floor_id": 1,
                            "hole_id": 42,
                            "content": "Floor one",
                            "anonyname": "Alice"
                        }
                    ])
                    .to_string(),
                )
            } else if path == "/api/holes/42" {
                (
                    200,
                    json!({
                        "hole_id": 42,
                        "division_id": 1,
                        "time_created": "2026-11-08T00:00:00Z"
                    })
                    .to_string(),
                )
            } else if path.starts_with("/api/holes") {
                assert!(path.contains("division_id=1"));
                assert!(path.contains("length=10"));
                assert!(path.contains("size=10"));
                assert!(path.contains("order=time_updated"));
                (
                    200,
                    json!([
                        {
                            "hole_id": 42,
                            "division_id": 1,
                            "time_created": "2026-11-08T00:00:00Z"
                        }
                    ])
                    .to_string(),
                )
            } else {
                (404, "not found".to_string())
            }
        })
        .await;

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("read_user");

        network
            .set_session("read_user", &tea_origin, Some("tok".into()), vec![])
            .unwrap();

        // 1. community.tea.holes
        let holes_res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.holes",
            &json!({
                "account_id": "read_user",
                "division_id": 1,
                "size": 20,
                "order": "time_updated"
            }),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        assert_eq!(holes_res.as_array().unwrap()[0]["hole_id"], 42);

        // 2. community.tea.hole
        let hole_res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.hole",
            &json!({"account_id": "read_user", "hole_id": 42}),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        assert_eq!(hole_res["hole_id"], 42);

        // 3. community.tea.floors
        let floors_res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.floors",
            &json!({"account_id": "read_user", "hole_id": 42, "offset": 0, "size": 20}),
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        assert_eq!(floors_res["count"], 1);
        assert_eq!(floors_res["items"][0]["content"], "Floor one");
    }

    #[tokio::test]
    async fn test_unit_publish_default_and_custom_tags() {
        let captured = Arc::new(Mutex::new(None));
        let cap_clone = captured.clone();

        let (tea_origin, _srv) = spawn_mock_server(move |method, path, body| {
            assert_eq!(method, "POST");
            assert_eq!(path, "/api/divisions/1/holes");
            *cap_clone.lock().unwrap() = body;
            (200, json!({"hole_id": 999}).to_string())
        })
        .await;

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("pub_unit");

        network
            .set_session("pub_unit", &tea_origin, Some("tok".into()), vec![])
            .unwrap();

        // 1. Publish with no tags -> defaults to KEY_NO_TAG ("默认")
        let params_default = json!({
            "account_id": "pub_unit",
            "division_id": 1,
            "content": "Hello DanXi!"
        });
        let res = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.publish",
            &params_default,
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();
        assert_eq!(res["status"], "committed");

        let body = captured.lock().unwrap().take().unwrap();
        let tags = body["tags"].as_array().unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0]["name"], KEY_NO_TAG);

        // 2. Publish with custom tags as label list
        let params_custom = json!({
            "account_id": "pub_unit",
            "division_id": 1,
            "content": "Tagged hole",
            "tags": ["cs", "ai"]
        });
        let _ = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.publish",
            &params_custom,
            &tea_origin,
            &tea_origin,
        )
        .await
        .unwrap();

        let body2 = captured.lock().unwrap().take().unwrap();
        let tags2 = body2["tags"].as_array().unwrap();
        assert_eq!(tags2.len(), 2);
        assert_eq!(tags2[0]["name"], "cs");
        assert_eq!(tags2[1]["name"], "ai");
    }

    #[tokio::test]
    async fn test_unit_single_dispatch_conflict() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());

        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut buf = [0u8; 4096];
                    let _ = socket.read(&mut buf).await;
                    tokio::time::sleep(tokio::time::Duration::from_millis(400)).await;
                    let body = json!({"floor_id": 1}).to_string();
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                });
            }
        });

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context1 = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let context2 = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("user_single");

        network
            .set_session("user_single", &origin, Some("tok".into()), vec![])
            .unwrap();

        let params = json!({
            "account_id": "user_single",
            "hole_id": 99,
            "content": "Single dispatch test text"
        });

        let p1 = params.clone();
        let p2 = params.clone();
        let o1 = owner.clone();
        let o2 = owner.clone();
        let g1 = grant.clone();
        let g2 = grant.clone();
        let orig1 = origin.clone();
        let orig2 = origin.clone();

        let (r1, r2) = tokio::join!(
            call_with_origins(
                &context1,
                &o1,
                &g1,
                "community.tea.reply",
                &p1,
                &orig1,
                &orig1
            ),
            call_with_origins(
                &context2,
                &o2,
                &g2,
                "community.tea.reply",
                &p2,
                &orig2,
                &orig2
            )
        );

        let mut successes = 0;
        let mut conflicts = 0;
        for r in [r1, r2] {
            match r {
                Ok(_) => successes += 1,
                Err(e) if e.code == "Conflict" => conflicts += 1,
                Err(_) => {}
            }
        }
        assert_eq!(successes, 1);
        assert_eq!(conflicts, 1);
    }

    #[tokio::test]
    async fn test_unit_reconciliation_authoritative_history_verification() {
        let history = Arc::new(Mutex::new(vec![]));
        let hist_clone = history.clone();

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let origin_clone = origin.clone();

        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let hist = hist_clone.clone();
                tokio::spawn(async move {
                    let mut buf = [0u8; 8192];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    let raw = String::from_utf8_lossy(&buf[..n]);
                    if raw.starts_with("POST") {
                        // Drop socket to simulate network timeout on write
                        let _ = socket.shutdown().await;
                    } else if raw.starts_with("GET /api/users/me/floors") {
                        let floors = hist.lock().unwrap().clone();
                        let body = serde_json::to_string(&floors).unwrap();
                        let resp = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = socket.write_all(resp.as_bytes()).await;
                    }
                });
            }
        });

        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(temp.path()).unwrap();
        let network = dansheng_core::network::Network::default();
        let platform = UnavailablePlatform;
        let context = ServiceContext {
            store: &store,
            network: &network,
            platform: &platform,
        };
        let owner = Principal::owner();
        let grant = owner_grant_for("recon_acc");

        network
            .set_session("recon_acc", &origin_clone, Some("tok".into()), vec![])
            .unwrap();

        let params = json!({
            "account_id": "recon_acc",
            "hole_id": 42,
            "content": "Specific reconciliation content text"
        });

        // 1. Initial write times out -> guard set to Uncertain
        let err = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.reply",
            &params,
            &origin_clone,
            &origin_clone,
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "NeedsReconciliation");

        // 2. Empty history list: cannot resolve
        *history.lock().unwrap() = vec![];
        let err2 = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.reply",
            &params,
            &origin_clone,
            &origin_clone,
        )
        .await
        .unwrap_err();
        assert_eq!(err2.code, "NeedsReconciliation");

        // 3. History with identical content but for a DIFFERENT hole_id: cannot resolve
        *history.lock().unwrap() = vec![json!({
            "floor_id": 1001,
            "hole_id": 999, // different!
            "content": "Specific reconciliation content text",
            "time_created": Utc::now().to_rfc3339()
        })];
        let err3 = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.reply",
            &params,
            &origin_clone,
            &origin_clone,
        )
        .await
        .unwrap_err();
        assert_eq!(err3.code, "NeedsReconciliation");

        // 4. History with identical content for target hole but from an OLD timestamp: cannot resolve
        *history.lock().unwrap() = vec![json!({
            "floor_id": 1002,
            "hole_id": 42,
            "content": "Specific reconciliation content text",
            "time_created": "2020-01-01T00:00:00Z" // old!
        })];
        let err4 = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.reply",
            &params,
            &origin_clone,
            &origin_clone,
        )
        .await
        .unwrap_err();
        assert_eq!(err4.code, "NeedsReconciliation");

        // 5. User provides approved: true on params: ignored, still cannot resolve
        let mut params_approved = params.clone();
        params_approved["approved"] = json!(true);
        let err5 = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.reply",
            &params_approved,
            &origin_clone,
            &origin_clone,
        )
        .await
        .unwrap_err();
        assert_eq!(err5.code, "NeedsReconciliation");

        // 6. Legitimate own-user floor created after dispatch started: RESOLVES!
        *history.lock().unwrap() = vec![json!({
            "floor_id": 2005,
            "hole_id": 42,
            "content": "Specific reconciliation content text",
            "time_created": Utc::now().to_rfc3339()
        })];
        let resolved = call_with_origins(
            &context,
            &owner,
            &grant,
            "community.tea.reply",
            &params,
            &origin_clone,
            &origin_clone,
        )
        .await
        .unwrap();
        assert_eq!(resolved["status"], "committed");
        assert_eq!(resolved["reconciled"], true);
        assert_eq!(resolved["floor_id"], 2005);
    }
}
