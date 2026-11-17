// SPDX-License-Identifier: GPL-3.0-or-later
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::sync::Arc;
use url::Url;

/// A list preserves repeated headers (including multiple Link fields).
pub type Headers = Vec<(String, String)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    /// Some source-defined read-only query endpoints require POST.
    Post,
    /// Writes to services whose protocol uses them (cloud drives, WebDAV).
    Put,
    Delete,
    /// WebDAV: list a collection (read-only), create one, move or rename.
    Propfind,
    Mkcol,
    Move,
}

impl HttpMethod {
    pub const fn is_mutating(self) -> bool {
        !matches!(self, Self::Get | Self::Propfind)
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
            Self::Put => "PUT",
            Self::Delete => "DELETE",
            Self::Propfind => "PROPFIND",
            Self::Mkcol => "MKCOL",
            Self::Move => "MOVE",
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthMode {
    Token,
    HttpSession,
    BrowserSession,
    SecretHeaders,
}

/// Instructions to the host, never credentials. Each transport is selected
/// explicitly; missing capability/authentication MUST NOT trigger a mode fallback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TransportAuth {
    Anonymous,
    /// Mediated native HTTP with a host-injected bearer token.
    HostToken {
        account_id: String,
    },
    /// Mediated native HTTP with origin-bound nonstandard credential headers.
    /// Names and values remain in the trusted host vault/session, never here.
    HostHeaders {
        account_id: String,
    },
    /// Mediated native HTTP using the host's opaque Cookie/session jar.
    /// A trusted login adapter may import an HTTP-usable session into that jar.
    HostSession {
        account_id: String,
    },
    /// Public source: use an existing matching HTTP session, otherwise make an
    /// anonymous first request. A server auth failure is never silently retried.
    OptionalSession {
        account_id: String,
    },
    /// Explicit page-context fetch/XHR, only when the caller requires that context.
    BrowserSession {
        account_id: String,
    },
}

/// The transport MUST enforce origin/grant checks before I/O, bound time/body size,
/// and prevent automatic cross-origin redirects with credentials. HostSession is
/// native HTTP. Only BrowserSession MUST execute inside the authenticated page.
/// Do not log or persist this wire object, headers, bodies, redirect or signed URLs.
/// Raw wire objects deliberately do not implement Serialize or a revealing Debug.
#[derive(Clone)]
pub struct ConnectorRequest {
    pub method: HttpMethod,
    pub url: Url,
    pub headers: Headers,
    pub body: Option<Vec<u8>>,
    pub auth: TransportAuth,
}

impl fmt::Debug for ConnectorRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConnectorRequest")
            .field("method", &self.method)
            .finish_non_exhaustive()
    }
}

#[derive(Clone)]
pub struct ConnectorResponse {
    pub status: u16,
    pub final_url: Url,
    pub headers: Headers,
    pub body: Vec<u8>,
}

impl fmt::Debug for ConnectorResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConnectorResponse")
            .field("status", &self.status)
            .field("body_bytes", &self.body.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthChallenge {
    pub connector: String,
    pub origin: String,
    pub account_id: String,
    pub mode: AuthMode,
}

#[derive(Clone, Debug, thiserror::Error, PartialEq, Eq)]
pub enum ConnectorError {
    /// A write may have reached the service. Reconcile before explicitly retrying.
    #[error("the remote write outcome requires reconciliation")]
    NeedsReconciliation,
    #[error("authentication required")]
    AuthRequired(AuthChallenge),
    /// The source's own credential is present, but the request was routed
    /// through a gateway whose session is missing or expired.
    #[error("gateway sign-in required")]
    GatewaySessionRequired,
    #[error("permission denied")]
    PermissionDenied,
    #[error("this course does not allow access to the resource")]
    CourseAccessDenied,
    #[error("host transport unavailable")]
    TransportUnavailable,
    #[error("host transport timed out")]
    Timeout,
    #[error("required platform capability unavailable")]
    CapabilityUnavailable,
    #[error("Canvas session needs a valid CSRF cookie before sending")]
    CanvasCsrfRequired,
    #[error("remote HTTP status {0}")]
    HttpStatus(u16),
    #[error("invalid connector configuration: {0}")]
    InvalidConfiguration(&'static str),
    #[error("invalid {source_name} response at {field}")]
    Parse {
        source_name: &'static str,
        field: &'static str,
    },
    #[error("unsafe response or pagination target")]
    UnsafeUrl,
    #[error("pagination cycle detected")]
    PaginationCycle,
    #[error("connector response limit exceeded")]
    LimitExceeded,
    /// The remote service refused a write for a known reason. The code is a
    /// fixed identifier (e.g. `NameConflict`), never remote text.
    #[error("remote service rejected the operation: {0}")]
    Rejected(&'static str),
}

impl ConnectorError {
    /// Used only after handing a write to a transport or decoding its response.
    /// Explicit preflight/remote rejections remain definite; lost or malformed
    /// responses have the same conservative semantics as Canvas writes.
    pub(crate) fn after_write(self) -> Self {
        match self {
            Self::TransportUnavailable
            | Self::Timeout
            | Self::Parse { .. }
            | Self::UnsafeUrl
            | Self::LimitExceeded
            | Self::HttpStatus(408 | 500..=599) => Self::NeedsReconciliation,
            other => other,
        }
    }
}

/// Mirrors Canvas's response boundary: only a response from the requested
/// endpoint and an explicit 4xx rejection can establish a failed write.
pub(crate) fn check_write_response(
    response: &ConnectorResponse,
    requested: &Url,
    max_bytes: usize,
) -> Result<(), ConnectorError> {
    if response.final_url.origin() != requested.origin()
        || response.final_url.path() != requested.path()
        || !(200..300).contains(&response.status) && !(400..500).contains(&response.status)
        || response.status == 408
        || response.body.len() > max_bytes
    {
        return Err(ConnectorError::NeedsReconciliation);
    }
    Ok(())
}

#[async_trait]
pub trait ConnectorTransport: Send + Sync {
    /// Trusted native host opt-in. The implementation must inject CSRF internally,
    /// bind account/origin, and dispatch at most once. Never fall back to execute.
    async fn execute_canvas_session_write(
        &self,
        _request: ConnectorRequest,
    ) -> Result<ConnectorResponse, crate::canvas::CanvasWriteError> {
        Err(ConnectorError::CapabilityUnavailable.into())
    }
    async fn execute(&self, request: ConnectorRequest)
    -> Result<ConnectorResponse, ConnectorError>;
}

#[async_trait]
impl<T: ConnectorTransport + ?Sized> ConnectorTransport for Arc<T> {
    async fn execute_canvas_session_write(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, crate::canvas::CanvasWriteError> {
        self.as_ref().execute_canvas_session_write(request).await
    }
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        self.as_ref().execute(request).await
    }
}

pub(crate) fn parse_error(source_name: &'static str, field: &'static str) -> ConnectorError {
    ConnectorError::Parse { source_name, field }
}

pub(crate) fn check_response(
    response: &ConnectorResponse,
    expected_origin: &Url,
    challenge: AuthChallenge,
    max_bytes: usize,
) -> Result<(), ConnectorError> {
    if response.status == 401 || (300..400).contains(&response.status) {
        return Err(ConnectorError::AuthRequired(challenge));
    }
    if response.status == 403 {
        return Err(ConnectorError::PermissionDenied);
    }
    if !(200..300).contains(&response.status) {
        return Err(ConnectorError::HttpStatus(response.status));
    }
    if response.body.len() > max_bytes {
        return Err(ConnectorError::LimitExceeded);
    }
    let path = response.final_url.path().to_ascii_lowercase();
    if response.final_url.origin() != expected_origin.origin()
        || path.contains("/login")
        || path.contains("/authserver")
    {
        return Err(ConnectorError::AuthRequired(challenge));
    }
    // Fudan SSO and Canvas can return a successful HTTP status with a login form.
    let prefix = String::from_utf8_lossy(&response.body[..response.body.len().min(16384)])
        .to_ascii_lowercase();
    let is_html =
        prefix.contains("<html") || prefix.contains("<!doctype html") || prefix.contains("<form");
    let is_login = prefix.contains("password")
        || prefix.contains("authserver")
        || prefix.contains("/login")
        || prefix.contains("统一身份认证");
    if is_html && is_login {
        return Err(ConnectorError::AuthRequired(challenge));
    }
    Ok(())
}
