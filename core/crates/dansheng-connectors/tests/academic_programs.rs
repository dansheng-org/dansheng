// SPDX-License-Identifier: GPL-3.0-or-later
use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use dansheng_connectors::academic_programs::*;
use dansheng_connectors::campus::{CampusError, Coverage};
use dansheng_connectors::models::SourceContext;
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
use url::Url;

const ID: &str = "9007199254740993123456789";
const LIST: &[u8] = include_bytes!("../fixtures/academic_programs/list-first.json");
const SECOND: &[u8] = include_bytes!("../fixtures/academic_programs/list-second.json");
const DETAIL: &[u8] = include_bytes!("../fixtures/academic_programs/detail.json");
const EMPTY: &[u8] = include_bytes!("../fixtures/academic_programs/empty-list.json");
fn source() -> SourceContext {
    SourceContext {
        account_id: "synthetic-owner".into(),
        source_id: "synthetic-programs".into(),
        observed_at: Utc.with_ymd_and_hms(2031, 9, 1, 1, 0, 0).unwrap(),
    }
}
fn page(number: u32) -> ProgramPage {
    ProgramPage { number, size: 1 }
}
fn path(number: u32) -> String {
    format!(
        "/manager/bizType/2/page-center/major-program-search-view/search?skipAuth=1&queryPage__={number}%2C1"
    )
}
fn reply(path: &str, body: &[u8]) -> ConnectorResponse {
    ConnectorResponse {
        status: 200,
        final_url: Url::parse(&format!("{PROGRAM_ORIGIN}{path}")).unwrap(),
        headers: vec![(
            "Content-Type".into(),
            "application/json; charset=UTF-8".into(),
        )],
        body: body.to_vec(),
    }
}
#[derive(Clone, Default)]
struct Fake {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    responses: Arc<Mutex<VecDeque<Result<ConnectorResponse, ConnectorError>>>>,
}
impl Fake {
    fn new(responses: Vec<ConnectorResponse>) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into_iter().map(Ok).collect())),
            ..Self::default()
        }
    }
}
#[async_trait]
impl ConnectorTransport for Fake {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected request")
    }
}
fn no_secret<T: serde::Serialize + std::fmt::Debug>(v: &T) {
    assert!(
        !serde_json::to_string(v)
            .unwrap()
            .contains("SYNTHETIC_EXCLUDED")
    );
    assert!(!format!("{v:?}").contains("SYNTHETIC_EXCLUDED"));
}

#[tokio::test]
async fn public_pages_preserve_decimal_ids_cohort_origin_and_source_coverage() {
    let fake = Fake::new(vec![reply(&path(1), LIST), reply(&path(2), SECOND)]);
    let c = FudanProgramClient::new(fake.clone());
    let first = c.list(&source(), page(1)).await.unwrap();
    let second = c.list(&source(), page(2)).await.unwrap();
    assert_eq!(first.records[0].payload.program_id, ID);
    assert_eq!(second.records[0].payload.program_id, "9007199254740993");
    assert_eq!(second.records[0].payload.cohort.as_deref(), Some("2032"));
    assert_eq!(first.source.source_id, "synthetic-programs");
    assert_eq!(
        first.coverage,
        Coverage::Page {
            next: Some(2),
            total: Some(2)
        }
    );
    assert_eq!(
        second.coverage,
        Coverage::Page {
            next: None,
            total: Some(2)
        }
    );
    assert_eq!(first.records[0].payload.department_ids, vec!["81", "82"]);
    no_secret(&first);
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    for req in requests.iter() {
        assert_eq!(req.method, HttpMethod::Get);
        assert!(matches!(req.auth, TransportAuth::Anonymous));
        assert!(req.body.is_none());
        assert_eq!(req.headers.len(), 1);
        assert_eq!(req.headers[0].0, "Accept");
        assert_eq!(req.url.host_str(), Some("fdjwgl.fudan.edu.cn"));
        assert!(
            req.url
                .query_pairs()
                .any(|(k, v)| k == "skipAuth" && v == "1")
        );
    }
}

#[tokio::test]
async fn detail_projects_public_requirements_and_inert_text_without_student_certification() {
    let fake = Fake::new(vec![reply(
        &format!("/manager/bizType/2/major-program-search/info/{ID}"),
        DETAIL,
    )]);
    let row = FudanProgramClient::new(fake.clone())
        .detail(&source(), ID)
        .await
        .unwrap();
    assert_eq!(
        row.payload.source_program_type.as_deref(),
        Some("CUSTOM_SOURCE_PROGRAM")
    );
    assert_eq!(
        row.payload.education.as_ref().unwrap().code.as_deref(),
        Some("SOURCE_UNKNOWN")
    );
    assert_eq!(row.payload.credits_required.as_deref(), Some("128.50"));
    assert_eq!(row.payload.course_modules.len(), 2);
    let root = &row.payload.course_modules[0];
    assert_eq!(root.child_ids, vec!["102"]);
    assert_eq!(root.required_credits.as_deref(), Some("12.50"));
    assert_eq!(root.courses[0].credits.as_deref(), Some("2.50"));
    assert_eq!(root.courses[0].plan_course_id, "9007199254740993123456001");
    assert_eq!(row.payload.sections[2].mode, ProgramSectionMode::Unknown);
    assert_eq!(row.payload.coverage.unknown_section_mode_count, 1);
    assert_eq!(row.payload.coverage.ignored_special_module_count, 1);
    assert!(matches!(
        row.payload.coverage.course_tree,
        Coverage::Window { .. }
    ));
    assert!(
        row.payload
            .coverage
            .unprojected_regions
            .contains(&"dynamic_study_require_tables".into())
    );
    assert!(
        row.payload.sections[0]
            .text
            .as_ref()
            .unwrap()
            .contains("查看说明")
    );
    assert!(!row.payload.sections[0].text.as_ref().unwrap().contains('<'));
    no_secret(&row);
    let output = serde_json::to_value(&row).unwrap();
    assert!(output["payload"].get("earned_credits").is_none());
    assert!(output["payload"].get("graduation_eligible").is_none());
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].url.query().is_none());
    assert!(matches!(requests[0].auth, TransportAuth::Anonymous));
}

#[test]
fn empty_page_is_valid_and_bad_pagination_does_not_become_an_empty_success() {
    let batch = parse_program_list(EMPTY, &source(), page(1)).unwrap();
    assert!(batch.records.is_empty());
    assert_eq!(
        batch.coverage,
        Coverage::Page {
            next: None,
            total: Some(0)
        }
    );
    for (key, value) in [
        ("currentPage", json!(2)),
        ("rowsInPage", json!(0)),
        ("rowsPerPage", json!(2)),
        ("totalRows", json!(1)),
        ("totalPages", json!(1)),
    ] {
        let mut v: Value = serde_json::from_slice(LIST).unwrap();
        v["_page_"][key] = value;
        assert_eq!(
            parse_program_list(&serde_json::to_vec(&v).unwrap(), &source(), page(1)).unwrap_err(),
            CampusError::PaginationInconsistent
        );
    }
    let mut v: Value = serde_json::from_slice(LIST).unwrap();
    v.as_object_mut().unwrap().remove("_page_");
    assert!(parse_program_list(&serde_json::to_vec(&v).unwrap(), &source(), page(1)).is_err());
    assert!(
        serde_json::from_str::<ProgramPage>(r#"{"number":1,"size":1,"YEARS":"2031"}"#).is_err()
    );
}

#[test]
fn list_invalid_duplicate_identifiers_and_private_source_identity_fail() {
    let mut v: Value = serde_json::from_slice(LIST).unwrap();
    let duplicate = v["data"][0].clone();
    v["data"].as_array_mut().unwrap().push(duplicate);
    v["_page_"] =
        json!({"currentPage":1,"rowsInPage":2,"rowsPerPage":2,"totalRows":2,"totalPages":1});
    assert!(
        parse_program_list(
            &serde_json::to_vec(&v).unwrap(),
            &source(),
            ProgramPage { number: 1, size: 2 }
        )
        .is_err()
    );
    for id in ["../real-info", "0", "-1", "", "1.1"] {
        let mut v: Value = serde_json::from_slice(LIST).unwrap();
        v["data"][0]["ID"] = json!(id);
        assert!(parse_program_list(&serde_json::to_vec(&v).unwrap(), &source(), page(1)).is_err());
    }
    let mut empty_source = source();
    empty_source.account_id.clear();
    assert!(parse_program_list(LIST, &empty_source, page(1)).is_err());
}

#[test]
fn detail_mismatched_program_or_academic_domain_cannot_be_returned() {
    assert!(parse_program_detail(DETAIL, "9007199254740993").is_err());
    for (key, value) in [
        ("id", json!("0")),
        ("bizType", json!({"id":1})),
        ("education", json!("not an entity")),
    ] {
        let mut v: Value = serde_json::from_slice(DETAIL).unwrap();
        v["model"][key] = value;
        assert!(parse_program_detail(&serde_json::to_vec(&v).unwrap(), ID).is_err());
    }
}

#[test]
fn repeated_references_are_normalized_but_conflicting_ids_and_parent_cycles_fail() {
    let valid = parse_program_detail(DETAIL, ID).unwrap();
    assert_eq!(valid.course_modules.len(), 2);
    let mut bad: Value = serde_json::from_slice(DETAIL).unwrap();
    bad["courseModules"][1]["nameZh"] = json!("conflicting name");
    let partial = parse_program_detail(&serde_json::to_vec(&bad).unwrap(), ID).unwrap();
    assert_eq!(partial.coverage.ambiguous_module_count, 1);
    assert!(
        partial
            .course_modules
            .iter()
            .all(|module| module.id != "102")
    );
    assert!(
        partial
            .coverage
            .unprojected_regions
            .contains(&"ambiguous_source_module_identifiers".into())
    );
    let mut bad: Value = serde_json::from_slice(DETAIL).unwrap();
    bad["programContent"]["paragraphs"][1]["id"] = json!("section-a");
    assert!(parse_program_detail(&serde_json::to_vec(&bad).unwrap(), ID).is_err());
    let mut bad: Value = serde_json::from_slice(DETAIL).unwrap();
    bad["courseModules"] = json!([{"id":1,"parentAssoc":2,"children":[],"planCourses":[]},{"id":2,"parentAssoc":1,"children":[],"planCourses":[]}]);
    assert!(parse_program_detail(&serde_json::to_vec(&bad).unwrap(), ID).is_err());
    let mut bad: Value = serde_json::from_slice(DETAIL).unwrap();
    bad["courseModules"][0]["children"][0]["parentAssoc"] = json!(999);
    assert!(parse_program_detail(&serde_json::to_vec(&bad).unwrap(), ID).is_err());
}

#[test]
fn source_signed_plan_row_ids_do_not_change_the_positive_course_identity() {
    let mut value: Value = serde_json::from_slice(DETAIL).unwrap();
    value["courseModules"][0]["planCourses"][0]["id"] = json!(-201);
    let program = parse_program_detail(&serde_json::to_vec(&value).unwrap(), ID).unwrap();
    assert_eq!(program.course_modules[0].courses[0].plan_course_id, "-201");
    assert_eq!(program.course_modules[0].courses[0].course_id, "201");
}

#[test]
fn dynamic_nonpositive_course_references_are_explicitly_unprojected() {
    let mut value: Value = serde_json::from_slice(DETAIL).unwrap();
    value["courseModules"][0]["planCourses"][0]["course"]["id"] = json!(-201);
    let program = parse_program_detail(&serde_json::to_vec(&value).unwrap(), ID).unwrap();
    assert!(program.course_modules[0].courses.is_empty());
    assert_eq!(program.coverage.ignored_dynamic_course_count, 1);
    assert!(
        program
            .coverage
            .unprojected_regions
            .contains(&"dynamic_course_references".into())
    );
}

#[tokio::test]
async fn limits_bound_body_text_sections_nodes_and_tree_depth() {
    let path = format!("/manager/bizType/2/major-program-search/info/{ID}");
    for limits in [
        ProgramLimits {
            max_body_bytes: 8,
            ..Default::default()
        },
        ProgramLimits {
            max_text_bytes: 8,
            ..Default::default()
        },
        ProgramLimits {
            max_total_text_bytes: 16,
            ..Default::default()
        },
        ProgramLimits {
            max_sections: 1,
            ..Default::default()
        },
        ProgramLimits {
            max_nodes: 2,
            ..Default::default()
        },
    ] {
        let c = FudanProgramClient::new(Fake::new(vec![reply(&path, DETAIL)]))
            .with_limits(limits)
            .unwrap();
        assert_eq!(
            c.detail(&source(), ID).await.unwrap_err(),
            CampusError::Transport(ConnectorError::LimitExceeded)
        );
    }
    let mut v: Value = serde_json::from_slice(DETAIL).unwrap();
    let leaf = json!({"id":4,"children":[],"planCourses":[]});
    v["courseModules"] =
        json!([{"id":1,"children":[{"id":2,"children":[leaf],"planCourses":[]}],"planCourses":[]}]);
    let c = FudanProgramClient::new(Fake::new(vec![reply(
        &path,
        &serde_json::to_vec(&v).unwrap(),
    )]))
    .with_limits(ProgramLimits {
        max_tree_depth: 1,
        ..Default::default()
    })
    .unwrap();
    assert_eq!(
        c.detail(&source(), ID).await.unwrap_err(),
        CampusError::Transport(ConnectorError::LimitExceeded)
    );
    assert!(
        FudanProgramClient::new(Fake::default())
            .with_limits(ProgramLimits {
                max_body_bytes: MAX_PROGRAM_BODY + 1,
                ..Default::default()
            })
            .is_err()
    );
}

#[tokio::test]
async fn login_shell_permission_later_page_error_and_redirects_are_not_successful_data() {
    let mut shell = reply(
        &path(1),
        b"<html><form><input name=\"password\">login</form></html>",
    );
    shell.headers = vec![("Content-Type".into(), "text/html".into())];
    let fake = Fake::new(vec![shell]);
    assert!(matches!(
        FudanProgramClient::new(fake.clone())
            .list(&source(), page(1))
            .await
            .unwrap_err(),
        CampusError::Transport(ConnectorError::AuthRequired(_))
    ));
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
    let mut failure = reply(&path(2), SECOND);
    failure.status = 403;
    let fake = Fake::new(vec![reply(&path(1), LIST), failure]);
    let c = FudanProgramClient::new(fake.clone());
    c.list(&source(), page(1)).await.unwrap();
    assert_eq!(
        c.list(&source(), page(2)).await.unwrap_err(),
        CampusError::Transport(ConnectorError::PermissionDenied)
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 2);
    for url in [
        format!("{PROGRAM_ORIGIN}/manager/bizType/2/major-program-search/real-info/{ID}"),
        format!("{PROGRAM_ORIGIN}{}&YEARS=2031", path(1)),
    ] {
        let mut response = reply(&path(1), LIST);
        response.final_url = Url::parse(&url).unwrap();
        assert!(
            FudanProgramClient::new(Fake::new(vec![response]))
                .list(&source(), page(1))
                .await
                .is_err()
        );
    }
}

#[test]
fn only_strict_json_is_accepted_without_evaluating_expressions_or_jsonp() {
    for body in [
        b"callback({})".as_slice(),
        b"({'model': {'id': 1}})".as_slice(),
        b"{\"model\":(()=>{throw 'SYNTHETIC_EXCLUDED'})()}".as_slice(),
        b"{\"model\":null}; alert(1)".as_slice(),
    ] {
        assert!(parse_program_detail(body, ID).is_err());
    }
    assert!(parse_program_list(b"[]", &source(), page(1)).is_err());
}

#[tokio::test]
async fn invalid_ids_and_paging_are_rejected_before_any_anonymous_io() {
    let fake = Fake::default();
    let c = FudanProgramClient::new(fake.clone());
    for id in ["../x", "0", "-1", "", "1/real-info"] {
        assert!(c.detail(&source(), id).await.is_err());
    }
    for p in [
        ProgramPage { number: 0, size: 1 },
        ProgramPage {
            number: 1,
            size: 101,
        },
        ProgramPage {
            number: 10_001,
            size: 1,
        },
    ] {
        assert!(c.list(&source(), p).await.is_err());
    }
    assert!(fake.requests.lock().unwrap().is_empty());
}

/// Explicit protocol-research probe: input is an anonymous public JSON response
/// supplied through stdin, never a stored profile or copied live fixture.
#[test]
#[ignore = "manual public response supplied via bounded stdin; no network in test"]
fn public_response_from_stdin() {
    use std::io::Read;
    let mut body = Vec::new();
    std::io::stdin()
        .take((MAX_PROGRAM_BODY + 1) as u64)
        .read_to_end(&mut body)
        .unwrap();
    let public_id =
        std::env::var("DANSHENG_PUBLIC_PROGRAM_ID").expect("explicit public program ID");
    let program =
        parse_program_detail(&body, &public_id).expect("public program schema must parse");
    println!(
        "public_schema sections={} modules={} unsupported_special_nodes={}",
        program.sections.len(),
        program.course_modules.len(),
        program.coverage.ignored_special_module_count
    );
}
