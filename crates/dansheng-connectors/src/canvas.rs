// SPDX-License-Identifier: GPL-3.0-or-later
// Pagination and source mapping adapted from Chang-Yo/Dela e82da12f,
// src/main/canvas/api.ts. Copyright (C) Dela authors and contributors.
// See ../NOTICE.md. Authentication and storage are exclusively host responsibilities.
use crate::models::{SourceContext, SourceRecord};
use crate::transport::{check_response, parse_error};
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::{HashMap, HashSet};
use url::Url;

/// Preserve Canvas IDs as decimal strings, including IDs above JS's safe-integer range.
#[derive(Clone, Debug, Serialize, PartialEq, Eq, Hash)]
#[serde(transparent)]
pub struct CanvasId(pub String);

impl<'de> Deserialize<'de> for CanvasId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        let id = match value {
            serde_json::Value::String(s) => s,
            serde_json::Value::Number(n) if n.is_u64() => n.to_string(),
            _ => return Err(serde::de::Error::custom("invalid Canvas id")),
        };
        if id.is_empty() || id.len() > 32 || !id.bytes().all(|c| c.is_ascii_digit()) {
            return Err(serde::de::Error::custom("invalid Canvas id"));
        }
        Ok(Self(id))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasTerm {
    pub id: CanvasId,
    pub name: String,
    pub start_at: Option<DateTime<Utc>>,
    pub end_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasCourse {
    pub id: CanvasId,
    /// Canvas may redact these fields for restricted enrollments.
    pub name: Option<String>,
    pub course_code: Option<String>,
    pub workflow_state: Option<String>,
    pub term: Option<CanvasTerm>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CanvasAssignment {
    pub id: CanvasId,
    pub course_id: CanvasId,
    pub name: String,
    pub due_at: Option<DateTime<Utc>>,
    pub unlock_at: Option<DateTime<Utc>>,
    pub lock_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub points_possible: Option<f64>,
    #[serde(default)]
    pub submission_types: Vec<String>,
    pub published: Option<bool>,
    pub locked_for_user: Option<bool>,
    pub has_submitted_submissions: Option<bool>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub html_url: Option<String>,
}

/// File/material metadata only. Ignore `url`, `thumbnail_url`, `preview_url`,
/// verifier tokens, and raw HTML. Resolve downloads through a separate host grant.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasMaterial {
    pub id: CanvasId,
    pub folder_id: Option<CanvasId>,
    pub display_name: String,
    pub filename: String,
    #[serde(rename = "content-type")]
    pub content_type: Option<String>,
    pub size: Option<u64>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub locked_for_user: Option<bool>,
    pub hidden_for_user: Option<bool>,
}

/// Folder metadata preserving parent-child directory hierarchy.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasFolder {
    pub id: CanvasId,
    #[serde(default)]
    pub parent_folder_id: Option<CanvasId>,
    pub name: String,
    #[serde(default)]
    pub full_name: Option<String>,
    #[serde(default)]
    pub context_id: Option<CanvasId>,
    #[serde(default)]
    pub context_type: Option<String>,
    #[serde(default)]
    pub files_count: Option<u64>,
    #[serde(default)]
    pub folders_count: Option<u64>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub locked: Option<bool>,
    #[serde(default)]
    pub hidden: Option<bool>,
    #[serde(default)]
    pub locked_for_user: Option<bool>,
    #[serde(default)]
    pub hidden_for_user: Option<bool>,
    #[serde(default)]
    pub for_submissions: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasModule {
    pub id: CanvasId,
    pub name: String,
    #[serde(default)]
    pub position: Option<u32>,
    #[serde(default)]
    pub unlock_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub require_sequential_progress: Option<bool>,
    #[serde(default)]
    pub prerequisite_module_ids: Vec<CanvasId>,
    #[serde(default)]
    pub items_count: Option<u32>,
    #[serde(default)]
    pub workflow_state: Option<String>,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub completed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub published: Option<bool>,
    #[serde(default)]
    pub course_id: Option<CanvasId>,
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
}

/// Module item preserving content/page references and sanitizing unsafe external URLs.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasModuleItem {
    pub id: CanvasId,
    #[serde(default)]
    pub module_id: Option<CanvasId>,
    #[serde(default)]
    pub position: Option<u32>,
    pub title: String,
    #[serde(default)]
    pub indent: Option<u32>,
    #[serde(rename = "type", alias = "item_type")]
    pub item_type: String,
    #[serde(default)]
    pub content_id: Option<CanvasId>,
    #[serde(default, alias = "page_url", alias = "slug")]
    pub page_slug: Option<String>,
    #[serde(default)]
    pub external_url: Option<String>,
    #[serde(default)]
    pub published: Option<bool>,
}

impl CanvasModuleItem {
    pub fn sanitize(&mut self) {
        self.external_url = self.external_url.as_deref().and_then(sanitize_external_url);
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasPageSummary {
    #[serde(default)]
    pub page_id: Option<CanvasId>,
    #[serde(alias = "url", alias = "slug")]
    pub page_slug: String,
    pub title: String,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub published: Option<bool>,
    #[serde(default)]
    pub front_page: Option<bool>,
    #[serde(default)]
    pub locked_for_user: Option<bool>,
    #[serde(default)]
    pub context_id: Option<CanvasId>,
    #[serde(default)]
    pub context_type: Option<String>,
}

impl CanvasPageSummary {
    pub fn url(&self) -> &str {
        &self.page_slug
    }
}

/// Detailed page with HTML body kept as inert data (never executed, no external fetches).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasPage {
    #[serde(default)]
    pub page_id: Option<CanvasId>,
    #[serde(alias = "url", alias = "slug")]
    pub page_slug: String,
    pub title: String,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub published: Option<bool>,
    #[serde(default)]
    pub front_page: Option<bool>,
    #[serde(default)]
    pub locked_for_user: Option<bool>,
    #[serde(default)]
    pub lock_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub editing_roles: Option<String>,
    #[serde(default)]
    pub context_id: Option<CanvasId>,
    #[serde(default)]
    pub context_type: Option<String>,
    #[serde(default)]
    pub html_url: Option<String>,
}

impl CanvasPage {
    pub fn url(&self) -> &str {
        &self.page_slug
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasAnnouncement {
    pub id: CanvasId,
    pub title: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub posted_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub delayed_post_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_reply_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub read_state: Option<String>,
    #[serde(default)]
    pub context_code: Option<String>,
    #[serde(default)]
    pub workflow_state: Option<String>,
    #[serde(default)]
    pub locked: Option<bool>,
    #[serde(default)]
    pub user_name: Option<String>,
    #[serde(default)]
    pub course_id: Option<CanvasId>,
}

/// Distinct construction modes select distinct host transport paths. This is not
/// a fallback list. HostSession uses native HTTP cookies; BrowserSession explicitly
/// requires page-context execution. No authentication/transport failure switches modes.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CanvasAccess {
    HostToken,
    HostSession,
    BrowserSession,
}

#[derive(Clone, Copy, Debug)]
pub struct CanvasLimits {
    pub max_pages: usize,
    pub max_items: usize,
    pub max_page_bytes: usize,
    pub max_body_bytes: usize,
}

impl Default for CanvasLimits {
    fn default() -> Self {
        Self {
            max_pages: 100,
            max_items: 50_000,
            max_page_bytes: 8 * 1024 * 1024,
            max_body_bytes: 2 * 1024 * 1024,
        }
    }
}

pub struct CanvasClient<T> {
    transport: T,
    origin: Url,
    access: CanvasAccess,
    limits: CanvasLimits,
}

fn origin(origin: &str) -> Result<Url, ConnectorError> {
    let url =
        Url::parse(origin).map_err(|_| ConnectorError::InvalidConfiguration("Canvas origin"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ConnectorError::InvalidConfiguration("Canvas HTTPS origin"));
    }
    Ok(url)
}

fn credential_query_key(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.starts_with("x-amz-")
        || name.starts_with("x-goog-")
        || matches!(
            name.as_str(),
            "access_token"
                | "token"
                | "authorization"
                | "session_token"
                | "verifier"
                | "signature"
                | "sig"
                | "api_key"
                | "apikey"
                | "credential"
                | "security-token"
        )
}
fn safe_api_url(candidate: Url, origin: &Url) -> Result<Url, ConnectorError> {
    if candidate.origin() != origin.origin()
        || !candidate.username().is_empty()
        || candidate.password().is_some()
        || candidate.fragment().is_some()
        || !candidate.path().starts_with("/api/v1/")
        // Credentials must never enter request URLs, even if returned by a server.
        || candidate.query_pairs().any(|(k, _)| credential_query_key(&k))
    {
        return Err(ConnectorError::UnsafeUrl);
    }
    // Encoded separators and traversal must not bypass the API path boundary at a proxy.
    let path = candidate.path().to_ascii_lowercase();
    if path.contains("%2f") || path.contains("%5c") || path.contains("%25") {
        return Err(ConnectorError::UnsafeUrl);
    }
    Ok(candidate)
}

fn sanitize_external_url(raw: &str) -> Option<String> {
    let parsed = Url::parse(raw).ok()?;
    if parsed.scheme() != "https" && parsed.scheme() != "http" {
        return None;
    }
    if parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    if parsed.query_pairs().any(|(k, _)| credential_query_key(&k)) {
        return None;
    }
    Some(parsed.into())
}

/// Split Link fields only outside URI references and quoted parameter values.
/// A comma in an opaque cursor or title is not a link separator.
fn link_entries(header: &str) -> Result<Vec<&str>, ConnectorError> {
    let mut entries = Vec::new();
    let (mut start, mut in_uri, mut quoted, mut escaped) = (0, false, false, false);
    for (offset, c) in header.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if quoted && c == '\\' {
            escaped = true;
            continue;
        }
        if !in_uri && c == '"' {
            quoted = !quoted;
        } else if !quoted {
            match c {
                '<' if !in_uri => in_uri = true,
                '>' if in_uri => in_uri = false,
                ',' if !in_uri => {
                    entries.push(header[start..offset].trim());
                    start = offset + 1;
                }
                _ => (),
            }
        }
    }
    if in_uri || quoted || escaped {
        return Err(parse_error("Canvas", "Link"));
    }
    entries.push(header[start..].trim());
    Ok(entries)
}

/// Follow the server's opaque rel=next URL; do not infer page numbers, page size,
/// or a last page. Supports repeated/case-insensitive headers and relation lists.
pub fn next_page(
    headers: &[(String, String)],
    current: &Url,
    configured_origin: &Url,
) -> Result<Option<Url>, ConnectorError> {
    let mut next = None;
    for (_, value) in headers
        .iter()
        .filter(|(name, _)| name.eq_ignore_ascii_case("link"))
    {
        for entry in link_entries(value)? {
            if entry.is_empty() {
                continue;
            }
            let rest = entry
                .strip_prefix('<')
                .ok_or_else(|| parse_error("Canvas", "Link"))?;
            let (target, params) = rest
                .split_once('>')
                .ok_or_else(|| parse_error("Canvas", "Link"))?;
            // Quoted values may contain semicolons, so scan parameters with a tiny lexer.
            let mut segments = Vec::new();
            let (mut start, mut quoted, mut escaped) = (0, false, false);
            for (i, c) in params.char_indices() {
                if escaped {
                    escaped = false;
                    continue;
                }
                if quoted && c == '\\' {
                    escaped = true;
                    continue;
                }
                if c == '"' {
                    quoted = !quoted;
                }
                if c == ';' && !quoted {
                    segments.push(&params[start..i]);
                    start = i + 1;
                }
            }
            segments.push(&params[start..]);
            let mut is_next = false;
            for param in segments {
                if let Some((key, value)) = param.trim().split_once('=')
                    && key.trim().eq_ignore_ascii_case("rel")
                {
                    is_next |= value
                        .trim()
                        .trim_matches('"')
                        .split_ascii_whitespace()
                        .any(|rel| rel.eq_ignore_ascii_case("next"));
                }
            }
            if is_next {
                let url = current
                    .join(target)
                    .map_err(|_| ConnectorError::UnsafeUrl)?;
                let url = safe_api_url(url, configured_origin)?;
                if next.as_ref().is_some_and(|existing| existing != &url) {
                    return Err(parse_error("Canvas", "multiple next links"));
                }
                next = Some(url);
            }
        }
    }
    Ok(next)
}

fn parse_list<T: for<'de> Deserialize<'de>>(body: &[u8]) -> Result<Vec<T>, ConnectorError> {
    // Deserialize only known fields. Do not retain raw remote responses or echo serde errors.
    serde_json::from_slice(body).map_err(|_| parse_error("Canvas", "list JSON"))
}

pub fn parse_courses(body: &[u8]) -> Result<Vec<CanvasCourse>, ConnectorError> {
    parse_list(body)
}
pub fn parse_assignments(body: &[u8]) -> Result<Vec<CanvasAssignment>, ConnectorError> {
    parse_list(body)
}
pub fn parse_materials(body: &[u8]) -> Result<Vec<CanvasMaterial>, ConnectorError> {
    parse_list(body)
}
pub fn parse_folders(body: &[u8]) -> Result<Vec<CanvasFolder>, ConnectorError> {
    parse_list(body)
}
pub fn parse_modules(body: &[u8]) -> Result<Vec<CanvasModule>, ConnectorError> {
    parse_list(body)
}
pub fn parse_module_items(body: &[u8]) -> Result<Vec<CanvasModuleItem>, ConnectorError> {
    let mut items: Vec<CanvasModuleItem> = parse_list(body)?;
    for item in &mut items {
        item.sanitize();
    }
    Ok(items)
}
pub fn parse_pages(body: &[u8]) -> Result<Vec<CanvasPageSummary>, ConnectorError> {
    parse_list(body)
}
pub fn parse_page(body: &[u8]) -> Result<CanvasPage, ConnectorError> {
    serde_json::from_slice(body).map_err(|_| parse_error("Canvas", "page JSON"))
}
pub fn parse_announcements(body: &[u8]) -> Result<Vec<CanvasAnnouncement>, ConnectorError> {
    parse_list(body)
}

impl<T: ConnectorTransport> CanvasClient<T> {
    pub fn new(
        transport: T,
        configured_origin: &str,
        access: CanvasAccess,
    ) -> Result<Self, ConnectorError> {
        Ok(Self {
            transport,
            origin: origin(configured_origin)?,
            access,
            limits: CanvasLimits::default(),
        })
    }

    pub fn with_limits(mut self, limits: CanvasLimits) -> Result<Self, ConnectorError> {
        if limits.max_pages == 0
            || limits.max_items == 0
            || limits.max_page_bytes == 0
            || limits.max_body_bytes == 0
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas limits"));
        }
        self.limits = limits;
        Ok(self)
    }

    pub fn configured_origin(&self) -> &Url {
        &self.origin
    }

    fn auth_for_source(&self, source: &SourceContext) -> (TransportAuth, AuthMode) {
        match self.access {
            CanvasAccess::HostToken => (
                TransportAuth::HostToken {
                    account_id: source.account_id.clone(),
                },
                AuthMode::Token,
            ),
            CanvasAccess::HostSession => (
                TransportAuth::HostSession {
                    account_id: source.account_id.clone(),
                },
                AuthMode::HttpSession,
            ),
            CanvasAccess::BrowserSession => (
                TransportAuth::BrowserSession {
                    account_id: source.account_id.clone(),
                },
                AuthMode::BrowserSession,
            ),
        }
    }

    async fn list<R: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        source: &SourceContext,
    ) -> Result<Vec<R>, ConnectorError> {
        source.validate()?;
        let initial_url = safe_api_url(
            self.origin
                .join(path)
                .map_err(|_| ConnectorError::UnsafeUrl)?,
            &self.origin,
        )?;
        let collection_path = initial_url.path().to_owned();
        let mut next = Some(initial_url);
        let mut visited = HashSet::new();
        let mut result = Vec::new();
        while let Some(url) = next {
            if url.path() != collection_path {
                return Err(ConnectorError::UnsafeUrl);
            }
            if !visited.insert(url.as_str().to_owned()) {
                return Err(ConnectorError::PaginationCycle);
            }
            if visited.len() > self.limits.max_pages {
                return Err(ConnectorError::LimitExceeded);
            }
            let (auth, mode) = self.auth_for_source(source);
            let response = self
                .transport
                .execute(ConnectorRequest {
                    method: HttpMethod::Get,
                    url: url.clone(),
                    headers: vec![("Accept".into(), "application/json".into())],
                    body: None,
                    auth,
                })
                .await?;
            check_response(
                &response,
                &self.origin,
                AuthChallenge {
                    connector: "canvas".into(),
                    origin: self.origin.origin().ascii_serialization(),
                    account_id: source.account_id.clone(),
                    mode,
                },
                self.limits.max_page_bytes,
            )?;
            // A same-origin non-API redirect is not a successful Canvas data response either.
            safe_api_url(response.final_url.clone(), &self.origin)?;
            if response.final_url.path() != collection_path {
                return Err(ConnectorError::UnsafeUrl);
            }
            let page: Vec<R> = parse_list(&response.body)?;
            if page.len() > self.limits.max_items.saturating_sub(result.len()) {
                return Err(ConnectorError::LimitExceeded);
            }
            next = next_page(&response.headers, &response.final_url, &self.origin)?;
            if let Some(ref next_url) = next
                && next_url.path() != collection_path
            {
                return Err(ConnectorError::UnsafeUrl);
            }
            result.extend(page);
        }
        // A later-page failure never returns an apparently complete partial snapshot.
        Ok(result)
    }

    async fn get<R: for<'de> Deserialize<'de>>(
        &self,
        url: Url,
        source: &SourceContext,
    ) -> Result<R, ConnectorError> {
        source.validate()?;
        let url = safe_api_url(url, &self.origin)?;
        let expected_path = url.path().to_owned();
        let (auth, mode) = self.auth_for_source(source);
        let response = self
            .transport
            .execute(ConnectorRequest {
                method: HttpMethod::Get,
                url: url.clone(),
                headers: vec![("Accept".into(), "application/json".into())],
                body: None,
                auth,
            })
            .await?;
        check_response(
            &response,
            &self.origin,
            AuthChallenge {
                connector: "canvas".into(),
                origin: self.origin.origin().ascii_serialization(),
                account_id: source.account_id.clone(),
                mode,
            },
            self.limits.max_page_bytes,
        )?;
        safe_api_url(response.final_url.clone(), &self.origin)?;
        if response.final_url.path() != expected_path {
            return Err(ConnectorError::UnsafeUrl);
        }
        serde_json::from_slice(&response.body).map_err(|_| parse_error("Canvas", "item JSON"))
    }

    pub async fn courses(
        &self,
        source: &SourceContext,
    ) -> Result<Vec<SourceRecord<CanvasCourse>>, ConnectorError> {
        let rows: Vec<CanvasCourse> = self
            .list("/api/v1/courses?include[]=term&per_page=100", source)
            .await?;
        let mut seen = HashSet::new();
        for row in &rows {
            if !seen.insert(row.id.0.as_str()) {
                return Err(parse_error("Canvas", "duplicate course id"));
            }
        }
        Ok(rows
            .into_iter()
            .map(|course| {
                source.record(format!("course:{}", course.id.0), course.updated_at, course)
            })
            .collect())
    }

    fn course_path(&self, course_id: &str, collection: &str) -> Result<String, ConnectorError> {
        if course_id.is_empty()
            || course_id.len() > 32
            || !course_id.bytes().all(|c| c.is_ascii_digit())
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas course id"));
        }
        Ok(format!(
            "/api/v1/courses/{course_id}/{collection}?per_page=100"
        ))
    }

    pub async fn assignments(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasAssignment>>, ConnectorError> {
        let rows: Vec<CanvasAssignment> = self
            .list(&self.course_path(course_id, "assignments")?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &rows {
            if row.course_id.0 != course_id {
                return Err(parse_error("Canvas", "assignment course_id"));
            }
            if !seen.insert(row.id.0.as_str()) {
                return Err(parse_error("Canvas", "duplicate assignment id"));
            }
            if let Some(ref desc) = row.description
                && desc.len() > self.limits.max_body_bytes
            {
                return Err(ConnectorError::LimitExceeded);
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("assignment:{}:{}", course_id, row.id.0),
                    row.updated_at,
                    row,
                )
            })
            .collect())
    }

    /// Enumerate course files as material metadata, without downloading files or
    /// persisting signed storage URLs. Pagination is shared with courses/assignments.
    pub async fn materials(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasMaterial>>, ConnectorError> {
        let rows: Vec<CanvasMaterial> = self
            .list(&self.course_path(course_id, "files")?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &rows {
            if !seen.insert(row.id.0.as_str()) {
                return Err(parse_error("Canvas", "duplicate material id"));
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("file:{}:{}", course_id, row.id.0),
                    row.updated_at,
                    row,
                )
            })
            .collect())
    }

    /// Course folders preserving directory hierarchy and parent-child links.
    pub async fn folders(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasFolder>>, ConnectorError> {
        let rows: Vec<CanvasFolder> = self
            .list(&self.course_path(course_id, "folders")?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &rows {
            if !seen.insert(row.id.0.as_str()) {
                return Err(parse_error("Canvas", "duplicate folder id"));
            }
            if let Some(ref cid) = row.context_id
                && cid.0 != course_id
            {
                return Err(parse_error("Canvas", "folder context_id"));
            }
            if let Some(ref ctype) = row.context_type
                && !ctype.eq_ignore_ascii_case("Course")
            {
                return Err(parse_error("Canvas", "folder context_type"));
            }
        }

        // Verify folder parent-child hierarchy has no cycles
        let parent_map: HashMap<&str, &str> = rows
            .iter()
            .filter_map(|f| {
                f.parent_folder_id
                    .as_ref()
                    .map(|p| (f.id.0.as_str(), p.0.as_str()))
            })
            .collect();
        #[derive(Clone, Copy, PartialEq, Eq)]
        enum VisitState {
            Visiting,
            Done,
        }
        let mut states: HashMap<&str, VisitState> = HashMap::new();
        for start_id in rows.iter().map(|f| f.id.0.as_str()) {
            if states.get(start_id) == Some(&VisitState::Done) {
                continue;
            }
            let mut current = start_id;
            let mut path = Vec::new();
            loop {
                match states.get(current) {
                    Some(VisitState::Done) => break,
                    Some(VisitState::Visiting) => return Err(ConnectorError::PaginationCycle),
                    None => {
                        states.insert(current, VisitState::Visiting);
                        path.push(current);
                        if let Some(&parent) = parent_map.get(current) {
                            current = parent;
                        } else {
                            break;
                        }
                    }
                }
            }
            for node in path {
                states.insert(node, VisitState::Done);
            }
        }

        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("folder:{}:{}", course_id, row.id.0),
                    row.updated_at,
                    row,
                )
            })
            .collect())
    }

    pub async fn modules(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasModule>>, ConnectorError> {
        let rows: Vec<CanvasModule> = self
            .list(&self.course_path(course_id, "modules")?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &rows {
            if !seen.insert(row.id.0.as_str()) {
                return Err(parse_error("Canvas", "duplicate module id"));
            }
            if let Some(ref cid) = row.course_id
                && cid.0 != course_id
            {
                return Err(parse_error("Canvas", "module course_id"));
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("module:{}:{}", course_id, row.id.0),
                    row.updated_at,
                    row,
                )
            })
            .collect())
    }

    fn module_items_path(
        &self,
        course_id: &str,
        module_id: &str,
    ) -> Result<String, ConnectorError> {
        if course_id.is_empty()
            || course_id.len() > 32
            || !course_id.bytes().all(|c| c.is_ascii_digit())
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas course id"));
        }
        if module_id.is_empty()
            || module_id.len() > 32
            || !module_id.bytes().all(|c| c.is_ascii_digit())
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas module id"));
        }
        Ok(format!(
            "/api/v1/courses/{course_id}/modules/{module_id}/items?per_page=100"
        ))
    }

    pub async fn module_items(
        &self,
        source: &SourceContext,
        course_id: &str,
        module_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasModuleItem>>, ConnectorError> {
        let mut rows: Vec<CanvasModuleItem> = self
            .list(&self.module_items_path(course_id, module_id)?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &mut rows {
            if !seen.insert(row.id.0.clone()) {
                return Err(parse_error("Canvas", "duplicate module_item id"));
            }
            if let Some(ref mid) = row.module_id
                && mid.0 != module_id
            {
                return Err(parse_error("Canvas", "module_item module_id"));
            }
            row.sanitize();
        }
        Ok(rows
            .into_iter()
            .map(|row| source.record(format!("module-item:{}:{}", course_id, row.id.0), None, row))
            .collect())
    }

    pub async fn pages(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasPageSummary>>, ConnectorError> {
        let rows: Vec<CanvasPageSummary> = self
            .list(&self.course_path(course_id, "pages")?, source)
            .await?;
        let mut seen_slugs = HashSet::new();
        let mut seen_ids = HashSet::new();
        for row in &rows {
            if !seen_slugs.insert(row.page_slug.to_ascii_lowercase()) {
                return Err(parse_error("Canvas", "duplicate page slug"));
            }
            if let Some(ref pid) = row.page_id
                && !seen_ids.insert(pid.0.as_str())
            {
                return Err(parse_error("Canvas", "duplicate page id"));
            }
            if let Some(ref cid) = row.context_id
                && cid.0 != course_id
            {
                return Err(parse_error("Canvas", "page context_id"));
            }
            if let Some(ref ctype) = row.context_type
                && !ctype.eq_ignore_ascii_case("Course")
            {
                return Err(parse_error("Canvas", "page context_type"));
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("page:{}:{}", course_id, row.page_slug),
                    row.updated_at,
                    row,
                )
            })
            .collect())
    }

    fn page_url(&self, course_id: &str, page_slug: &str) -> Result<Url, ConnectorError> {
        if course_id.is_empty()
            || course_id.len() > 32
            || !course_id.bytes().all(|c| c.is_ascii_digit())
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas course id"));
        }
        let slug = page_slug.trim();
        if slug.is_empty()
            || slug.len() > 256
            || slug == "."
            || slug == ".."
            || slug.contains('/')
            || slug.contains('\\')
            || slug.bytes().any(|b| b < 0x20 || b == 0x7f)
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas page slug"));
        }
        let mut url = self.origin.clone();
        {
            let mut segments = url
                .path_segments_mut()
                .map_err(|_| ConnectorError::UnsafeUrl)?;
            segments
                .pop_if_empty()
                .push("api")
                .push("v1")
                .push("courses")
                .push(course_id)
                .push("pages")
                .push(slug);
        }
        safe_api_url(url, &self.origin)
    }

    /// Fetch a single page by slug. HTML body is kept purely as inert data.
    pub async fn page(
        &self,
        source: &SourceContext,
        course_id: &str,
        page_slug: &str,
    ) -> Result<SourceRecord<CanvasPage>, ConnectorError> {
        let url = self.page_url(course_id, page_slug)?;
        let page: CanvasPage = self.get(url, source).await?;
        if let Some(ref cid) = page.context_id
            && cid.0 != course_id
        {
            return Err(parse_error("Canvas", "page context_id"));
        }
        if let Some(ref ctype) = page.context_type
            && !ctype.eq_ignore_ascii_case("Course")
        {
            return Err(parse_error("Canvas", "page context_type"));
        }
        if !page.page_slug.eq_ignore_ascii_case(page_slug.trim()) {
            return Err(parse_error("Canvas", "page slug mismatch"));
        }
        if let Some(ref body) = page.body
            && body.len() > self.limits.max_body_bytes
        {
            return Err(ConnectorError::LimitExceeded);
        }
        Ok(source.record(
            format!("page:{}:{}", course_id, page.page_slug),
            page.updated_at,
            page,
        ))
    }

    pub async fn announcements(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasAnnouncement>>, ConnectorError> {
        if course_id.is_empty()
            || course_id.len() > 32
            || !course_id.bytes().all(|c| c.is_ascii_digit())
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas course id"));
        }
        let path = format!(
            "/api/v1/courses/{course_id}/discussion_topics?only_announcements=true&per_page=100"
        );
        let rows: Vec<CanvasAnnouncement> = self.list(&path, source).await?;
        let expected_context = format!("course_{course_id}");
        let mut seen = HashSet::new();
        for row in &rows {
            if !seen.insert(row.id.0.as_str()) {
                return Err(parse_error("Canvas", "duplicate announcement id"));
            }
            if let Some(ref cc) = row.context_code
                && cc != &expected_context
            {
                return Err(parse_error("Canvas", "announcement context_code"));
            }
            if let Some(ref cid) = row.course_id
                && cid.0 != course_id
            {
                return Err(parse_error("Canvas", "announcement course_id"));
            }
            if let Some(ref msg) = row.message
                && msg.len() > self.limits.max_body_bytes
            {
                return Err(ConnectorError::LimitExceeded);
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                let updated = row
                    .updated_at
                    .or(row.last_reply_at)
                    .or(row.posted_at)
                    .or(row.created_at);
                source.record(
                    format!("announcement:{}:{}", course_id, row.id.0),
                    updated,
                    row,
                )
            })
            .collect())
    }
}
