// SPDX-License-Identifier: GPL-3.0-or-later
//! Read-only page transport with a binding issued by the trusted platform.
//! It never extracts cookies, starts login, evaluates arbitrary JS or falls back
//! to native HTTP. The embedding app executes the request in its current page.
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse, HttpMethod,
    core_adapter::BoundTransport,
};
use dansheng_core::{CoreError, policy::Grant};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::time::Duration;
use url::Url;

fn challenge(bound: &BoundTransport<'_>, origin: &Url) -> ConnectorError {
    ConnectorError::AuthRequired(AuthChallenge {
        connector: "official-campus-page".into(),
        origin: origin.origin().ascii_serialization(),
        account_id: bound.account.to_owned(),
        mode: AuthMode::BrowserSession,
    })
}

fn current_grant(bound: &BoundTransport<'_>, url: &Url) -> Result<Grant, ConnectorError> {
    let mut current = bound
        .store
        .grant(&bound.principal.id)
        .map_err(|_| ConnectorError::PermissionDenied)?;
    current
        .check(bound.principal, bound.source_capability)
        .map_err(|_| ConnectorError::PermissionDenied)?;
    current
        .check_account(bound.principal, Some(bound.account))
        .map_err(|_| ConnectorError::PermissionDenied)?;
    // Only the explicitly selected source's read transport is delegated. There
    // is no browser.login/browser.write or arbitrary-origin permission here.
    current
        .capabilities
        .extend(["browser.evaluate".into(), "browser.request".into()]);
    current.origins.insert(url.origin().ascii_serialization());
    Ok(current)
}

fn provider_error(error: CoreError, bound: &BoundTransport<'_>, url: &Url) -> ConnectorError {
    // Platform errors can contain raw page exception text. Classify by a fixed
    // code and discard their message before crossing the connector boundary.
    match error.code.as_str() {
        "AuthenticationRequired" | "SessionExpired" | "InvalidSession" => challenge(bound, url),
        "PermissionDenied" | "SessionOwnershipMismatch" => ConnectorError::PermissionDenied,
        "OriginMismatch" => ConnectorError::UnsafeUrl,
        "CapabilityUnavailable" => ConnectorError::CapabilityUnavailable,
        "Timeout" | "DeadlineExceeded" => ConnectorError::Timeout,
        "ResponseTooLarge" => ConnectorError::LimitExceeded,
        _ => ConnectorError::TransportUnavailable,
    }
}

pub(crate) async fn verify(
    bound: &BoundTransport<'_>,
    url: &Url,
) -> Result<String, ConnectorError> {
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(ConnectorError::UnsafeUrl);
    }
    let capabilities = bound.platform.capabilities();
    if !["browser.evaluate", "browser.request"]
        .iter()
        .all(|name| capabilities.iter().any(|cap| cap == name))
    {
        return Err(ConnectorError::CapabilityUnavailable);
    }
    let grant = current_grant(bound, url)?;
    let state = tokio::time::timeout(
        Duration::from_secs(5),
        bound.platform.call(
            "browser.evaluate",
            json!({"principal":bound.principal,"grant":grant,"input":{
                "operation":"session.status","require_authenticated":true,
                "account_id":bound.account,"url":url.origin().ascii_serialization()
            }}),
        ),
    )
    .await
    .map_err(|_| ConnectorError::Timeout)?
    .map_err(|error| provider_error(error, bound, url))?;
    current_grant(bound, url)?;
    if state["account_id"].as_str() != Some(bound.account) {
        return Err(ConnectorError::PermissionDenied);
    }
    if state["authenticated"].as_bool() != Some(true) {
        return Err(challenge(bound, url));
    }
    if state["origin"].as_str() != Some(url.origin().ascii_serialization().as_str()) {
        return Err(ConnectorError::UnsafeUrl);
    }
    let handle = state["session_handle"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256 && s.bytes().all(|b| b.is_ascii_graphic()))
        .map(str::to_owned)
        .ok_or_else(|| challenge(bound, url))?;
    let auth = crate::AuthChallenge {
        connector: "official-campus-page".into(),
        origin: url.origin().ascii_serialization(),
        account_id: bound.account.to_owned(),
        mode: AuthMode::BrowserSession,
    };
    bound.pin_credential_identity(format!("page:{handle}"), &auth)?;
    Ok(handle)
}

fn safe_link(base: &Url, value: &str) -> Result<(), ConnectorError> {
    if value.len() > 32_768 || value.chars().any(char::is_control) {
        return Err(ConnectorError::UnsafeUrl);
    }
    let mut rest = value;
    while let Some((_, tail)) = rest.split_once('<') {
        let (target, next) = tail.split_once('>').ok_or(ConnectorError::UnsafeUrl)?;
        let url = base.join(target).map_err(|_| ConnectorError::UnsafeUrl)?;
        if url.origin() != base.origin()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || url.query_pairs().any(|(key, _)| {
                let key = key.to_ascii_lowercase();
                [
                    "token",
                    "ticket",
                    "signature",
                    "password",
                    "credential",
                    "session",
                    "secret",
                    "auth",
                ]
                .iter()
                .any(|word| key.contains(word))
                    || matches!(key.as_str(), "api_key" | "apikey" | "sig" | "verifier")
                    || key.starts_with("x-amz-")
                    || key.starts_with("x-goog-")
            })
        {
            return Err(ConnectorError::UnsafeUrl);
        }
        rest = next;
    }
    Ok(())
}

fn response_headers(value: &Value, base: &Url) -> Result<Vec<(String, String)>, ConnectorError> {
    let pairs: Vec<(&str, &str)> = match value {
        Value::Null => Vec::new(),
        Value::Object(object) if object.len() <= 64 => object
            .iter()
            .map(|(key, value)| {
                value
                    .as_str()
                    .map(|s| (key.as_str(), s))
                    .ok_or(ConnectorError::TransportUnavailable)
            })
            .collect::<Result<_, _>>()?,
        Value::Array(array) if array.len() <= 64 => array
            .iter()
            .map(|pair| {
                let pair = pair
                    .as_array()
                    .filter(|p| p.len() == 2)
                    .ok_or(ConnectorError::TransportUnavailable)?;
                Ok((
                    pair[0]
                        .as_str()
                        .ok_or(ConnectorError::TransportUnavailable)?,
                    pair[1]
                        .as_str()
                        .ok_or(ConnectorError::TransportUnavailable)?,
                ))
            })
            .collect::<Result<_, ConnectorError>>()?,
        _ => return Err(ConnectorError::TransportUnavailable),
    };
    let mut headers = Vec::new();
    for (key, value) in pairs {
        let key = key.to_ascii_lowercase();
        match key.as_str() {
            "link" => safe_link(base, value)?,
            "content-type" if value.len() <= 1024 && !value.chars().any(char::is_control) => {}
            "content-type" => return Err(ConnectorError::TransportUnavailable),
            _ => continue,
        }
        headers.push((key, value.to_owned()));
    }
    Ok(headers)
}

pub(crate) async fn execute(
    bound: &BoundTransport<'_>,
    input: ConnectorRequest,
) -> Result<ConnectorResponse, ConnectorError> {
    if input.method != HttpMethod::Get || input.body.is_some() {
        return Err(ConnectorError::CapabilityUnavailable);
    }
    if input.headers.iter().any(|(key, value)| {
        key.eq_ignore_ascii_case("accept")
            && value.split([',', ';']).any(|mime| {
                matches!(
                    mime.trim().to_ascii_lowercase().as_str(),
                    "application/x-protobuf" | "application/protobuf" | "application/octet-stream"
                )
            })
    }) {
        // The current platform contract returns text. Explicit bytes require a
        // byte-capable page port, never response.text() or a native fallback.
        return Err(ConnectorError::CapabilityUnavailable);
    }
    let started = tokio::time::Instant::now();
    let handle = verify(bound, &input.url).await?;
    let remaining = Duration::from_secs(15).saturating_sub(started.elapsed());
    if remaining.is_zero() {
        return Err(ConnectorError::Timeout);
    }
    let grant = current_grant(bound, &input.url)?;
    let mut headers = BTreeMap::new();
    for (key, value) in input.headers {
        if !key.eq_ignore_ascii_case("accept")
            || value.len() > 1024
            || value.chars().any(char::is_control)
        {
            return Err(ConnectorError::PermissionDenied);
        }
        headers.insert(key, value);
    }
    let result = tokio::time::timeout(
        remaining,
        bound.platform.call(
            "browser.request",
            json!({"principal":bound.principal,"grant":grant,"input":{
                "account_id":bound.account,"session_handle":handle,"url":input.url.as_str(),
                "method":"GET","headers":headers,"transport":"fetch",
                "deadline_epoch_ms":chrono::Utc::now().timestamp_millis()
                    + remaining.as_millis().min(i64::MAX as u128) as i64
            }}),
        ),
    )
    .await
    .map_err(|_| ConnectorError::Timeout)?
    .map_err(|error| provider_error(error, bound, &input.url))?;
    current_grant(bound, &input.url)?;
    let status = result["status"]
        .as_u64()
        .filter(|s| (100..=599).contains(s))
        .ok_or(ConnectorError::TransportUnavailable)? as u16;
    let final_url = result["url"]
        .as_str()
        .or_else(|| result["final_url"].as_str())
        .ok_or(ConnectorError::UnsafeUrl)?;
    let final_url = Url::parse(final_url).map_err(|_| ConnectorError::UnsafeUrl)?;
    if final_url.origin() != input.url.origin()
        || !final_url.username().is_empty()
        || final_url.password().is_some()
        || final_url.fragment().is_some()
    {
        return Err(ConnectorError::UnsafeUrl);
    }
    let body = result["body"]
        .as_str()
        .ok_or(ConnectorError::TransportUnavailable)?;
    if body.len() > 2 * 1024 * 1024 {
        return Err(ConnectorError::LimitExceeded);
    }
    Ok(ConnectorResponse {
        status,
        headers: response_headers(&result["headers"], &final_url)?,
        final_url,
        body: body.as_bytes().to_vec(),
    })
}
