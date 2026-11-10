// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2021 DanXi-Dev; Rust adaptation (C) 2026 dansheng-core contributors.
// Derived from DanXi 3c1f5f0: lib/model/time_table.dart and
// lib/repository/fdu/{time_table,postgraduate_timetable}_repository.dart.
// See ../NOTICE.md for source links and GPL attribution.
use crate::models::{Semester, SemesterCatalog, SourceContext, Timetable, TimetableCourse};
use crate::transport::{check_response, parse_error};
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use chrono::{Datelike, Duration, NaiveDate, Weekday};
use regex::Regex;
use scraper::{Html, Selector};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use url::Url;

pub const UNDERGRADUATE_ORIGIN: &str = "https://fdjwgl.fudan.edu.cn";
pub const UNDERGRADUATE_TABLE_PATH: &str = "/student/for-std/course-table";
pub const POSTGRADUATE_PRIMARY: &str = "http://yjsxk.fudan.edu.cn";
pub const POSTGRADUATE_SECONDARY: &str = "http://yjsxktest.fudan.sh.cn";
pub const POSTGRADUATE_TABLE_PATH: &str = "/yjsxkapp/sys/xsxkappfudan/xsxkCourse/loadKbxx.do";
const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_ACTIVITIES: usize = 10_000;

fn invalid(field: &'static str) -> ConnectorError {
    parse_error("Fudan timetable", field)
}

fn json(body: &[u8]) -> Result<Value, ConnectorError> {
    if body.len() > MAX_BODY {
        return Err(ConnectorError::LimitExceeded);
    }
    serde_json::from_slice(body).map_err(|_| invalid("json"))
}

fn text(value: &Value, field: &'static str) -> Result<String, ConnectorError> {
    value
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| invalid(field))
}

fn id(value: &Value, field: &'static str) -> Result<String, ConnectorError> {
    match value {
        Value::String(s) if !s.is_empty() => Ok(s.clone()),
        Value::Number(n) if n.is_u64() => Ok(n.to_string()),
        _ => Err(invalid(field)),
    }
}

fn number(value: &Value, field: &'static str) -> Result<u16, ConnectorError> {
    let n = match value {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    };
    n.and_then(|n| u16::try_from(n).ok())
        .ok_or_else(|| invalid(field))
}

fn unit(value: &Value, field: &'static str, max: u16) -> Result<u8, ConnectorError> {
    let n = number(value, field)?;
    if !(1..=max).contains(&n) {
        return Err(invalid(field));
    }
    Ok(n as u8)
}

fn validate_semester(semester: &Semester) -> Result<(), ConnectorError> {
    if semester.external_id.is_empty() || semester.starts_on.weekday() != Weekday::Mon {
        return Err(ConnectorError::InvalidConfiguration(
            "semester id and Monday start date",
        ));
    }
    Ok(())
}

fn table(
    source: SourceContext,
    semester: Semester,
    courses: Vec<TimetableCourse>,
) -> Result<Timetable, ConnectorError> {
    source.validate()?;
    validate_semester(&semester)?;
    let mut seen = BTreeSet::new();
    let mut records = Vec::new();
    for course in courses {
        // PG exposes no stable row id; content identity avoids unstable array-index IDs.
        // UG lesson identity remains available separately in payload.lesson_id.
        let bytes = serde_json::to_vec(&(&semester.external_id, &course))
            .map_err(|_| invalid("activity identity"))?;
        let external_id = format!("activity:{:x}", Sha256::digest(bytes));
        if seen.insert(external_id.clone()) {
            records.push(source.record(external_id, None, course));
        }
    }
    Ok(Timetable {
        source,
        semester,
        timezone: "Asia/Shanghai".into(),
        courses: records,
    })
}

/// Parse the JWGL print-data payload. Reject unknown envelopes instead of claiming
/// an empty successful timetable. An explicit empty activities array is valid.
pub fn parse_undergraduate_timetable(
    body: &[u8],
    source: SourceContext,
    semester: Semester,
) -> Result<Timetable, ConnectorError> {
    let data = json(body)?;
    let tables = data["studentTableVms"]
        .as_array()
        .ok_or_else(|| invalid("studentTableVms"))?;
    // An account-scoped endpoint must contain exactly one student's table.
    if tables.len() != 1 {
        return Err(invalid("studentTableVms count"));
    }
    let activities = tables[0]["activities"]
        .as_array()
        .ok_or_else(|| invalid("activities"))?;
    if activities.len() > MAX_ACTIVITIES {
        return Err(ConnectorError::LimitExceeded);
    }
    let mut courses = Vec::new();
    for activity in activities {
        let weekday = unit(&activity["weekday"], "weekday", 7)?;
        let start_unit = unit(&activity["startUnit"], "startUnit", 15)?;
        let end_unit = unit(&activity["endUnit"], "endUnit", 15)?;
        if end_unit < start_unit {
            return Err(invalid("unit range"));
        }
        let teachers = activity["teachers"]
            .as_array()
            .ok_or_else(|| invalid("teachers"))?
            .iter()
            .map(|v| text(v, "teacher"))
            .collect::<Result<Vec<_>, _>>()?;
        let weeks = activity["weekIndexes"]
            .as_array()
            .ok_or_else(|| invalid("weekIndexes"))?
            .iter()
            .map(|v| {
                let week = number(v, "weekIndexes")?;
                if !(1..=64).contains(&week) {
                    return Err(invalid("weekIndexes"));
                }
                // JWGL starts a week on Sunday; Monday-based week is one earlier for Sundays.
                Ok(if weekday == 7 { week - 1 } else { week })
            })
            .collect::<Result<BTreeSet<_>, ConnectorError>>()?
            .into_iter()
            .collect();
        let room = match &activity["room"] {
            Value::Null => None,
            Value::String(s) => Some(s.clone()),
            _ => return Err(invalid("room")),
        };
        courses.push(TimetableCourse {
            lesson_id: Some(id(&activity["lessonId"], "lessonId")?),
            course_code: Some(text(&activity["lessonCode"], "lessonCode")?),
            name: text(&activity["courseName"], "courseName")?,
            teachers,
            room,
            weekday,
            start_unit,
            end_unit,
            weeks,
        });
    }
    table(source, semester, courses)
}

/// The PG endpoint returns the current timetable only; `semester` is explicit
/// host-supplied calendar metadata, not a server-side semester query filter.
pub fn parse_postgraduate_timetable(
    body: &[u8],
    source: SourceContext,
    semester: Semester,
) -> Result<Timetable, ConnectorError> {
    let data = json(body)?;
    if data.get("success").and_then(Value::as_bool) == Some(false) {
        return Err(invalid("success"));
    }
    let results = data["results"]
        .as_array()
        .ok_or_else(|| invalid("results"))?;
    if results.len() > MAX_ACTIVITIES {
        return Err(ConnectorError::LimitExceeded);
    }
    let mut courses = Vec::new();
    for row in results {
        let bitmap = text(&row["ZCBH"], "ZCBH")?;
        if bitmap.len() > 64 || !bitmap.bytes().all(|b| b == b'0' || b == b'1') {
            return Err(invalid("ZCBH"));
        }
        let weeks = bitmap
            .bytes()
            .enumerate()
            .filter_map(|(i, b)| (b == b'1').then_some(i as u16 + 1))
            .collect();
        let teachers = match &row["JSXM"] {
            Value::Null => Vec::new(),
            Value::String(s) => {
                if s.is_empty() {
                    Vec::new()
                } else {
                    vec![s.clone()]
                }
            }
            _ => return Err(invalid("JSXM")),
        };
        let room = match &row["JASMC"] {
            Value::Null => None,
            Value::String(s) => Some(s.clone()),
            _ => return Err(invalid("JASMC")),
        };
        let start_unit = unit(&row["KSJCDM"], "KSJCDM", 15)?;
        // Reference PG rows represent a single slot. Honor an explicit end if provided.
        let end_unit = if row["JSJCDM"].is_null() {
            start_unit
        } else {
            unit(&row["JSJCDM"], "JSJCDM", 15)?
        };
        if end_unit < start_unit {
            return Err(invalid("unit range"));
        }
        courses.push(TimetableCourse {
            lesson_id: None,
            course_code: row
                .get("KCDM")
                .filter(|v| !v.is_null())
                .map(|v| id(v, "KCDM"))
                .transpose()?,
            name: text(&row["KCMC"], "KCMC")?,
            teachers,
            room,
            weekday: unit(&row["XQ"], "XQ", 7)?,
            start_unit,
            end_unit,
            weeks,
        });
    }
    table(source, semester, courses)
}

fn decode_js_string(literal: &str) -> Result<String, ConnectorError> {
    if literal.starts_with('"') {
        return serde_json::from_str(literal).map_err(|_| invalid("semesters literal"));
    }
    let mut encoded = String::from("\"");
    let mut chars = literal[1..literal.len() - 1].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                let escaped = chars.next().ok_or_else(|| invalid("semesters escape"))?;
                if escaped == '\'' {
                    encoded.push('\'');
                } else {
                    encoded.push('\\');
                    encoded.push(escaped);
                }
            }
            '"' => encoded.push_str("\\\""),
            _ => encoded.push(c),
        }
    }
    encoded.push('"');
    serde_json::from_str(&encoded).map_err(|_| invalid("semesters literal"))
}

/// Extract JSON from the semester script without executing any JavaScript.
pub fn parse_undergraduate_semesters(html: &str) -> Result<SemesterCatalog, ConnectorError> {
    if html.len() > MAX_BODY {
        return Err(ConnectorError::LimitExceeded);
    }
    let pattern = Regex::new(r#"(?s)\b(?:var|let|const)\s+semesters\s*=\s*JSON\.parse\(\s*((?:'(?:\\.|[^'\\])*')|(?:"(?:\\.|[^"\\])*"))\s*\)\s*;"#)
        .expect("constant regex");
    let captures = pattern
        .captures(html)
        .ok_or_else(|| invalid("semesters script"))?;
    let decoded = decode_js_string(&captures[1])?;
    let data: Value = serde_json::from_str(&decoded).map_err(|_| invalid("semesters JSON"))?;
    let entries = data.as_array().ok_or_else(|| invalid("semesters"))?;
    let mut semesters = Vec::new();
    for entry in entries.iter().rev() {
        let external_id = id(&entry["id"], "semester id")?;
        let raw_date = text(&entry["startDate"], "startDate")?;
        let sunday =
            NaiveDate::parse_from_str(&raw_date, "%Y-%m-%d").map_err(|_| invalid("startDate"))?;
        let starts_on = sunday
            .checked_add_signed(Duration::days(1))
            .ok_or_else(|| invalid("startDate"))?;
        let name = text(&entry["name"], "name")?;
        let semester = Semester {
            external_id,
            name,
            starts_on,
        };
        validate_semester(&semester).map_err(|_| invalid("startDate weekday"))?;
        semesters.push(semester);
    }
    let document = Html::parse_document(html);
    let selector = Selector::parse("#allSemesters option").expect("constant selector");
    let options: Vec<_> = document.select(&selector).collect();
    let default_semester_id = options
        .iter()
        .find(|o| o.value().attr("selected").is_some())
        .or_else(|| options.first())
        .and_then(|o| o.value().attr("value"))
        .ok_or_else(|| invalid("default semester"))?
        .to_owned();
    if !semesters
        .iter()
        .any(|s| s.external_id == default_semester_id)
    {
        return Err(invalid("default semester id"));
    }
    Ok(SemesterCatalog {
        semesters,
        default_semester_id,
    })
}

#[derive(Clone, Copy, Debug)]
pub enum PostgraduateEndpoint {
    Primary,
    Secondary,
}

pub struct FudanTimetableClient<T> {
    transport: T,
}

impl<T: ConnectorTransport> FudanTimetableClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport }
    }

    async fn get(&self, url: Url, source: &SourceContext) -> Result<Vec<u8>, ConnectorError> {
        source.validate()?;
        let challenge = AuthChallenge {
            connector: "fudan-timetable".into(),
            origin: url.origin().ascii_serialization(),
            account_id: source.account_id.clone(),
            mode: AuthMode::HttpSession,
        };
        let response = self
            .transport
            .execute(ConnectorRequest {
                method: HttpMethod::Get,
                url: url.clone(),
                headers: vec![("Accept".into(), "application/json, text/html".into())],
                body: None,
                auth: TransportAuth::HostSession {
                    account_id: source.account_id.clone(),
                },
            })
            .await?;
        check_response(&response, &url, challenge, MAX_BODY)?;
        Ok(response.body)
    }

    pub async fn undergraduate_semesters(
        &self,
        source: &SourceContext,
    ) -> Result<SemesterCatalog, ConnectorError> {
        let url = Url::parse(UNDERGRADUATE_ORIGIN)
            .expect("constant URL")
            .join(UNDERGRADUATE_TABLE_PATH)
            .expect("constant path");
        let bytes = self.get(url, source).await?;
        let html = std::str::from_utf8(&bytes).map_err(|_| invalid("HTML encoding"))?;
        parse_undergraduate_semesters(html)
    }

    /// None discovers the selected semester and its Monday start date first.
    pub async fn undergraduate(
        &self,
        source: SourceContext,
        semester: Option<Semester>,
    ) -> Result<Timetable, ConnectorError> {
        let semester = match semester {
            Some(s) => s,
            None => {
                let catalog = self.undergraduate_semesters(&source).await?;
                catalog
                    .semesters
                    .into_iter()
                    .find(|s| s.external_id == catalog.default_semester_id)
                    .ok_or_else(|| invalid("default semester"))?
            }
        };
        validate_semester(&semester)?;
        if semester.external_id.len() > 32
            || !semester.external_id.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(ConnectorError::InvalidConfiguration(
                "undergraduate semester id",
            ));
        }
        let mut url = Url::parse(UNDERGRADUATE_ORIGIN).expect("constant URL");
        // Use path segments: an untrusted ID cannot inject a path/query.
        url.path_segments_mut().expect("HTTP URL").extend([
            "student",
            "for-std",
            "course-table",
            "semester",
            &semester.external_id,
            "print-data",
        ]);
        let bytes = self.get(url, &source).await?;
        parse_undergraduate_timetable(&bytes, source, semester)
    }

    /// Endpoint selection is explicit. Never silently switch account session origins.
    pub async fn postgraduate(
        &self,
        source: SourceContext,
        semester: Semester,
        endpoint: PostgraduateEndpoint,
    ) -> Result<Timetable, ConnectorError> {
        validate_semester(&semester)?;
        let origin = match endpoint {
            PostgraduateEndpoint::Primary => POSTGRADUATE_PRIMARY,
            PostgraduateEndpoint::Secondary => POSTGRADUATE_SECONDARY,
        };
        let mut url = Url::parse(origin)
            .expect("constant URL")
            .join(POSTGRADUATE_TABLE_PATH)
            .expect("constant path");
        url.query_pairs_mut()
            .append_pair("_", &source.observed_at.timestamp_millis().to_string());
        let bytes = self.get(url, &source).await?;
        parse_postgraduate_timetable(&bytes, source, semester)
    }
}
