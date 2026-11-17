use async_trait::async_trait;
use chrono::{NaiveDate, TimeZone, Utc};
use dansheng_connectors::canvas::*;
use dansheng_connectors::fudan::*;
use dansheng_connectors::models::{Semester, SourceContext};
use dansheng_connectors::{
    AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport,
    TransportAuth,
};
use serde_json::json;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use url::Url;

const UG: &[u8] = include_bytes!("../fixtures/undergraduate.json");
const PG: &[u8] = include_bytes!("../fixtures/postgraduate.json");
const COURSES1: &[u8] = include_bytes!("../fixtures/courses-page1.json");
const COURSES2: &[u8] = include_bytes!("../fixtures/courses-page2.json");
const ASSIGNMENTS: &[u8] = include_bytes!("../fixtures/assignments.json");
const MATERIALS: &[u8] = include_bytes!("../fixtures/materials.json");
const CANVAS: &str = "https://canvas.example.invalid";
const FIRST: &str = "https://canvas.example.invalid/api/v1/courses?include[]=term&per_page=100";

fn source() -> SourceContext {
    SourceContext {
        account_id: "test-account".into(),
        source_id: "test-source".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 5, 10, 0, 0).unwrap(),
    }
}
fn semester() -> Semester {
    Semester {
        external_id: "901".into(),
        name: "Synthetic term".into(),
        starts_on: NaiveDate::from_ymd_opt(2026, 3, 2).unwrap(),
    }
}
fn response(url: &str, body: &[u8]) -> ConnectorResponse {
    ConnectorResponse {
        status: 200,
        final_url: Url::parse(url).unwrap(),
        headers: vec![],
        body: body.to_vec(),
    }
}
#[derive(Clone, Default)]
struct FakeTransport {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    responses: Arc<Mutex<VecDeque<Result<ConnectorResponse, ConnectorError>>>>,
}
impl FakeTransport {
    fn new(responses: Vec<ConnectorResponse>) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into_iter().map(Ok).collect())),
            ..Self::default()
        }
    }
}
#[async_trait]
impl ConnectorTransport for FakeTransport {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected transport request")
    }
}
fn client(transport: FakeTransport, access: CanvasAccess) -> CanvasClient<FakeTransport> {
    CanvasClient::new(transport, CANVAS, access).unwrap()
}

#[test]
fn undergraduate_preserves_slots_teachers_and_converts_sunday_weeks() {
    let table = parse_undergraduate_timetable(UG, source(), semester()).unwrap();
    assert_eq!(table.timezone, "Asia/Shanghai");
    assert_eq!(table.courses.len(), 2);
    let first = &table.courses[0];
    assert_eq!(first.account_id, "test-account");
    assert_eq!(first.source_id, "test-source");
    assert_eq!(first.observed_at, source().observed_at);
    assert_eq!(first.payload.teachers.len(), 2);
    assert_eq!((first.payload.start_unit, first.payload.end_unit), (1, 3));
    assert_eq!(first.payload.weeks, [1, 2, 4]);
    assert_eq!(table.courses[1].payload.weeks, [0, 1, 2]);
    assert_eq!(table.courses[1].payload.weekday, 7);
    assert!(table.courses[1].payload.room.is_none());
}

#[test]
fn postgraduate_bitmap_is_one_based_and_nullable_fields_are_not_invented() {
    let table = parse_postgraduate_timetable(PG, source(), semester()).unwrap();
    assert_eq!(table.courses[0].payload.weeks, [1, 3, 5]);
    assert_eq!(table.courses[1].payload.weeks, [2, 3]);
    assert_eq!(table.courses[0].payload.start_unit, 6);
    assert_eq!(table.courses[1].payload.weekday, 7);
    assert!(table.courses[1].payload.teachers.is_empty());
    assert!(table.courses[1].payload.course_code.is_none());
}

#[test]
fn semester_parser_decodes_apostrophes_and_converts_sunday_to_monday() {
    let catalog =
        parse_undergraduate_semesters(include_str!("../fixtures/semesters.html")).unwrap();
    assert_eq!(catalog.default_semester_id, "901");
    assert_eq!(catalog.semesters[0].starts_on, semester().starts_on);
    assert!(catalog.semesters[1].name.contains("O'Brien"));
    let quoted = serde_json::to_string(
        &json!([{"id":901,"name":"Synthetic", "startDate":"2026-03-01"}]).to_string(),
    )
    .unwrap();
    let html = format!(
        "<select id='allSemesters'><option value='901'>x</option></select><script>const semesters = JSON.parse({quoted});</script>"
    );
    assert_eq!(
        parse_undergraduate_semesters(&html)
            .unwrap()
            .semesters
            .len(),
        1
    );
}

#[test]
fn unknown_envelopes_are_errors_but_explicit_empty_tables_are_valid() {
    for body in [
        br#"{}"#.as_slice(),
        br#"{"studentTableVms":[]}"#,
        br#"{"error":"login"}"#,
    ] {
        assert!(parse_undergraduate_timetable(body, source(), semester()).is_err());
    }
    assert!(
        parse_undergraduate_timetable(
            br#"{"studentTableVms":[{"activities":[]}]}"#,
            source(),
            semester()
        )
        .unwrap()
        .courses
        .is_empty()
    );
    assert!(
        parse_postgraduate_timetable(br#"{"results":[]}"#, source(), semester())
            .unwrap()
            .courses
            .is_empty()
    );
    assert!(
        parse_postgraduate_timetable(br#"{"success":false,"results":[]}"#, source(), semester())
            .is_err()
    );
}

#[test]
fn malformed_units_weeks_and_bitmap_are_rejected_without_echoing_data() {
    let original: serde_json::Value = serde_json::from_slice(UG).unwrap();
    for (key, value) in [
        ("weekday", json!(0)),
        ("endUnit", json!(0)),
        ("weekIndexes", json!([0])),
        ("startUnit", json!(99)),
    ] {
        let mut data = original.clone();
        data["studentTableVms"][0]["activities"][0][key] = value;
        assert!(
            parse_undergraduate_timetable(
                &serde_json::to_vec(&data).unwrap(),
                source(),
                semester()
            )
            .is_err()
        );
    }
    let mut pg: serde_json::Value = serde_json::from_slice(PG).unwrap();
    pg["results"][0]["ZCBH"] = json!("SYNTHETIC-NON-CREDENTIAL");
    let error =
        parse_postgraduate_timetable(&serde_json::to_vec(&pg).unwrap(), source(), semester())
            .unwrap_err();
    assert!(!format!("{error:?}").contains("SYNTHETIC-NON-CREDENTIAL"));
}

#[test]
fn activity_ids_are_order_independent_and_distinct_for_different_slots() {
    let a = parse_postgraduate_timetable(PG, source(), semester()).unwrap();
    let mut data: serde_json::Value = serde_json::from_slice(PG).unwrap();
    data["results"].as_array_mut().unwrap().reverse();
    let b = parse_postgraduate_timetable(&serde_json::to_vec(&data).unwrap(), source(), semester())
        .unwrap();
    assert_eq!(a.courses[0].external_id, b.courses[1].external_id);
    assert_ne!(a.courses[0].external_id, a.courses[1].external_id);
}

#[test]
fn canvas_typed_parsers_preserve_ids_dates_and_drop_signed_urls() {
    let courses = parse_courses(COURSES2).unwrap();
    assert_eq!(courses[0].id.0, "9007199254740993");
    let assignments = parse_assignments(ASSIGNMENTS).unwrap();
    assert_eq!(
        assignments[0].due_at.unwrap().to_rfc3339(),
        "2026-11-08T15:59:00+00:00"
    );
    assert_eq!(assignments[0].points_possible, Some(12.5));
    assert!(assignments[1].due_at.is_none());
    let materials = parse_materials(MATERIALS).unwrap();
    let exported = serde_json::to_string(&materials).unwrap();
    assert!(!exported.contains("SYNTHETIC-NON-CREDENTIAL"));
    assert!(!exported.contains("preview_url"));
    assert_eq!(
        materials[0].content_type.as_deref(),
        Some("application/pdf")
    );
}

#[test]
fn next_link_supports_case_repeated_headers_relation_lists_and_opaque_commas() {
    let current = Url::parse(FIRST).unwrap();
    let headers = vec![("LiNk".into(), "<https://canvas.example.invalid/api/v1/courses?cursor=a,b>; title=\"x,y; z\"; REL=\"prev next\"".into()),
        ("link".into(), "</api/v1/courses?cursor=end>; rel=last".into())];
    let next = next_page(&headers, &current, &Url::parse(CANVAS).unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(next.query(), Some("cursor=a,b"));
}

#[test]
fn next_link_rejects_cross_origin_credentials_non_api_and_conflicting_links() {
    let current = Url::parse(FIRST).unwrap();
    for target in [
        "https://evil.example.invalid/api/v1/courses",
        "/login",
        "https://user:secret@canvas.example.invalid/api/v1/courses",
        "/api/v1/courses?access_token=SYNTHETIC",
        "/api/v1/%2f..%2flogin",
        "/api/v1/courses#secret",
    ] {
        let headers = vec![("Link".into(), format!("<{target}>; rel=\"next\""))];
        assert!(
            next_page(&headers, &current, &Url::parse(CANVAS).unwrap()).is_err(),
            "target was accepted"
        );
    }
    let headers = vec![(
        "Link".into(),
        "<?cursor=1>; rel=next, <?cursor=2>; rel=next".into(),
    )];
    assert!(next_page(&headers, &current, &Url::parse(CANVAS).unwrap()).is_err());
}

#[tokio::test]
async fn pagination_follows_next_even_for_short_or_empty_pages_and_separates_auth_modes() {
    for access in [
        CanvasAccess::HostToken,
        CanvasAccess::HostSession,
        CanvasAccess::BrowserSession,
    ] {
        let mut first = response(FIRST, b"[]");
        first.headers = vec![(
            "lInK".into(),
            "</api/v1/courses?opaque=one%2Btwo>; rel=next".into(),
        )];
        let fake = FakeTransport::new(vec![
            first,
            response(
                "https://canvas.example.invalid/api/v1/courses?opaque=one%2Btwo",
                COURSES2,
            ),
        ]);
        let records = client(fake.clone(), access)
            .courses(&source())
            .await
            .unwrap();
        assert_eq!(records.len(), 1);
        let requests = fake.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[1].url.query(), Some("opaque=one%2Btwo"));
        for request in requests.iter() {
            assert_eq!(
                request.auth,
                match access {
                    CanvasAccess::HostToken => TransportAuth::HostToken {
                        account_id: "test-account".into()
                    },
                    CanvasAccess::HostSession => TransportAuth::HostSession {
                        account_id: "test-account".into()
                    },
                    CanvasAccess::BrowserSession => TransportAuth::BrowserSession {
                        account_id: "test-account".into()
                    },
                }
            );
            assert!(
                request
                    .headers
                    .iter()
                    .all(|(name, _)| !name.eq_ignore_ascii_case("authorization"))
            );
        }
    }
}

#[tokio::test]
async fn pagination_cycles_and_page_limits_stop_before_extra_io() {
    let mut first = response(FIRST, COURSES1);
    first.headers = vec![("Link".into(), format!("<{FIRST}>; rel=next"))];
    let fake = FakeTransport::new(vec![first]);
    assert_eq!(
        client(fake.clone(), CanvasAccess::HostToken)
            .courses(&source())
            .await
            .unwrap_err(),
        ConnectorError::PaginationCycle
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
    let mut first = response(FIRST, COURSES1);
    first.headers = vec![("Link".into(), "<?cursor=2>; rel=next".into())];
    let fake = FakeTransport::new(vec![first]);
    let c = client(fake.clone(), CanvasAccess::HostToken)
        .with_limits(CanvasLimits {
            max_pages: 1,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        c.courses(&source()).await.unwrap_err(),
        ConnectorError::LimitExceeded
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn later_page_auth_failure_is_not_a_partial_success_or_mode_fallback() {
    let mut first = response(FIRST, COURSES1);
    first.headers = vec![("Link".into(), "<?cursor=2>; rel=next".into())];
    let mut denied = response(
        "https://canvas.example.invalid/api/v1/courses?cursor=2",
        b"{}",
    );
    denied.status = 401;
    let fake = FakeTransport::new(vec![first, denied]);
    let error = client(fake.clone(), CanvasAccess::HostToken)
        .courses(&source())
        .await
        .unwrap_err();
    let ConnectorError::AuthRequired(challenge) = error else {
        panic!("expected auth challenge")
    };
    assert_eq!(challenge.mode, AuthMode::Token);
    assert_eq!(fake.requests.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn login_redirects_forms_and_permission_denial_are_explicit() {
    for mut reply in [
        response("https://sso.example.invalid/authserver/login", b"{}"),
        response(
            FIRST,
            br#"<!doctype html><html><form><input type="password"></form></html>"#,
        ),
    ] {
        let fake = FakeTransport::new(vec![reply.clone()]);
        assert!(matches!(
            client(fake, CanvasAccess::HostSession)
                .courses(&source())
                .await,
            Err(ConnectorError::AuthRequired(_))
        ));
        reply.status = 403;
        let fake = FakeTransport::new(vec![reply]);
        assert_eq!(
            client(fake, CanvasAccess::HostToken)
                .courses(&source())
                .await
                .unwrap_err(),
            ConnectorError::PermissionDenied
        );
    }
}

#[tokio::test]
async fn assignments_and_materials_use_course_endpoints_and_source_identity() {
    let fake = FakeTransport::new(vec![
        response(
            "https://canvas.example.invalid/api/v1/courses/81001/assignments",
            ASSIGNMENTS,
        ),
        response(
            "https://canvas.example.invalid/api/v1/courses/81001/files",
            MATERIALS,
        ),
    ]);
    let c = client(fake.clone(), CanvasAccess::HostSession);
    let assignments = c.assignments(&source(), "81001").await.unwrap();
    let files = c.materials(&source(), "81001").await.unwrap();
    assert_eq!(assignments[0].external_id, "assignment:81001:82001");
    assert_eq!(files[0].external_id, "file:81001:83001");
    assert_eq!(files[0].source_id, "test-source");
    assert!(files[0].updated_at.is_some());
    assert_eq!(
        fake.requests.lock().unwrap()[1].url.path(),
        "/api/v1/courses/81001/files"
    );
    assert!(c.assignments(&source(), "../profile").await.is_err());
    assert_eq!(fake.requests.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn undergraduate_service_discovers_semester_and_pg_selects_explicit_endpoint() {
    let fake = FakeTransport::new(vec![
        response(
            "https://fdjwgl.fudan.edu.cn/student/for-std/course-table",
            include_bytes!("../fixtures/semesters.html"),
        ),
        response(
            "https://fdjwgl.fudan.edu.cn/student/for-std/course-table/semester/901/print-data",
            UG,
        ),
        response(
            "http://yjsxktest.fudan.sh.cn/yjsxkapp/sys/xsxkappfudan/xsxkCourse/loadKbxx.do",
            PG,
        ),
    ]);
    let c = FudanTimetableClient::new(fake.clone());
    assert_eq!(
        c.undergraduate(source(), None)
            .await
            .unwrap()
            .semester
            .external_id,
        "901"
    );
    assert_eq!(
        c.postgraduate(source(), semester(), PostgraduateEndpoint::Secondary)
            .await
            .unwrap()
            .courses
            .len(),
        2
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert_eq!(
        requests[1].url.path(),
        "/student/for-std/course-table/semester/901/print-data"
    );
    assert_eq!(requests[2].url.host_str(), Some("yjsxktest.fudan.sh.cn"));
    assert!(
        requests
            .iter()
            .all(|r| matches!(r.auth, TransportAuth::HostSession { .. }))
    );
}

#[tokio::test]
async fn fudan_auth_challenge_is_explicit_and_does_not_fallback() {
    let mut reply = response(POSTGRADUATE_PRIMARY, b"{}");
    reply.status = 401;
    let fake = FakeTransport::new(vec![reply]);
    let result = FudanTimetableClient::new(fake.clone())
        .postgraduate(source(), semester(), PostgraduateEndpoint::Primary)
        .await;
    assert!(
        matches!(result, Err(ConnectorError::AuthRequired(ref challenge)) if challenge.mode == AuthMode::HttpSession)
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
}

#[test]
fn transport_debug_does_not_disclose_wire_secrets_or_body() {
    let r = response(
        "https://canvas.example.invalid/?token=SYNTHETIC-NON-CREDENTIAL",
        b"SYNTHETIC-NON-CREDENTIAL",
    );
    assert!(!format!("{r:?}").contains("SYNTHETIC"));
    let q = ConnectorRequest {
        method: dansheng_connectors::HttpMethod::Get,
        url: r.final_url,
        headers: vec![("Cookie".into(), "SYNTHETIC-NON-CREDENTIAL".into())],
        body: Some(r.body),
        auth: TransportAuth::Anonymous,
    };
    assert!(!format!("{q:?}").contains("SYNTHETIC"));
}

#[test]
fn origin_configuration_rejects_paths_queries_userinfo_and_http() {
    for origin in [
        "http://canvas.example.invalid",
        "https://user:pass@canvas.example.invalid",
        "https://canvas.example.invalid/api/v1",
        "https://canvas.example.invalid/?token=x",
    ] {
        assert!(
            CanvasClient::new(FakeTransport::default(), origin, CanvasAccess::HostToken).is_err()
        );
    }
    assert!(
        CanvasClient::new(
            FakeTransport::default(),
            "https://custom.example.invalid:8443",
            CanvasAccess::HostSession
        )
        .is_ok()
    );
}

#[tokio::test]
async fn shared_trait_object_transport_preserves_missing_capability_without_retry() {
    let fake = FakeTransport::default();
    fake.responses
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::CapabilityUnavailable));
    let shared: Arc<dyn ConnectorTransport> = Arc::new(fake.clone());
    let c = CanvasClient::new(shared, CANVAS, CanvasAccess::BrowserSession).unwrap();
    assert_eq!(
        c.courses(&source()).await.unwrap_err(),
        ConnectorError::CapabilityUnavailable
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn response_and_item_caps_and_wrong_assignment_course_fail_closed() {
    let fake = FakeTransport::new(vec![response(FIRST, COURSES1)]);
    let c = client(fake, CanvasAccess::HostToken)
        .with_limits(CanvasLimits {
            max_page_bytes: 2,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        c.courses(&source()).await.unwrap_err(),
        ConnectorError::LimitExceeded
    );
    let two_courses = serde_json::to_vec(&json!([{"id":1},{"id":2}])).unwrap();
    let fake = FakeTransport::new(vec![response(FIRST, &two_courses)]);
    let c = client(fake, CanvasAccess::HostToken)
        .with_limits(CanvasLimits {
            max_items: 1,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        c.courses(&source()).await.unwrap_err(),
        ConnectorError::LimitExceeded
    );
    let fake = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/9/assignments",
        ASSIGNMENTS,
    )]);
    assert!(matches!(
        client(fake, CanvasAccess::HostToken)
            .assignments(&source(), "9")
            .await,
        Err(ConnectorError::Parse { .. })
    ));
}

#[tokio::test]
async fn invalid_ug_semester_id_is_rejected_before_transport() {
    let fake = FakeTransport::default();
    let mut term = semester();
    term.external_id = "..".into();
    assert!(
        FudanTimetableClient::new(fake.clone())
            .undergraduate(source(), Some(term))
            .await
            .is_err()
    );
    assert!(fake.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn challenges_distinguish_native_cookie_session_from_browser_and_token() {
    for (access, mode) in [
        (CanvasAccess::HostToken, AuthMode::Token),
        (CanvasAccess::HostSession, AuthMode::HttpSession),
        (CanvasAccess::BrowserSession, AuthMode::BrowserSession),
    ] {
        let mut denied = response(FIRST, b"{}");
        denied.status = 401;
        let fake = FakeTransport::new(vec![denied]);
        let error = client(fake.clone(), access)
            .courses(&source())
            .await
            .unwrap_err();
        assert!(
            matches!(error, ConnectorError::AuthRequired(ref challenge) if challenge.mode == mode)
        );
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
}
