// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2021-2023 DanXi-Dev; Rust adaptation (C) 2026 dansheng-core contributors.
//! Read-only Tea/Danke adapters derived from DanXi 3c1f5f0:
//! lib/repository/forum/forum_repository.dart, lib/repository/danke/curriculum_board_repository.dart,
//! lib/model/forum/{division,hole,floors,floor}.dart and lib/model/danke/*.dart.
//! GPL version 3 or later, without warranty; see ../LICENSE and source links in ../README.md.

use crate::campus::{
    CampusError, Coverage, MAX_BODY, MAX_ITEMS, PageWindow, SourceBatch, batch, changed, json,
};
use crate::models::{SourceContext, SourceRecord};
use crate::transport::check_response;
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use url::Url;

pub const TEA_ORIGIN: &str = "https://forum.fduhole.com";
pub const TEA_ORIGIN_LEGACY: &str = "https://www.fduhole.com";
pub const DANKE_ORIGIN: &str = "https://danke.fduhole.com";

/// DanXi POST_COUNT_PER_PAGE and the upstream /api/holes size/length limit.
/// Search and floor endpoints have separate limits.
pub const TEA_HOLES_PAGE_SIZE: u16 = 10;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TeaTag {
    pub tag_id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature: Option<i64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TeaFloor {
    pub floor_id: u64,
    pub hole_id: u64,
    pub content: Option<String>,
    pub anonyname: Option<String>,
    pub time_created: Option<String>,
    pub time_updated: Option<String>,
    pub deleted: Option<bool>,
    pub modified: Option<u64>,
    pub like: Option<u64>,
    pub dislike: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fold: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub special_tag: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TeaFloorPreview {
    pub first_floor: Option<TeaFloor>,
    pub last_floor: Option<TeaFloor>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TeaHole {
    pub hole_id: u64,
    pub division_id: u64,
    pub time_created: Option<String>,
    pub time_updated: Option<String>,
    pub time_deleted: Option<String>,
    pub view: Option<u64>,
    pub reply: Option<u64>,
    pub floors: Option<TeaFloorPreview>,
    pub hidden: Option<bool>,
    pub locked: Option<bool>,
    pub frozen: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<TeaTag>>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TeaDivision {
    pub division_id: u64,
    pub name: String,
    pub description: Option<String>,
    pub pinned: Option<Vec<TeaHole>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DankeRatings {
    /// Preserve raw API directions. DanXi's presentation computes 6-content/6-workload.
    pub overall: Option<u8>,
    pub content: Option<u8>,
    pub workload: Option<u8>,
    pub assessment: Option<u8>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DankeReview {
    pub id: u64,
    pub reviewer_id: Option<u64>,
    pub title: Option<String>,
    pub content: Option<String>,
    #[serde(rename = "timeCreated")]
    pub time_created: Option<String>,
    #[serde(rename = "timeUpdated")]
    pub time_updated: Option<String>,
    pub rank: Option<DankeRatings>,
    pub remark: Option<i64>,
    pub modified: Option<u64>,
    pub deleted: Option<bool>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DankeCourse {
    pub id: u64,
    pub name: Option<String>,
    pub code: Option<String>,
    pub code_id: Option<String>,
    pub credit: Option<f64>,
    pub department: Option<String>,
    pub teachers: Option<String>,
    pub max_student: Option<u64>,
    pub week_hour: Option<u64>,
    pub year: Option<u16>,
    pub semester: Option<u8>,
    pub review_list: Option<Vec<DankeReview>>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DankeCourseGroup {
    pub id: u64,
    pub name: String,
    pub code: Option<String>,
    pub department: Option<String>,
    pub week_hour: Option<u64>,
    pub credits: Option<Vec<f64>>,
    pub course_list: Option<Vec<DankeCourse>>,
    pub course_count: Option<u64>,
    pub review_count: Option<u64>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DankeSearchPage {
    pub page: u32,
    pub page_size: u16,
    pub items: Vec<DankeCourseGroup>,
}

fn decode<T: DeserializeOwned>(value: Value, domain: &'static str) -> Result<T, CampusError> {
    serde_json::from_value(value).map_err(|_| changed(domain, "fields"))
}
fn list<T: DeserializeOwned>(body: &[u8], domain: &'static str) -> Result<Vec<T>, CampusError> {
    let value = json(body, domain)?;
    if !value.is_array() {
        return Err(changed(domain, "list"));
    }
    if value.as_array().expect("array").len() > MAX_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    decode(value, domain)
}

pub fn parse_tea_divisions(body: &[u8]) -> Result<Vec<TeaDivision>, CampusError> {
    list(body, "tea divisions")
}
pub fn parse_tea_holes(body: &[u8]) -> Result<Vec<TeaHole>, CampusError> {
    list(body, "tea holes")
}
pub fn parse_tea_floors(body: &[u8]) -> Result<Vec<TeaFloor>, CampusError> {
    list(body, "tea floors")
}
pub fn parse_danke_reviews(body: &[u8]) -> Result<Vec<DankeReview>, CampusError> {
    list(body, "Danke reviews")
}
pub fn parse_danke_group(body: &[u8]) -> Result<DankeCourseGroup, CampusError> {
    decode(json(body, "Danke group")?, "Danke group")
}
pub fn parse_danke_search(body: &[u8]) -> Result<DankeSearchPage, CampusError> {
    let result: DankeSearchPage = decode(json(body, "Danke search")?, "Danke search")?;
    if result.page == 0
        || result.page_size == 0
        || result.page_size > 100
        || result.items.len() > usize::from(result.page_size)
    {
        return Err(CampusError::PaginationInconsistent);
    }
    Ok(result)
}

fn timestamp(value: Option<&str>) -> Option<DateTime<Utc>> {
    // Preserve source strings in payloads. Never invent a timezone for unzoned source times.
    value
        .and_then(|v| DateTime::parse_from_rfc3339(v).ok())
        .map(|t| t.with_timezone(&Utc))
}

fn positive_id(id: u64) -> Result<(), CampusError> {
    if id == 0 {
        Err(CampusError::InvalidQuery("positive source id"))
    } else {
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
pub enum TeaOrder {
    LastReplied,
    LastCreated,
}
impl TeaOrder {
    fn as_str(self) -> &'static str {
        match self {
            Self::LastReplied => "time_updated",
            Self::LastCreated => "time_created",
        }
    }
}

/// HostToken only. This client never acquires, refreshes, serializes or logs a token.
/// No login, email verification, posting, voting, subscription or view-count writes.
pub struct CommunityClient<T> {
    transport: T,
    tea: Url,
    danke: Url,
}
impl<T: ConnectorTransport> CommunityClient<T> {
    pub fn new(transport: T) -> Self {
        Self {
            transport,
            tea: Url::parse(TEA_ORIGIN).expect("constant URL"),
            danke: Url::parse(DANKE_ORIGIN).expect("constant URL"),
        }
    }

    /// Dedicated verified origins only. Legacy www.fduhole.com is normalized to forum.fduhole.com
    /// matching DanXi SettingsProvider. Arbitrary user origin overrides are rejected.
    pub fn with_origins(mut self, tea: &str, danke: &str) -> Result<Self, CampusError> {
        fn origin(value: &str, allowed: &[&str]) -> Result<Url, CampusError> {
            let url =
                Url::parse(value).map_err(|_| CampusError::InvalidQuery("community origin"))?;
            if url.scheme() != "https"
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.path() != "/"
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err(CampusError::InvalidQuery("community HTTPS origin"));
            }
            let origin_str = url.origin().ascii_serialization();
            if !allowed.contains(&origin_str.as_str()) {
                return Err(CampusError::InvalidQuery(
                    "unverified community HTTPS origin",
                ));
            }
            Ok(url)
        }
        let tea_url = origin(tea, &[TEA_ORIGIN, TEA_ORIGIN_LEGACY])?;
        self.tea = if tea_url.origin().ascii_serialization() == TEA_ORIGIN_LEGACY {
            Url::parse(TEA_ORIGIN).expect("constant URL")
        } else {
            tea_url
        };
        self.danke = origin(danke, &[DANKE_ORIGIN])?;
        Ok(self)
    }

    async fn get(
        &self,
        source: &SourceContext,
        base: &Url,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Vec<u8>, CampusError> {
        source.validate()?;
        let mut url = base.join(path).map_err(|_| ConnectorError::UnsafeUrl)?;
        if url.origin() != base.origin() || !url.path().starts_with("/api/") {
            return Err(ConnectorError::UnsafeUrl.into());
        }
        url.query_pairs_mut()
            .extend_pairs(query.iter().map(|(k, v)| (*k, v.as_str())));
        let challenge = AuthChallenge {
            connector: "tea-danke".into(),
            origin: base.origin().ascii_serialization(),
            account_id: source.account_id.clone(),
            mode: AuthMode::Token,
        };
        let response = self
            .transport
            .execute(ConnectorRequest {
                method: HttpMethod::Get,
                url,
                headers: vec![("Accept".into(), "application/json".into())],
                body: None,
                auth: TransportAuth::HostToken {
                    account_id: source.account_id.clone(),
                },
            })
            .await?;
        check_response(&response, base, challenge.clone(), MAX_BODY)?;
        if response.final_url.path().starts_with("/api/") {
            // Interpret an explicit auth code before generic success:false handling.
            let value: Value =
                serde_json::from_slice(&response.body).map_err(|_| changed("community", "json"))?;
            let code = value.get("code").and_then(|v| {
                v.as_str()
                    .map(str::to_owned)
                    .or_else(|| v.as_u64().map(|n| n.to_string()))
            });
            if code.as_deref() == Some("403") {
                return Err(ConnectorError::PermissionDenied.into());
            }
            if code.as_deref() == Some("401") {
                return Err(ConnectorError::AuthRequired(challenge).into());
            }
            if value.get("success").and_then(Value::as_bool) == Some(false) {
                return Err(changed("community", "success"));
            }
            Ok(response.body)
        } else {
            Err(ConnectorError::UnsafeUrl.into())
        }
    }

    pub async fn tea_divisions(
        &self,
        source: &SourceContext,
    ) -> Result<SourceBatch<TeaDivision>, CampusError> {
        let body = self.get(source, &self.tea, "/api/divisions", &[]).await?;
        let rows = parse_tea_divisions(&body)?;
        batch(
            source,
            "tea-division",
            rows.into_iter()
                .map(|r| (r.division_id.to_string(), r))
                .collect(),
            Coverage::Complete,
        )
    }
    pub async fn tea_hole(
        &self,
        source: &SourceContext,
        hole_id: u64,
    ) -> Result<SourceRecord<TeaHole>, CampusError> {
        positive_id(hole_id)?;
        let body = self
            .get(source, &self.tea, &format!("/api/holes/{hole_id}"), &[])
            .await?;
        let row: TeaHole = decode(json(&body, "tea hole")?, "tea hole")?;
        if row.hole_id != hole_id {
            return Err(changed("tea hole", "hole_id"));
        }
        Ok(source.record(
            format!("tea-hole:{hole_id}"),
            timestamp(row.time_updated.as_deref()),
            row,
        ))
    }
    /// One timestamp-bounded window. The caller must choose the next source timestamp;
    /// no timestamp subtraction or guessed tie-break cursor can silently skip tied rows.
    pub async fn tea_holes(
        &self,
        source: &SourceContext,
        division: Option<u64>,
        before: DateTime<Utc>,
        size: u16,
        order: TeaOrder,
    ) -> Result<SourceBatch<TeaHole>, CampusError> {
        self.tea_holes_with_tag(source, division, before, size, order, None)
            .await
    }

    /// Query holes with optional tag filter matching DanXi `loadHoles(..., tag: tag)`.
    pub async fn tea_holes_with_tag(
        &self,
        source: &SourceContext,
        division: Option<u64>,
        before: DateTime<Utc>,
        size: u16,
        order: TeaOrder,
        tag: Option<&str>,
    ) -> Result<SourceBatch<TeaHole>, CampusError> {
        PageWindow { offset: 0, size }.validate()?;
        // Older hosts requested 20. Bound the wire request before the server rejects
        // it with HTTP 400, and check the response against this effective limit.
        let size = size.min(TEA_HOLES_PAGE_SIZE);
        if let Some(id) = division {
            positive_id(id)?;
        }
        let mut query = vec![
            ("start_time", before.to_rfc3339()),
            ("size", size.to_string()),
            ("length", size.to_string()),
            ("order", order.as_str().into()),
        ];
        if let Some(id) = division {
            query.push(("division_id", id.to_string()));
        }
        if let Some(t) = tag {
            let trimmed = t.trim();
            if !trimmed.is_empty() {
                query.push(("tag", trimmed.into()));
            }
        }
        let body = self.get(source, &self.tea, "/api/holes", &query).await?;
        let rows = parse_tea_holes(&body)?;
        if rows.len() > usize::from(size)
            || rows
                .iter()
                .any(|r| division.is_some_and(|id| r.division_id != id))
        {
            return Err(CampusError::PaginationInconsistent);
        }
        let mut result = batch(
            source,
            "tea-hole",
            rows.into_iter()
                .map(|r| (r.hole_id.to_string(), r))
                .collect(),
            Coverage::Window {
                position: before.to_rfc3339(),
            },
        )?;
        for record in &mut result.records {
            record.updated_at = timestamp(record.payload.time_updated.as_deref());
        }
        Ok(result)
    }
    pub async fn tea_floors(
        &self,
        source: &SourceContext,
        hole_id: u64,
        page: PageWindow,
    ) -> Result<SourceBatch<TeaFloor>, CampusError> {
        positive_id(hole_id)?;
        page.validate()?;
        let body = self
            .get(
                source,
                &self.tea,
                &format!("/api/holes/{hole_id}/floors"),
                &[
                    ("offset", page.offset.to_string()),
                    ("size", page.size.to_string()),
                ],
            )
            .await?;
        let rows = parse_tea_floors(&body)?;
        if rows.len() > usize::from(page.size) || rows.iter().any(|r| r.hole_id != hole_id) {
            return Err(CampusError::PaginationInconsistent);
        }
        let next = if rows.len() == usize::from(page.size) {
            Some(
                page.offset
                    .checked_add(u32::from(page.size))
                    .ok_or(CampusError::PaginationInconsistent)?,
            )
        } else {
            None
        };
        let mut result = batch(
            source,
            "tea-floor",
            rows.into_iter()
                .map(|r| (r.floor_id.to_string(), r))
                .collect(),
            Coverage::Page { next, total: None },
        )?;
        for record in &mut result.records {
            record.updated_at = timestamp(record.payload.time_updated.as_deref());
        }
        Ok(result)
    }
    pub async fn danke_search(
        &self,
        source: &SourceContext,
        keyword: &str,
        page: u32,
        page_size: u16,
    ) -> Result<SourceBatch<DankeCourseGroup>, CampusError> {
        PageWindow {
            offset: 0,
            size: page_size,
        }
        .validate()?;
        if page == 0 || page > 10_000 || keyword.trim().is_empty() || keyword.len() > 512 {
            return Err(CampusError::InvalidQuery("Danke search"));
        }
        let body = self
            .get(
                source,
                &self.danke,
                "/api/v3/course_groups/search",
                &[
                    ("query", keyword.into()),
                    ("page", page.to_string()),
                    ("page_size", page_size.to_string()),
                ],
            )
            .await?;
        let result = parse_danke_search(&body)?;
        if result.page != page || result.page_size > page_size {
            return Err(CampusError::PaginationInconsistent);
        }
        let next = if result.items.len() == usize::from(result.page_size) {
            Some(page + 1)
        } else {
            None
        };
        batch(
            source,
            "Danke-group",
            result
                .items
                .into_iter()
                .map(|r| (r.id.to_string(), r))
                .collect(),
            Coverage::Page { next, total: None },
        )
    }
    pub async fn danke_group(
        &self,
        source: &SourceContext,
        group_id: u64,
    ) -> Result<SourceRecord<DankeCourseGroup>, CampusError> {
        positive_id(group_id)?;
        let body = self
            .get(
                source,
                &self.danke,
                &format!("/api/v3/course_groups/{group_id}"),
                &[],
            )
            .await?;
        let row = parse_danke_group(&body)?;
        if row.id != group_id {
            return Err(changed("Danke group", "id"));
        }
        Ok(source.record(format!("Danke-group:{group_id}"), None, row))
    }
    pub async fn danke_reviews(
        &self,
        source: &SourceContext,
        course_id: u64,
    ) -> Result<SourceBatch<DankeReview>, CampusError> {
        positive_id(course_id)?;
        let body = self
            .get(
                source,
                &self.danke,
                &format!("/api/courses/{course_id}/reviews"),
                &[],
            )
            .await?;
        let rows = parse_danke_reviews(&body)?;
        let mut result = batch(
            source,
            "Danke-review",
            rows.into_iter().map(|r| (r.id.to_string(), r)).collect(),
            Coverage::Complete,
        )?;
        for record in &mut result.records {
            record.updated_at = timestamp(record.payload.time_updated.as_deref());
        }
        Ok(result)
    }
}
