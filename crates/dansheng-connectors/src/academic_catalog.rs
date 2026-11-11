// SPDX-License-Identifier: GPL-3.0-or-later
//! Public Fudan academic catalog and syllabus reads observed 2026-11-09.
//! No login, selection, evaluation, export or other business mutation is performed.
use crate::campus::{CampusError, Coverage, SourceBatch};
use crate::models::{SourceContext, SourceRecord};
use crate::transport::check_response;
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use regex::Regex;
use scraper::{ElementRef, Html, Selector};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use url::Url;

pub const CATALOG_ORIGIN: &str = "https://fdjwgl.fudan.edu.cn";
pub const CATALOG_REVISION: &str = "fudan-public-academic-2026-11-09";
const ROOT: &str = "/student/for-all/lesson-search";
const MAX_BODY: usize = 2 * 1024 * 1024;
const MAX_TEXT: usize = 256 * 1024;
const MAX_SEMESTERS: usize = 256;
const MAX_SECTIONS: usize = 200;

fn schema(field: &'static str) -> CampusError {
    CampusError::SchemaChanged {
        domain: "academic_catalog",
        field,
    }
}
fn invalid(field: &'static str) -> CampusError {
    CampusError::InvalidQuery(field)
}
fn selector(s: &str) -> Selector {
    Selector::parse(s).expect("constant selector")
}
fn bounded_utf8(body: &[u8]) -> Result<&str, CampusError> {
    if body.len() > MAX_BODY {
        return Err(ConnectorError::LimitExceeded.into());
    }
    std::str::from_utf8(body).map_err(|_| schema("encoding"))
}
fn id(s: &str) -> Result<String, CampusError> {
    if s.is_empty()
        || s.len() > 32
        || !s.bytes().all(|c| c.is_ascii_digit())
        || s.bytes().all(|c| c == b'0')
    {
        return Err(invalid("positive decimal identifier"));
    }
    Ok(s.to_owned())
}
fn json_id(v: &Value) -> Result<String, CampusError> {
    let s = match v {
        Value::String(s) => s.clone(),
        Value::Number(n) if n.is_u64() => n.to_string(),
        _ => return Err(schema("identifier")),
    };
    id(&s).map_err(|_| schema("identifier"))
}
fn normalized(s: &str) -> Result<String, CampusError> {
    if s.len() > MAX_TEXT {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(s.split_whitespace().collect::<Vec<_>>().join(" "))
}
fn plain_text(element: ElementRef<'_>) -> Result<String, CampusError> {
    let mut text = String::new();
    for node in element.descendants() {
        let Some(t) = node.value().as_text() else {
            continue;
        };
        let excluded = node
            .ancestors()
            .filter_map(|a| a.value().as_element())
            .any(|e| {
                matches!(
                    e.name(),
                    "script" | "style" | "template" | "noscript" | "iframe" | "object" | "svg"
                )
            });
        if !excluded {
            text.push_str(t);
            text.push(' ');
            if text.len() > MAX_TEXT {
                return Err(ConnectorError::LimitExceeded.into());
            }
        }
    }
    normalized(&text)
}
fn html_text(html: &str) -> Result<String, CampusError> {
    if html.len() > MAX_TEXT {
        return Err(ConnectorError::LimitExceeded.into());
    }
    plain_text(Html::parse_document(html).root_element())
}
fn optional_text(v: &Value, field: &'static str) -> Result<Option<String>, CampusError> {
    match v {
        Value::Null => Ok(None),
        Value::String(s) => {
            let s = normalized(s)?;
            Ok((!s.is_empty()).then_some(s))
        }
        _ => Err(schema(field)),
    }
}
fn schedule_text(v: &Value) -> Result<Option<String>, CampusError> {
    let value = if v.is_object() {
        let text = v
            .get("dateTimePlacePersonText")
            .ok_or_else(|| schema("scheduleText.dateTimePlacePersonText"))?;
        if text.is_object() {
            text.get("textZh")
                .ok_or_else(|| schema("scheduleText.textZh"))?
        } else {
            text
        }
    } else {
        v
    };
    optional_text(value, "schedule text")
}
fn required_text(v: &Value, field: &'static str) -> Result<String, CampusError> {
    optional_text(v, field)?.ok_or_else(|| schema(field))
}
fn optional_named(v: &Value, field: &'static str) -> Result<Option<String>, CampusError> {
    if v.is_null() {
        return Ok(None);
    }
    if v.is_string() {
        return optional_text(v, field);
    }
    let o = v.as_object().ok_or_else(|| schema(field))?;
    optional_text(
        o.get("nameZh")
            .or_else(|| o.get("name"))
            .ok_or_else(|| schema(field))?,
        field,
    )
}
fn optional_number(v: &Value, field: &'static str) -> Result<Option<String>, CampusError> {
    if v.is_null() {
        return Ok(None);
    }
    let s = match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return Err(schema(field)),
    };
    if s.len() > 32
        || s.parse::<f64>()
            .ok()
            .is_none_or(|v| !v.is_finite() || v < 0.0)
    {
        return Err(schema(field));
    }
    Ok(Some(s))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogSemester {
    pub id: String,
    pub name: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogSemesters {
    pub semesters: Vec<CatalogSemester>,
    pub default_semester_id: String,
}

pub fn parse_catalog_semesters(body: &[u8]) -> Result<CatalogSemesters, CampusError> {
    let html = Html::parse_document(bounded_utf8(body)?);
    let semester_selector = selector("select#semester");
    let mut selects = html.select(&semester_selector);
    let select = selects.next().ok_or_else(|| schema("semester selector"))?;
    if selects.next().is_some() {
        return Err(schema("ambiguous semester selector"));
    }
    let mut ids = BTreeSet::new();
    let mut semesters = Vec::new();
    let mut selected = None;
    for option in select.select(&selector("option")) {
        let raw = option
            .value()
            .attr("value")
            .ok_or_else(|| schema("semester value"))?;
        if raw.is_empty() {
            if option.value().attr("selected").is_some() {
                return Err(schema("default semester"));
            }
            continue;
        }
        let identifier = id(raw).map_err(|_| schema("semester identifier"))?;
        if !ids.insert(identifier.clone()) {
            return Err(schema("duplicate semester"));
        }
        let name = plain_text(option)?;
        if name.is_empty() || name.len() > 512 {
            return Err(schema("semester name"));
        }
        if option.value().attr("selected").is_some()
            && selected.replace(identifier.clone()).is_some()
        {
            return Err(schema("multiple default semesters"));
        }
        semesters.push(CatalogSemester {
            id: identifier,
            name,
        });
        if semesters.len() > MAX_SEMESTERS {
            return Err(ConnectorError::LimitExceeded.into());
        }
    }
    if semesters.is_empty() {
        return Err(schema("semesters"));
    }
    Ok(CatalogSemesters {
        semesters,
        default_semester_id: selected.ok_or_else(|| schema("default semester"))?,
    })
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogPage {
    pub number: u32,
    pub size: u16,
}
impl CatalogPage {
    pub fn validate(self) -> Result<(), CampusError> {
        if self.number == 0 || self.number > 10_000 || self.size == 0 || self.size > 100 {
            return Err(invalid("page must be 1..10000 and size 1..100"));
        }
        Ok(())
    }
}
/// Explicit public form keys only. Values are URL encoded; hidden account selectors are excluded.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogFilters {
    pub fields: BTreeMap<String, String>,
}
impl CatalogFilters {
    pub fn validate(&self) -> Result<(), CampusError> {
        if self.fields.len() > 16 {
            return Err(invalid("too many catalog filters"));
        }
        for (key, value) in &self.fields {
            if !matches!(
                key.as_str(),
                "courseCodeLike"
                    | "courseNameZhLike"
                    | "codeLike"
                    | "nameZhLike"
                    | "teacherNameLike"
                    | "roomNameLike"
                    | "teachingSyllabus"
                    | "creditsGte"
                    | "creditsLte"
                    | "scheduleWeekGte"
                    | "scheduleWeekLte"
                    | "limitCountGte"
                    | "limitCountLte"
                    | "stdCountGte"
                    | "stdCountLte"
            ) {
                return Err(invalid("unsupported public catalog filter"));
            }
            if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
                return Err(invalid("invalid catalog filter value"));
            }
            if key == "teachingSyllabus" && !matches!(value.as_str(), "0" | "1") {
                return Err(invalid("teachingSyllabus must be 0 or 1"));
            }
            if (key.ends_with("Gte") || key.ends_with("Lte"))
                && value
                    .parse::<f64>()
                    .ok()
                    .is_none_or(|n| !n.is_finite() || n < 0.0)
            {
                return Err(invalid("catalog numeric filter"));
            }
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogCourse {
    pub course_id: String,
    pub code: String,
    pub name: String,
    /// Preserve the source decimal representation instead of converting credits to integer units.
    pub credits: Option<String>,
    pub subject_class: Option<String>,
    pub level: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogLesson {
    pub semester_id: String,
    pub lesson_id: String,
    pub lesson_code: String,
    pub name: String,
    pub course: CatalogCourse,
    pub department: Option<String>,
    pub teachers: Vec<String>,
    pub schedule_text: Option<String>,
    pub teaching_language: Option<String>,
    pub enrollment_limit: Option<String>,
    pub enrolled: Option<String>,
}
impl CatalogLesson {
    /// Course information is a catalog projection; the separate info route returned 404.
    pub fn course_record(
        &self,
        source: &SourceContext,
    ) -> Result<SourceRecord<CatalogCourse>, CampusError> {
        source.validate()?;
        Ok(source.record(
            format!(
                "catalog_course:{}:{}",
                self.semester_id, self.course.course_id
            ),
            None,
            self.course.clone(),
        ))
    }
}
fn parse_lesson(v: &Value, semester: &str) -> Result<CatalogLesson, CampusError> {
    let course = v
        .get("course")
        .filter(|c| c.is_object())
        .ok_or_else(|| schema("course"))?;
    let mut teachers = Vec::new();
    if let Some(values) = v.get("teacherAssignmentList").filter(|v| !v.is_null()) {
        let values = values
            .as_array()
            .ok_or_else(|| schema("teacherAssignmentList"))?;
        if values.len() > 100 {
            return Err(ConnectorError::LimitExceeded.into());
        }
        for value in values {
            let teacher = value
                .get("person")
                .or_else(|| value.get("teacher"))
                .unwrap_or(value);
            if let Some(name) = optional_named(teacher, "teacher")? {
                teachers.push(name);
            }
        }
    }
    Ok(CatalogLesson {
        semester_id: semester.into(),
        lesson_id: json_id(&v["id"])?,
        lesson_code: required_text(&v["code"], "lesson code")?,
        name: optional_text(&v["nameZh"], "lesson name")?
            .unwrap_or(required_text(&course["nameZh"], "course name")?),
        course: CatalogCourse {
            course_id: json_id(&course["id"])?,
            code: required_text(&course["code"], "course code")?,
            name: required_text(&course["nameZh"], "course name")?,
            credits: optional_number(&course["credits"], "credits")?,
            subject_class: optional_named(&course["subjectClass"], "subject class")?,
            level: optional_named(&course["courseDifficultyLevel"], "level")?,
        },
        department: optional_named(&v["openDepartment"], "department")?,
        teachers,
        schedule_text: schedule_text(&v["scheduleText"])?,
        teaching_language: optional_named(&v["teachLang"], "teaching language")?,
        enrollment_limit: optional_number(&v["limitCount"], "limit count")?,
        enrolled: optional_number(&v["stdCount"], "enrolled count")?,
    })
}

pub fn parse_catalog_lessons(
    body: &[u8],
    source: &SourceContext,
    semester: &str,
    page: CatalogPage,
) -> Result<SourceBatch<CatalogLesson>, CampusError> {
    source.validate()?;
    id(semester)?;
    page.validate()?;
    let value: Value =
        serde_json::from_slice(bounded_utf8(body)?.as_bytes()).map_err(|_| schema("json"))?;
    let data = value
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| schema("data"))?;
    if data.len() > usize::from(page.size) {
        return Err(ConnectorError::LimitExceeded.into());
    }
    let coverage = match value.get("_page_") {
        None | Some(Value::Null) => Coverage::Window {
            position: format!(
                "semester:{semester}:page:{}:size:{}",
                page.number, page.size
            ),
        },
        Some(p) => {
            let current = p["currentPage"]
                .as_u64()
                .ok_or_else(|| schema("currentPage"))?;
            let size = p["rowsPerPage"]
                .as_u64()
                .ok_or_else(|| schema("rowsPerPage"))?;
            let count = p["rowsInPage"]
                .as_u64()
                .ok_or_else(|| schema("rowsInPage"))?;
            let total = p["totalRows"].as_u64().ok_or_else(|| schema("totalRows"))?;
            let total_pages = p["totalPages"]
                .as_u64()
                .ok_or_else(|| schema("totalPages"))?;
            let expected_pages = total.div_ceil(u64::from(page.size));
            if current != u64::from(page.number)
                || size != u64::from(page.size)
                || count != data.len() as u64
                || count
                    != total
                        .saturating_sub(current.saturating_sub(1).saturating_mul(size))
                        .min(size)
                || total_pages != expected_pages
                || total > 1_000_000
                || (current - 1).saturating_mul(size).saturating_add(count) > total
                || (total > 0 && current > total_pages)
                || (total > 0 && count == 0)
            {
                return Err(CampusError::PaginationInconsistent);
            }
            Coverage::Page {
                next: (current < total_pages).then_some(page.number + 1),
                total: Some(total),
            }
        }
    };
    let mut ids = BTreeSet::new();
    let mut records = Vec::new();
    for value in data {
        let lesson = parse_lesson(value, semester)?;
        if !ids.insert(lesson.lesson_id.clone()) {
            return Err(schema("duplicate lesson identifier"));
        }
        records.push(source.record(
            format!("catalog_lesson:{semester}:{}", lesson.lesson_id),
            None,
            lesson,
        ));
    }
    Ok(SourceBatch {
        source: source.clone(),
        source_revision: CATALOG_REVISION.into(),
        records,
        coverage,
    })
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyllabusSection {
    pub title: String,
    pub text: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogSyllabus {
    /// Only supported HTML/paragraph text is projected; dynamic assessment tables are not a full syllabus export.
    pub text_coverage: Coverage,
    pub lesson_id: String,
    pub sections: Vec<SyllabusSection>,
}

/// Convert a data-only JS object literal to strict JSON without executing JavaScript.
/// Only JSON values plus single-quoted strings are accepted; functions/expressions fail.
fn js_data_to_json(input: &str) -> Result<Value, CampusError> {
    if input.len() > MAX_BODY / 2 {
        return Err(ConnectorError::LimitExceeded.into());
    }
    let mut chars = input.chars().peekable();
    let mut output = String::new();
    while let Some(c) = chars.next() {
        if c != '\'' && c != '"' {
            output.push(c);
            continue;
        }
        let quote = c;
        let mut encoded = String::from("\"");
        let mut closed = false;
        while let Some(c) = chars.next() {
            if c == quote {
                closed = true;
                break;
            }
            match c {
                '\\' => {
                    let e = chars
                        .next()
                        .ok_or_else(|| schema("syllabus literal escape"))?;
                    if e == 'x' {
                        let first = chars.next().ok_or_else(|| schema("syllabus hex escape"))?;
                        let second = chars.next().ok_or_else(|| schema("syllabus hex escape"))?;
                        if !first.is_ascii_hexdigit() || !second.is_ascii_hexdigit() {
                            return Err(schema("syllabus hex escape"));
                        }
                        encoded.push_str("\\u00");
                        encoded.push(first);
                        encoded.push(second);
                    } else if e == '\'' {
                        encoded.push('\'');
                    } else {
                        encoded.push('\\');
                        encoded.push(e);
                    }
                }
                '"' => encoded.push_str("\\\""),
                '\n' | '\r' => return Err(schema("syllabus literal newline")),
                _ => encoded.push(c),
            }
        }
        if !closed {
            return Err(schema("syllabus literal string"));
        }
        encoded.push('"');
        let decoded: String =
            serde_json::from_str(&encoded).map_err(|_| schema("syllabus literal escape"))?;
        output.push_str(&serde_json::to_string(&decoded).map_err(|_| schema("syllabus string"))?);
    }
    serde_json::from_str(&output).map_err(|_| schema("syllabus data literal"))
}
fn model_literal(script: &str) -> Result<Option<Value>, CampusError> {
    let pattern = Regex::new(r"(?m)^\s*(?:let|var|const)\s+model\s*=\s*").expect("constant regex");
    let mut matches = pattern.find_iter(script);
    let Some(start) = matches.next() else {
        return Ok(None);
    };
    if matches.next().is_some() {
        return Err(schema("ambiguous syllabus model"));
    }
    let input = &script[start.end()..];
    let mut depth = 0u32;
    let mut quote = None;
    let mut escape = false;
    let mut end = None;
    if !input.starts_with('{') {
        return Err(schema("syllabus model literal"));
    }
    for (i, c) in input.char_indices() {
        if let Some(q) = quote {
            if escape {
                escape = false;
            } else if c == '\\' {
                escape = true;
            } else if c == q {
                quote = None;
            }
            continue;
        }
        match c {
            '\'' | '"' => quote = Some(c),
            '{' | '[' => {
                depth += 1;
                if depth > 64 {
                    return Err(ConnectorError::LimitExceeded.into());
                }
            }
            '}' | ']' => {
                depth = depth
                    .checked_sub(1)
                    .ok_or_else(|| schema("syllabus model nesting"))?;
                if depth == 0 {
                    end = Some(i + c.len_utf8());
                    break;
                }
            }
            _ => {}
        }
    }
    let end = end.ok_or_else(|| schema("syllabus model boundary"))?;
    if !input[end..].trim_start().starts_with(';') {
        return Err(schema("syllabus model expression"));
    }
    Ok(Some(js_data_to_json(&input[..end])?))
}

pub fn parse_catalog_syllabus(
    body: &[u8],
    lesson_id: &str,
) -> Result<CatalogSyllabus, CampusError> {
    id(lesson_id)?;
    let document = Html::parse_document(bounded_utf8(body)?);
    let mut sections = Vec::new();
    for item in document.select(&selector(".base-info-item")) {
        let label = item
            .select(&selector(".base-info-label"))
            .next()
            .ok_or_else(|| schema("syllabus base label"))?;
        let value = item
            .select(&selector(".base-info-value"))
            .next()
            .ok_or_else(|| schema("syllabus base value"))?;
        let title = plain_text(label)?;
        let text = plain_text(value)?;
        if !title.is_empty() {
            sections.push(SyllabusSection { title, text });
        }
    }
    let mut model = None;
    for script in document.select(&selector("script:not([src])")) {
        if let Some(value) = model_literal(&script.text().collect::<String>())?
            && model.replace(value).is_some()
        {
            return Err(schema("multiple syllabus models"));
        }
    }
    if let Some(model) = model {
        let paragraphs = model
            .pointer("/structuredDocument/paragraphs")
            .and_then(Value::as_array)
            .ok_or_else(|| schema("syllabus paragraphs"))?;
        if paragraphs.len() > MAX_SECTIONS {
            return Err(ConnectorError::LimitExceeded.into());
        }
        for paragraph in paragraphs {
            let title = optional_text(&paragraph["titleZh"], "syllabus title")?
                .or(optional_text(
                    &paragraph["titleEn"],
                    "syllabus English title",
                )?)
                .ok_or_else(|| schema("syllabus title"))?;
            let mut text = Vec::new();
            for field in ["contentZh", "contentEn"] {
                if let Some(value) = optional_text(&paragraph[field], "syllabus content")? {
                    text.push(html_text(&value)?);
                }
            }
            sections.push(SyllabusSection {
                title: html_text(&title)?,
                text: text.join("\n"),
            });
        }
    } else {
        for element in document.select(&selector(".para")) {
            let Some(title) = element.select(&selector(".para-title")).next() else {
                continue;
            };
            let title = plain_text(title)?;
            let text = plain_text(element)?;
            if !title.is_empty() {
                sections.push(SyllabusSection { title, text });
            }
        }
    }
    if sections.is_empty() {
        return Err(schema("syllabus sections"));
    }
    if sections.len() > MAX_SECTIONS
        || sections
            .iter()
            .map(|s| s.title.len() + s.text.len())
            .sum::<usize>()
            > MAX_TEXT
    {
        return Err(ConnectorError::LimitExceeded.into());
    }
    Ok(CatalogSyllabus {
        text_coverage: Coverage::Window {
            position: "supported_html_and_paragraph_text".into(),
        },
        lesson_id: lesson_id.into(),
        sections,
    })
}

pub struct FudanAcademicCatalogClient<T: ConnectorTransport> {
    transport: T,
}
impl<T: ConnectorTransport> FudanAcademicCatalogClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport }
    }
    async fn get(
        &self,
        source: &SourceContext,
        path: &str,
        query: &[(String, String)],
        html: bool,
    ) -> Result<Vec<u8>, CampusError> {
        source.validate()?;
        let origin = Url::parse(CATALOG_ORIGIN).expect("constant origin");
        let mut url = origin.join(path).map_err(|_| ConnectorError::UnsafeUrl)?;
        if url.origin() != origin.origin()
            || !url.path().starts_with(ROOT)
            || url.username() != ""
            || url.password().is_some()
        {
            return Err(ConnectorError::UnsafeUrl.into());
        }
        if !query.is_empty() {
            url.query_pairs_mut()
                .extend_pairs(query.iter().map(|(k, v)| (k.as_str(), v.as_str())));
        }
        let response = self
            .transport
            .execute(ConnectorRequest {
                method: HttpMethod::Get,
                url: url.clone(),
                headers: vec![(
                    "Accept".into(),
                    if html {
                        "text/html"
                    } else {
                        "application/json"
                    }
                    .into(),
                )],
                body: None,
                auth: TransportAuth::Anonymous,
            })
            .await?;
        check_response(
            &response,
            &origin,
            AuthChallenge {
                connector: "fudan.academic_catalog".into(),
                origin: CATALOG_ORIGIN.into(),
                account_id: source.account_id.clone(),
                mode: AuthMode::HttpSession,
            },
            MAX_BODY,
        )?;
        if response.final_url != url {
            return Err(ConnectorError::UnsafeUrl.into());
        }
        if let Some((_, content_type)) = response
            .headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case("content-type"))
        {
            let mime = content_type
                .split(';')
                .next()
                .unwrap_or("")
                .trim()
                .to_ascii_lowercase();
            if if html {
                mime != "text/html"
            } else {
                mime != "application/json"
            } {
                return Err(schema("content type"));
            }
        }
        Ok(response.body)
    }
    pub async fn semesters(
        &self,
        source: &SourceContext,
    ) -> Result<SourceRecord<CatalogSemesters>, CampusError> {
        let body = self.get(source, ROOT, &[], true).await?;
        Ok(source.record(
            "catalog_semesters".into(),
            None,
            parse_catalog_semesters(&body)?,
        ))
    }
    /// Reads one bounded page. Failure never yields a partial successful batch.
    pub async fn lessons(
        &self,
        source: &SourceContext,
        semester: &str,
        page: CatalogPage,
        filters: &CatalogFilters,
    ) -> Result<SourceBatch<CatalogLesson>, CampusError> {
        id(semester)?;
        page.validate()?;
        filters.validate()?;
        let path = format!("{ROOT}/semester/{semester}/search/{semester}");
        let mut query = vec![(
            "queryPage__".into(),
            format!("{},{}", page.number, page.size),
        )];
        query.extend(filters.fields.iter().map(|(k, v)| (k.clone(), v.clone())));
        let body = self.get(source, &path, &query, false).await?;
        parse_catalog_lessons(&body, source, semester, page)
    }
    pub async fn syllabus(
        &self,
        source: &SourceContext,
        lesson_id: &str,
    ) -> Result<SourceRecord<CatalogSyllabus>, CampusError> {
        id(lesson_id)?;
        let check = self
            .get(
                source,
                &format!("{ROOT}/check-can-info"),
                &[("id".into(), lesson_id.into())],
                false,
            )
            .await?;
        let check: Value = serde_json::from_slice(&check).map_err(|_| schema("syllabus check"))?;
        match check {
            Value::Null => {}
            Value::String(reason) if !reason.trim().is_empty() => {
                return Err(ConnectorError::CourseAccessDenied.into());
            }
            _ => return Err(schema("syllabus check")),
        }
        let body = self
            .get(
                source,
                &format!("{ROOT}/teachingSyllabusInfo/{lesson_id}"),
                &[],
                true,
            )
            .await?;
        Ok(source.record(
            format!("catalog_syllabus:{lesson_id}"),
            None,
            parse_catalog_syllabus(&body, lesson_id)?,
        ))
    }
}
