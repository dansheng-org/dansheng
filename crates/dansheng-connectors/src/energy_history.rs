// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2021, 2025 DanXi-Dev. Rust adaptation (C) 2026 dansheng-core contributors.
//! Read-only electricity history connector adapted from public DanXi 3c1f5f026fbc7ca50e151865f813cdb381807abe,
//! lib/repository/fdu/data_center_repository.dart and lib/feature/dorm_electricity_feature.dart.
//! Fixed read-only POST to my.fudan.edu.cn/data_tables/ykt_xszsqyydqk.json.
//! GPL version 3 or later, without warranty; see ../LICENSE.

use crate::campus::{CampusError, Coverage, DANXI_REVISION, PageWindow, SourceBatch, unsigned};
use crate::models::SourceContext;
use crate::transport::check_response;
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;

pub const MY_ORIGIN: &str = "https://my.fudan.edu.cn";
pub const ELECTRICITY_HISTORY_PATH: &str = "/data_tables/ykt_xszsqyydqk.json";
pub const MAX_BODY: usize = 8 * 1024 * 1024;
pub const MAX_ITEMS: usize = 10_000;

fn changed(field: &'static str) -> CampusError {
    CampusError::SchemaChanged {
        domain: "electricity-history",
        field,
    }
}

/// One electricity history item parsed from DataTables or HTML table.
/// Mirrors DanXi ElectricityHistoryItem (date, amount, dorm_name).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ElectricityHistoryRecord {
    pub date: String,
    pub amount: String,
    pub dorm_name: String,
}

fn clean_cell_text(s: &str) -> String {
    if s.contains('<') && s.contains('>') {
        let mut out = String::with_capacity(s.len());
        let mut in_tag = false;
        for ch in s.chars() {
            if ch == '<' {
                in_tag = true;
            } else if ch == '>' {
                in_tag = false;
            } else if !in_tag {
                out.push(ch);
            }
        }
        out.trim().to_string()
    } else {
        s.trim().to_string()
    }
}

fn cell_to_string(value: &Value, field: &'static str) -> Result<String, CampusError> {
    match value {
        Value::String(s) => {
            let cleaned = clean_cell_text(s);
            if cleaned.is_empty() {
                Err(changed(field))
            } else {
                Ok(cleaned)
            }
        }
        Value::Number(n) => Ok(n.to_string()),
        _ => Err(changed(field)),
    }
}

fn check_login_content(text: &str, challenge: Option<&AuthChallenge>) -> Result<(), CampusError> {
    let lower = text.to_ascii_lowercase();
    let has_html =
        lower.contains("<html") || lower.contains("<!doctype") || lower.contains("<form");
    let has_login = lower.contains("password")
        || lower.contains("authserver")
        || lower.contains("/login")
        || lower.contains("统一身份认证")
        || lower.contains("uis.fudan.edu.cn");
    if (has_html && has_login) || lower.contains("authserver/login") {
        let auth_challenge = challenge.cloned().unwrap_or_else(|| AuthChallenge {
            connector: "fudan-campus".into(),
            origin: MY_ORIGIN.into(),
            account_id: String::new(),
            mode: AuthMode::HttpSession,
        });
        return Err(ConnectorError::AuthRequired(auth_challenge).into());
    }
    Ok(())
}

/// Parse electricity history response bytes (DataTables JSON or HTML table).
/// Distinguishes login redirects/pages, malformed schemas, and legitimate empty responses.
pub fn parse_electricity_history_with_meta(
    body: &[u8],
    challenge: Option<&AuthChallenge>,
) -> Result<(Vec<ElectricityHistoryRecord>, Option<u64>), CampusError> {
    if body.len() > MAX_BODY {
        return Err(ConnectorError::LimitExceeded.into());
    }
    let text = std::str::from_utf8(body).map_err(|_| changed("encoding"))?;
    check_login_content(text, challenge)?;

    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(changed("empty_body"));
    }

    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        let data: Value = serde_json::from_str(trimmed).map_err(|_| changed("json"))?;
        if let Some(code) = data.get("code").and_then(|v| {
            v.as_str()
                .map(str::to_owned)
                .or_else(|| v.as_i64().map(|n| n.to_string()))
        }) {
            if code == "401" {
                let auth_challenge = challenge.cloned().unwrap_or_else(|| AuthChallenge {
                    connector: "fudan-campus".into(),
                    origin: MY_ORIGIN.into(),
                    account_id: String::new(),
                    mode: AuthMode::HttpSession,
                });
                return Err(ConnectorError::AuthRequired(auth_challenge).into());
            }
            if code == "403" {
                return Err(ConnectorError::PermissionDenied.into());
            }
        }
        if data.get("success").and_then(Value::as_bool) == Some(false) {
            return Err(changed("success"));
        }

        let data_field = data.get("data").ok_or_else(|| changed("data"))?;
        let rows = data_field.as_array().ok_or_else(|| changed("data_array"))?;
        let total = if let Some(v) = data
            .get("recordsFiltered")
            .or_else(|| data.get("recordsTotal"))
        {
            if v.is_null() {
                None
            } else {
                Some(unsigned(v, "electricity-history", "total")?)
            }
        } else {
            None
        };

        if rows.is_empty() {
            return Ok((Vec::new(), total));
        }

        if rows.len() > MAX_ITEMS {
            return Err(ConnectorError::LimitExceeded.into());
        }

        let mut records = Vec::with_capacity(rows.len());
        for row in rows {
            let cells = row.as_array().ok_or_else(|| changed("row_array"))?;
            if cells.len() < 6 {
                return Err(changed("row_columns"));
            }
            let campus = cell_to_string(&cells[1], "campus")?;
            let building = cell_to_string(&cells[2], "building")?;
            let room = cell_to_string(&cells[3], "room")?;
            let date = cell_to_string(&cells[4], "date")?;
            let amount = cell_to_string(&cells[5], "amount")?;

            let dorm_name = format!("{campus}/{building}/{room}");
            records.push(ElectricityHistoryRecord {
                date,
                amount,
                dorm_name,
            });
        }
        return Ok((records, total));
    }

    if trimmed.starts_with('<') {
        let doc = Html::parse_document(trimmed);
        let table_sel = Selector::parse("table").map_err(|_| changed("selector"))?;
        let table = doc
            .select(&table_sel)
            .next()
            .ok_or_else(|| changed("table"))?;
        let tr_sel = Selector::parse("tr").map_err(|_| changed("selector"))?;
        let td_sel = Selector::parse("td").map_err(|_| changed("selector"))?;

        let mut records = Vec::new();
        for tr in table.select(&tr_sel) {
            let class_attr = tr.value().attr("class").unwrap_or("");
            if class_attr.contains("tr-empty") || class_attr.contains("empty") {
                continue;
            }
            let cells: Vec<String> = tr
                .select(&td_sel)
                .map(|td| clean_cell_text(&td.text().collect::<String>()))
                .collect();
            if cells.is_empty() {
                continue;
            }
            if cells.len() == 1
                && (cells[0].contains("暂无") || cells[0].contains("无数据") || cells[0].is_empty())
            {
                continue;
            }
            if cells.len() >= 6 {
                let campus = &cells[1];
                let building = &cells[2];
                let room = &cells[3];
                let date = cells[4].clone();
                let amount = cells[5].clone();
                if campus.is_empty()
                    || building.is_empty()
                    || room.is_empty()
                    || date.is_empty()
                    || amount.is_empty()
                {
                    return Err(changed("table_cell_empty"));
                }
                let dorm_name = format!("{campus}/{building}/{room}");
                records.push(ElectricityHistoryRecord {
                    date,
                    amount,
                    dorm_name,
                });
            } else if cells.len() >= 3 {
                let dorm_name = cells[0].clone();
                let date = cells[1].clone();
                let amount = cells[2].clone();
                if dorm_name.is_empty() || date.is_empty() || amount.is_empty() {
                    return Err(changed("table_cell_empty"));
                }
                records.push(ElectricityHistoryRecord {
                    date,
                    amount,
                    dorm_name,
                });
            } else {
                return Err(changed("table_columns"));
            }
        }
        return Ok((records, None));
    }

    Err(changed("invalid_format"))
}

/// Parse electricity history response bytes into a record array.
pub fn parse_electricity_history(
    body: &[u8],
) -> Result<Vec<ElectricityHistoryRecord>, CampusError> {
    parse_electricity_history_with_meta(body, None).map(|(records, _)| records)
}

/// Official Fudan electricity history client.
/// Exact read-only POST to my.fudan.edu.cn/data_tables/ykt_xszsqyydqk.json.
pub struct ElectricityHistoryClient<T> {
    transport: T,
}

impl<T: ConnectorTransport> ElectricityHistoryClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport }
    }

    pub async fn electricity_history(
        &self,
        source: &SourceContext,
        page: PageWindow,
    ) -> Result<SourceBatch<ElectricityHistoryRecord>, CampusError> {
        source.validate()?;
        page.validate()?;

        let boundary = "dansheng-read-query";
        let body = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"draw\"\r\n\r\n2\r\n\
             --{boundary}\r\nContent-Disposition: form-data; name=\"start\"\r\n\r\n{}\r\n\
             --{boundary}\r\nContent-Disposition: form-data; name=\"length\"\r\n\r\n{}\r\n\
             --{boundary}--\r\n",
            page.offset, page.size
        )
        .into_bytes();

        let url =
            Url::parse(&format!("{MY_ORIGIN}{ELECTRICITY_HISTORY_PATH}")).expect("constant URL");
        let challenge = AuthChallenge {
            connector: "fudan-campus".into(),
            origin: url.origin().ascii_serialization(),
            account_id: source.account_id.clone(),
            mode: AuthMode::HttpSession,
        };

        let response = self
            .transport
            .execute(ConnectorRequest {
                method: HttpMethod::Post,
                url: url.clone(),
                headers: vec![
                    ("Accept".into(), "application/json, text/html".into()),
                    (
                        "Content-Type".into(),
                        format!("multipart/form-data; boundary={boundary}"),
                    ),
                ],
                body: Some(body),
                auth: TransportAuth::HostSession {
                    account_id: source.account_id.clone(),
                },
            })
            .await?;

        check_response(&response, &url, challenge.clone(), MAX_BODY)?;

        let (rows, total) = parse_electricity_history_with_meta(&response.body, Some(&challenge))?;

        let coverage = match total {
            Some(total) => {
                let count = rows.len();
                if count > usize::from(page.size)
                    || u64::from(page.offset) > total
                    || u64::from(page.offset) + count as u64 > total
                {
                    return Err(CampusError::PaginationInconsistent);
                }
                let next = page
                    .offset
                    .checked_add(count as u32)
                    .ok_or(CampusError::PaginationInconsistent)?;
                if u64::from(next) < total && count == 0 {
                    return Err(CampusError::PaginationInconsistent);
                }
                Coverage::Page {
                    next: (u64::from(next) < total).then_some(next),
                    total: Some(total),
                }
            }
            None => Coverage::Window {
                position: format!("offset:{},size:{}", page.offset, page.size),
            },
        };

        let records = rows
            .into_iter()
            .enumerate()
            .map(|(i, row)| {
                let id = format!(
                    "electricity-history:{}:{}:{}",
                    row.dorm_name,
                    row.date,
                    page.offset as usize + i
                );
                source.record(id, None, row)
            })
            .collect();

        Ok(SourceBatch {
            source: source.clone(),
            source_revision: DANXI_REVISION.into(),
            records,
            coverage,
        })
    }
}
