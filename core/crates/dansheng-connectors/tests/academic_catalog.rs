use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use dansheng_connectors::academic_catalog::*;
use dansheng_connectors::campus::{CampusError, Coverage};
use dansheng_connectors::models::SourceContext;
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, Mutex},
};
use url::Url;
macro_rules! fixture {
    ($name:literal) => {
        include_bytes!(concat!("../fixtures/academic_catalog/", $name))
    };
}
fn source() -> SourceContext {
    SourceContext {
        account_id: "synthetic-owner".into(),
        source_id: "synthetic-catalog".into(),
        observed_at: Utc.with_ymd_and_hms(2031, 9, 1, 1, 0, 0).unwrap(),
    }
}
fn page(number: u32) -> CatalogPage {
    CatalogPage { number, size: 1 }
}
#[derive(Clone)]
struct Fake {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    replies: Arc<Mutex<VecDeque<Result<Reply, ConnectorError>>>>,
}
struct Reply {
    body: Vec<u8>,
    status: u16,
    final_url: Option<Url>,
    mime: Option<&'static str>,
}
impl Fake {
    fn new(bodies: &[&[u8]]) -> Self {
        Self {
            requests: Arc::default(),
            replies: Arc::new(Mutex::new(
                bodies
                    .iter()
                    .map(|b| {
                        Ok(Reply {
                            body: b.to_vec(),
                            status: 200,
                            final_url: None,
                            mime: None,
                        })
                    })
                    .collect(),
            )),
        }
    }
    fn special(
        status: u16,
        final_url: Option<&str>,
        body: &[u8],
        mime: Option<&'static str>,
    ) -> Self {
        Self {
            requests: Arc::default(),
            replies: Arc::new(Mutex::new(VecDeque::from([Ok(Reply {
                body: body.to_vec(),
                status,
                final_url: final_url.map(|u| Url::parse(u).unwrap()),
                mime,
            })]))),
        }
    }
}
#[async_trait]
impl ConnectorTransport for Fake {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        let url = request.url.clone();
        self.requests.lock().unwrap().push(request);
        let r = self
            .replies
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected request")?;
        Ok(ConnectorResponse {
            status: r.status,
            final_url: r.final_url.unwrap_or(url),
            headers: r
                .mime
                .map(|m| vec![("content-type".into(), m.into())])
                .unwrap_or_default(),
            body: r.body,
        })
    }
}

#[test]
fn dynamic_semesters_have_no_invented_dates_or_default() {
    let parsed = parse_catalog_semesters(fixture!("semesters.html")).unwrap();
    assert_eq!(parsed.default_semester_id, "902");
    assert_eq!(parsed.semesters.len(), 2);
    assert_eq!(parsed.semesters[0].id, "901");
    assert!(
        !serde_json::to_string(&parsed)
            .unwrap()
            .contains("starts_on")
    );
}
#[test]
fn semester_schema_rejects_missing_duplicate_and_ambiguous_default() {
    for html in [
        "<select id='semester'><option value='1'>No selected</option></select>",
        "<select id='semester'><option value='1' selected>A</option><option value='1'>B</option></select>",
        "<select id='semester'><option value='1' selected>A</option><option value='2' selected>B</option></select>",
        "<select id='semester'><option value='../1' selected>A</option></select>",
        "<select id='semester'><option value='1' selected>A</option></select><select id='semester'></select>",
    ] {
        assert!(parse_catalog_semesters(html.as_bytes()).is_err());
    }
}
#[test]
fn lesson_ids_are_lossless_separate_from_courses_and_source_is_retained() {
    let batch =
        parse_catalog_lessons(fixture!("lessons-page1.json"), &source(), "902", page(1)).unwrap();
    let row = &batch.records[0];
    assert_eq!(row.payload.lesson_id, "9007199254740993123");
    assert_eq!(row.payload.course.course_id, "18446744073709551616000");
    assert_eq!(row.payload.course.credits.as_deref(), Some("0.5"));
    assert_eq!(row.payload.teachers, vec!["Synthetic Teacher"]);
    assert_eq!(row.source_id, source().source_id);
    assert_eq!(row.account_id, source().account_id);
    assert_eq!(row.observed_at, source().observed_at);
    assert_eq!(
        row.payload.course_record(&source()).unwrap().external_id,
        "catalog_course:902:18446744073709551616000"
    );
    assert_eq!(
        batch.coverage,
        Coverage::Page {
            next: Some(2),
            total: Some(2)
        }
    );
}
#[test]
fn terminal_and_empty_pages_are_bounded_observations() {
    let batch =
        parse_catalog_lessons(fixture!("lessons-page2.json"), &source(), "902", page(2)).unwrap();
    assert_eq!(
        batch.coverage,
        Coverage::Page {
            next: None,
            total: Some(2)
        }
    );
    let empty=br#"{"data":[],"_page_":{"currentPage":1,"rowsInPage":0,"rowsPerPage":1,"totalRows":0,"totalPages":0}}"#;
    let batch = parse_catalog_lessons(empty, &source(), "902", page(1)).unwrap();
    assert_eq!(batch.source, source());
    assert!(batch.records.is_empty());
    assert_eq!(
        batch.coverage,
        Coverage::Page {
            next: None,
            total: Some(0)
        }
    );
}
#[test]
fn missing_pagination_is_unknown_coverage_not_complete() {
    let mut v: Value = serde_json::from_slice(fixture!("lessons-page1.json")).unwrap();
    v.as_object_mut().unwrap().remove("_page_");
    let result =
        parse_catalog_lessons(&serde_json::to_vec(&v).unwrap(), &source(), "902", page(1)).unwrap();
    assert!(matches!(result.coverage, Coverage::Window { .. }));
}
#[test]
fn malformed_pagination_identity_and_rows_fail_closed() {
    for (path, value) in [
        ("currentPage", json!(2)),
        ("rowsPerPage", json!(20)),
        ("rowsInPage", json!(0)),
        ("totalRows", json!(1)),
        ("totalPages", json!(99)),
    ] {
        let mut v: Value = serde_json::from_slice(fixture!("lessons-page1.json")).unwrap();
        v["_page_"][path] = value;
        assert!(
            parse_catalog_lessons(&serde_json::to_vec(&v).unwrap(), &source(), "902", page(1))
                .is_err(),
            "{path}"
        );
    }
    for bad in [
        json!(1.5),
        json!(-1),
        json!("../1"),
        json!("0"),
        json!(null),
    ] {
        let mut v: Value = serde_json::from_slice(fixture!("lessons-page1.json")).unwrap();
        v["data"][0]["id"] = bad;
        assert!(
            parse_catalog_lessons(&serde_json::to_vec(&v).unwrap(), &source(), "902", page(1))
                .is_err()
        );
    }
    let oversized = vec![b' '; 2 * 1024 * 1024 + 1];
    assert!(matches!(
        parse_catalog_semesters(&oversized),
        Err(CampusError::Transport(ConnectorError::LimitExceeded))
    ));
}
#[test]
fn invalid_queries_and_unsupported_identity_filters_fail_before_io() {
    let mut filters = CatalogFilters::default();
    filters
        .fields
        .insert("assignAccountId".into(), "123".into());
    assert!(filters.validate().is_err());
    filters.fields = BTreeMap::from([("teachingSyllabus".into(), "yes".into())]);
    assert!(filters.validate().is_err());
    filters.fields = BTreeMap::from([("creditsGte".into(), "NaN".into())]);
    assert!(filters.validate().is_err());
    assert!(CatalogPage { number: 0, size: 1 }.validate().is_err());
    assert!(
        CatalogPage {
            number: 1,
            size: 101
        }
        .validate()
        .is_err()
    );
}
#[test]
fn syllabus_extracts_safe_sections_without_running_or_exporting_scripts() {
    let parsed = parse_catalog_syllabus(fixture!("syllabus.html"), "9901").unwrap();
    assert_eq!(parsed.sections.len(), 3);
    assert!(matches!(parsed.text_coverage, Coverage::Window { .. }));
    assert_eq!(parsed.sections[1].title, "课程简介");
    let text = serde_json::to_string(&parsed).unwrap();
    assert!(text.contains("Safe & useful"), "{parsed:?}");
    assert!(text.contains("Don't execute code"));
    for secret in [
        "BASE_SCRIPT_SECRET",
        "STYLE_SECRET",
        "PAYLOAD_SECRET",
        "HANDLER_SECRET",
        "TEMPLATE_SECRET",
        "evil.example",
        "<script",
    ] {
        assert!(!text.contains(secret), "{secret}");
    }
}
#[test]
fn syllabus_data_expressions_unknown_layout_and_duplicate_model_fail() {
    for html in [
        "<html><body>No syllabus</body></html>",
        "<script>\nlet model = runRemoteCode();\n</script>",
        "<script>\nlet model = {'structuredDocument':{'paragraphs':[]}} + remote();\n</script>",
        "<script>\nlet model = {'structuredDocument':{'paragraphs':[]}};\nlet model = {'structuredDocument':{'paragraphs':[]}};\n</script>",
        "<script>\nlet model = {'structuredDocument':{'paragraphs':[{'titleZh':'A','contentZh':undefined}]}};\n</script>",
    ] {
        assert!(parse_catalog_syllabus(html.as_bytes(), "9901").is_err());
    }
}
#[tokio::test]
async fn requests_are_anonymous_gets_with_encoded_explicit_filters() {
    let fake = Fake::new(&[
        fixture!("semesters.html"),
        fixture!("lessons-page1.json"),
        fixture!("lessons-page2.json"),
    ]);
    let client = FudanAcademicCatalogClient::new(fake.clone());
    assert_eq!(
        client
            .semesters(&source())
            .await
            .unwrap()
            .payload
            .default_semester_id,
        "902"
    );
    let filters = CatalogFilters {
        fields: BTreeMap::from([("courseNameZhLike".into(), "A & B 中文".into())]),
    };
    client
        .lessons(&source(), "902", page(1), &filters)
        .await
        .unwrap();
    client
        .lessons(&source(), "902", page(2), &CatalogFilters::default())
        .await
        .unwrap();
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    for request in requests.iter() {
        assert_eq!(request.method, HttpMethod::Get);
        assert_eq!(request.auth, TransportAuth::Anonymous);
        assert!(request.body.is_none());
    }
    assert_eq!(
        requests[1].url.path(),
        "/student/for-all/lesson-search/semester/902/search/902"
    );
    let pairs: BTreeMap<_, _> = requests[1].url.query_pairs().collect();
    assert_eq!(pairs.get("queryPage__").unwrap(), "1,1");
    assert_eq!(pairs.get("courseNameZhLike").unwrap(), "A & B 中文");
    assert!(requests[2].url.query().unwrap().contains("2%2C1"));
}
#[tokio::test]
async fn failure_on_later_page_is_not_a_successful_empty_snapshot() {
    let fake = Fake::new(&[fixture!("lessons-page1.json")]);
    fake.replies
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::Timeout));
    let client = FudanAcademicCatalogClient::new(fake.clone());
    let first = client
        .lessons(&source(), "902", page(1), &CatalogFilters::default())
        .await
        .unwrap();
    assert_eq!(first.records.len(), 1);
    assert!(matches!(
        client
            .lessons(&source(), "902", page(2), &CatalogFilters::default())
            .await,
        Err(CampusError::Transport(ConnectorError::Timeout))
    ));
    assert_eq!(fake.requests.lock().unwrap().len(), 2);
}
#[tokio::test]
async fn invalid_input_never_dispatches() {
    let fake = Fake::new(&[]);
    let client = FudanAcademicCatalogClient::new(fake.clone());
    assert!(
        client
            .lessons(&source(), "../2", page(1), &CatalogFilters::default())
            .await
            .is_err()
    );
    assert!(client.syllabus(&source(), "0").await.is_err());
    let mut s = source();
    s.source_id = "".into();
    assert!(client.semesters(&s).await.is_err());
    assert!(fake.requests.lock().unwrap().is_empty());
}
#[tokio::test]
async fn auth_shell_redirect_and_wrong_mime_are_not_catalog_results() {
    for fake in [
        Fake::special(
            200,
            None,
            b"<!doctype html><form><input type='password'></form>",
            None,
        ),
        Fake::special(
            200,
            Some("https://id.fudan.edu.cn/ac/"),
            b"login shell",
            None,
        ),
        Fake::special(401, None, b"denied", None),
    ] {
        let client = FudanAcademicCatalogClient::new(fake.clone());
        assert!(matches!(
            client.semesters(&source()).await,
            Err(CampusError::Transport(ConnectorError::AuthRequired(_)))
        ));
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
    let client = FudanAcademicCatalogClient::new(Fake::special(
        200,
        None,
        fixture!("semesters.html"),
        Some("application/json"),
    ));
    assert!(client.semesters(&source()).await.is_err());
    let client = FudanAcademicCatalogClient::new(Fake::special(
        200,
        Some("https://fdjwgl.fudan.edu.cn/student/for-all/unrelated"),
        fixture!("semesters.html"),
        None,
    ));
    assert!(matches!(
        client.semesters(&source()).await,
        Err(CampusError::Transport(ConnectorError::UnsafeUrl))
    ));
}
#[tokio::test]
async fn syllabus_guard_null_allows_text_reason_denies_without_second_get() {
    let fake = Fake::new(&[b"null", fixture!("syllabus.html")]);
    let client = FudanAcademicCatalogClient::new(fake.clone());
    let result = client.syllabus(&source(), "9901").await.unwrap();
    assert_eq!(result.external_id, "catalog_syllabus:9901");
    {
        let r = fake.requests.lock().unwrap();
        assert_eq!(r.len(), 2);
        assert_eq!(
            r[0].url.path(),
            "/student/for-all/lesson-search/check-can-info"
        );
        assert_eq!(
            r[1].url.path(),
            "/student/for-all/lesson-search/teachingSyllabusInfo/9901"
        );
    }
    for check in [
        br#""Not yet published""#.as_slice(),
        b"false",
        b"{}",
        br#""""#,
    ] {
        let fake = Fake::new(&[check]);
        let result = FudanAcademicCatalogClient::new(fake.clone())
            .syllabus(&source(), "9901")
            .await;
        assert!(result.is_err());
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
}

#[test]
fn syllabus_hex_and_unicode_are_data_not_executable_code() {
    let body = br#"<script>
let model = {'structuredDocument':{'paragraphs':[{'titleZh':'\u0041','contentZh':'<p>safe\xB7text<\/p>'}]}};
</script>"#;
    let parsed = parse_catalog_syllabus(body, "9901").unwrap();
    assert_eq!(parsed.sections[0].title, "A");
    assert_eq!(parsed.sections[0].text, "safe·text");
}
