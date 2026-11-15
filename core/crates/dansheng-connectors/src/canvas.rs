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

/// Course roster whitelist. Never retain email, login/SIS IDs, avatars or grades.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasCourseUser {
    pub id: CanvasId,
    pub name: String,
    pub short_name: Option<String>,
    #[serde(default, deserialize_with = "null_vec")]
    pub enrollments: Vec<CanvasCourseUserEnrollment>,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasCourseUserEnrollment {
    #[serde(rename = "type")]
    pub enrollment_type: String,
    pub role: Option<String>,
    pub role_id: Option<CanvasId>,
    pub enrollment_state: Option<String>,
    pub course_id: Option<CanvasId>,
    pub course_section_id: Option<CanvasId>,
    pub user_id: Option<CanvasId>,
}

/// Conversations API whitelist: message text is inert data; signed URLs,
/// avatars, UUIDs and arbitrary remote fields are never retained.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasRecipient {
    pub id: CanvasId,
    pub name: Option<String>,
    pub full_name: Option<String>,
    pub common_courses: Option<HashMap<CanvasId, Vec<String>>>,
    pub common_groups: Option<HashMap<CanvasId, Vec<String>>>,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasConversationMessage {
    pub id: CanvasId,
    pub author_id: Option<CanvasId>,
    pub body: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub generated: Option<bool>,
    #[serde(default, deserialize_with = "null_vec")]
    pub attachments: Vec<CanvasLearningAttachment>,
    #[serde(default, deserialize_with = "null_vec")]
    pub forwarded_messages: Vec<CanvasConversationMessage>,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasConversation {
    pub id: CanvasId,
    pub subject: Option<String>,
    pub workflow_state: Option<String>,
    pub last_message: Option<String>,
    pub last_message_at: Option<DateTime<Utc>>,
    pub message_count: Option<u64>,
    pub subscribed: Option<bool>,
    pub private: Option<bool>,
    pub starred: Option<bool>,
    pub visible: Option<bool>,
    pub context_name: Option<String>,
    #[serde(default, deserialize_with = "null_vec")]
    pub audience: Vec<CanvasId>,
    #[serde(default, deserialize_with = "null_vec")]
    pub participants: Vec<CanvasRecipient>,
    #[serde(default, deserialize_with = "null_vec")]
    pub messages: Vec<CanvasConversationMessage>,
}

// Debug must not print private message bodies, subjects or recipient names.
macro_rules! private_canvas_debug {
    ($($ty:ty),+ $(,)?) => {$ (
        impl std::fmt::Debug for $ty {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.debug_struct(stringify!($ty)).finish_non_exhaustive()
            }
        }
    )+};
}
private_canvas_debug!(
    CanvasCourseUser,
    CanvasCourseUserEnrollment,
    CanvasRecipient,
    CanvasConversationMessage,
    CanvasConversation
);

/// Separate from read errors: once a POST is dispatched, an unconfirmed result
/// must never be interpreted as permission to retry.
#[derive(Debug, thiserror::Error)]
pub enum CanvasWriteError {
    #[error(transparent)]
    Rejected(#[from] ConnectorError),
    #[error("Canvas send outcome is unknown; reconcile before sending again")]
    NeedsReconciliation,
}

fn conversation_id(id: &str) -> Result<(), ConnectorError> {
    if id.is_empty() || id.len() > 32 || !id.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ConnectorError::InvalidConfiguration("Canvas id"));
    }
    Ok(())
}

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

/// Classic Quizzes metadata only. New Quizzes use a separate LTI/New Quizzes API;
/// this connector never launches an attempt or requests questions/access codes.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CanvasQuiz {
    pub id: CanvasId,
    pub title: String,
    pub course_id: Option<CanvasId>,
    pub description: Option<String>,
    pub quiz_type: Option<String>,
    pub assignment_id: Option<CanvasId>,
    pub assignment_group_id: Option<CanvasId>,
    pub time_limit: Option<u32>,
    pub allowed_attempts: Option<i32>,
    pub question_count: Option<u32>,
    pub points_possible: Option<f64>,
    pub due_at: Option<DateTime<Utc>>,
    pub unlock_at: Option<DateTime<Utc>>,
    pub lock_at: Option<DateTime<Utc>>,
    pub published: Option<bool>,
    pub locked_for_user: Option<bool>,
    pub html_url: Option<String>,
    pub updated_at: Option<DateTime<Utc>>,
    pub permissions: Option<CanvasLearningPermissions>,
}

/// Retain read permission only, never teacher actions or authentication material.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasLearningPermissions {
    pub read: Option<bool>,
}

/// Metadata intentionally excludes download/preview/avatar/feed URLs and verifier tokens.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasLearningAttachment {
    pub id: Option<CanvasId>,
    pub display_name: Option<String>,
    pub filename: Option<String>,
    #[serde(rename = "content-type", alias = "content_type")]
    pub content_type: Option<String>,
    pub size: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasDiscussionTopic {
    pub id: CanvasId,
    pub title: String,
    pub course_id: Option<CanvasId>,
    pub context_code: Option<String>,
    /// Plain text derived from HTML; no active tags or URL attributes survive.
    pub message: Option<String>,
    pub html_url: Option<String>,
    pub posted_at: Option<DateTime<Utc>>,
    pub last_reply_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub discussion_type: Option<String>,
    pub discussion_subentry_count: Option<u64>,
    pub read_state: Option<String>,
    pub require_initial_post: Option<bool>,
    pub user_can_see_posts: Option<bool>,
    pub locked: Option<bool>,
    pub locked_for_user: Option<bool>,
    pub is_announcement: Option<bool>,
    pub permissions: Option<CanvasLearningPermissions>,
    #[serde(default, deserialize_with = "null_vec")]
    pub attachments: Vec<CanvasLearningAttachment>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasDiscussionEntry {
    pub id: CanvasId,
    pub user_id: Option<CanvasId>,
    pub parent_id: Option<CanvasId>,
    pub message: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub deleted: Option<bool>,
    #[serde(default, deserialize_with = "null_vec")]
    pub replies: Vec<CanvasDiscussionEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasDiscussionParticipant {
    pub id: CanvasId,
    pub display_name: Option<String>,
}

/// A server-authorized cached view, without changing any entry's read state.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasDiscussionView {
    pub view: Vec<CanvasDiscussionEntry>,
    #[serde(default)]
    pub participants: Vec<CanvasDiscussionParticipant>,
    #[serde(default)]
    pub unread_entries: Vec<CanvasId>,
    #[serde(default)]
    pub forced_entries: Vec<CanvasId>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasGradingRules {
    pub drop_lowest: Option<u32>,
    pub drop_highest: Option<u32>,
    #[serde(default)]
    pub never_drop: Vec<CanvasId>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CanvasAssignmentGroup {
    pub id: CanvasId,
    pub name: String,
    pub course_id: Option<CanvasId>,
    pub position: Option<u32>,
    pub group_weight: Option<f64>,
    pub rules: Option<CanvasGradingRules>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanvasSubmissionComment {
    pub id: CanvasId,
    pub author_id: Option<CanvasId>,
    pub author_name: Option<String>,
    pub comment: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
}

/// Current authenticated user's submission only. Authentication fields, preview
/// URLs, grader/admin data and raw nested user/course objects are not retained.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CanvasSelfSubmission {
    pub assignment_id: CanvasId,
    pub user_id: CanvasId,
    pub course_id: Option<CanvasId>,
    pub attempt: Option<u32>,
    pub body: Option<String>,
    pub grade: Option<String>,
    pub score: Option<f64>,
    pub grade_matches_current_submission: Option<bool>,
    pub submission_type: Option<String>,
    pub workflow_state: Option<String>,
    pub submitted_at: Option<DateTime<Utc>>,
    pub graded_at: Option<DateTime<Utc>>,
    pub posted_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub late: Option<bool>,
    pub missing: Option<bool>,
    pub excused: Option<bool>,
    pub assignment_visible: Option<bool>,
    pub html_url: Option<String>,
    #[serde(default, deserialize_with = "null_vec")]
    pub attachments: Vec<CanvasLearningAttachment>,
    #[serde(default, deserialize_with = "null_vec")]
    pub submission_comments: Vec<CanvasSubmissionComment>,
}

/// Published grades returned for this user. Unposted, SIS and observer data are ignored.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CanvasGrades {
    pub current_grade: Option<String>,
    pub final_grade: Option<String>,
    pub current_score: Option<f64>,
    pub final_score: Option<f64>,
    pub current_points: Option<f64>,
    pub html_url: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CanvasSelfEnrollment {
    pub id: CanvasId,
    pub course_id: CanvasId,
    pub user_id: CanvasId,
    pub course_section_id: Option<CanvasId>,
    #[serde(rename = "type")]
    pub enrollment_type: String,
    pub enrollment_state: Option<String>,
    pub role: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub grades: Option<CanvasGrades>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CanvasGradeSummary {
    pub enrollment_id: CanvasId,
    pub course_id: CanvasId,
    pub user_id: CanvasId,
    pub enrollment_state: Option<String>,
    pub grades: Option<CanvasGrades>,
}

fn null_vec<'de, D: Deserializer<'de>, R: Deserialize<'de>>(
    deserializer: D,
) -> Result<Vec<R>, D::Error> {
    Ok(Option::<Vec<R>>::deserialize(deserializer)?.unwrap_or_default())
}

/// HTML is converted to inert visible text. Attributes (including signed URLs),
/// script/style/template contents and active embedded resources are discarded.
fn learning_text(value: &mut Option<String>, max_bytes: usize) -> Result<(), ConnectorError> {
    let Some(raw) = value.take() else {
        return Ok(());
    };
    if raw.len() > max_bytes {
        return Err(ConnectorError::LimitExceeded);
    }
    let fragment = scraper::Html::parse_fragment(&raw);
    let text = fragment
        .root_element()
        .descendants()
        .filter_map(|node| {
            let text = node.value().as_text()?;
            if node.ancestors().any(|ancestor| {
                ancestor.value().as_element().is_some_and(|element| {
                    matches!(
                        element.name(),
                        "script" | "style" | "template" | "iframe" | "object" | "embed"
                    )
                })
            }) {
                return None;
            }
            Some(text.to_string())
        })
        .collect::<Vec<_>>()
        .join(" ");
    // Escaping also makes text safe if a consumer accidentally treats it as HTML.
    let text = text
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    if text.len() > max_bytes {
        return Err(ConnectorError::LimitExceeded);
    }
    *value = Some(text);
    Ok(())
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
        // Roster Links may change pagination, never the search or included fields.
        let roster =
            collection_path.starts_with("/api/v1/courses/") && collection_path.ends_with("/users");
        let roster_query = |candidate: &Url| {
            let mut pairs: Vec<_> = candidate
                .query_pairs()
                .filter(|(key, _)| !matches!(key.as_ref(), "page" | "per_page" | "cursor"))
                .map(|(key, value)| (key.into_owned(), value.into_owned()))
                .collect();
            pairs.sort();
            pairs
        };
        let expected_roster_query = roster_query(&initial_url);
        // Conversation/search pagination must retain the requested audience and
        // search scope. Reject a widened Link before making the next request.
        let conversation_query: Vec<_> = initial_url
            .query_pairs()
            .filter(|(key, _)| matches!(key.as_ref(), "filter[]" | "context" | "type" | "search"))
            .map(|(key, value)| (key.into_owned(), value.into_owned()))
            .collect();
        let conversation_scope = |candidate: &Url| {
            if roster && roster_query(candidate) != expected_roster_query {
                return false;
            }
            if !matches!(
                collection_path.as_str(),
                "/api/v1/conversations" | "/api/v1/search/recipients"
            ) {
                return true;
            }
            let mut expected = conversation_query.clone();
            let mut actual: Vec<_> = candidate
                .query_pairs()
                .filter(|(key, _)| {
                    matches!(
                        key.as_ref(),
                        "filter" | "filter[]" | "context" | "type" | "search"
                    ) || key.starts_with("filter[")
                        || key.starts_with("types[")
                })
                .map(|(key, value)| (key.into_owned(), value.into_owned()))
                .collect();
            expected.sort();
            actual.sort();
            actual == expected
        };
        // A self-only enrollment query must stay self-only on every server Link
        // and final redirect; dropping its filter would expose a course roster.
        let user_filter = initial_url
            .query_pairs()
            .find(|(key, _)| key == "user_id")
            .map(|(_, value)| value.into_owned());
        let self_only = |candidate: &Url| {
            user_filter.as_ref().is_none_or(|expected| {
                let filters: Vec<_> = candidate
                    .query_pairs()
                    .filter(|(key, _)| key == "user_id" || key.starts_with("user_id["))
                    .collect();
                filters.len() == 1 && filters[0].0 == "user_id" && filters[0].1 == expected.as_str()
            })
        };
        let mut next = Some(initial_url);
        let mut visited = HashSet::new();
        let mut result = Vec::new();
        while let Some(url) = next {
            if url.path() != collection_path || !self_only(&url) || !conversation_scope(&url) {
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
            if response.final_url.path() != collection_path
                || !self_only(&response.final_url)
                || !conversation_scope(&response.final_url)
            {
                return Err(ConnectorError::UnsafeUrl);
            }
            let page: Vec<R> = parse_list(&response.body)?;
            if page.len() > self.limits.max_items.saturating_sub(result.len()) {
                return Err(ConnectorError::LimitExceeded);
            }
            next = next_page(&response.headers, &response.final_url, &self.origin)?;
            if let Some(ref next_url) = next
                && (next_url.path() != collection_path
                    || !self_only(next_url)
                    || !conversation_scope(next_url))
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

    /// GET /conversations follows opaque Link pagination. No course means the
    /// Canvas default inbox (all non-archived conversations).
    pub async fn conversations(
        &self,
        source: &SourceContext,
        course_id: Option<&str>,
    ) -> Result<Vec<SourceRecord<CanvasConversation>>, ConnectorError> {
        let mut url = self
            .origin
            .join("/api/v1/conversations?per_page=100")
            .map_err(|_| ConnectorError::UnsafeUrl)?;
        if let Some(id) = course_id {
            conversation_id(id)?;
            url.query_pairs_mut()
                .append_pair("filter[]", &format!("course_{id}"));
        }
        let rows: Vec<CanvasConversation> = self.list(url.as_str(), source).await?;
        let mut seen = HashSet::new();
        rows.into_iter()
            .map(|row| {
                if !seen.insert(row.id.clone()) {
                    return Err(parse_error("Canvas", "duplicate conversation id"));
                }
                Ok(source.record(
                    format!("conversation:{}", row.id.0),
                    row.last_message_at,
                    row,
                ))
            })
            .collect()
    }

    /// Explicitly suppress Canvas's default read-state mutation.
    pub async fn conversation(
        &self,
        source: &SourceContext,
        id: &str,
    ) -> Result<SourceRecord<CanvasConversation>, ConnectorError> {
        conversation_id(id)?;
        let url = self
            .origin
            .join(&format!(
                "/api/v1/conversations/{id}?auto_mark_as_read=false"
            ))
            .map_err(|_| ConnectorError::UnsafeUrl)?;
        let row: CanvasConversation = self.get(url, source).await?;
        if row.id.0 != id {
            return Err(parse_error("Canvas", "conversation id mismatch"));
        }
        Ok(source.record(format!("conversation:{id}"), row.last_message_at, row))
    }

    /// User-only search, scoped to the selected course; never substitutes a roster.
    pub async fn recipients(
        &self,
        source: &SourceContext,
        course_id: &str,
        search: &str,
    ) -> Result<Vec<SourceRecord<CanvasRecipient>>, ConnectorError> {
        conversation_id(course_id)?;
        if search.len() > 1024 || search.chars().any(char::is_control) {
            return Err(ConnectorError::InvalidConfiguration(
                "Canvas recipient search",
            ));
        }
        let mut url = self
            .origin
            .join("/api/v1/search/recipients?per_page=100")
            .map_err(|_| ConnectorError::UnsafeUrl)?;
        url.query_pairs_mut()
            .append_pair("context", &format!("course_{course_id}"))
            .append_pair("type", "user")
            .append_pair("search", search);
        let rows: Vec<CanvasRecipient> = self.list(url.as_str(), source).await?;
        let mut seen = HashSet::new();
        rows.into_iter()
            .map(|row| {
                if !seen.insert(row.id.clone()) {
                    return Err(parse_error("Canvas", "duplicate recipient id"));
                }
                Ok(source.record(format!("recipient:{}", row.id.0), None, row))
            })
            .collect()
    }

    /// GET the authorized roster; search terms and roster results are not cached.
    pub async fn course_users(
        &self,
        source: &SourceContext,
        course_id: &str,
        search: Option<&str>,
    ) -> Result<Vec<SourceRecord<CanvasCourseUser>>, ConnectorError> {
        let path = self.course_path(course_id, "users")?;
        let mut url = self
            .origin
            .join(&path)
            .map_err(|_| ConnectorError::UnsafeUrl)?;
        url.query_pairs_mut()
            .append_pair("include[]", "enrollments");
        if let Some(search) = search {
            if search.len() > 256 || search.chars().any(char::is_control) {
                return Err(ConnectorError::InvalidConfiguration("Canvas roster search"));
            }
            if !search.trim().is_empty() {
                url.query_pairs_mut()
                    .append_pair("search_term", search.trim());
            }
        }
        let rows: Vec<CanvasCourseUser> = self.list(url.as_str(), source).await?;
        let mut seen = HashSet::new();
        for row in &rows {
            if !seen.insert(&row.id) {
                return Err(parse_error("Canvas", "duplicate course user id"));
            }
            if row.enrollments.len() > self.limits.max_items {
                return Err(ConnectorError::LimitExceeded);
            }
            for enrollment in &row.enrollments {
                if enrollment
                    .course_id
                    .as_ref()
                    .is_some_and(|id| id.0 != course_id)
                    || enrollment.user_id.as_ref().is_some_and(|id| id != &row.id)
                {
                    return Err(parse_error("Canvas", "roster enrollment context"));
                }
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| source.record(format!("course-user:{course_id}:{}", row.id.0), None, row))
            .collect())
    }

    fn validate_send(&self, source: &SourceContext, body: &str) -> Result<(), ConnectorError> {
        source.validate()?;
        // Page contexts have no trusted CSRF facility. Native session writes are
        // separately opt-in at the transport and restricted to the school origin.
        if self.access == CanvasAccess::BrowserSession
            || (self.access == CanvasAccess::HostSession
                && self.origin.origin().ascii_serialization() != "https://elearning.fudan.edu.cn")
        {
            return Err(ConnectorError::CapabilityUnavailable);
        }
        if body.trim().is_empty() || body.len() > self.limits.max_body_bytes || body.contains('\0')
        {
            return Err(ConnectorError::InvalidConfiguration("Canvas message body"));
        }
        Ok(())
    }

    async fn post_conversation<R: for<'de> Deserialize<'de>>(
        &self,
        source: &SourceContext,
        path: &str,
        form: Vec<(String, String)>,
    ) -> Result<R, CanvasWriteError> {
        let url = safe_api_url(
            self.origin
                .join(path)
                .map_err(|_| ConnectorError::UnsafeUrl)?,
            &self.origin,
        )?;
        let (auth, mode) = self.auth_for_source(source);
        let body = url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs(form)
            .finish();
        // Exactly one dispatch. Even revoked authority after dispatch can hide a
        // successful send, so transport failures are conservatively uncertain.
        let request = ConnectorRequest {
            method: HttpMethod::Post,
            url: url.clone(),
            auth,
            headers: vec![
                ("Accept".into(), "application/json".into()),
                (
                    "Content-Type".into(),
                    "application/x-www-form-urlencoded".into(),
                ),
            ],
            body: Some(body.into_bytes()),
        };
        let response = if self.access == CanvasAccess::HostSession {
            self.transport.execute_canvas_session_write(request).await
        } else {
            self.transport
                .execute(request)
                .await
                .map_err(|_| CanvasWriteError::NeedsReconciliation)
        }?;
        if safe_api_url(response.final_url.clone(), &self.origin).is_err()
            || response.final_url.path() != url.path()
        {
            return Err(CanvasWriteError::NeedsReconciliation);
        }
        // Only explicit client rejections are confirmed failures. Redirects,
        // timeout statuses, 5xx and malformed/oversized successes are uncertain.
        if (400..500).contains(&response.status) && response.status != 408 {
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
        }
        if !matches!(response.status, 200 | 201) || response.body.len() > self.limits.max_page_bytes
        {
            return Err(CanvasWriteError::NeedsReconciliation);
        }
        serde_json::from_slice(&response.body).map_err(|_| CanvasWriteError::NeedsReconciliation)
    }

    /// POST /conversations/:id/add_message sends to all existing participants.
    pub async fn reply_conversation(
        &self,
        source: &SourceContext,
        id: &str,
        body: &str,
    ) -> Result<SourceRecord<CanvasConversation>, CanvasWriteError> {
        conversation_id(id)?;
        self.validate_send(source, body)?;
        let row: CanvasConversation = self
            .post_conversation(
                source,
                &format!("/api/v1/conversations/{id}/add_message"),
                vec![("body".into(), body.into())],
            )
            .await?;
        if row.id.0 != id || row.messages.is_empty() {
            return Err(CanvasWriteError::NeedsReconciliation);
        }
        Ok(source.record(format!("conversation:{id}"), row.last_message_at, row))
    }

    /// POST /conversations. One new thread; multiple explicit user IDs form a
    /// group, never a course-wide/bulk broadcast or asynchronous batch.
    pub async fn create_conversation(
        &self,
        source: &SourceContext,
        course_id: &str,
        recipients: &[CanvasId],
        subject: &str,
        body: &str,
    ) -> Result<Vec<SourceRecord<CanvasConversation>>, CanvasWriteError> {
        conversation_id(course_id)?;
        self.validate_send(source, body)?;
        if recipients.is_empty()
            || recipients.len() > 100
            || subject.trim().is_empty()
            || subject.chars().count() > 255
            || subject.chars().any(char::is_control)
        {
            return Err(ConnectorError::InvalidConfiguration(
                "Canvas conversation recipients/subject",
            )
            .into());
        }
        let mut unique = HashSet::new();
        let mut form = vec![
            ("context_code".into(), format!("course_{course_id}")),
            ("subject".into(), subject.into()),
            ("body".into(), body.into()),
            ("force_new".into(), "true".into()),
            (
                "group_conversation".into(),
                (recipients.len() > 1).to_string(),
            ),
        ];
        for id in recipients {
            conversation_id(&id.0)?;
            if !unique.insert(&id.0) {
                return Err(
                    ConnectorError::InvalidConfiguration("duplicate Canvas recipient").into(),
                );
            }
            form.push(("recipients[]".into(), id.0.clone()));
        }
        let rows: Vec<CanvasConversation> = self
            .post_conversation(source, "/api/v1/conversations", form)
            .await?;
        if rows.len() != 1 {
            return Err(CanvasWriteError::NeedsReconciliation);
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("conversation:{}", row.id.0),
                    row.last_message_at,
                    row,
                )
            })
            .collect())
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

    fn learning_url(
        &self,
        course_id: &str,
        collection: &str,
        id: &str,
    ) -> Result<Url, ConnectorError> {
        let _ = self.course_path(course_id, collection)?;
        if id.is_empty() || id.len() > 32 || !id.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(ConnectorError::InvalidConfiguration("Canvas resource id"));
        }
        safe_api_url(
            self.origin
                .join(&format!("/api/v1/courses/{course_id}/{collection}/{id}"))
                .map_err(|_| ConnectorError::UnsafeUrl)?,
            &self.origin,
        )
    }

    fn learning_link(&self, link: &mut Option<String>, course_id: &str) {
        *link = link
            .as_deref()
            .and_then(sanitize_external_url)
            .filter(|value| {
                Url::parse(value).is_ok_and(|url| {
                    url.origin() == self.origin.origin()
                        && url.path().starts_with(&format!("/courses/{course_id}/"))
                })
            });
    }

    fn check_learning_course(
        &self,
        returned: &Option<CanvasId>,
        course_id: &str,
    ) -> Result<(), ConnectorError> {
        if returned.as_ref().is_some_and(|id| id.0 != course_id) {
            return Err(parse_error("Canvas", "learning course_id"));
        }
        Ok(())
    }

    fn sanitize_quiz(&self, quiz: &mut CanvasQuiz, course_id: &str) -> Result<(), ConnectorError> {
        self.check_learning_course(&quiz.course_id, course_id)?;
        if quiz
            .permissions
            .as_ref()
            .is_some_and(|permissions| permissions.read == Some(false))
        {
            return Err(ConnectorError::PermissionDenied);
        }
        learning_text(&mut quiz.description, self.limits.max_body_bytes)?;
        self.learning_link(&mut quiz.html_url, course_id);
        Ok(())
    }

    /// List Classic Quizzes metadata. This never requests quiz questions or creates attempts.
    pub async fn quizzes(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasQuiz>>, ConnectorError> {
        let mut rows: Vec<CanvasQuiz> = self
            .list(&self.course_path(course_id, "quizzes")?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &mut rows {
            if !seen.insert(row.id.0.clone()) {
                return Err(parse_error("Canvas", "duplicate quiz id"));
            }
            self.sanitize_quiz(row, course_id)?;
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("quiz:{course_id}:{}", row.id.0),
                    row.updated_at,
                    row,
                )
            })
            .collect())
    }

    pub async fn quiz(
        &self,
        source: &SourceContext,
        course_id: &str,
        quiz_id: &str,
    ) -> Result<SourceRecord<CanvasQuiz>, ConnectorError> {
        let mut row: CanvasQuiz = self
            .get(self.learning_url(course_id, "quizzes", quiz_id)?, source)
            .await?;
        if row.id.0 != quiz_id {
            return Err(parse_error("Canvas", "quiz id mismatch"));
        }
        self.sanitize_quiz(&mut row, course_id)?;
        Ok(source.record(
            format!("quiz:{course_id}:{}", row.id.0),
            row.updated_at,
            row,
        ))
    }

    fn sanitize_topic(
        &self,
        topic: &mut CanvasDiscussionTopic,
        course_id: &str,
    ) -> Result<(), ConnectorError> {
        self.check_learning_course(&topic.course_id, course_id)?;
        if topic
            .context_code
            .as_ref()
            .is_some_and(|code| code != &format!("course_{course_id}"))
        {
            return Err(parse_error("Canvas", "discussion context_code"));
        }
        if topic
            .permissions
            .as_ref()
            .is_some_and(|permissions| permissions.read == Some(false))
        {
            return Err(ConnectorError::PermissionDenied);
        }
        if topic.attachments.len() > self.limits.max_items {
            return Err(ConnectorError::LimitExceeded);
        }
        learning_text(&mut topic.message, self.limits.max_body_bytes)?;
        self.learning_link(&mut topic.html_url, course_id);
        Ok(())
    }

    pub async fn discussion_topics(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasDiscussionTopic>>, ConnectorError> {
        let mut rows: Vec<CanvasDiscussionTopic> = self
            .list(&self.course_path(course_id, "discussion_topics")?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &mut rows {
            if !seen.insert(row.id.0.clone()) {
                return Err(parse_error("Canvas", "duplicate discussion id"));
            }
            self.sanitize_topic(row, course_id)?;
        }
        // Announcements already have a dedicated service and must not be duplicated.
        Ok(rows
            .into_iter()
            .filter(|row| row.is_announcement != Some(true))
            .map(|row| {
                let updated = row.updated_at.or(row.last_reply_at).or(row.posted_at);
                source.record(format!("discussion:{course_id}:{}", row.id.0), updated, row)
            })
            .collect())
    }

    pub async fn discussion_topic(
        &self,
        source: &SourceContext,
        course_id: &str,
        topic_id: &str,
    ) -> Result<SourceRecord<CanvasDiscussionTopic>, ConnectorError> {
        let mut row: CanvasDiscussionTopic = self
            .get(
                self.learning_url(course_id, "discussion_topics", topic_id)?,
                source,
            )
            .await?;
        if row.id.0 != topic_id {
            return Err(parse_error("Canvas", "discussion id mismatch"));
        }
        self.sanitize_topic(&mut row, course_id)?;
        Ok(source.record(
            format!("discussion:{course_id}:{}", row.id.0),
            row.updated_at.or(row.last_reply_at).or(row.posted_at),
            row,
        ))
    }

    /// GET the cached authorized thread without PUT/POSTing any read-state update.
    /// require_initial_post/locked access is preserved; never post to unlock a view.
    pub async fn discussion_view(
        &self,
        source: &SourceContext,
        course_id: &str,
        topic_id: &str,
    ) -> Result<SourceRecord<CanvasDiscussionView>, ConnectorError> {
        let topic = self.discussion_topic(source, course_id, topic_id).await?;
        if topic.payload.locked_for_user == Some(true)
            || topic.payload.user_can_see_posts == Some(false)
        {
            return Err(ConnectorError::CourseAccessDenied);
        }
        let mut url = self.learning_url(course_id, "discussion_topics", topic_id)?;
        url.set_path(&format!("{}/view", url.path()));
        let mut view: CanvasDiscussionView = self.get(url, source).await?;
        if view.participants.len() > self.limits.max_items
            || view.unread_entries.len() > self.limits.max_items
            || view.forced_entries.len() > self.limits.max_items
        {
            return Err(ConnectorError::LimitExceeded);
        }
        let mut participants = HashSet::new();
        for participant in &view.participants {
            if !participants.insert(&participant.id) {
                return Err(parse_error("Canvas", "duplicate participant id"));
            }
        }
        fn clean_entries(
            entries: &mut [CanvasDiscussionEntry],
            parent: Option<&CanvasId>,
            depth: usize,
            seen: &mut HashSet<CanvasId>,
            limits: CanvasLimits,
        ) -> Result<(), ConnectorError> {
            if depth > 32 {
                return Err(ConnectorError::LimitExceeded);
            }
            for entry in entries {
                if !seen.insert(entry.id.clone()) {
                    return Err(parse_error("Canvas", "duplicate discussion entry id"));
                }
                if seen.len() > limits.max_items {
                    return Err(ConnectorError::LimitExceeded);
                }
                if entry
                    .parent_id
                    .as_ref()
                    .is_some_and(|id| Some(id) != parent)
                {
                    return Err(parse_error("Canvas", "discussion parent_id"));
                }
                if entry.deleted == Some(true) {
                    entry.message = None;
                    entry.user_id = None;
                }
                learning_text(&mut entry.message, limits.max_body_bytes)?;
                clean_entries(&mut entry.replies, Some(&entry.id), depth + 1, seen, limits)?;
            }
            Ok(())
        }
        clean_entries(&mut view.view, None, 0, &mut HashSet::new(), self.limits)?;
        Ok(source.record(
            format!("discussion-view:{course_id}:{topic_id}"),
            topic.updated_at,
            view,
        ))
    }

    pub async fn assignment_groups(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasAssignmentGroup>>, ConnectorError> {
        let rows: Vec<CanvasAssignmentGroup> = self
            .list(&self.course_path(course_id, "assignment_groups")?, source)
            .await?;
        let mut seen = HashSet::new();
        for row in &rows {
            self.check_learning_course(&row.course_id, course_id)?;
            if !seen.insert(&row.id) {
                return Err(parse_error("Canvas", "duplicate assignment group id"));
            }
            if row
                .rules
                .as_ref()
                .is_some_and(|rules| rules.never_drop.len() > self.limits.max_items)
            {
                return Err(ConnectorError::LimitExceeded);
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("assignment-group:{course_id}:{}", row.id.0),
                    None,
                    row,
                )
            })
            .collect())
    }

    async fn current_user_id(&self, source: &SourceContext) -> Result<CanvasId, ConnectorError> {
        #[derive(Deserialize)]
        struct Identity {
            id: CanvasId,
        }
        let identity: Identity = self
            .get(
                self.origin
                    .join("/api/v1/users/self/profile")
                    .map_err(|_| ConnectorError::UnsafeUrl)?,
                source,
            )
            .await?;
        Ok(identity.id)
    }

    /// No caller-provided student ID is accepted. Both path and returned identity
    /// are constrained to the authenticated user; profile data is never retained.
    pub async fn self_submission(
        &self,
        source: &SourceContext,
        course_id: &str,
        assignment_id: &str,
    ) -> Result<SourceRecord<CanvasSelfSubmission>, ConnectorError> {
        let mut url = self.learning_url(course_id, "assignments", assignment_id)?;
        url.set_path(&format!("{}/submissions/self", url.path()));
        url.set_query(Some("include[]=submission_comments&include[]=visibility"));
        let user_id = self.current_user_id(source).await?;
        let mut row: CanvasSelfSubmission = self.get(url, source).await?;
        if row.user_id != user_id {
            return Err(ConnectorError::PermissionDenied);
        }
        if row.assignment_id.0 != assignment_id {
            return Err(parse_error("Canvas", "submission assignment_id"));
        }
        self.check_learning_course(&row.course_id, course_id)?;
        if row.assignment_visible == Some(false) {
            return Err(ConnectorError::CourseAccessDenied);
        }
        if row.attachments.len() > self.limits.max_items
            || row.submission_comments.len() > self.limits.max_items
        {
            return Err(ConnectorError::LimitExceeded);
        }
        learning_text(&mut row.body, self.limits.max_body_bytes)?;
        for comment in &mut row.submission_comments {
            learning_text(&mut comment.comment, self.limits.max_body_bytes)?;
        }
        self.learning_link(&mut row.html_url, course_id);
        Ok(source.record(
            format!("submission-self:{course_id}:{assignment_id}"),
            row.updated_at.or(row.graded_at).or(row.submitted_at),
            row,
        ))
    }

    /// Course-scoped self enrollments. Do not return a roster, observed students,
    /// SIS identifiers or teacher-only unposted grades even if the server sends them.
    pub async fn self_enrollments(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasSelfEnrollment>>, ConnectorError> {
        let _ = self.course_path(course_id, "enrollments")?;
        let user_id = self.current_user_id(source).await?;
        let mut rows: Vec<CanvasSelfEnrollment> = self
            .list(
                &format!(
                    "/api/v1/courses/{course_id}/enrollments?user_id={}&per_page=100",
                    user_id.0
                ),
                source,
            )
            .await?;
        let mut seen = HashSet::new();
        for row in &mut rows {
            if row.user_id != user_id {
                return Err(ConnectorError::PermissionDenied);
            }
            if row.course_id.0 != course_id {
                return Err(parse_error("Canvas", "enrollment course_id"));
            }
            if !seen.insert(row.id.clone()) {
                return Err(parse_error("Canvas", "duplicate enrollment id"));
            }
            if let Some(grades) = &mut row.grades {
                self.learning_link(&mut grades.html_url, course_id);
            }
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                source.record(
                    format!("enrollment-self:{course_id}:{}", row.id.0),
                    row.updated_at,
                    row,
                )
            })
            .collect())
    }

    /// Server-provided student grades, preserving missing/redacted values and
    /// separate section enrollments. This performs no synthetic GPA calculation.
    pub async fn self_grade_summary(
        &self,
        source: &SourceContext,
        course_id: &str,
    ) -> Result<Vec<SourceRecord<CanvasGradeSummary>>, ConnectorError> {
        Ok(self
            .self_enrollments(source, course_id)
            .await?
            .into_iter()
            .filter(|record| record.payload.enrollment_type == "StudentEnrollment")
            .map(|record| {
                let row = record.payload;
                source.record(
                    format!("grade-self:{course_id}:{}", row.id.0),
                    record.updated_at,
                    CanvasGradeSummary {
                        enrollment_id: row.id,
                        course_id: row.course_id,
                        user_id: row.user_id,
                        enrollment_state: row.enrollment_state,
                        grades: row.grades,
                    },
                )
            })
            .collect())
    }
}
