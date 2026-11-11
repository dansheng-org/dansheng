// SPDX-License-Identifier: GPL-3.0-or-later
//! Fudan OPAC public metadata and token-subject-scoped private loan summaries.
//!
//! Public singleVolume, smjlh detail and v2 holdings JSON were anonymously
//! validated on 2026-11-09. Private schemas are based on the official public
//! app.ea0f02cf08d19b244213.js, not a personal server capture. Only fixed GETs
//! are implemented. The host injects access_token; no credential value belongs
//! in these request objects. Reader names/barcodes/contact information and
//! arbitrary server URLs are never returned, cached or included in errors.

use crate::campus::{CampusError, Coverage, SourceBatch};
use crate::models::{SourceContext, SourceRecord};
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use chrono::{DateTime, NaiveDate, NaiveDateTime};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use url::Url;

pub const LIBRARY_ORIGIN: &str = "https://fdulspgw.fudan.edu.cn";
pub const OPAC_ORIGIN: &str = "https://opac.fudan.edu.cn";
/// Name only; BoundTransport must inject the account secret at the fixed origin.
pub const ACCESS_TOKEN_HEADER: &str = "access_token";
pub const SINGLE_VOLUME_PATH: &str = "/urdh/open-api/opac/search/singleVolume";
pub const BIBLIOGRAPHY_PREFIX: &str = "/urdh/open-api/opac/search/smjlh/";
pub const HOLDINGS_PATH: &str = "/alsp/open-api/opac/v2/holdings";
pub const READER_INFO_PATH: &str = "/alsp/open-api/elib5/getReaderInfo";
pub const CURRENT_LOANS_PATH: &str = "/alsp/open-api/elib5/getReaderCurrentLoan";
pub const HISTORY_LOANS_PATH: &str = "/alsp/open-api/elib5/v2/getReaderHistoryLoan";
pub const PUBLIC_REVISION: &str = "fudan-opac-public-json-2026-11-09";
pub const PRIVATE_REVISION: &str = "fudan-opac-private-static-only-2026-11-09";
pub const MAX_LIBRARY_BODY: usize = 2 * 1024 * 1024;
pub const MAX_LIBRARY_PAGE_SIZE: u16 = 50;
const MAX_WIRE_ITEMS: usize = 2_000;

#[derive(Clone, Debug, thiserror::Error, PartialEq, Eq)]
pub enum LibraryError {
    #[error(transparent)]
    Campus(#[from] CampusError),
    #[error(transparent)]
    Transport(#[from] ConnectorError),
    #[error("trusted host reader binding has not been verified")]
    IdentityUnverified,
    #[error("library token subject does not match the trusted account binding")]
    IdentityMismatch,
    #[error("library source record not found")]
    NotFound,
    #[error("private library protocol is unverified at {field}")]
    ProtocolUnverified { field: &'static str },
}

fn changed(field: &'static str) -> LibraryError {
    CampusError::SchemaChanged {
        domain: "library",
        field,
    }
    .into()
}

fn validate_source(source: &SourceContext) -> Result<(), LibraryError> {
    if source.account_id.trim().is_empty() || source.source_id.trim().is_empty() {
        return Err(ConnectorError::InvalidConfiguration("source identity").into());
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LibraryLookupKind {
    Barcode,
    CallNumber,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryVolumeMatch {
    pub catalogue_id: String,
    pub lookup_kind: LibraryLookupKind,
    pub official_url: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryBibliographicRecord {
    pub catalogue_id: String,
    pub title: String,
    pub authors: Vec<String>,
    pub publisher: Option<String>,
    pub publication_place: Option<String>,
    pub publication_year: Option<i32>,
    pub isbns: Vec<String>,
    pub resource_kind: Option<String>,
    /// Constructed from the public numeric ID and the observed base62 route.
    pub official_url: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LibraryDatePrecision {
    DateOnly,
    DateTimeWithoutZone,
    DateTimeWithExplicitZone,
    NumericUnknownUnit,
    Unclassified,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LibraryDateMeaning {
    Checkout,
    DueAsDisplayedByOfficialCurrentLoanUi,
    ExpectedReturnAsDisplayedByHoldingsUi,
    ReturnedAsDisplayedByOfficialHistoryUi,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibrarySourceDate {
    pub raw: String,
    pub source_field: String,
    pub precision: LibraryDatePrecision,
    pub meaning: LibraryDateMeaning,
    /// Always None unless the original text itself declares an offset/zone.
    /// No campus timezone is inferred by the connector.
    pub timezone: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryHolding {
    pub id: String,
    pub catalogue_id: String,
    pub call_number: Option<String>,
    pub permanent_library: Option<String>,
    pub permanent_location: Option<String>,
    pub temporary_library: Option<String>,
    pub temporary_location: Option<String>,
    pub item_status: String,
    pub item_status_name: Option<String>,
    /// Only the observed Available enum is normalized; other enums stay raw.
    pub known_available: bool,
    pub expected_return: Option<LibrarySourceDate>,
    pub volume_info: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryPage {
    pub page_no: u32,
    pub page_size: u16,
}

impl LibraryPage {
    pub fn validate(self) -> Result<(), LibraryError> {
        if self.page_no == 0
            || self.page_no > 10_000
            || !(1..=MAX_LIBRARY_PAGE_SIZE).contains(&self.page_size)
        {
            return Err(CampusError::InvalidQuery("library page").into());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LibraryIdentityState {
    /// getReaderInfo had a valid subject. The host must verify the intended user
    /// independently during visible authentication before persisting this ref.
    ObservedUnbound,
    MatchedTrustedFingerprint,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryReaderIdentity {
    /// Account-scoped digest of the server's reader barcode, not the barcode.
    pub reader_ref: String,
    pub state: LibraryIdentityState,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LibraryLoanKind {
    Current,
    History,
}

impl LibraryLoanKind {
    fn label(self) -> &'static str {
        match self {
            Self::Current => "current",
            Self::History => "history",
        }
    }
    fn path(self) -> &'static str {
        match self {
            Self::Current => CURRENT_LOANS_PATH,
            Self::History => HISTORY_LOANS_PATH,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LibraryLoanIdBasis {
    SourceId,
    AccountItemFingerprint,
    ContentFingerprint,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryLoan {
    pub kind: LibraryLoanKind,
    pub title: Option<String>,
    pub authors: Vec<String>,
    pub catalogue_id: Option<String>,
    pub item_ref: Option<String>,
    pub checkout: Option<LibrarySourceDate>,
    pub due: Option<LibrarySourceDate>,
    pub returned: Option<LibrarySourceDate>,
    pub renewal_count: Option<u32>,
    pub location: Option<String>,
    pub call_number: Option<String>,
    pub id_basis: LibraryLoanIdBasis,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct LibraryLoanPage {
    pub batch: SourceBatch<LibraryLoan>,
    pub identity: LibraryIdentityState,
    /// These schemas were observed in public code, not validated with real loans.
    pub protocol_live_validated: bool,
}

pub struct LibraryClient<T> {
    transport: T,
}

impl<T: ConnectorTransport> LibraryClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport }
    }

    async fn get(
        &self,
        source: &SourceContext,
        path: &str,
        parameters: &[(&str, String)],
        private: bool,
    ) -> Result<Value, LibraryError> {
        let mut url = Url::parse(LIBRARY_ORIGIN).expect("constant origin");
        url.set_path(path);
        if !parameters.is_empty() {
            url.query_pairs_mut()
                .extend_pairs(parameters.iter().map(|(k, v)| (*k, v)));
        }
        let response = self
            .transport
            .execute(ConnectorRequest {
                method: HttpMethod::Get,
                url: url.clone(),
                headers: vec![("Accept".into(), "application/json".into())],
                body: None,
                auth: if private {
                    TransportAuth::HostHeaders {
                        account_id: source.account_id.clone(),
                    }
                } else {
                    TransportAuth::Anonymous
                },
            })
            .await?;
        let challenge = AuthChallenge {
            connector: "fudan-library".into(),
            origin: LIBRARY_ORIGIN.into(),
            account_id: source.account_id.clone(),
            mode: AuthMode::SecretHeaders,
        };
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
        if response.body.len() > MAX_LIBRARY_BODY {
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
            return Err(ConnectorError::AuthRequired(challenge.clone()).into());
        }
        let value: Value = serde_json::from_slice(&response.body).map_err(|_| changed("json"))?;
        let code = unsigned(value.get("code").ok_or_else(|| changed("code"))?, "code")?;
        match code {
            200 => {}
            401 => return Err(ConnectorError::AuthRequired(challenge).into()),
            403 => return Err(ConnectorError::PermissionDenied.into()),
            _ => return Err(changed("code")),
        }
        if value.get("success").and_then(Value::as_bool) == Some(false) {
            return Err(changed("success"));
        }
        value.get("data").cloned().ok_or_else(|| changed("data"))
    }

    /// Exact barcode/call-number lookup, not the unverified advanced/full-text API.
    /// The public response has list but no total; limit is strictly local.
    pub async fn single_volume(
        &self,
        source: &SourceContext,
        kind: LibraryLookupKind,
        value: &str,
        limit: u16,
    ) -> Result<SourceBatch<LibraryVolumeMatch>, LibraryError> {
        validate_source(source)?;
        clean_input(value, 256)?;
        if !(1..=100).contains(&limit) {
            return Err(CampusError::InvalidQuery("library lookup limit").into());
        }
        let key = match kind {
            LibraryLookupKind::Barcode => "resource_djtmh",
            LibraryLookupKind::CallNumber => "resource_djssh",
        };
        let data = self
            .get(
                source,
                SINGLE_VOLUME_PATH,
                &[("searchKey", key.into()), ("value", value.into())],
                false,
            )
            .await?;
        let rows = list(&data)?;
        let mut seen = HashSet::new();
        let mut records = Vec::new();
        for row in rows {
            let row = row.as_object().ok_or_else(|| changed("volume.item"))?;
            let id = catalogue_id(
                row.get("resource_smjlh")
                    .ok_or_else(|| changed("resource_smjlh"))?,
            )?;
            if !seen.insert(id.clone()) {
                return Err(ConnectorError::PaginationCycle.into());
            }
            if records.len() < usize::from(limit) {
                let payload = LibraryVolumeMatch {
                    catalogue_id: id.clone(),
                    lookup_kind: kind,
                    official_url: official_url(&id)?,
                };
                records.push(source.record(format!("library:volume:{id}"), None, payload));
            }
        }
        Ok(SourceBatch {
            source: source.clone(),
            source_revision: PUBLIC_REVISION.into(),
            records,
            coverage: Coverage::Window {
                position: format!("single_volume:limit:{limit},returned:{}", rows.len()),
            },
        })
    }

    pub async fn bibliography(
        &self,
        source: &SourceContext,
        id: &str,
    ) -> Result<SourceRecord<LibraryBibliographicRecord>, LibraryError> {
        validate_source(source)?;
        let id = catalogue_id(&Value::String(id.into()))?;
        let data = self
            .get(source, &format!("{BIBLIOGRAPHY_PREFIX}{id}"), &[], false)
            .await?;
        let rows = data
            .as_array()
            .ok_or_else(|| changed("bibliography.array"))?;
        if rows.is_empty() {
            return Err(LibraryError::NotFound);
        }
        if rows.len() != 1 {
            return Err(changed("bibliography.count"));
        }
        let row = rows[0]
            .as_object()
            .ok_or_else(|| changed("bibliography.item"))?;
        let actual_id = catalogue_id(
            row.get("resource_smjlh")
                .ok_or_else(|| changed("resource_smjlh"))?,
        )?;
        if actual_id != id {
            return Err(changed("bibliography.identity"));
        }
        let payload = LibraryBibliographicRecord {
            catalogue_id: id.clone(),
            title: text(row.get("resource_ztm"), 1_024)?
                .ok_or_else(|| changed("bibliography.title"))?,
            authors: text_list(
                row.get("resource_zrz_arr")
                    .or_else(|| row.get("resource_zrz")),
                50,
            )?,
            publisher: text(row.get("resource_cbz"), 512)?,
            publication_place: text(row.get("resource_cbd"), 256)?,
            publication_year: match row.get("publication_year_int") {
                None | Some(Value::Null) => None,
                Some(v) => Some(
                    i32::try_from(unsigned(v, "publication_year")?)
                        .map_err(|_| changed("publication_year"))?,
                ),
            },
            isbns: text_list(
                row.get("resource_isbn_arr")
                    .or_else(|| row.get("resource_isbn")),
                50,
            )?,
            resource_kind: text(row.get("resource_fmt_name"), 128)?,
            official_url: official_url(&id)?,
        };
        Ok(source.record(format!("library:bibliography:{id}"), None, payload))
    }

    pub async fn holdings(
        &self,
        source: &SourceContext,
        id: &str,
        page: LibraryPage,
    ) -> Result<SourceBatch<LibraryHolding>, LibraryError> {
        validate_source(source)?;
        page.validate()?;
        let id = catalogue_id(&Value::String(id.into()))?;
        let data = self
            .get(
                source,
                HOLDINGS_PATH,
                &[
                    ("catalogueId", id.clone()),
                    ("pageNo", page.page_no.to_string()),
                    ("pageSize", page.page_size.to_string()),
                    ("display", "true".into()),
                ],
                false,
            )
            .await?;
        let rows = list(&data)?;
        let coverage = page_coverage(&data, page, rows.len())?;
        let mut seen = HashSet::new();
        let mut records = Vec::new();
        for row in rows {
            let row = row.as_object().ok_or_else(|| changed("holdings.item"))?;
            let item_id = opaque_id(row.get("id").ok_or_else(|| changed("holdings.id"))?)?;
            if !seen.insert(item_id.clone()) {
                return Err(ConnectorError::PaginationCycle.into());
            }
            if let Some(actual) = row.get("catalogueId")
                && catalogue_id(actual)? != id
            {
                return Err(changed("holdings.catalogue_id"));
            }
            match row.get("display").and_then(Value::as_bool) {
                Some(true) => {}
                Some(false) => return Err(changed("holdings.hidden_item")),
                None => return Err(changed("holdings.display")),
            }
            let status =
                text(row.get("itemStatus"), 128)?.ok_or_else(|| changed("holdings.item_status"))?;
            let payload = LibraryHolding {
                id: item_id.clone(),
                catalogue_id: id.clone(),
                call_number: text(row.get("callNo"), 256)?,
                permanent_library: text(row.get("permanentLibraryName"), 256)?,
                permanent_location: text(row.get("permanentLocationName"), 256)?,
                temporary_library: text(row.get("temporaryLibraryName"), 256)?,
                temporary_location: text(row.get("temporaryLocationName"), 256)?,
                item_status: status.clone(),
                item_status_name: text(row.get("itemStatusName"), 256)?,
                known_available: status == "Available",
                expected_return: if status == "Available" {
                    None
                } else {
                    source_date(
                        row.get("checkinDateTime"),
                        "checkinDateTime",
                        LibraryDateMeaning::ExpectedReturnAsDisplayedByHoldingsUi,
                    )?
                },
                volume_info: text(row.get("volumeInfo"), 256)?,
            };
            records.push(source.record(format!("library:holding:{id}:{item_id}"), None, payload));
        }
        Ok(SourceBatch {
            source: source.clone(),
            source_revision: PUBLIC_REVISION.into(),
            records,
            coverage,
        })
    }

    /// Observes only the server token subject. This alone does not verify that
    /// it is the user's intended account and must not establish a trusted binding.
    pub async fn reader_identity(
        &self,
        source: &SourceContext,
    ) -> Result<LibraryReaderIdentity, LibraryError> {
        validate_source(source)?;
        let data = self.get(source, READER_INFO_PATH, &[], true).await?;
        let barcode = data.as_object().and_then(|v| v.get("barcode")).ok_or(
            LibraryError::ProtocolUnverified {
                field: "reader.barcode",
            },
        )?;
        let barcode = opaque_id(barcode).map_err(|_| LibraryError::ProtocolUnverified {
            field: "reader.barcode",
        })?;
        Ok(LibraryReaderIdentity {
            reader_ref: reader_fingerprint(source, &barcode),
            state: LibraryIdentityState::ObservedUnbound,
        })
    }

    /// expected_reader_ref MUST come from trusted host login/account configuration,
    /// never a caller's username/user-ID or request JSON. Missing binding blocks
    /// loan I/O. Each read rechecks getReaderInfo before the loan endpoint.
    pub async fn loans(
        &self,
        source: &SourceContext,
        kind: LibraryLoanKind,
        page: LibraryPage,
        expected_reader_ref: Option<&str>,
    ) -> Result<LibraryLoanPage, LibraryError> {
        validate_source(source)?;
        page.validate()?;
        let expected = expected_reader_ref.ok_or(LibraryError::IdentityUnverified)?;
        if !expected.starts_with("library-reader:")
            || expected.len() != 79
            || !expected[15..]
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(LibraryError::IdentityUnverified);
        }
        let identity = self.reader_identity(source).await?;
        if identity.reader_ref != expected {
            return Err(LibraryError::IdentityMismatch);
        }
        let data = self
            .get(
                source,
                kind.path(),
                &[
                    ("pageNo", page.page_no.to_string()),
                    ("pageSize", page.page_size.to_string()),
                ],
                true,
            )
            .await?;
        let rows = list(&data).map_err(|error| match error {
            LibraryError::Campus(CampusError::SchemaChanged { .. }) => {
                LibraryError::ProtocolUnverified {
                    field: "loans.list",
                }
            }
            other => other,
        })?;
        let coverage = page_coverage(&data, page, rows.len())?;
        let mut seen = HashSet::new();
        let mut records = Vec::new();
        for row in rows {
            let (external_id, payload) = loan_record(source, kind, row)?;
            if !seen.insert(external_id.clone()) {
                return Err(ConnectorError::PaginationCycle.into());
            }
            records.push(source.record(
                format!("library:{}:{external_id}", kind.label()),
                None,
                payload,
            ));
        }
        Ok(LibraryLoanPage {
            batch: SourceBatch {
                source: source.clone(),
                source_revision: format!("{PRIVATE_REVISION}/{}", kind.label()),
                records,
                coverage,
            },
            identity: LibraryIdentityState::MatchedTrustedFingerprint,
            protocol_live_validated: false,
        })
    }
}

fn list(data: &Value) -> Result<&Vec<Value>, LibraryError> {
    let rows = data
        .get("list")
        .and_then(Value::as_array)
        .ok_or_else(|| changed("list"))?;
    if rows.len() > MAX_WIRE_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(rows)
}

fn page_coverage(data: &Value, page: LibraryPage, count: usize) -> Result<Coverage, LibraryError> {
    if count > usize::from(page.page_size) {
        return Err(ConnectorError::LimitExceeded.into());
    }
    let total = match data.get("total") {
        None | Some(Value::Null) => None,
        Some(v) => Some(unsigned(v, "total")?),
    };
    let offset = u64::from(page.page_no - 1) * u64::from(page.page_size);
    let end = offset + count as u64;
    match total {
        Some(total)
            if offset <= total
                && end <= total
                && (end == total || count == usize::from(page.page_size)) =>
        {
            Ok(Coverage::Page {
                next: (end < total).then_some(page.page_no + 1),
                total: Some(total),
            })
        }
        Some(_) => Err(CampusError::PaginationInconsistent.into()),
        None => Ok(Coverage::Window {
            position: format!(
                "page_no:{},page_size:{},total:unknown",
                page.page_no, page.page_size
            ),
        }),
    }
}

fn unsigned(value: &Value, field: &'static str) -> Result<u64, LibraryError> {
    match value {
        Value::Number(v) => v.as_u64().ok_or_else(|| changed(field)),
        Value::String(v) => v.parse().map_err(|_| changed(field)),
        _ => Err(changed(field)),
    }
}

fn opaque_id(value: &Value) -> Result<String, LibraryError> {
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

fn catalogue_id(value: &Value) -> Result<String, LibraryError> {
    let id = opaque_id(value)?;
    let number: u64 = id.parse().map_err(|_| changed("catalogue_id"))?;
    if number == 0 || number > 9_007_199_254_740_991 {
        return Err(changed("catalogue_id"));
    }
    Ok(id)
}

fn clean_input(value: &str, max_bytes: usize) -> Result<(), LibraryError> {
    let lower = value.to_ascii_lowercase();
    if value.trim().is_empty()
        || value.len() > max_bytes
        || value.chars().any(char::is_control)
        || lower.contains("http:")
        || lower.contains("https:")
        || lower.contains("javascript:")
    {
        return Err(CampusError::InvalidQuery("library text input").into());
    }
    Ok(())
}

fn text(value: Option<&Value>, max_bytes: usize) -> Result<Option<String>, LibraryError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(v)) => {
            if v.trim().is_empty() {
                return Ok(None);
            }
            clean_input(v, max_bytes * 4)?;
            let result = if v.contains('<') {
                scraper::Html::parse_fragment(v)
                    .root_element()
                    .text()
                    .collect::<Vec<_>>()
                    .join(" ")
            } else {
                v.clone()
            };
            let result = result.split_whitespace().collect::<Vec<_>>().join(" ");
            if result.len() > max_bytes * 4 {
                return Err(changed("text"));
            }
            Ok((!result.is_empty()).then_some(result))
        }
        _ => Err(changed("text")),
    }
}

fn text_list(value: Option<&Value>, max_items: usize) -> Result<Vec<String>, LibraryError> {
    let mut values = match value {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(v)) => {
            if v.len() > max_items {
                return Err(ConnectorError::LimitExceeded.into());
            }
            v.iter()
                .map(|v| text(Some(v), 512))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .collect()
        }
        Some(v) => text(Some(v), 2_048)?.map_or_else(Vec::new, |v| {
            v.split('#')
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
                .collect()
        }),
    };
    if values.len() > max_items {
        return Err(ConnectorError::LimitExceeded.into());
    }
    values.dedup();
    Ok(values)
}

fn source_date(
    value: Option<&Value>,
    field: &str,
    meaning: LibraryDateMeaning,
) -> Result<Option<LibrarySourceDate>, LibraryError> {
    let (raw, numeric) = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::String(v)) if v.trim().is_empty() => return Ok(None),
        Some(Value::String(v)) => {
            clean_input(v, 80)?;
            (v.clone(), false)
        }
        Some(Value::Number(v)) if v.as_i64().is_some() => (v.to_string(), true),
        _ => return Err(changed("date")),
    };
    let (precision, timezone) = if numeric {
        (LibraryDatePrecision::NumericUnknownUnit, None)
    } else if NaiveDate::parse_from_str(&raw, "%Y-%m-%d").is_ok() {
        (LibraryDatePrecision::DateOnly, None)
    } else if let Ok(value) = DateTime::parse_from_rfc3339(&raw) {
        (
            LibraryDatePrecision::DateTimeWithExplicitZone,
            Some(value.offset().to_string()),
        )
    } else if NaiveDateTime::parse_from_str(&raw, "%Y-%m-%d %H:%M:%S").is_ok()
        || NaiveDateTime::parse_from_str(&raw, "%Y-%m-%dT%H:%M:%S").is_ok()
    {
        (LibraryDatePrecision::DateTimeWithoutZone, None)
    } else {
        (LibraryDatePrecision::Unclassified, None)
    };
    Ok(Some(LibrarySourceDate {
        raw,
        source_field: field.into(),
        precision,
        meaning,
        timezone,
    }))
}

fn digest(parts: &[&str]) -> String {
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(parts).expect("strings serialize"))
    )
}

fn reader_fingerprint(source: &SourceContext, barcode: &str) -> String {
    format!(
        "library-reader:{}",
        digest(&[LIBRARY_ORIGIN, &source.account_id, barcode])
    )
}

fn official_url(id: &str) -> Result<String, LibraryError> {
    let mut number: u64 = id.parse().map_err(|_| changed("catalogue_id"))?;
    let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let mut digits = Vec::new();
    while number > 0 {
        digits.push(alphabet[(number % 62) as usize] as char);
        number /= 62;
    }
    digits.reverse();
    Ok(format!(
        "{OPAC_ORIGIN}/#/bookInfo/{}",
        digits.into_iter().collect::<String>()
    ))
}

fn loan_record(
    source: &SourceContext,
    kind: LibraryLoanKind,
    value: &Value,
) -> Result<(String, LibraryLoan), LibraryError> {
    let outer = value
        .as_object()
        .ok_or(LibraryError::ProtocolUnverified { field: "loan.item" })?;
    let item_info = outer.get("itemInfo").and_then(Value::as_object);
    let item = item_info
        .and_then(|v| v.get("item"))
        .and_then(Value::as_object);
    let instance = item_info
        .and_then(|v| v.get("instance"))
        .and_then(Value::as_object);
    let history_instance = outer.get("catalogueInstance").and_then(Value::as_object);
    let fields: Vec<&Map<String, Value>> = if kind == LibraryLoanKind::Current {
        item.into_iter()
            .chain(instance)
            .chain(std::iter::once(outer))
            .collect()
    } else {
        std::iter::once(outer).chain(history_instance).collect()
    };
    let lookup = |field: &str| fields.iter().find_map(|v| v.get(field));
    let barcode = lookup("barcode").map(opaque_id).transpose()?;
    let item_ref = barcode
        .as_ref()
        .map(|v| format!("library-item:{}", digest(&[&source.account_id, v])));
    let catalogue_id = lookup("catalogueId").map(catalogue_id).transpose()?;
    let checkout_field = if kind == LibraryLoanKind::Current {
        "checkoutDate"
    } else {
        "loanDate"
    };
    let checkout = source_date(
        lookup(checkout_field),
        checkout_field,
        LibraryDateMeaning::Checkout,
    )?;
    let due = if kind == LibraryLoanKind::Current {
        source_date(
            lookup("checkinDateTime"),
            "checkinDateTime",
            LibraryDateMeaning::DueAsDisplayedByOfficialCurrentLoanUi,
        )?
    } else {
        None
    };
    let returned = if kind == LibraryLoanKind::History {
        source_date(
            lookup("returnDate"),
            "returnDate",
            LibraryDateMeaning::ReturnedAsDisplayedByOfficialHistoryUi,
        )?
    } else {
        None
    };
    let source_id = outer
        .get("id")
        .or_else(|| outer.get("loanId"))
        .map(opaque_id)
        .transpose()?;
    let (external_id, id_basis) = if let Some(id) = source_id {
        (
            digest(&[&source.account_id, kind.label(), &id]),
            LibraryLoanIdBasis::SourceId,
        )
    } else if kind == LibraryLoanKind::Current {
        let item = item_ref
            .as_deref()
            .ok_or(LibraryError::ProtocolUnverified {
                field: "current.item_identity",
            })?;
        (
            digest(&[&source.account_id, kind.label(), item]),
            LibraryLoanIdBasis::AccountItemFingerprint,
        )
    } else {
        let catalogue = catalogue_id
            .as_deref()
            .ok_or(LibraryError::ProtocolUnverified {
                field: "history.catalogue_id",
            })?;
        let date = checkout.as_ref().ok_or(LibraryError::ProtocolUnverified {
            field: "history.loan_date",
        })?;
        (
            digest(&[
                &source.account_id,
                kind.label(),
                catalogue,
                &date.raw,
                item_ref.as_deref().unwrap_or(""),
            ]),
            LibraryLoanIdBasis::ContentFingerprint,
        )
    };
    let title = text(lookup("title"), 1_024)?;
    if kind == LibraryLoanKind::Current && title.is_none() {
        return Err(LibraryError::ProtocolUnverified {
            field: "current.title",
        });
    }
    let renewal_field = if kind == LibraryLoanKind::Current {
        "renewCount"
    } else {
        "renewalCount"
    };
    let renewal_count = match lookup(renewal_field) {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            u32::try_from(unsigned(v, "renewal_count")?).map_err(|_| changed("renewal_count"))?,
        ),
    };
    let payload = LibraryLoan {
        kind,
        title,
        authors: text_list(lookup("author"), 50)?,
        catalogue_id,
        item_ref,
        checkout,
        due,
        returned,
        renewal_count,
        location: text(lookup("temporaryLocationName"), 256)?,
        call_number: text(lookup("callNo"), 256)?,
        id_basis,
    };
    Ok((external_id, payload))
}
