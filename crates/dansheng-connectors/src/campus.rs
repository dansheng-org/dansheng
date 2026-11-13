// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2021, 2025 DanXi-Dev. Rust adaptation (C) 2026 dansheng-core contributors.
//! Read-only mappings adapted from public DanXi 3c1f5f026fbc7ca50e151865f813cdb381807abe,
//! lib/repository/fdu/{edu_service,graduate_exam,data_center,ecard,dorm,empty_classroom,
//! library,pe,bus,aao,qr_code}_repository.dart. Full source links and limitations: ../README.md.
//! GPL version 3 or later, without warranty; see ../LICENSE.

use crate::models::{SourceContext, SourceRecord};
use crate::transport::check_response;
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use regex::Regex;
use scraper::{ElementRef, Html, Selector};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub const DANXI_REVISION: &str = "3c1f5f026fbc7ca50e151865f813cdb381807abe";
const JWGL: &str = "https://fdjwgl.fudan.edu.cn";
const ECARD: &str = "https://ecard.fudan.edu.cn";
#[cfg(feature = "services")]
pub(crate) const QR_ORIGIN: &str = ECARD;
#[cfg(feature = "services")]
const MAX_QR_PAGE_BYTES: usize = 256 * 1024;
#[cfg(feature = "services")]
const MAX_QR_PAYLOAD_BYTES: usize = 4096;
const MY: &str = "https://my.fudan.edu.cn";
const ZLAPP: &str = "https://zlapp.fudan.edu.cn";
pub(crate) const MAX_BODY: usize = 8 * 1024 * 1024;
pub(crate) const MAX_ITEMS: usize = 10_000;

#[derive(Clone, Debug, thiserror::Error, PartialEq, Eq)]
pub enum CampusError {
    #[error(transparent)]
    Transport(#[from] ConnectorError),
    #[error("source schema changed or malformed at {domain}.{field}")]
    SchemaChanged {
        domain: &'static str,
        field: &'static str,
    },
    #[error("source is outside its reporting hours")]
    OutsideReportingHours,
    #[error("source reports maintenance or requires campus network access")]
    MaintenanceOrCampusNetwork,
    #[error("invalid campus query: {0}")]
    InvalidQuery(&'static str),
    #[error("source pagination metadata is inconsistent")]
    PaginationInconsistent,
    #[error("QR terms require explicit action in the trusted host")]
    TermsNotAccepted,
}

pub(crate) fn changed(domain: &'static str, field: &'static str) -> CampusError {
    CampusError::SchemaChanged { domain, field }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Coverage {
    /// Complete source-defined unpaged response, not a claim about other sources/accounts.
    Complete,
    Page {
        next: Option<u32>,
        total: Option<u64>,
    },
    /// One bounded source window; no verified end-of-collection/next-page metadata.
    Window { position: String },
    /// The source reports more rows but this pinned client has no verified paging protocol.
    UnsupportedRemainder {
        reported_total: u64,
        returned: usize,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SourceBatch<T> {
    /// Retained even when a source legitimately returns no records.
    pub source: SourceContext,
    pub source_revision: String,
    pub records: Vec<SourceRecord<T>>,
    pub coverage: Coverage,
}

pub(crate) fn batch<T: Serialize>(
    source: &SourceContext,
    domain: &str,
    rows: Vec<(String, T)>,
    coverage: Coverage,
) -> Result<SourceBatch<T>, CampusError> {
    source.validate()?;
    if rows.len() > MAX_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    let records = rows
        .into_iter()
        .map(|(id, row)| source.record(format!("{domain}:{id}"), None, row))
        .collect();
    Ok(SourceBatch {
        source: source.clone(),
        source_revision: DANXI_REVISION.into(),
        records,
        coverage,
    })
}

pub(crate) fn identity<T: Serialize>(value: &T) -> Result<String, CampusError> {
    let encoded = serde_json::to_vec(value).map_err(|_| changed("identity", "serialization"))?;
    Ok(format!("{:x}", Sha256::digest(encoded)))
}

fn snapshot<T: Serialize>(
    source: &SourceContext,
    domain: &str,
    rows: Vec<T>,
) -> Result<SourceBatch<T>, CampusError> {
    let rows = rows
        .into_iter()
        .map(|row| Ok((identity(&row)?, row)))
        .collect::<Result<_, CampusError>>()?;
    batch(source, domain, rows, Coverage::Complete)
}

pub(crate) fn json(body: &[u8], domain: &'static str) -> Result<Value, CampusError> {
    if body.len() > MAX_BODY {
        return Err(ConnectorError::LimitExceeded.into());
    }
    let value: Value = serde_json::from_slice(body).map_err(|_| changed(domain, "json"))?;
    if value.get("success").and_then(Value::as_bool) == Some(false) {
        return Err(changed(domain, "success"));
    }
    Ok(value)
}

pub(crate) fn utf8<'a>(body: &'a [u8], domain: &'static str) -> Result<&'a str, CampusError> {
    if body.len() > MAX_BODY {
        return Err(ConnectorError::LimitExceeded.into());
    }
    std::str::from_utf8(body).map_err(|_| changed(domain, "encoding"))
}

pub(crate) fn string(
    value: &Value,
    domain: &'static str,
    field: &'static str,
) -> Result<String, CampusError> {
    match value {
        Value::String(s) if !s.trim().is_empty() => Ok(s.trim().to_owned()),
        Value::Number(n) => Ok(n.to_string()),
        _ => Err(changed(domain, field)),
    }
}

fn optional_string(
    value: &Value,
    domain: &'static str,
    field: &'static str,
) -> Result<Option<String>, CampusError> {
    if value.is_null() || value.as_str().is_some_and(|s| s.trim().is_empty()) {
        Ok(None)
    } else {
        string(value, domain, field).map(Some)
    }
}

pub(crate) fn unsigned(
    value: &Value,
    domain: &'static str,
    field: &'static str,
) -> Result<u64, CampusError> {
    string(value, domain, field)?
        .parse()
        .map_err(|_| changed(domain, field))
}

pub(crate) fn decimal(
    value: &Value,
    domain: &'static str,
    field: &'static str,
) -> Result<f64, CampusError> {
    let n: f64 = string(value, domain, field)?
        .parse()
        .map_err(|_| changed(domain, field))?;
    if !n.is_finite() {
        return Err(changed(domain, field));
    }
    Ok(n)
}

fn optional_decimal(
    value: &Value,
    domain: &'static str,
    field: &'static str,
) -> Result<Option<f64>, CampusError> {
    if value.is_null() {
        Ok(None)
    } else {
        decimal(value, domain, field).map(Some)
    }
}

pub(crate) fn array<'a>(
    value: &'a Value,
    domain: &'static str,
    field: &'static str,
) -> Result<&'a [Value], CampusError> {
    let rows = value.as_array().ok_or_else(|| changed(domain, field))?;
    if rows.len() > MAX_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(rows)
}

pub(crate) fn selector(value: &str) -> Selector {
    Selector::parse(value).expect("constant selector")
}
pub(crate) fn text(element: ElementRef<'_>) -> String {
    element
        .text()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn date(value: &str, domain: &'static str) -> Result<NaiveDate, CampusError> {
    for format in ["%Y-%m-%d", "%Y.%m.%d", "%Y/%m/%d"] {
        if let Ok(date) = NaiveDate::parse_from_str(value, format) {
            return Ok(date);
        }
    }
    Err(changed(domain, "date"))
}

fn local_timestamp(value: &str, domain: &'static str) -> Result<DateTime<Utc>, CampusError> {
    if let Ok(time) = DateTime::parse_from_rfc3339(value) {
        return Ok(time.with_timezone(&Utc));
    }
    let raw = NaiveDateTime::parse_from_str(value, "%Y-%m-%d %H:%M:%S")
        .map_err(|_| changed(domain, "timestamp"))?;
    FixedOffset::east_opt(8 * 3600)
        .expect("Shanghai offset")
        .from_local_datetime(&raw)
        .single()
        .map(|t| t.with_timezone(&Utc))
        .ok_or_else(|| changed(domain, "timestamp"))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Exam {
    pub course_code: String,
    pub course_name: String,
    pub category: String,
    pub exam_type: String,
    pub on: NaiveDate,
    pub time_range: String,
    pub room: Option<String>,
    pub note: String,
    pub finished: bool,
}

pub fn parse_exams(body: &[u8]) -> Result<Vec<Exam>, CampusError> {
    let doc = Html::parse_document(utf8(body, "exams")?);
    let table = doc
        .select(&selector("table.exam-table"))
        .next()
        .ok_or_else(|| changed("exams", "exam-table"))?;
    let mut result = Vec::new();
    for row in table.select(&selector("tbody tr")) {
        if row.value().classes().any(|class| class == "tr-empty") {
            continue;
        }
        let cells: Vec<_> = row.select(&selector("td")).collect();
        if cells.len() < 4 {
            return Err(changed("exams", "cells"));
        }
        let time = cells[0]
            .select(&selector("div.time"))
            .next()
            .map(text)
            .ok_or_else(|| changed("exams", "time"))?;
        let (on, time_range) = time
            .split_once(' ')
            .ok_or_else(|| changed("exams", "time range"))?;
        let first = cells[1]
            .select(&selector("div"))
            .next()
            .ok_or_else(|| changed("exams", "course"))?;
        let spans: Vec<_> = first.select(&selector("span")).map(text).collect();
        if spans.len() < 3 || spans[0].is_empty() || spans[1].is_empty() {
            return Err(changed("exams", "course spans"));
        }
        let finished = match row.value().attr("data-finished") {
            Some("true") => true,
            Some("false") => false,
            _ => return Err(changed("exams", "finished")),
        };
        result.push(Exam {
            course_code: spans[1].clone(),
            course_name: spans[0].clone(),
            category: spans[2]
                .trim_start_matches('（')
                .trim_end_matches('）')
                .into(),
            exam_type: cells[1]
                .select(&selector(".tag-span"))
                .next()
                .map(text)
                .ok_or_else(|| changed("exams", "type"))?,
            on: date(on, "exams")?,
            time_range: time_range.into(),
            room: cells[0].select(&selector("span")).nth(2).map(text),
            note: text(cells[2]),
            finished,
        });
    }
    if result.len() > MAX_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(result)
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Grade {
    pub course_code: String,
    pub course_name: String,
    pub semester: Option<String>,
    pub category: Option<String>,
    pub credits: Option<f64>,
    pub letter_grade: Option<String>,
    pub grade_point: Option<f64>,
}

pub fn parse_undergraduate_grades(body: &[u8], semester: &str) -> Result<Vec<Grade>, CampusError> {
    let data = json(body, "grades")?;
    array(
        &data["semesterId2studentGrades"][semester],
        "grades",
        "semesterId2studentGrades",
    )?
    .iter()
    .map(|row| {
        let first = |a: &str, b: &str| if row[a].is_null() { &row[b] } else { &row[a] };
        Ok(Grade {
            course_code: string(first("lessonCode", "courseCode"), "grades", "code")?,
            course_name: string(first("courseName", "courseNameEn"), "grades", "name")?,
            semester: Some(semester.into()),
            category: optional_string(
                first("courseModuleTypeName", "courseType"),
                "grades",
                "category",
            )?,
            credits: None,
            letter_grade: optional_string(&row["gaGrade"], "grades", "gaGrade")?,
            grade_point: optional_decimal(&row["gp"], "grades", "gp")?,
        })
    })
    .collect()
}

pub fn parse_data_center_grades(body: &[u8]) -> Result<Vec<Grade>, CampusError> {
    let data = json(body, "data-center grades")?;
    array(&data["data"], "data-center grades", "data")?
        .iter()
        .map(|row| {
            let cells = array(row, "data-center grades", "row")?;
            if cells.len() < 7 {
                return Err(changed("data-center grades", "columns"));
            }
            Ok(Grade {
                course_code: string(&cells[0], "grades", "code")?,
                course_name: string(&cells[3], "grades", "name")?,
                semester: Some(string(
                    if cells[2].is_null() {
                        &cells[1]
                    } else {
                        &cells[2]
                    },
                    "grades",
                    "semester",
                )?),
                category: None,
                credits: optional_decimal(&cells[4], "grades", "credits")?,
                letter_grade: optional_string(&cells[5], "grades", "letter")?,
                grade_point: optional_decimal(&cells[6], "grades", "gp")?,
            })
        })
        .collect()
}

pub fn parse_graduate_grades(body: &[u8]) -> Result<(Vec<Grade>, Option<u64>), CampusError> {
    let data = json(body, "graduate grades")?;
    if string(&data["code"], "graduate grades", "code")? != "0" {
        return Err(changed("graduate grades", "code"));
    }
    let section = &data["datas"]["jdjscjcx"];
    let rows = array(&section["rows"], "graduate grades", "rows")?
        .iter()
        .map(|row| {
            Ok(Grade {
                course_code: string(&row["KCDM"], "graduate grades", "KCDM")?,
                course_name: string(&row["KCMC"], "graduate grades", "KCMC")?,
                semester: None,
                category: optional_string(&row["KCLBMC"], "graduate grades", "KCLBMC")?,
                credits: optional_decimal(&row["XF"], "graduate grades", "XF")?,
                letter_grade: optional_string(&row["CJ"], "graduate grades", "CJ")?,
                grade_point: optional_decimal(&row["JDZ"], "graduate grades", "JDZ")?,
            })
        })
        .collect::<Result<Vec<_>, CampusError>>()?;
    let total = section
        .get("totalSize")
        .map(|v| unsigned(v, "graduate grades", "totalSize"))
        .transpose()?;
    Ok((rows, total))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct GpaEntry {
    pub student_code: String,
    pub name: Option<String>,
    pub entry_year: Option<String>,
    pub department: Option<String>,
    pub major: Option<String>,
    pub gpa: Option<f64>,
    pub credits: Option<f64>,
    pub ranking: Option<u64>,
}

pub fn parse_gpa(body: &[u8]) -> Result<Vec<GpaEntry>, CampusError> {
    let data = json(body, "GPA")?;
    array(&data["data"], "GPA", "data")?
        .iter()
        .map(|row| {
            Ok(GpaEntry {
                student_code: string(&row["code"], "GPA", "code")?,
                name: optional_string(&row["name"], "GPA", "name")?,
                entry_year: optional_string(&row["grade"], "GPA", "grade")?,
                department: optional_string(&row["department"], "GPA", "department")?,
                major: optional_string(&row["major"], "GPA", "major")?,
                gpa: optional_decimal(&row["gpa"], "GPA", "gpa")?,
                credits: optional_decimal(&row["credit"], "GPA", "credit")?,
                ranking: row
                    .get("ranking")
                    .filter(|v| !v.is_null())
                    .map(|v| unsigned(v, "GPA", "ranking"))
                    .transpose()?,
            })
        })
        .collect()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Money {
    pub cents: i64,
    pub currency: String,
}

fn money(value: &str) -> Result<Money, CampusError> {
    let trimmed = value
        .trim()
        .trim_start_matches(['¥', '￥'])
        .trim_end_matches('元')
        .trim();
    let pattern = Regex::new(r"^([+-]?)([0-9]+)(?:\.([0-9]{1,2}))?$").expect("constant regex");
    let parts = pattern
        .captures(trimmed)
        .ok_or_else(|| changed("ecard", "money"))?;
    let whole: i64 = parts[2].parse().map_err(|_| changed("ecard", "money"))?;
    let fraction = parts.get(3).map(|v| v.as_str()).unwrap_or("0");
    let minor: i64 = fraction.parse().map_err(|_| changed("ecard", "money"))?;
    let cents = whole
        .checked_mul(100)
        .and_then(|v| {
            v.checked_add(if fraction.len() == 1 {
                minor * 10
            } else {
                minor
            })
        })
        .ok_or_else(|| changed("ecard", "money"))?;
    Ok(Money {
        cents: if &parts[1] == "-" { -cents } else { cents },
        currency: "CNY".into(),
    })
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EcardBalance {
    pub holder_name: Option<String>,
    pub balance: Money,
}

pub fn parse_ecard_balance(body: &[u8]) -> Result<EcardBalance, CampusError> {
    let doc = Html::parse_document(utf8(body, "ecard")?);
    let cash = doc
        .select(&selector(".payway-box-bottom-item > p"))
        .next()
        .map(text)
        .ok_or_else(|| changed("ecard", "balance"))?;
    let name = doc
        .select(&selector(".custname"))
        .next()
        .map(text)
        .and_then(|s| {
            s.split_once("您好，")
                .and_then(|(_, b)| b.split_once('！').map(|(name, _)| name.trim().to_owned()))
        });
    if name.as_ref().is_none_or(|name| name.is_empty()) {
        return Err(changed("ecard", "authenticated holder name"));
    }
    Ok(EcardBalance {
        holder_name: name,
        balance: money(&cash)?,
    })
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EcardTransaction {
    pub at: DateTime<Utc>,
    pub transaction_type: String,
    pub location: String,
    pub amount: Money,
}

pub fn parse_ecard_transactions(body: &[u8]) -> Result<(Vec<EcardTransaction>, u32), CampusError> {
    let raw = utf8(body, "ecard transactions")?;
    let fragment = raw
        .split_once("<![CDATA[")
        .and_then(|(_, v)| v.split_once("]]>").map(|(v, _)| v))
        .ok_or_else(|| changed("ecard transactions", "CDATA"))?;
    let doc = Html::parse_fragment(fragment);
    let table = doc
        .select(&selector("tbody"))
        .next()
        .ok_or_else(|| changed("ecard transactions", "tbody"))?;
    let mut result = Vec::new();
    for row in table.select(&selector("tr")) {
        let cells: Vec<_> = row.select(&selector("td")).collect();
        // Current epay adds balance, status and operation after the four original
        // columns. Keep the legacy layout, and reject other unknown layouts.
        if !matches!(cells.len(), 4 | 7) {
            return Err(changed("ecard transactions", "columns"));
        }
        let children: Vec<_> = cells[0]
            .children()
            .filter_map(ElementRef::wrap)
            .map(text)
            .collect();
        if children.len() < 2 {
            return Err(changed("ecard transactions", "time"));
        }
        // epay's current table reports minute precision; legacy rows include seconds.
        let clock = NaiveTime::parse_from_str(&children[1], "%H:%M:%S")
            .or_else(|_| NaiveTime::parse_from_str(&children[1], "%H:%M"))
            .map_err(|_| changed("ecard transactions", "time"))?;
        let at = local_timestamp(
            &format!("{} {}", children[0].replace('.', "-"), clock),
            "ecard transactions",
        )?;
        result.push(EcardTransaction {
            at,
            transaction_type: text(cells[1]),
            location: text(cells[2]),
            amount: money(&text(cells[3]))?,
        });
    }
    let count = Regex::new(r"</b>\s*/\s*(\d+)\s*页")
        .expect("constant regex")
        .captures(raw)
        .and_then(|m| m.get(1).and_then(|v| v.as_str().parse::<u32>().ok()))
        .ok_or_else(|| changed("ecard transactions", "page count"))?;
    if result.len() > 10 || count > 10_000 {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok((result, count))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Electricity {
    pub room_id: String,
    pub campus: String,
    pub building: String,
    pub room: String,
    pub remaining_kwh: f64,
    pub used_kwh: f64,
    pub updated_at: Option<DateTime<Utc>>,
}

pub fn parse_electricity(body: &[u8]) -> Result<Electricity, CampusError> {
    let data = json(body, "electricity")?;
    let row = &data["d"];
    Ok(Electricity {
        room_id: string(&row["roomid"], "electricity", "roomid")?,
        campus: string(&row["xq"], "electricity", "xq")?,
        building: string(&row["ssmc"], "electricity", "ssmc")?,
        room: string(&row["fjmc"], "electricity", "fjmc")?,
        remaining_kwh: decimal(&row["fj_surplus"], "electricity", "fj_surplus")?,
        used_kwh: decimal(&row["fj_used"], "electricity", "fj_used")?,
        updated_at: optional_string(&row["fj_update_time"], "electricity", "fj_update_time")?
            .map(|date| local_timestamp(&date, "electricity"))
            .transpose()?,
    })
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryOccupancy {
    pub campus: String,
    pub inside: u64,
}

pub fn parse_library_occupancy(body: &[u8]) -> Result<Vec<LibraryOccupancy>, CampusError> {
    let data = json(body, "library occupancy")?;
    array(&data["data"], "library occupancy", "data")?
        .iter()
        .map(|row| {
            Ok(LibraryOccupancy {
                campus: string(&row["campusName"], "library occupancy", "campusName")?,
                inside: unsigned(&row["inNum"], "library occupancy", "inNum")?,
            })
        })
        .collect()
}

/// Extract a balanced array/object from mixed script text, respecting quoted delimiters.
pub(crate) fn balanced(value: &str, start: usize) -> Option<&str> {
    let mut depth = 0u32;
    let mut quote = None;
    let mut escaped = false;
    for (i, c) in value[start..].char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if let Some(q) = quote {
            if c == '\\' {
                escaped = true;
            } else if c == q {
                quote = None;
            }
            continue;
        }
        if c == '\'' || c == '"' {
            quote = Some(c);
            continue;
        }
        if c == '[' || c == '{' {
            depth += 1;
        }
        if c == ']' || c == '}' {
            depth = depth.checked_sub(1)?;
            if depth == 0 {
                return Some(&value[start..start + i + c.len_utf8()]);
            }
        }
    }
    None
}

fn js_array(value: &str) -> Result<Value, CampusError> {
    let mut output = String::new();
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\'' {
            output.push(c);
            if c == '"' {
                let mut escaped = false;
                for next in chars.by_ref() {
                    output.push(next);
                    if !escaped && next == '"' {
                        break;
                    }
                    escaped = !escaped && next == '\\';
                }
            }
            continue;
        }
        output.push('"');
        let mut closed = false;
        while let Some(c) = chars.next() {
            match c {
                '\'' => {
                    closed = true;
                    break;
                }
                '"' => output.push_str("\\\""),
                '\\' => {
                    let escaped = chars.next().ok_or_else(|| changed("dining", "escape"))?;
                    if escaped == '\'' {
                        output.push('\'');
                    } else {
                        output.push('\\');
                        output.push(escaped);
                    }
                }
                _ => output.push(c),
            }
        }
        if !closed {
            return Err(changed("dining", "string"));
        }
        output.push('"');
    }
    serde_json::from_str(&output).map_err(|_| changed("dining", "arrays"))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiningOccupancy {
    pub area_code: u8,
    pub name: String,
    pub current: u64,
    pub capacity: u64,
}

pub fn parse_dining_occupancy(
    body: &[u8],
    area_code: u8,
) -> Result<Vec<DiningOccupancy>, CampusError> {
    let html = utf8(body, "dining")?;
    let doc = Html::parse_document(html);
    let script = doc
        .select(&selector("script"))
        .next()
        .map(|e| e.text().collect::<String>())
        .ok_or_else(|| {
            if html.contains('仅') {
                CampusError::OutsideReportingHours
            } else {
                changed("dining", "script")
            }
        })?;
    let mut arrays = Vec::new();
    let mut offset = 0;
    while let Some(i) = script[offset..].find('[') {
        let start = offset + i;
        let value = balanced(&script, start).ok_or_else(|| changed("dining", "array boundary"))?;
        arrays.push(js_array(value)?);
        offset = start + value.len();
        if arrays.len() > 48 {
            return Err(ConnectorError::LimitExceeded.into());
        }
    }
    let base = usize::from(area_code) * 3;
    if arrays.len() < base + 3 {
        return Err(changed("dining", "area arrays"));
    }
    let names = array(&arrays[base], "dining", "names")?;
    let current = array(&arrays[base + 1], "dining", "current")?;
    let capacity = array(&arrays[base + 2], "dining", "capacity")?;
    if current.len() != names.len() || capacity.len() != names.len() {
        return Err(changed("dining", "array lengths"));
    }
    names
        .iter()
        .enumerate()
        .map(|(i, name)| {
            Ok(DiningOccupancy {
                area_code,
                name: string(name, "dining", "name")?.replace('\n', "-"),
                current: unsigned(&current[i], "dining", "current")?,
                capacity: unsigned(&capacity[i], "dining", "capacity")?,
            })
        })
        .collect()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EmptyClassroom {
    pub id: String,
    pub room: String,
    pub on: NaiveDate,
    pub seats: Option<u32>,
    pub busy_units: Vec<bool>,
}

pub fn parse_empty_classrooms(
    status_body: &[u8],
    details_body: &[u8],
    on: NaiveDate,
) -> Result<Vec<EmptyClassroom>, CampusError> {
    let raw = utf8(status_body, "empty classrooms")?;
    let marker = Regex::new(r#""status"\s*:\s*\["#)
        .expect("constant regex")
        .find(raw)
        .ok_or_else(|| changed("empty classrooms", "status"))?;
    let start = marker.end() - 1;
    let status =
        balanced(raw, start).ok_or_else(|| changed("empty classrooms", "status boundary"))?;
    let data: Value =
        serde_json::from_str(status).map_err(|_| changed("empty classrooms", "status JSON"))?;
    let rows = array(&data, "empty classrooms", "status")?;
    let details = utf8(details_body, "empty classrooms")?;
    let capacity = Regex::new(r">\s*(\d+)\s*<").expect("constant regex");
    // The room legend is a multiline styled cell. DanXi counts only the fourteen
    // one-line period cells (the last is a sentinel), not the legend.
    let usage = Regex::new(r#"<td\s+style="background-color[^"<>]*"[^>]*>(.*?)</td>"#)
        .expect("constant regex");
    let boundary = Regex::new(r#""r[0-9]+"|innerHTML"#).expect("constant regex");
    rows.iter()
        .map(|row| {
            let id = string(&row["id"], "empty classrooms", "id")?;
            identifier(&id)?;
            let start = details
                .find(&format!("\"c{id}\""))
                .ok_or_else(|| changed("empty classrooms", "room marker"))?;
            let remaining = &details[start..];
            let end = boundary
                .find(remaining)
                .ok_or_else(|| changed("empty classrooms", "room boundary"))?
                .start();
            let segment = &remaining[..end];
            let mut busy: Vec<bool> = usage
                .captures_iter(segment)
                .map(|m| !m[1].is_empty())
                .collect();
            if busy.len() != 14 {
                return Err(changed("empty classrooms", "14 source slots"));
            }
            busy.pop();
            let seats = capacity
                .captures(segment)
                .map(|m| {
                    m[1].parse::<u32>()
                        .map_err(|_| changed("empty classrooms", "seats"))
                })
                .transpose()?;
            Ok(EmptyClassroom {
                id,
                room: string(&row["room"], "empty classrooms", "room")?,
                on,
                seats,
                busy_units: busy,
            })
        })
        .collect()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PeRecord {
    Count {
        title: String,
        times: Option<u64>,
    },
    Assessment {
        title: String,
        result: String,
        score: String,
        comment: String,
    },
}

pub fn parse_pe_records(body: &[u8]) -> Result<Vec<PeRecord>, CampusError> {
    let doc = Html::parse_document(utf8(body, "PE")?);
    let rows: Vec<_> = doc
        .select(&selector(
            "#pAll > table > tbody > tr:nth-child(6) > td > table > tbody > tr",
        ))
        .collect();
    if rows.is_empty() {
        return Err(changed("PE", "count table"));
    }
    let mut result = Vec::new();
    for row in rows {
        let cells: Vec<_> = row.select(&selector("td")).map(text).collect();
        if cells.len() % 2 != 0 {
            return Err(changed("PE", "count pairs"));
        }
        for pair in cells.as_chunks::<2>().0 {
            result.push(PeRecord::Count {
                title: pair[0].replace('：', ""),
                times: pair[1].parse().ok(),
            });
        }
    }
    let scores: Vec<_> = doc
        .select(&selector(
            "#pAll > table > tbody > tr:nth-child(26) > td > table > tbody > tr > td",
        ))
        .map(text)
        .collect();
    if scores.len() % 6 != 0 {
        return Err(changed("PE", "assessment columns"));
    }
    for cells in scores.as_chunks::<6>().0 {
        result.push(PeRecord::Assessment {
            title: cells[1].clone(),
            result: cells[2].clone(),
            score: cells[3].clone(),
            comment: cells[4].clone(),
        });
    }
    Ok(result)
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BusDirection {
    None,
    Both,
    Backward,
    Forward,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BusDeparture {
    pub id: String,
    pub from: String,
    pub to: String,
    pub starts_at: Option<NaiveTime>,
    pub ends_at: Option<NaiveTime>,
    pub direction: BusDirection,
    pub holiday: bool,
}

pub fn parse_bus(body: &[u8]) -> Result<Vec<BusDeparture>, CampusError> {
    let data = json(body, "bus")?;
    let mut result = Vec::new();
    for route in array(&data["d"]["data"], "bus", "d.data")? {
        for row in array(&route["lists"], "bus", "lists")? {
            let time = |key: &str| -> Result<Option<NaiveTime>, CampusError> {
                let raw = row[key].as_str().ok_or_else(|| changed("bus", "time"))?;
                if raw.is_empty() {
                    return Ok(None);
                }
                NaiveTime::parse_from_str(&raw.replace('.', ":"), "%H:%M")
                    .map(Some)
                    .map_err(|_| changed("bus", "time"))
            };
            let direction = match unsigned(&row["arrow"], "bus", "arrow")? {
                0 => BusDirection::None,
                1 => BusDirection::Both,
                2 => BusDirection::Backward,
                3 => BusDirection::Forward,
                _ => return Err(changed("bus", "arrow")),
            };
            let departure = BusDeparture {
                id: string(&row["id"], "bus", "id")?,
                from: string(&row["start"], "bus", "start")?,
                to: string(&row["end"], "bus", "end")?,
                starts_at: time("stime")?,
                ends_at: time("etime")?,
                direction,
                holiday: unsigned(&row["holiday"], "bus", "holiday")? != 0,
            };
            if departure.starts_at.is_some() || departure.ends_at.is_some() {
                result.push(departure);
            }
        }
    }
    if result.len() > MAX_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(result)
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum AaoKind {
    Undergraduate,
    Postgraduate,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AaoNotice {
    pub title: String,
    pub url: String,
    pub published_on: NaiveDate,
}

pub fn parse_aao_notices(body: &[u8], kind: AaoKind) -> Result<Vec<AaoNotice>, CampusError> {
    let raw = utf8(body, "AAO")?;
    if raw.contains("Under Maintenance") {
        return Err(CampusError::MaintenanceOrCampusNetwork);
    }
    let doc = Html::parse_document(raw);
    let mut result = Vec::new();
    let (base, list_selector, row_selector) = match kind {
        AaoKind::Undergraduate => (
            "https://jwc.fudan.edu.cn",
            ".wp_article_list_table",
            ".wp_article_list_table > tbody > tr > td > table > tbody",
        ),
        AaoKind::Postgraduate => (
            "https://gs.fudan.edu.cn",
            ".wp_article_list",
            ".wp_article_list > li",
        ),
    };
    if doc.select(&selector(list_selector)).next().is_none() {
        return Err(changed("AAO", "list"));
    }
    for row in doc.select(&selector(row_selector)) {
        let anchor = row
            .select(&selector("a"))
            .next()
            .ok_or_else(|| changed("AAO", "anchor"))?;
        let title = text(anchor);
        if title.is_empty() {
            return Err(changed("AAO", "title"));
        }
        let link = anchor
            .value()
            .attr("href")
            .ok_or_else(|| changed("AAO", "href"))?;
        let url = public_url(base, link)?;
        let time = match kind {
            AaoKind::Undergraduate => row.select(&selector("tr > td")).nth(1).map(text),
            AaoKind::Postgraduate => row
                .select(&selector(".Article_PublishDate"))
                .next()
                .map(text),
        }
        .ok_or_else(|| changed("AAO", "date"))?;
        result.push(AaoNotice {
            title,
            url,
            published_on: date(&time, "AAO")?,
        });
    }
    if result.len() > MAX_ITEMS {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(result)
}

fn public_url(base: &str, relative: &str) -> Result<String, CampusError> {
    let origin = url::Url::parse(base).expect("constant origin");
    let url = origin
        .join(relative)
        .map_err(|_| ConnectorError::UnsafeUrl)?;
    if url.origin() != origin.origin()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
    {
        return Err(ConnectorError::UnsafeUrl.into());
    }
    Ok(url.into())
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QrState {
    Ready,
    TermsNotAccepted,
}
/// QR content is an ephemeral credential. Only state leaves this parser.
pub fn parse_qr_state(body: &[u8]) -> Result<QrState, CampusError> {
    let doc = Html::parse_document(utf8(body, "QR")?);
    if doc
        .select(&selector("#myText"))
        .next()
        .and_then(|e| e.value().attr("value"))
        .is_some_and(|v| !v.trim().is_empty())
    {
        return Ok(QrState::Ready);
    }
    if doc.select(&selector("#btn-agree-ok")).next().is_some() {
        return Ok(QrState::TermsNotAccepted);
    }
    Err(changed("QR", "state elements"))
}

// Never a public source model: no Debug, Serialize, Clone or persistent identity.
// Ownership moves directly into the trusted platform call, not into SourceRecord.
#[cfg(feature = "services")]
pub(crate) struct QrPresentation(String);

#[cfg(feature = "services")]
impl QrPresentation {
    pub(crate) fn into_payload(self) -> String {
        self.0
    }
}

#[cfg(feature = "services")]
fn parse_qr_presentation(body: &[u8]) -> Result<QrPresentation, CampusError> {
    if body.len() > MAX_QR_PAGE_BYTES {
        return Err(ConnectorError::LimitExceeded.into());
    }
    let doc = Html::parse_document(utf8(body, "QR")?);
    // Terms always win, including a malformed page containing both a code and terms.
    if doc.select(&selector("#btn-agree-ok")).next().is_some() {
        return Err(CampusError::TermsNotAccepted);
    }
    let code_selector = selector("#myText");
    let mut codes = doc.select(&code_selector);
    let element = codes.next().ok_or_else(|| changed("QR", "code element"))?;
    if codes.next().is_some() {
        return Err(changed("QR", "multiple code elements"));
    }
    let value = element
        .value()
        .attr("value")
        .ok_or_else(|| changed("QR", "code value"))?;
    if value.trim().is_empty()
        || value.len() > MAX_QR_PAYLOAD_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(changed("QR", "code bounds"));
    }
    Ok(QrPresentation(value.to_owned()))
}

#[derive(Clone, Copy, Debug)]
pub struct PageWindow {
    pub offset: u32,
    pub size: u16,
}
impl PageWindow {
    pub(crate) fn validate(self) -> Result<(), CampusError> {
        if self.size == 0 || self.size > 100 || self.offset > 1_000_000 {
            return Err(CampusError::InvalidQuery("page window"));
        }
        Ok(())
    }
}
pub(crate) fn identifier(value: &str) -> Result<(), CampusError> {
    if value.is_empty() || value.len() > 32 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(CampusError::InvalidQuery("numeric source identifier"));
    }
    Ok(())
}

/// All school sessions use mediated native HTTP cookies. POST is only used for
/// source-defined read queries; no transfer, payment, registration, terms agreement,
/// loan renewal or QR payload export API is provided.
pub struct FudanCampusClient<T> {
    transport: T,
}
impl<T: ConnectorTransport> FudanCampusClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport }
    }

    async fn request(
        &self,
        source: &SourceContext,
        url: url::Url,
        method: HttpMethod,
        body: Option<(Vec<u8>, &str)>,
        public: bool,
    ) -> Result<Vec<u8>, CampusError> {
        source.validate()?;
        let auth = if public {
            TransportAuth::Anonymous
        } else if matches!(url.host_str(), Some("jwc.fudan.edu.cn" | "gs.fudan.edu.cn")) {
            TransportAuth::OptionalSession {
                account_id: source.account_id.clone(),
            }
        } else {
            TransportAuth::HostSession {
                account_id: source.account_id.clone(),
            }
        };
        let mut headers = vec![(
            "Accept".into(),
            "application/json, text/html, text/xml".into(),
        )];
        let body = body.map(|(bytes, content_type)| {
            headers.push(("Content-Type".into(), content_type.into()));
            bytes
        });
        let response = self
            .transport
            .execute(ConnectorRequest {
                method,
                url: url.clone(),
                headers,
                body,
                auth,
            })
            .await?;
        check_response(
            &response,
            &url,
            AuthChallenge {
                connector: "fudan-campus".into(),
                origin: url.origin().ascii_serialization(),
                account_id: source.account_id.clone(),
                mode: AuthMode::HttpSession,
            },
            MAX_BODY,
        )?;
        // Source-level JSON auth envelopes do not become empty successful lists.
        if let Ok(data) = serde_json::from_slice::<Value>(&response.body) {
            let code = data.get("code").and_then(|v| {
                v.as_str()
                    .map(str::to_owned)
                    .or_else(|| v.as_i64().map(|n| n.to_string()))
            });
            if code.as_deref() == Some("403") {
                return Err(ConnectorError::PermissionDenied.into());
            }
            if code.as_deref() == Some("401") {
                return Err(ConnectorError::AuthRequired(AuthChallenge {
                    connector: "fudan-campus".into(),
                    origin: url.origin().ascii_serialization(),
                    account_id: source.account_id.clone(),
                    mode: AuthMode::HttpSession,
                })
                .into());
            }
            if data.get("success").and_then(Value::as_bool) == Some(false) {
                return Err(changed("campus", "success"));
            }
        }
        Ok(response.body)
    }

    async fn get(
        &self,
        source: &SourceContext,
        origin: &str,
        path: &str,
    ) -> Result<Vec<u8>, CampusError> {
        let url = url::Url::parse(origin)
            .expect("constant origin")
            .join(path)
            .map_err(|_| ConnectorError::UnsafeUrl)?;
        self.request(source, url, HttpMethod::Get, None, false)
            .await
    }

    pub async fn student_association(
        &self,
        source: &SourceContext,
        semester: &str,
    ) -> Result<SourceRecord<String>, CampusError> {
        identifier(semester)?;
        let bytes = self
            .get(
                source,
                JWGL,
                &format!("/student/for-std/course-table/semester/{semester}/print-data"),
            )
            .await?;
        let data = json(&bytes, "student association")?;
        let tables = array(
            &data["studentTableVms"],
            "student association",
            "studentTableVms",
        )?;
        if tables.len() != 1 {
            return Err(changed("student association", "table count"));
        }
        let id = string(&tables[0]["id"], "student association", "id")?;
        identifier(&id)?;
        Ok(source.record("student-association".into(), None, id))
    }

    pub async fn exams(
        &self,
        source: &SourceContext,
        student_assoc: &str,
        include_finished: bool,
    ) -> Result<SourceBatch<Exam>, CampusError> {
        identifier(student_assoc)?;
        let data = self
            .get(
                source,
                JWGL,
                &format!("/student/for-std/exam-arrange/info/{student_assoc}"),
            )
            .await?;
        snapshot(
            source,
            "exam",
            parse_exams(&data)?
                .into_iter()
                .filter(|e| include_finished || !e.finished)
                .collect(),
        )
    }

    pub async fn undergraduate_grades(
        &self,
        source: &SourceContext,
        student_assoc: &str,
        semester: &str,
    ) -> Result<SourceBatch<Grade>, CampusError> {
        identifier(student_assoc)?;
        identifier(semester)?;
        let data = self
            .get(
                source,
                JWGL,
                &format!("/student/for-std/grade/sheet/info/{student_assoc}?semester={semester}"),
            )
            .await?;
        snapshot(
            source,
            "undergraduate-grade",
            parse_undergraduate_grades(&data, semester)?,
        )
    }

    pub async fn graduate_grades(
        &self,
        source: &SourceContext,
    ) -> Result<SourceBatch<Grade>, CampusError> {
        let data = self
            .get(
                source,
                "https://yzsfwapp.fudan.edu.cn",
                "/gsapp/sys/wdcjapp/modules/xscjcx/jdjscjcx.do",
            )
            .await?;
        let (rows, total) = parse_graduate_grades(&data)?;
        let coverage = match total {
            Some(total) if total > rows.len() as u64 => Coverage::UnsupportedRemainder {
                reported_total: total,
                returned: rows.len(),
            },
            Some(total) if total < rows.len() as u64 => {
                return Err(CampusError::PaginationInconsistent);
            }
            _ => Coverage::Complete,
        };
        let mut result = snapshot(source, "graduate-grade", rows)?;
        result.coverage = coverage;
        Ok(result)
    }

    pub async fn data_center_grades(
        &self,
        source: &SourceContext,
        page: PageWindow,
    ) -> Result<SourceBatch<Grade>, CampusError> {
        page.validate()?;
        let body = serde_json::to_vec(&serde_json::json!({"start":page.offset,"length":page.size}))
            .map_err(|_| changed("grades", "query"))?;
        let bytes = self
            .request(
                source,
                url::Url::parse(&format!("{MY}/data_tables/bks_xx_cj.json")).expect("constant URL"),
                HttpMethod::Post,
                Some((body, "application/json")),
                false,
            )
            .await?;
        let data = json(&bytes, "grades pagination")?;
        let rows = parse_data_center_grades(&bytes)?;
        let coverage = data_table_coverage(&data, page, rows.len())?;
        let mut result = snapshot(source, "data-center-grade", rows)?;
        result.coverage = coverage;
        Ok(result)
    }

    pub async fn gpa(
        &self,
        source: &SourceContext,
        student_assoc: &str,
    ) -> Result<SourceBatch<GpaEntry>, CampusError> {
        identifier(student_assoc)?;
        let index = self
            .get(
                source,
                JWGL,
                &format!("/student/for-std/grade/my-gpa/search-index/{student_assoc}"),
            )
            .await?;
        let (grade, department) = {
            let doc = Html::parse_document(utf8(&index, "GPA search")?);
            let input = |name: &str| -> Result<String, CampusError> {
                doc.select(&selector(&format!("input[name=\"{name}\"]")))
                    .next()
                    .and_then(|e| e.value().attr("value"))
                    .map(str::to_owned)
                    .ok_or_else(|| changed("GPA", "search form"))
            };
            (input("grade")?, input("departmentAssoc")?)
        };
        let mut url = url::Url::parse(&format!("{JWGL}/student/for-std/grade/my-gpa/search"))
            .expect("constant URL");
        url.query_pairs_mut().extend_pairs([
            ("studentAssoc", student_assoc),
            ("grade", &grade),
            ("departmentAssoc", &department),
            ("majorAssoc", ""),
        ]);
        let bytes = self
            .request(source, url, HttpMethod::Get, None, false)
            .await?;
        let rows = parse_gpa(&bytes)?;
        let data = json(&bytes, "GPA")?;
        let total = data
            .get("recordsFiltered")
            .or_else(|| data.get("recordsTotal"))
            .map(|v| unsigned(v, "GPA", "total"))
            .transpose()?;
        let coverage = match total {
            Some(total) if total > rows.len() as u64 => Coverage::UnsupportedRemainder {
                reported_total: total,
                returned: rows.len(),
            },
            Some(total) if total < rows.len() as u64 => {
                return Err(CampusError::PaginationInconsistent);
            }
            _ => Coverage::Complete,
        };
        batch(
            source,
            "GPA",
            rows.into_iter()
                .map(|r| (r.student_code.clone(), r))
                .collect(),
            coverage,
        )
    }

    pub async fn ecard_balance(
        &self,
        source: &SourceContext,
    ) -> Result<SourceRecord<EcardBalance>, CampusError> {
        let data = self.get(source, ECARD, "/epay/myepay/index").await?;
        Ok(source.record("ecard-balance".into(), None, parse_ecard_balance(&data)?))
    }

    /// One source page (10 rows), no unbounded crawl. CSRF is ephemeral and never exported.
    pub async fn ecard_transactions(
        &self,
        source: &SourceContext,
        start: NaiveDate,
        end: NaiveDate,
        page: u32,
    ) -> Result<SourceBatch<EcardTransaction>, CampusError> {
        if start > end || (end - start).num_days() > 366 || page == 0 || page > 10_000 {
            return Err(CampusError::InvalidQuery("ecard date/page window"));
        }
        let csrf_page = self.get(source, ECARD, "/epay/consume/index").await?;
        let token = {
            let doc = Html::parse_document(utf8(&csrf_page, "ecard CSRF")?);
            doc.select(&selector("meta[name=\"_csrf\"]"))
                .next()
                .and_then(|e| e.value().attr("content"))
                .filter(|s| !s.is_empty() && s.len() < 8192)
                .ok_or_else(|| changed("ecard", "CSRF meta"))?
                .to_owned()
        };
        let body = url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs([
                ("aaxmlrequest", "true".to_owned()),
                ("pageNo", page.to_string()),
                ("tabNo", "1".to_owned()),
                ("pager.offset", "10".to_owned()),
                ("tradename", String::new()),
                ("starttime", start.to_string()),
                ("endtime", end.to_string()),
                ("timetype", "1".into()),
                ("_tradedirect", "on".into()),
                ("_csrf", token),
            ])
            .finish()
            .into_bytes();
        let bytes = self
            .request(
                source,
                url::Url::parse(&format!("{ECARD}/epay/consume/query")).expect("constant URL"),
                HttpMethod::Post,
                Some((body, "application/x-www-form-urlencoded")),
                false,
            )
            .await?;
        let (rows, total) = parse_ecard_transactions(&bytes)?;
        if total > 0 && page > total
            || total == 0 && !rows.is_empty()
            || page < total && rows.is_empty()
        {
            return Err(CampusError::PaginationInconsistent);
        }
        let mut result = snapshot(source, "ecard-transaction", rows)?;
        result.coverage = Coverage::Page {
            next: (page < total).then_some(page + 1),
            total: None,
        };
        Ok(result)
    }

    pub async fn electricity(
        &self,
        source: &SourceContext,
    ) -> Result<SourceRecord<Electricity>, CampusError> {
        let data = self
            .get(source, ZLAPP, "/fudanelec/wap/default/info")
            .await?;
        let row = parse_electricity(&data)?;
        Ok(source.record(format!("electricity:{}", row.room_id), row.updated_at, row))
    }

    pub async fn library_occupancy(
        &self,
        source: &SourceContext,
    ) -> Result<SourceBatch<LibraryOccupancy>, CampusError> {
        let bytes = self
            .request(
                source,
                url::Url::parse("https://mlibrary.fudan.edu.cn/api/common/h5/getspaceseat")
                    .expect("constant URL"),
                HttpMethod::Post,
                None,
                true,
            )
            .await?;
        let rows = parse_library_occupancy(&bytes)?;
        batch(
            source,
            "library-occupancy",
            rows.into_iter().map(|r| (r.campus.clone(), r)).collect(),
            Coverage::Complete,
        )
    }

    pub async fn dining_occupancy(
        &self,
        source: &SourceContext,
        area_code: u8,
    ) -> Result<SourceBatch<DiningOccupancy>, CampusError> {
        if area_code > 15 {
            return Err(CampusError::InvalidQuery("dining area code"));
        }
        let data = self.get(source, MY, "/simple_list/stqk").await?;
        let rows = parse_dining_occupancy(&data, area_code)?;
        batch(
            source,
            "dining-occupancy",
            rows.into_iter()
                .map(|r| (format!("{}:{}", area_code, r.name), r))
                .collect(),
            Coverage::Complete,
        )
    }

    /// LAN URL is preserved; grant/VPN routing belongs to the host. No automatic proxy.
    pub async fn empty_classrooms(
        &self,
        source: &SourceContext,
        building: &str,
        on: NaiveDate,
    ) -> Result<SourceBatch<EmptyClassroom>, CampusError> {
        if building.trim().is_empty() || building.len() > 128 {
            return Err(CampusError::InvalidQuery("building"));
        }
        let mut status = url::Url::parse("http://10.64.130.6/daystatus.asp").expect("constant URL");
        status
            .query_pairs_mut()
            .extend_pairs([("b", building), ("day", &on.to_string())]);
        let mut detail = url::Url::parse("http://10.64.130.6/").expect("constant URL");
        detail.query_pairs_mut().extend_pairs([
            ("b", building),
            ("c", ""),
            ("p", ""),
            ("day", &on.to_string()),
        ]);
        let ids = self
            .request(source, status, HttpMethod::Get, None, true)
            .await?;
        let page = self
            .request(source, detail, HttpMethod::Get, None, true)
            .await?;
        let rows = parse_empty_classrooms(&ids, &page, on)?;
        batch(
            source,
            "empty-classroom",
            rows.into_iter()
                .map(|r| (format!("{}:{}", r.id, on), r))
                .collect(),
            Coverage::Complete,
        )
    }

    pub async fn pe_records(
        &self,
        source: &SourceContext,
    ) -> Result<SourceBatch<PeRecord>, CampusError> {
        let data = self
            .get(
                source,
                "https://fdtyjw.fudan.edu.cn",
                "/sportScore/stScore.aspx",
            )
            .await?;
        snapshot(source, "PE", parse_pe_records(&data)?)
    }

    pub async fn bus(
        &self,
        source: &SourceContext,
        holiday: bool,
    ) -> Result<SourceBatch<BusDeparture>, CampusError> {
        // Match Dio FormData's multipart shape, not an unverified JSON substitution.
        let body=format!("--dansheng-read-query\r\nContent-Disposition: form-data; name=\"holiday\"\r\n\r\n{}\r\n--dansheng-read-query--\r\n",if holiday {"1"} else {"0"}).into_bytes();
        let bytes = self
            .request(
                source,
                url::Url::parse(&format!("{ZLAPP}/fudanbus/wap/default/lists"))
                    .expect("constant URL"),
                HttpMethod::Post,
                Some((body, "multipart/form-data; boundary=dansheng-read-query")),
                false,
            )
            .await?;
        let rows = parse_bus(&bytes)?;
        batch(
            source,
            "bus",
            rows.into_iter().map(|r| (r.id.clone(), r)).collect(),
            Coverage::Complete,
        )
    }

    /// Explicit bounded page; `next` is unknown because pinned source has no pager parser.
    pub async fn aao_notices(
        &self,
        source: &SourceContext,
        kind: AaoKind,
        page: u32,
    ) -> Result<SourceBatch<AaoNotice>, CampusError> {
        if page == 0 || page > 1000 {
            return Err(CampusError::InvalidQuery("notice page"));
        }
        let (origin, category) = match kind {
            AaoKind::Undergraduate => ("https://jwc.fudan.edu.cn", "9397"),
            AaoKind::Postgraduate => ("https://gs.fudan.edu.cn", "tzgg"),
        };
        let suffix = if page == 1 {
            String::new()
        } else {
            page.to_string()
        };
        let bytes = self
            .get(source, origin, &format!("/{category}/list{suffix}.htm"))
            .await?;
        let rows = parse_aao_notices(&bytes, kind)?;
        let mut result = batch(
            source,
            "AAO",
            rows.into_iter().map(|r| (r.url.clone(), r)).collect(),
            Coverage::Complete,
        )?;
        // Do not pretend that a single notice page is the whole archive.
        result.coverage = Coverage::Window {
            position: format!("page:{page}"),
        };
        Ok(result)
    }

    pub async fn qr_state(
        &self,
        source: &SourceContext,
    ) -> Result<SourceRecord<QrState>, CampusError> {
        let data = self
            .get(source, ECARD, "/epay/wxpage/fudan/zfm/qrcode")
            .await?;
        Ok(source.record("qr-state".into(), None, parse_qr_state(&data)?))
    }

    /// Fixed read-only protocol from the pinned qr_code_repository.dart.
    /// Only the trusted service adapter can consume this transient credential.
    #[cfg(feature = "services")]
    pub(crate) async fn qr_presentation(
        &self,
        source: &SourceContext,
    ) -> Result<QrPresentation, CampusError> {
        let data = self
            .get(source, ECARD, "/epay/wxpage/fudan/zfm/qrcode")
            .await?;
        parse_qr_presentation(&data)
    }
}

fn data_table_coverage(
    data: &Value,
    page: PageWindow,
    count: usize,
) -> Result<Coverage, CampusError> {
    let total = unsigned(
        data.get("recordsFiltered")
            .or_else(|| data.get("recordsTotal"))
            .unwrap_or(&Value::Null),
        "data tables",
        "total",
    )?;
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
    Ok(Coverage::Page {
        next: (u64::from(next) < total).then_some(next),
        total: Some(total),
    })
}
