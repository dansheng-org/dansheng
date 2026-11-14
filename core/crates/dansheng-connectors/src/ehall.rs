// SPDX-License-Identifier: GPL-3.0-or-later
//! Fixed GET-only Fudan eHall catalog and task summaries.
//!
//! Public protocol discovery: 2026-11-09, getApp plus the official task component
//! index-PS69NXBl.js and dls.js. Private responses have not been live validated.
//! Form/flowchart/mobile URLs, contacts and applicant identity are intentionally
//! discarded. An internal reference identifies a summary; it is not a URL opener
//! or evidence of a complete approval history.

use crate::campus::{CampusError, Coverage, SourceBatch};
use crate::models::SourceContext;
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse,
    ConnectorTransport, HttpMethod, TransportAuth,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use url::Url;

pub const EHALL_ORIGIN: &str = "https://ehall.fudan.edu.cn";
pub const CATALOG_PATH: &str = "/appmarket/frontend/default/getApp";
pub const TASK_PATH: &str = "/personal/frontend/task";
pub const APPLICATION_PATH: &str = "/personal/frontend/task/apply";
pub const SOURCE_REVISION: &str = "fudan-ehall-public-protocol-2026-11-09";
pub const MAX_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_WIRE_ITEMS: usize = 2_000;
pub const MAX_PAGE_SIZE: u16 = 50;

fn changed(field: &'static str) -> CampusError {
    CampusError::SchemaChanged {
        domain: "ehall",
        field,
    }
}

fn validate_source(source: &SourceContext) -> Result<(), CampusError> {
    if source.account_id.trim().is_empty() || source.source_id.trim().is_empty() {
        return Err(ConnectorError::InvalidConfiguration("source identity").into());
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EhallService {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub description_state: EhallDescriptionState,
    pub category: Option<String>,
    /// Public, validated Fudan URLs only. Never grants permission to open/write.
    pub pc_url: Option<String>,
    pub mobile_url: Option<String>,
    /// An anonymous source hint, not an account grant or eligibility decision.
    pub access_hint: EhallAccessHint,
    pub internal_ref: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EhallDescriptionState {
    Present,
    Missing,
    OmittedUnsafe,
    OmittedTooLarge,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EhallAccessHint {
    Advertised,
    Restricted,
    Unknown,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum EhallTaskKind {
    Todo,
    Done,
    Application,
}

impl EhallTaskKind {
    fn label(self) -> &'static str {
        match self {
            Self::Todo => "todo",
            Self::Done => "done",
            Self::Application => "application",
        }
    }

    fn endpoint(self) -> (&'static str, &'static str) {
        match self {
            Self::Todo => (TASK_PATH, "todo"),
            Self::Done => (TASK_PATH, "done"),
            Self::Application => (APPLICATION_PATH, "all"),
        }
    }
}

/// Application status is separate from membership of the todo/done task queues.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum EhallApplicationStatus {
    InProgress,
    Terminated,
    Completed,
    Withdrawn,
    Unknown { code: Option<String> },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EhallTaskSummary {
    pub id: String,
    pub kind: EhallTaskKind,
    pub title: String,
    pub current_step: Option<String>,
    /// Preserves source-local text; a missing/ambiguous time is not invented.
    pub created_at: Option<String>,
    pub finished_at: Option<String>,
    /// Only application records carry a source application status.
    pub application_status: Option<EhallApplicationStatus>,
    pub internal_ref: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EhallPage {
    pub page: u32,
    pub page_size: u16,
}

impl EhallPage {
    pub fn validate(self) -> Result<(), CampusError> {
        if self.page == 0 || self.page > 10_000 || !(1..=MAX_PAGE_SIZE).contains(&self.page_size) {
            return Err(CampusError::InvalidQuery("ehall page"));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EhallReadBudget {
    pub max_pages: u16,
    pub max_items: usize,
    pub max_bytes: usize,
}

impl Default for EhallReadBudget {
    fn default() -> Self {
        Self {
            max_pages: 10,
            max_items: 500,
            max_bytes: 4 * 1024 * 1024,
        }
    }
}

impl EhallReadBudget {
    fn validate(self) -> Result<(), CampusError> {
        if !(1..=100).contains(&self.max_pages)
            || !(1..=5_000).contains(&self.max_items)
            || self.max_bytes == 0
            || self.max_bytes > 32 * 1024 * 1024
        {
            return Err(CampusError::InvalidQuery("ehall read budget"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "reason", rename_all = "snake_case")]
pub enum EhallReadStop {
    EndOfReportedList,
    UnverifiedEnd,
    Budget,
    DuplicateId,
    InconsistentPagination,
    Interrupted { failure: EhallReadFailure },
}

/// Redacted error classifications; never contains source m, URLs or credentials.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EhallReadFailure {
    Authentication,
    Permission,
    Timeout,
    Http { status: u16 },
    UnsafeResponse,
    Limit,
    SourceChanged,
    Transport,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct EhallTaskCollection {
    pub batch: SourceBatch<EhallTaskSummary>,
    /// Only true for a consistent, reported total reached starting at page one.
    pub complete: bool,
    pub pages_read: u16,
    pub bytes_read: usize,
    pub next_page: Option<u32>,
    pub stop: EhallReadStop,
}

struct TaskPage {
    batch: SourceBatch<EhallTaskSummary>,
    bytes: usize,
    total: Option<u64>,
    consistent_total: bool,
}

/// Transport owns account authentication, origin grants and per-request timeouts.
/// The catalog always uses Anonymous; personal reads explicitly use HostSession.
pub struct EhallClient<T> {
    transport: T,
}

impl<T: ConnectorTransport> EhallClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport }
    }

    async fn get(
        &self,
        source: &SourceContext,
        path: &'static str,
        parameters: &[(&str, String)],
        private: bool,
        byte_limit: usize,
    ) -> Result<ConnectorResponse, CampusError> {
        let mut url = Url::parse(EHALL_ORIGIN).expect("constant origin");
        url.set_path(path);
        url.query_pairs_mut()
            .extend_pairs(parameters.iter().map(|(k, v)| (*k, v)));
        let response = self
            .transport
            .execute(ConnectorRequest {
                method: HttpMethod::Get,
                url: url.clone(),
                headers: vec![
                    ("Accept".into(), "application/json".into()),
                    ("X-Requested-With".into(), "XMLHttpRequest".into()),
                    ("userLanguage".into(), "zh".into()),
                ],
                body: None,
                auth: if private {
                    TransportAuth::HostSession {
                        account_id: source.account_id.clone(),
                    }
                } else {
                    TransportAuth::Anonymous
                },
            })
            .await?;
        let challenge = challenge(source);
        if response.status == 401 || (300..400).contains(&response.status) {
            return Err(ConnectorError::AuthRequired(challenge).into());
        }
        if response.status == 403 {
            return Err(ConnectorError::PermissionDenied.into());
        }
        if !(200..300).contains(&response.status) {
            return Err(ConnectorError::HttpStatus(response.status).into());
        }
        if response.final_url.origin() != url.origin()
            || !response.final_url.username().is_empty()
            || response.final_url.password().is_some()
        {
            return Err(ConnectorError::UnsafeUrl.into());
        }
        if response.body.len() > byte_limit.min(MAX_RESPONSE_BYTES) {
            return Err(ConnectorError::LimitExceeded.into());
        }
        let lower = String::from_utf8_lossy(&response.body[..response.body.len().min(16_384)])
            .to_ascii_lowercase();
        if response.final_url.path() != path
            || ((lower.contains("<html") || lower.contains("<form") || lower.contains("<!doctype"))
                && (lower.contains("password")
                    || lower.contains("/login")
                    || lower.contains("统一身份认证")))
        {
            return Err(ConnectorError::AuthRequired(challenge).into());
        }
        Ok(response)
    }

    /// A bounded public catalog window. The real source ignores limit and reports
    /// total=0 with a non-empty list; no catalog response is claimed complete.
    pub async fn catalog(
        &self,
        source: &SourceContext,
        limit: u16,
    ) -> Result<SourceBatch<EhallService>, CampusError> {
        validate_source(source)?;
        if !(1..=100).contains(&limit) {
            return Err(CampusError::InvalidQuery("ehall catalog limit"));
        }
        let response = self
            .get(
                source,
                CATALOG_PATH,
                &[("type", "all".into()), ("limit", limit.to_string())],
                false,
                MAX_RESPONSE_BYTES,
            )
            .await?;
        let data = envelope(&response.body, source)?;
        let list = list(&data)?;
        let reported_total = total(&data)?;
        let mut ids = HashSet::new();
        let mut records = Vec::new();
        for raw in list {
            let row = raw.as_object().ok_or_else(|| changed("catalog.item"))?;
            let id = required_id(row, &["id"])?;
            if !ids.insert(id.clone()) {
                return Err(ConnectorError::PaginationCycle.into());
            }
            if records.len() < usize::from(limit) {
                let extra = row.get("extra_url").and_then(Value::as_object);
                let (description, description_state) = catalog_description(row)?;
                let entry = EhallService {
                    id: id.clone(),
                    title: required_text(row, "name", 512)?,
                    description,
                    description_state,
                    category: optional_text(row, "category_name", 256)?,
                    pc_url: extra.and_then(|v| v.get("pc_url")).and_then(public_url),
                    mobile_url: extra.and_then(|v| v.get("mobile_url")).and_then(public_url),
                    access_hint: match row.get("has_permission") {
                        Some(Value::Bool(true)) => EhallAccessHint::Advertised,
                        Some(Value::Bool(false)) => EhallAccessHint::Restricted,
                        Some(Value::String(v)) if v == "y" || v == "1" => {
                            EhallAccessHint::Advertised
                        }
                        Some(Value::String(v)) if v == "n" || v == "0" => {
                            EhallAccessHint::Restricted
                        }
                        _ => EhallAccessHint::Unknown,
                    },
                    internal_ref: internal_ref(source, "service", &id),
                };
                records.push(source.record(format!("ehall:service:{id}"), None, entry));
            }
        }
        Ok(SourceBatch {
            source: source.clone(),
            source_revision: SOURCE_REVISION.into(),
            records,
            coverage: Coverage::Window {
                position: format!(
                    "catalog:limit:{limit},wire:{},reported_total:{}",
                    list.len(),
                    reported_total.map_or_else(|| "unknown".into(), |n| n.to_string())
                ),
            },
        })
    }

    pub async fn tasks(
        &self,
        source: &SourceContext,
        kind: EhallTaskKind,
        page: EhallPage,
    ) -> Result<SourceBatch<EhallTaskSummary>, CampusError> {
        self.task_page(source, kind, page, MAX_RESPONSE_BYTES)
            .await
            .map(|v| v.batch)
    }

    async fn task_page(
        &self,
        source: &SourceContext,
        kind: EhallTaskKind,
        page: EhallPage,
        byte_limit: usize,
    ) -> Result<TaskPage, CampusError> {
        validate_source(source)?;
        page.validate()?;
        let (path, kind_parameter) = kind.endpoint();
        let response = self
            .get(
                source,
                path,
                &[
                    ("type", kind_parameter.into()),
                    ("page", page.page.to_string()),
                    ("pageSize", page.page_size.to_string()),
                ],
                true,
                byte_limit,
            )
            .await?;
        let data = envelope(&response.body, source)?;
        let rows = list(&data)?;
        if rows.len() > usize::from(page.page_size) {
            return Err(ConnectorError::LimitExceeded.into());
        }
        let total = total(&data)?;
        let offset = u64::from(page.page - 1) * u64::from(page.page_size);
        let end = offset + rows.len() as u64;
        let consistent_total = total.is_some_and(|t| {
            offset <= t && end <= t && (end == t || rows.len() == usize::from(page.page_size))
        });
        let mut records = Vec::with_capacity(rows.len());
        let mut ids = HashSet::new();
        for raw in rows {
            let row = raw.as_object().ok_or_else(|| changed("task.item"))?;
            let id = required_id(
                row,
                if kind == EhallTaskKind::Application {
                    &["id", "inst_id", "third_inst_id"]
                } else {
                    &["id", "task_id"]
                },
            )?;
            if !ids.insert(id.clone()) {
                return Err(ConnectorError::PaginationCycle.into());
            }
            let summary = EhallTaskSummary {
                id: id.clone(),
                kind,
                title: required_text(
                    row,
                    if kind == EhallTaskKind::Application {
                        "third_inst_name"
                    } else {
                        "task_name"
                    },
                    512,
                )?,
                current_step: optional_text(row, "node_name", 256)?,
                created_at: optional_text(
                    row,
                    if kind == EhallTaskKind::Application {
                        "inst_created"
                    } else {
                        "task_created"
                    },
                    64,
                )?,
                finished_at: if kind == EhallTaskKind::Done {
                    optional_text(row, "task_finished", 64)?
                } else {
                    None
                },
                application_status: if kind == EhallTaskKind::Application {
                    Some(application_status(row.get("inst_status"))?)
                } else {
                    None
                },
                internal_ref: internal_ref(source, kind.label(), &id),
            };
            records.push(source.record(format!("ehall:{}:{id}", kind.label()), None, summary));
        }
        let coverage = if consistent_total {
            Coverage::Page {
                next: total.filter(|t| end < *t).map(|_| page.page + 1),
                total,
            }
        } else {
            Coverage::Window {
                position: format!(
                    "{}:page:{},size:{},total:unverified",
                    kind.label(),
                    page.page,
                    page.page_size
                ),
            }
        };
        Ok(TaskPage {
            batch: SourceBatch {
                source: source.clone(),
                source_revision: SOURCE_REVISION.into(),
                records,
                coverage,
            },
            bytes: response.body.len(),
            total,
            consistent_total,
        })
    }

    /// Starts at page one with a fixed page size. Failures after the first page
    /// retain earlier records as an explicitly incomplete window; callers MUST
    /// NOT delete absent cached records using an incomplete collection.
    pub async fn collect_tasks(
        &self,
        source: &SourceContext,
        kind: EhallTaskKind,
        page_size: u16,
        budget: EhallReadBudget,
    ) -> Result<EhallTaskCollection, CampusError> {
        validate_source(source)?;
        EhallPage { page: 1, page_size }.validate()?;
        budget.validate()?;
        if usize::from(page_size) > budget.max_items {
            return Err(CampusError::InvalidQuery("ehall page exceeds item budget"));
        }
        let mut collection = EhallTaskCollection {
            batch: SourceBatch {
                source: source.clone(),
                source_revision: SOURCE_REVISION.into(),
                records: Vec::new(),
                coverage: Coverage::Window {
                    position: format!("{}:scan:incomplete", kind.label()),
                },
            },
            complete: false,
            pages_read: 0,
            bytes_read: 0,
            next_page: Some(1),
            stop: EhallReadStop::Budget,
        };
        let mut ids = HashSet::new();
        let mut expected_total = None;
        let mut all_consistent = true;
        loop {
            let page = collection.next_page.expect("loop has a next page");
            if collection.pages_read >= budget.max_pages
                || collection.batch.records.len() + usize::from(page_size) > budget.max_items
                || collection.bytes_read >= budget.max_bytes
            {
                return Ok(collection);
            }
            let result = self
                .task_page(
                    source,
                    kind,
                    EhallPage { page, page_size },
                    budget.max_bytes - collection.bytes_read,
                )
                .await;
            let response = match result {
                Ok(v) => v,
                Err(e) if collection.pages_read == 0 => return Err(e),
                Err(e) => {
                    collection.stop = match e {
                        CampusError::Transport(ConnectorError::PaginationCycle) => {
                            EhallReadStop::DuplicateId
                        }
                        _ => EhallReadStop::Interrupted {
                            failure: classify(&e),
                        },
                    };
                    return Ok(collection);
                }
            };
            collection.pages_read += 1;
            collection.bytes_read += response.bytes;
            if response
                .batch
                .records
                .iter()
                .any(|v| ids.contains(&v.external_id))
            {
                collection.stop = EhallReadStop::DuplicateId;
                return Ok(collection);
            }
            if page > 1 && response.total != expected_total {
                collection.stop = EhallReadStop::InconsistentPagination;
                return Ok(collection);
            }
            expected_total = response.total;
            all_consistent &= response.consistent_total;
            let count = response.batch.records.len();
            for record in response.batch.records {
                ids.insert(record.external_id.clone());
                collection.batch.records.push(record);
            }
            let reached_total =
                all_consistent && expected_total == Some(collection.batch.records.len() as u64);
            if reached_total {
                collection.complete = true;
                collection.batch.coverage = Coverage::Complete;
                collection.next_page = None;
                collection.stop = EhallReadStop::EndOfReportedList;
                return Ok(collection);
            }
            if count < usize::from(page_size) {
                collection.next_page = None;
                collection.stop = EhallReadStop::UnverifiedEnd;
                return Ok(collection);
            }
            collection.next_page = page.checked_add(1);
            if collection.next_page.is_none() {
                return Ok(collection);
            }
        }
    }
}

fn challenge(source: &SourceContext) -> AuthChallenge {
    AuthChallenge {
        connector: "fudan-ehall".into(),
        origin: EHALL_ORIGIN.into(),
        account_id: source.account_id.clone(),
        mode: AuthMode::HttpSession,
    }
}

fn envelope(body: &[u8], source: &SourceContext) -> Result<Map<String, Value>, CampusError> {
    let value: Value = serde_json::from_slice(body).map_err(|_| changed("json"))?;
    let error = value.get("e").ok_or_else(|| changed("envelope.e"))?;
    let code = match error {
        Value::Number(v) => v.as_i64().ok_or_else(|| changed("envelope.e"))?,
        Value::String(v) => v.parse::<i64>().map_err(|_| changed("envelope.e"))?,
        _ => return Err(changed("envelope.e")),
    };
    match code {
        0 => {}
        10013
            if value
                .pointer("/d/loginUrl")
                .and_then(Value::as_str)
                .is_some_and(|url| !url.is_empty() && url.len() <= 16_384) =>
        {
            // Observed AJAX authentication envelope. Discard the login URL and
            // message; they may contain tickets or signed redirect state.
            return Err(ConnectorError::AuthRequired(challenge(source)).into());
        }
        401 => return Err(ConnectorError::AuthRequired(challenge(source)).into()),
        403 => return Err(ConnectorError::PermissionDenied.into()),
        _ => return Err(changed("envelope.e")),
    }
    value
        .get("d")
        .and_then(Value::as_object)
        .cloned()
        .ok_or_else(|| changed("envelope.d"))
}

fn list(data: &Map<String, Value>) -> Result<&Vec<Value>, CampusError> {
    let list = data
        .get("list")
        .and_then(Value::as_array)
        .ok_or_else(|| changed("list"))?;
    if list.len() > MAX_WIRE_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(list)
}

fn total(data: &Map<String, Value>) -> Result<Option<u64>, CampusError> {
    match data.get("total") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(v)) => v.as_u64().map(Some).ok_or_else(|| changed("total")),
        Some(Value::String(v)) => v.parse::<u64>().map(Some).map_err(|_| changed("total")),
        _ => Err(changed("total")),
    }
}

fn required_id(row: &Map<String, Value>, fields: &[&str]) -> Result<String, CampusError> {
    let value = fields
        .iter()
        .find_map(|f| row.get(*f))
        .ok_or_else(|| changed("id"))?;
    let id = match value {
        Value::String(v) => v.clone(),
        Value::Number(v) if v.as_u64().is_some() => v.to_string(),
        _ => return Err(changed("id")),
    };
    if id.is_empty()
        || id.len() > 128
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.:".contains(&b))
    {
        return Err(changed("id"));
    }
    Ok(id)
}

fn optional_text(
    row: &Map<String, Value>,
    field: &str,
    limit: usize,
) -> Result<Option<String>, CampusError> {
    match row.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(v)) => {
            if v.len() > limit * 4 || v.chars().any(|c| c.is_control() && !c.is_whitespace()) {
                return Err(changed("text"));
            }
            let text = if v.contains('<') {
                let fragment = scraper::Html::parse_fragment(v);
                fragment
                    .root_element()
                    .descendants()
                    .filter_map(|node| {
                        let text = node.value().as_text()?;
                        if node.ancestors().any(|parent| {
                            parent.value().as_element().is_some_and(|element| {
                                matches!(
                                    element.name(),
                                    "script"
                                        | "style"
                                        | "template"
                                        | "noscript"
                                        | "iframe"
                                        | "object"
                                        | "embed"
                                        | "svg"
                                )
                            })
                        }) {
                            None
                        } else {
                            Some(text.to_string())
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            } else {
                v.clone()
            };
            let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
            if text.len() > limit * 4 || text.contains("https://") || text.contains("http://") {
                return Err(changed("text"));
            }
            Ok((!text.is_empty()).then_some(text))
        }
        _ => Err(changed("text")),
    }
}

fn catalog_description(
    row: &Map<String, Value>,
) -> Result<(Option<String>, EhallDescriptionState), CampusError> {
    match row.get("dsc") {
        None | Some(Value::Null) => Ok((None, EhallDescriptionState::Missing)),
        Some(Value::String(raw)) if raw.len() > 8_192 => {
            Ok((None, EhallDescriptionState::OmittedTooLarge))
        }
        Some(Value::String(_)) => match optional_text(row, "dsc", 2_048) {
            Ok(Some(text)) => Ok((Some(text), EhallDescriptionState::Present)),
            Ok(None) => Ok((None, EhallDescriptionState::Missing)),
            Err(CampusError::SchemaChanged { field: "text", .. }) => {
                // A real public description can contain long prose or a URL.
                // This optional field may be omitted without dropping the app.
                Ok((None, EhallDescriptionState::OmittedUnsafe))
            }
            Err(error) => Err(error),
        },
        _ => Err(changed("description.type")),
    }
}

fn required_text(
    row: &Map<String, Value>,
    field: &str,
    limit: usize,
) -> Result<String, CampusError> {
    optional_text(row, field, limit)?.ok_or_else(|| changed("title"))
}

fn application_status(value: Option<&Value>) -> Result<EhallApplicationStatus, CampusError> {
    let code = match value {
        None | Some(Value::Null) => None,
        Some(Value::String(v))
            if v.len() <= 64
                && v.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b)) =>
        {
            Some(v.clone())
        }
        Some(Value::Number(v)) => Some(v.to_string()),
        _ => return Err(changed("inst_status")),
    };
    Ok(match code.as_deref() {
        Some("0") => EhallApplicationStatus::InProgress,
        Some("1") => EhallApplicationStatus::Terminated,
        Some("2") => EhallApplicationStatus::Completed,
        Some("4") => EhallApplicationStatus::Withdrawn,
        _ => EhallApplicationStatus::Unknown { code },
    })
}

fn internal_ref(source: &SourceContext, kind: &str, id: &str) -> String {
    let bytes = serde_json::to_vec(&(&source.account_id, &source.source_id, kind, id))
        .expect("strings serialize");
    format!("ehall:{:x}", Sha256::digest(bytes))
}

fn public_url(value: &Value) -> Option<String> {
    let text = value.as_str()?;
    if text.len() > 2_048 {
        return None;
    }
    let url = Url::parse(text).ok()?;
    let host = url.host_str()?;
    if url.scheme() != "https"
        || !host.ends_with(".fudan.edu.cn")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    // Only documented public route selectors. Unknown/signed queries are omitted.
    let mut query_keys = HashSet::new();
    for (key, value) in url.query_pairs() {
        if !query_keys.insert(key.to_string()) {
            return None;
        }
        let numeric =
            !value.is_empty() && value.len() <= 10 && value.bytes().all(|b| b.is_ascii_digit());
        match key.as_ref() {
            "id" | "cate_id" if numeric => {}
            "type" if numeric || value == "all" => {}
            _ => return None,
        }
    }
    Some(url.to_string())
}

fn classify(error: &CampusError) -> EhallReadFailure {
    match error {
        CampusError::Transport(ConnectorError::AuthRequired(_)) => EhallReadFailure::Authentication,
        CampusError::Transport(ConnectorError::PermissionDenied) => EhallReadFailure::Permission,
        CampusError::Transport(ConnectorError::Timeout) => EhallReadFailure::Timeout,
        CampusError::Transport(ConnectorError::HttpStatus(status)) => {
            EhallReadFailure::Http { status: *status }
        }
        CampusError::Transport(ConnectorError::UnsafeUrl) => EhallReadFailure::UnsafeResponse,
        CampusError::Transport(ConnectorError::LimitExceeded) => EhallReadFailure::Limit,
        CampusError::SchemaChanged { .. } | CampusError::PaginationInconsistent => {
            EhallReadFailure::SourceChanged
        }
        _ => EhallReadFailure::Transport,
    }
}
