// SPDX-License-Identifier: GPL-3.0-or-later
//! Public undergraduate/integrated Fudan programs, observed 2026-11-09.
//! Only anonymous GET list/detail requests; no real-info, login, exports or selection.
use crate::campus::{CampusError, Coverage, SourceBatch};
use crate::models::{SourceContext, SourceRecord};
use crate::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse,
    ConnectorTransport, HttpMethod, TransportAuth,
};
use scraper::Html;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use url::Url;

pub const PROGRAM_ORIGIN: &str = "https://fdjwgl.fudan.edu.cn";
pub const PROGRAM_REVISION: &str = "fudan-public-programs-2026-11-09";
pub const PROGRAM_BIZ_TYPE: &str = "2";
pub const MAX_PROGRAM_BODY: usize = 2 * 1024 * 1024;
const LIST_PATH: &str = "/manager/bizType/2/page-center/major-program-search-view/search";
const DETAIL_PREFIX: &str = "/manager/bizType/2/major-program-search/info/";

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ProgramPage {
    pub number: u32,
    pub size: u16,
}
impl ProgramPage {
    pub fn validate(self) -> Result<(), CampusError> {
        if !(1..=10_000).contains(&self.number) || !(1..=100).contains(&self.size) {
            return Err(CampusError::InvalidQuery(
                "program page must be 1..10000 and size 1..100",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ProgramLimits {
    pub max_body_bytes: usize,
    pub max_text_bytes: usize,
    pub max_total_text_bytes: usize,
    pub max_sections: usize,
    pub max_nodes: usize,
    pub max_tree_depth: usize,
}
impl Default for ProgramLimits {
    fn default() -> Self {
        Self {
            max_body_bytes: MAX_PROGRAM_BODY,
            max_text_bytes: 256 * 1024,
            max_total_text_bytes: 1024 * 1024,
            max_sections: 200,
            max_nodes: 5_000,
            max_tree_depth: 16,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramSummary {
    pub program_id: String,
    pub biz_type_id: String,
    pub public_scope: String,
    pub title: String,
    pub cohort: Option<String>,
    pub major_id: Option<String>,
    pub major_name: Option<String>,
    pub department_name: Option<String>,
    pub department_ids: Vec<String>,
    /// Source-reported public publication/audit state, not a student's status.
    pub publication_state: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramEntity {
    pub id: Option<String>,
    pub name: Option<String>,
    pub code: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProgramSectionMode {
    Normal,
    CourseModuleSetting,
    StudyRequire,
    Unknown,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramSection {
    /// Paragraph IDs are bounded opaque strings (including UUIDs), not program IDs.
    pub id: String,
    pub position: Option<u32>,
    pub level: Option<u16>,
    pub title: Option<String>,
    pub title_en: Option<String>,
    pub text: Option<String>,
    pub text_en: Option<String>,
    pub mode: ProgramSectionMode,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramCourse {
    /// Source plan-row identifiers may be signed; preserve the reported sign.
    pub plan_course_id: String,
    pub course_id: String,
    pub code: String,
    pub name: String,
    /// Decimal source representation; never a computed earned-credit value.
    pub credits: Option<String>,
    pub compulsory: Option<bool>,
    pub terms_text: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramModule {
    pub id: String,
    pub name: Option<String>,
    pub name_en: Option<String>,
    pub parent_id: Option<String>,
    pub child_ids: Vec<String>,
    pub required_credits: Option<String>,
    pub required_courses: Option<u32>,
    pub required_submodules: Option<u32>,
    pub credits_upper_limit: Option<String>,
    pub courses_upper_limit: Option<u32>,
    pub courses: Vec<ProgramCourse>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramDetailCoverage {
    pub sections: Coverage,
    pub course_tree: Coverage,
    pub ignored_special_module_count: usize,
    pub unsupported_parent_reference_count: usize,
    pub ignored_dynamic_course_count: usize,
    pub ambiguous_module_count: usize,
    pub unknown_section_mode_count: usize,
    pub document_present: bool,
    pub study_require_present: bool,
    /// Fixed field families, never unknown raw payloads/keys or authentication material.
    pub unprojected_regions: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramDetail {
    pub program_id: String,
    pub biz_type_id: String,
    pub public_scope: String,
    pub title: String,
    pub title_en: Option<String>,
    pub cohort: Option<String>,
    /// Kept as a source code; unknown types are not interpreted as a student's role.
    pub source_program_type: Option<String>,
    pub education: Option<ProgramEntity>,
    pub major: Option<ProgramEntity>,
    pub department: Option<ProgramEntity>,
    pub credits_required: Option<String>,
    pub duration_years: Option<String>,
    pub terms_count: Option<u32>,
    pub effective_on: Option<String>,
    pub invalid_on: Option<String>,
    pub publication_state: Option<String>,
    pub sections: Vec<ProgramSection>,
    pub course_modules: Vec<ProgramModule>,
    pub coverage: ProgramDetailCoverage,
}

fn schema(field: &'static str) -> CampusError {
    CampusError::SchemaChanged {
        domain: "academic_programs",
        field,
    }
}
fn limit() -> CampusError {
    ConnectorError::LimitExceeded.into()
}
fn validate_source(source: &SourceContext) -> Result<(), CampusError> {
    if source.account_id.trim().is_empty() || source.source_id.trim().is_empty() {
        return Err(ConnectorError::InvalidConfiguration("source identity").into());
    }
    Ok(())
}

fn check_public_response(
    response: &ConnectorResponse,
    source: &SourceContext,
    max_bytes: usize,
) -> Result<(), CampusError> {
    let auth = || {
        ConnectorError::AuthRequired(AuthChallenge {
            connector: "fudan.programs".into(),
            origin: PROGRAM_ORIGIN.into(),
            account_id: source.account_id.clone(),
            mode: AuthMode::HttpSession,
        })
    };
    if response.status == 401 || (300..400).contains(&response.status) {
        return Err(auth().into());
    }
    if response.status == 403 {
        return Err(ConnectorError::PermissionDenied.into());
    }
    if !(200..300).contains(&response.status) {
        return Err(ConnectorError::HttpStatus(response.status).into());
    }
    if response.body.len() > max_bytes {
        return Err(limit());
    }
    let origin = Url::parse(PROGRAM_ORIGIN).expect("constant origin");
    let path = response.final_url.path().to_ascii_lowercase();
    if response.final_url.origin() != origin.origin()
        || path.contains("/login")
        || path.contains("/authserver")
    {
        return Err(auth().into());
    }
    let prefix = String::from_utf8_lossy(&response.body[..response.body.len().min(16384)])
        .to_ascii_lowercase();
    if (prefix.contains("<html") || prefix.contains("<!doctype html") || prefix.contains("<form"))
        && (prefix.contains("password")
            || prefix.contains("authserver")
            || prefix.contains("/login")
            || prefix.contains("统一身份认证"))
    {
        return Err(auth().into());
    }
    Ok(())
}
fn id(value: &str) -> Result<String, CampusError> {
    if value.is_empty()
        || value.len() > 32
        || !value.bytes().all(|b| b.is_ascii_digit())
        || value.bytes().all(|b| b == b'0')
    {
        return Err(CampusError::InvalidQuery(
            "positive decimal program identifier",
        ));
    }
    Ok(value.to_owned())
}
fn json_id(v: &Value, field: &'static str) -> Result<String, CampusError> {
    let raw = match v {
        Value::String(s) => s.clone(),
        Value::Number(n) if n.is_u64() => n.to_string(),
        _ => return Err(schema(field)),
    };
    id(&raw).map_err(|_| schema(field))
}
fn signed_plan_id(v: &Value) -> Result<String, CampusError> {
    let raw = match v {
        Value::String(s) => s.clone(),
        Value::Number(n) if n.is_i64() || n.is_u64() => n.to_string(),
        _ => return Err(schema("plan course id")),
    };
    let digits = raw.strip_prefix('-').unwrap_or(&raw);
    if digits.is_empty()
        || digits.len() > 32
        || !digits.bytes().all(|b| b.is_ascii_digit())
        || digits.bytes().all(|b| b == b'0')
    {
        return Err(schema("plan course id"));
    }
    Ok(raw)
}
fn opaque_id(v: &Value) -> Result<String, CampusError> {
    let value = v.as_str().ok_or_else(|| schema("paragraph id"))?;
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    {
        return Err(schema("paragraph id"));
    }
    Ok(value.to_owned())
}
fn json(body: &[u8], limits: ProgramLimits) -> Result<Value, CampusError> {
    if body.len() > limits.max_body_bytes {
        return Err(limit());
    }
    // Strict JSON only: no eval, JS expressions, callbacks, JSONP or script extraction.
    serde_json::from_slice(body).map_err(|_| schema("strict JSON"))
}
fn object<'a>(v: &'a Value, field: &'static str) -> Result<&'a Map<String, Value>, CampusError> {
    v.as_object().ok_or_else(|| schema(field))
}
fn nonempty(v: &Value) -> bool {
    !v.is_null() && (!v.is_array() || !v.as_array().is_some_and(Vec::is_empty))
}
fn optional_u32(v: &Value, field: &'static str) -> Result<Option<u32>, CampusError> {
    if v.is_null() {
        return Ok(None);
    }
    v.as_u64()
        .and_then(|n| u32::try_from(n).ok())
        .map(Some)
        .ok_or_else(|| schema(field))
}
fn optional_bool(v: &Value, field: &'static str) -> Result<Option<bool>, CampusError> {
    if v.is_null() {
        return Ok(None);
    }
    v.as_bool().map(Some).ok_or_else(|| schema(field))
}
fn decimal(v: &Value, field: &'static str) -> Result<Option<String>, CampusError> {
    if v.is_null() {
        return Ok(None);
    }
    let value = match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return Err(schema(field)),
    };
    if value.len() > 32
        || value.is_empty()
        || !value.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        || value.matches('.').count() > 1
        || value.starts_with('.')
        || value.ends_with('.')
    {
        return Err(schema(field));
    }
    Ok(Some(value))
}
struct Budget {
    limits: ProgramLimits,
    text: usize,
    nodes: usize,
}
impl Budget {
    fn text(&mut self, v: &Value, field: &'static str) -> Result<Option<String>, CampusError> {
        if v.is_null() {
            return Ok(None);
        }
        let raw = v.as_str().ok_or_else(|| schema(field))?;
        if raw.len() > self.limits.max_text_bytes {
            return Err(limit());
        }
        let doc = Html::parse_fragment(raw);
        let mut output = String::new();
        for node in doc.root_element().descendants() {
            let Some(text) = node.value().as_text() else {
                continue;
            };
            if node
                .ancestors()
                .filter_map(|a| a.value().as_element())
                .any(|e| {
                    matches!(
                        e.name(),
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
            {
                continue;
            }
            output.push_str(text);
            output.push(' ');
            if output.len() > self.limits.max_text_bytes {
                return Err(limit());
            }
        }
        let output = output
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        self.text = self.text.checked_add(output.len()).ok_or_else(limit)?;
        if output.len() > self.limits.max_text_bytes || self.text > self.limits.max_total_text_bytes
        {
            return Err(limit());
        }
        Ok((!output.is_empty()).then_some(output))
    }
    fn required_text(&mut self, v: &Value, field: &'static str) -> Result<String, CampusError> {
        self.text(v, field)?.ok_or_else(|| schema(field))
    }
    fn node(&mut self) -> Result<(), CampusError> {
        self.nodes = self.nodes.checked_add(1).ok_or_else(limit)?;
        if self.nodes > self.limits.max_nodes {
            return Err(limit());
        }
        Ok(())
    }
}
fn entity(v: &Value, budget: &mut Budget) -> Result<Option<ProgramEntity>, CampusError> {
    if v.is_null() {
        return Ok(None);
    }
    object(v, "named entity")?;
    Ok(Some(ProgramEntity {
        id: if v["id"].is_null() {
            None
        } else {
            Some(json_id(&v["id"], "entity id")?)
        },
        name: budget.text(&v["nameZh"], "entity name")?,
        code: budget.text(&v["code"], "entity code")?,
    }))
}

pub fn parse_program_list(
    body: &[u8],
    source: &SourceContext,
    page: ProgramPage,
) -> Result<SourceBatch<ProgramSummary>, CampusError> {
    parse_program_list_with_limits(body, source, page, ProgramLimits::default())
}
fn parse_program_list_with_limits(
    body: &[u8],
    source: &SourceContext,
    page: ProgramPage,
    limits: ProgramLimits,
) -> Result<SourceBatch<ProgramSummary>, CampusError> {
    validate_source(source)?;
    page.validate()?;
    let value = json(body, limits)?;
    let data = value["data"].as_array().ok_or_else(|| schema("data"))?;
    if data.len() > usize::from(page.size) {
        return Err(limit());
    }
    let pagination = object(&value["_page_"], "pagination")?;
    let n = |key: &'static str| {
        pagination
            .get(key)
            .and_then(Value::as_u64)
            .ok_or_else(|| schema(key))
    };
    let current = n("currentPage")?;
    let size = n("rowsPerPage")?;
    let count = n("rowsInPage")?;
    let total = n("totalRows")?;
    let pages = n("totalPages")?;
    let offset = u64::from(page.number - 1) * u64::from(page.size);
    if current != u64::from(page.number)
        || size != u64::from(page.size)
        || count != data.len() as u64
        || total > 1_000_000
        || pages != total.div_ceil(u64::from(page.size))
        || offset > total
        || count != total.saturating_sub(offset).min(size)
        || (total > 0 && current > pages)
        || (total == 0 && page.number != 1)
    {
        return Err(CampusError::PaginationInconsistent);
    }
    let mut seen = BTreeSet::new();
    let mut records = Vec::new();
    let mut budget = Budget {
        limits,
        text: 0,
        nodes: 0,
    };
    for row in data {
        object(row, "program row")?;
        budget.node()?;
        let program_id = json_id(&row["ID"], "program id")?;
        if !seen.insert(program_id.clone()) {
            return Err(schema("duplicate program id"));
        }
        let cohort = match &row["YEARS"] {
            Value::Number(n) if n.is_u64() => Some(n.to_string()),
            v => budget.text(v, "cohort")?,
        };
        let mut department_ids = Vec::new();
        match &row["DEPART_IDS"] {
            Value::Null => {}
            Value::Array(ids) => {
                if ids.len() > 100 {
                    return Err(limit());
                }
                for value in ids {
                    department_ids.push(json_id(value, "department id")?)
                }
            }
            Value::String(s) => {
                if s.len() > 1024 {
                    return Err(limit());
                }
                for part in s.split(',') {
                    department_ids.push(id(part.trim()).map_err(|_| schema("department ids"))?)
                }
            }
            v => department_ids.push(json_id(v, "department id")?),
        }
        if department_ids.iter().collect::<BTreeSet<_>>().len() != department_ids.len() {
            return Err(schema("duplicate department id"));
        }
        let summary = ProgramSummary {
            program_id: program_id.clone(),
            biz_type_id: PROGRAM_BIZ_TYPE.into(),
            public_scope: "undergraduate_and_integrated_public_program".into(),
            title: budget.required_text(&row["NAME_ZH"], "program title")?,
            cohort,
            major_id: if row["MAJOR_ID"].is_null() {
                None
            } else {
                Some(json_id(&row["MAJOR_ID"], "major id")?)
            },
            major_name: budget.text(&row["MAJOR_NAME"], "major name")?,
            department_name: budget.text(&row["DEPART_NAME"], "department name")?,
            department_ids,
            publication_state: budget.text(&row["AUDIT_STATE"], "publication state")?,
        };
        records.push(source.record(
            format!("program:{PROGRAM_BIZ_TYPE}:{program_id}"),
            None,
            summary,
        ));
    }
    Ok(SourceBatch {
        source: source.clone(),
        source_revision: PROGRAM_REVISION.into(),
        records,
        coverage: if current < pages && page.number == 10_000 {
            Coverage::UnsupportedRemainder {
                reported_total: total,
                returned: data.len(),
            }
        } else {
            Coverage::Page {
                next: (current < pages).then_some(page.number + 1),
                total: Some(total),
            }
        },
    })
}

pub fn parse_program_detail(body: &[u8], program_id: &str) -> Result<ProgramDetail, CampusError> {
    parse_program_detail_with_limits(body, program_id, ProgramLimits::default())
}

fn parse_program_detail_with_limits(
    body: &[u8],
    program_id: &str,
    limits: ProgramLimits,
) -> Result<ProgramDetail, CampusError> {
    id(program_id)?;
    let value = json(body, limits)?;
    object(&value, "detail object")?;
    let model = &value["model"];
    object(model, "model")?;
    if json_id(&model["id"], "model id")? != program_id {
        return Err(schema("model id mismatch"));
    }
    if json_id(&model["bizType"]["id"], "model biz type")? != PROGRAM_BIZ_TYPE {
        return Err(schema("model biz type mismatch"));
    }
    let mut budget = Budget {
        limits,
        text: 0,
        nodes: 0,
    };
    let title = budget.required_text(&model["nameZh"], "model title")?;
    let mut sections = Vec::new();
    let mut section_ids = BTreeSet::new();
    let mut unknown_modes = 0;
    let paragraph_values = value["programContent"]["paragraphs"]
        .as_array()
        .ok_or_else(|| schema("paragraphs"))?;
    if paragraph_values.len() > limits.max_sections {
        return Err(limit());
    }
    let modes = object(&value["paragraphMode"], "paragraph modes")?;
    for row in paragraph_values {
        object(row, "paragraph")?;
        budget.node()?;
        let section_id = opaque_id(&row["id"])?;
        if !section_ids.insert(section_id.clone()) {
            return Err(schema("duplicate paragraph id"));
        }
        let mode = match modes.get(&section_id).and_then(Value::as_str) {
            Some("NORMAL") => ProgramSectionMode::Normal,
            Some("COURSE_MODULE_SETTING") => ProgramSectionMode::CourseModuleSetting,
            Some("STUDY_REQUIRE") => ProgramSectionMode::StudyRequire,
            _ => {
                unknown_modes += 1;
                ProgramSectionMode::Unknown
            }
        };
        let level = optional_u32(&row["level"], "paragraph level")?
            .map(|n| u16::try_from(n).map_err(|_| schema("paragraph level")))
            .transpose()?;
        sections.push(ProgramSection {
            id: section_id,
            position: optional_u32(&row["indexNo"], "paragraph position")?,
            level,
            title: budget.text(&row["titleZh"], "paragraph title")?,
            title_en: budget.text(&row["titleEn"], "paragraph english title")?,
            text: budget.text(&row["contentZh"], "paragraph text")?,
            text_en: budget.text(&row["contentEn"], "paragraph english text")?,
            mode,
        });
    }
    let mut modules = BTreeMap::new();
    let mut unsupported = UnprojectedCounts::default();
    let module_values = value["courseModules"]
        .as_array()
        .ok_or_else(|| schema("course modules"))?;
    visit_modules(
        module_values,
        None,
        0,
        &mut budget,
        &mut modules,
        &mut unsupported,
    )?;
    let mut external_relations = false;
    for module in modules.values() {
        if module
            .parent_id
            .as_ref()
            .is_some_and(|parent| !modules.contains_key(parent))
            || module
                .child_ids
                .iter()
                .any(|child| !modules.contains_key(child))
        {
            external_relations = true
        }
        let mut parents = BTreeSet::new();
        let mut current = Some(module.id.as_str());
        while let Some(node) = current {
            if !parents.insert(node) {
                return Err(schema("module cycle"));
            }
            if parents.len() > limits.max_tree_depth + 1 {
                return Err(limit());
            }
            current = modules.get(node).and_then(|item| item.parent_id.as_deref());
        }
    }
    let mut unprojected = vec![
        "module_rules_outside_supported_fields".to_owned(),
        "management_and_personal_associations".to_owned(),
    ];
    let document_present = nonempty(&value["document"]);
    let study_require_present = nonempty(&value["studyRequire"]);
    if document_present {
        unprojected.push("document_download_protocol".into())
    }
    if study_require_present {
        unprojected.push("dynamic_study_require_tables".into())
    }
    if unsupported.special_modules > 0 {
        unprojected.push("special_module_identifiers".into())
    }
    if unsupported.parent_references > 0 {
        unprojected.push("unsupported_parent_references".into());
    }
    if unsupported.dynamic_courses > 0 {
        unprojected.push("dynamic_course_references".into());
    }
    if !unsupported.ambiguous_modules.is_empty() {
        unprojected.push("ambiguous_source_module_identifiers".into());
    }
    if unknown_modes > 0 {
        unprojected.push("unknown_paragraph_modes".into())
    }
    if external_relations {
        unprojected.push("external_module_relations".into())
    }
    if value.as_object().is_some_and(|obj| {
        obj.keys().any(|key| {
            !matches!(
                key.as_str(),
                "document"
                    | "paragraphMode"
                    | "model"
                    | "programContent"
                    | "studyRequire"
                    | "courseModules"
            )
        })
    }) {
        unprojected.push("unknown_top_level_regions".into());
    }
    Ok(ProgramDetail {
        program_id: program_id.into(),
        biz_type_id: PROGRAM_BIZ_TYPE.into(),
        public_scope: "undergraduate_and_integrated_public_program".into(),
        title,
        title_en: budget.text(&model["nameEn"], "model english title")?,
        cohort: budget.text(&model["grade"], "model cohort")?,
        source_program_type: budget.text(&model["type"], "program type")?,
        education: entity(&model["education"], &mut budget)?,
        major: entity(&model["major"], &mut budget)?,
        department: entity(&model["department"], &mut budget)?,
        credits_required: decimal(&model["credits"], "program credits")?,
        duration_years: decimal(&model["duration"], "duration")?,
        terms_count: optional_u32(&model["termsCount"], "terms count")?,
        effective_on: budget.text(&model["effectiveOn"], "effective on")?,
        invalid_on: budget.text(&model["invalidOn"], "invalid on")?,
        publication_state: budget.text(&model["auditState"], "model publication state")?,
        sections,
        course_modules: modules.into_values().collect(),
        coverage: ProgramDetailCoverage {
            sections: Coverage::Window {
                position: "supported_public_paragraph_text".into(),
            },
            course_tree: Coverage::Window {
                position: "supported_public_course_module_projection".into(),
            },
            ignored_special_module_count: unsupported.special_modules,
            unsupported_parent_reference_count: unsupported.parent_references,
            ignored_dynamic_course_count: unsupported.dynamic_courses,
            ambiguous_module_count: unsupported.ambiguous_modules.len(),
            unknown_section_mode_count: unknown_modes,
            document_present,
            study_require_present,
            unprojected_regions: unprojected,
        },
    })
}

fn optional_array<'a>(v: &'a Value, field: &'static str) -> Result<&'a [Value], CampusError> {
    match v {
        Value::Null => Ok(&[]),
        Value::Array(values) => Ok(values),
        _ => Err(schema(field)),
    }
}
#[derive(Default)]
struct UnprojectedCounts {
    special_modules: usize,
    parent_references: usize,
    dynamic_courses: usize,
    ambiguous_modules: BTreeSet<String>,
}

fn relation_id(
    v: &Value,
    unsupported: &mut UnprojectedCounts,
) -> Result<Option<String>, CampusError> {
    if v.is_null() {
        return Ok(None);
    }
    match json_id(v, "module relation id") {
        Ok(value) => Ok(Some(value)),
        Err(_) => {
            unsupported.parent_references += 1;
            Ok(None)
        }
    }
}
fn visit_modules(
    rows: &[Value],
    parent: Option<&str>,
    depth: usize,
    budget: &mut Budget,
    modules: &mut BTreeMap<String, ProgramModule>,
    unsupported: &mut UnprojectedCounts,
) -> Result<(), CampusError> {
    if depth > budget.limits.max_tree_depth {
        return Err(limit());
    }
    for row in rows {
        object(row, "module")?;
        budget.node()?;
        let children = optional_array(&row["children"], "module children")?;
        let module_id = match json_id(&row["id"], "module id") {
            Ok(id) => id,
            Err(_) => {
                unsupported.special_modules += 1;
                visit_modules(children, parent, depth + 1, budget, modules, unsupported)?;
                continue;
            }
        };
        let declared_parent = relation_id(&row["parentAssoc"], unsupported)?;
        if parent.is_some()
            && declared_parent
                .as_deref()
                .is_some_and(|declared| Some(declared) != parent)
        {
            return Err(schema("module parent mismatch"));
        }
        let parent_id = declared_parent.or_else(|| parent.map(str::to_owned));
        if parent_id.as_deref() == Some(&module_id) {
            return Err(schema("module self parent"));
        }
        let mut child_ids = Vec::new();
        let mut unique_children = BTreeSet::new();
        for child in children {
            object(child, "module child")?;
            if let Ok(child_id) = json_id(&child["id"], "child id") {
                if !unique_children.insert(child_id.clone()) {
                    return Err(schema("duplicate child id"));
                }
                child_ids.push(child_id);
            }
        }
        child_ids.sort();
        if !row["requireInfo"].is_null() {
            object(&row["requireInfo"], "module requirements")?;
        }
        if !row["limitInfo"].is_null() {
            object(&row["limitInfo"], "module limits")?;
        }
        let mut courses = Vec::new();
        let mut course_ids = BTreeSet::new();
        for plan in optional_array(&row["planCourses"], "module courses")? {
            object(plan, "plan course")?;
            budget.node()?;
            let course = &plan["course"];
            object(course, "course")?;
            // Non-positive public references do not establish an ordinary
            // catalog-course identity. Leave them explicitly unprojected.
            let nonpositive = match &course["id"] {
                Value::Number(n) => n.as_i64().is_some_and(|n| n <= 0),
                Value::String(s) => {
                    s.strip_prefix('-').is_some_and(|digits| {
                        !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
                    }) || (!s.is_empty() && s.bytes().all(|b| b == b'0'))
                }
                _ => false,
            };
            if nonpositive {
                unsupported.dynamic_courses += 1;
                continue;
            }
            let course_id = json_id(&course["id"], "course id")?;
            let plan_id = signed_plan_id(&plan["id"])?;
            if !course_ids.insert(plan_id.clone()) {
                return Err(schema("duplicate plan course id"));
            }
            courses.push(ProgramCourse {
                plan_course_id: plan_id,
                course_id,
                code: budget.required_text(&course["code"], "course code")?,
                name: budget.required_text(&course["nameZh"], "course name")?,
                credits: decimal(&course["credits"], "course credits")?,
                compulsory: optional_bool(&plan["compulsory"], "course compulsory")?,
                terms_text: budget.text(&plan["termsText"], "course terms")?,
            });
        }
        courses.sort_by(|a, b| a.plan_course_id.cmp(&b.plan_course_id));
        let module = ProgramModule {
            id: module_id.clone(),
            name: budget.text(&row["nameZh"], "module name")?,
            name_en: budget.text(&row["nameEn"], "module english name")?,
            parent_id,
            child_ids,
            required_credits: decimal(
                &row["requireInfo"]["requiredCredits"],
                "module required credits",
            )?,
            required_courses: optional_u32(
                &row["requireInfo"]["requiredCourseNum"],
                "module required courses",
            )?,
            required_submodules: optional_u32(
                &row["requireInfo"]["requiredSubModuleNum"],
                "module required submodules",
            )?,
            credits_upper_limit: decimal(
                &row["limitInfo"]["creditsUpperLimit"],
                "module maximum credits",
            )?,
            courses_upper_limit: optional_u32(
                &row["limitInfo"]["courseNumUpperLimit"],
                "module maximum courses",
            )?,
            courses,
        };
        if unsupported.ambiguous_modules.contains(&module_id) {
            // Already excluded: another occurrence cannot silently restore it.
        } else if let Some(previous) = modules.get(&module_id) {
            if previous != &module {
                modules.remove(&module_id);
                unsupported.ambiguous_modules.insert(module_id.clone());
            }
        } else {
            modules.insert(module_id.clone(), module);
        }
        visit_modules(
            children,
            Some(&module_id),
            depth + 1,
            budget,
            modules,
            unsupported,
        )?;
    }
    Ok(())
}

pub struct FudanProgramClient<T: ConnectorTransport> {
    transport: T,
    limits: ProgramLimits,
}
impl<T: ConnectorTransport> FudanProgramClient<T> {
    pub fn new(transport: T) -> Self {
        Self {
            transport,
            limits: ProgramLimits::default(),
        }
    }
    pub fn with_limits(mut self, limits: ProgramLimits) -> Result<Self, CampusError> {
        let maximum = ProgramLimits::default();
        if limits.max_body_bytes == 0
            || limits.max_body_bytes > maximum.max_body_bytes
            || limits.max_text_bytes == 0
            || limits.max_text_bytes > maximum.max_text_bytes
            || limits.max_total_text_bytes == 0
            || limits.max_total_text_bytes > maximum.max_total_text_bytes
            || limits.max_sections == 0
            || limits.max_sections > maximum.max_sections
            || limits.max_nodes == 0
            || limits.max_nodes > maximum.max_nodes
            || limits.max_tree_depth == 0
            || limits.max_tree_depth > maximum.max_tree_depth
        {
            return Err(CampusError::InvalidQuery("program limits"));
        }
        self.limits = limits;
        Ok(self)
    }
    async fn get(
        &self,
        source: &SourceContext,
        path: &str,
        query: &[(String, String)],
    ) -> Result<Vec<u8>, CampusError> {
        validate_source(source)?;
        let origin = Url::parse(PROGRAM_ORIGIN).expect("constant origin");
        let mut url = origin.join(path).map_err(|_| ConnectorError::UnsafeUrl)?;
        if url.origin() != origin.origin()
            || !(url.path() == LIST_PATH || url.path().starts_with(DETAIL_PREFIX))
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
                headers: vec![("Accept".into(), "application/json".into())],
                body: None,
                auth: TransportAuth::Anonymous,
            })
            .await?;
        check_public_response(&response, source, self.limits.max_body_bytes)?;
        if response.final_url != url {
            return Err(ConnectorError::UnsafeUrl.into());
        }
        if let Some((_, mime)) = response
            .headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case("content-type"))
            && !mime
                .split(';')
                .next()
                .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
        {
            return Err(schema("content type"));
        }
        Ok(response.body)
    }
    /// One explicitly bounded public page. No filters have yet been publicly verified.
    pub async fn list(
        &self,
        source: &SourceContext,
        page: ProgramPage,
    ) -> Result<SourceBatch<ProgramSummary>, CampusError> {
        page.validate()?;
        let body = self
            .get(
                source,
                LIST_PATH,
                &[
                    ("skipAuth".into(), "1".into()),
                    (
                        "queryPage__".into(),
                        format!("{},{}", page.number, page.size),
                    ),
                ],
            )
            .await?;
        parse_program_list_with_limits(&body, source, page, self.limits)
    }
    /// Public program rules only, never student progress, real-info or Word export.
    pub async fn detail(
        &self,
        source: &SourceContext,
        program_id: &str,
    ) -> Result<SourceRecord<ProgramDetail>, CampusError> {
        id(program_id)?;
        let body = self
            .get(source, &format!("{DETAIL_PREFIX}{program_id}"), &[])
            .await?;
        Ok(source.record(
            format!("program:{PROGRAM_BIZ_TYPE}:{program_id}"),
            None,
            parse_program_detail_with_limits(&body, program_id, self.limits)?,
        ))
    }
}
