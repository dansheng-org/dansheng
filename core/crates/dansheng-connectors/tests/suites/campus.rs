use async_trait::async_trait;
use chrono::{NaiveDate, NaiveTime, TimeZone, Utc};
use dansheng_connectors::campus::*;
use dansheng_connectors::community::*;
use dansheng_connectors::models::SourceContext;
use dansheng_connectors::{
    AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
use url::Url;

macro_rules! fixture {
    ($name:literal) => {
        include_bytes!(concat!("../../fixtures/campus/", $name))
    };
}

fn source() -> SourceContext {
    SourceContext {
        account_id: "synthetic-account".into(),
        source_id: "synthetic-source".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 5, 10, 0, 0).unwrap(),
    }
}

#[test]
fn qr_status_never_serializes_or_debug_prints_the_synthetic_credential() {
    let secret = "SYNTHETIC-QR-NOT-A-REAL-CREDENTIAL";
    let body = format!("<input id='myText' value='{secret}'>");
    let state = parse_qr_state(body.as_bytes()).unwrap();
    assert_eq!(state, QrState::Ready);
    assert_eq!(serde_json::to_string(&state).unwrap(), "\"ready\"");
    assert!(!format!("{state:?}").contains(secret));
    assert_eq!(
        parse_qr_state(b"<button id='btn-agree-ok'></button>").unwrap(),
        QrState::TermsNotAccepted
    );
}
fn on() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 11, 1).unwrap()
}

#[tokio::test]
async fn statement_loads_all_pages_and_does_not_hide_a_second_page_failure() {
    let csrf = b"<meta name='_csrf' content='synthetic'>";
    let page = fixture!("ecard_transactions.xml");
    let second = String::from_utf8(page.to_vec())
        .unwrap()
        .replace("合成商户", "另一个合成商户");
    let fake = Offline::new(&[csrf, page, csrf, second.as_bytes()]);
    let result = FudanCampusClient::new(fake.clone())
        .ecard_statement(&source(), on(), on().succ_opt().unwrap())
        .await
        .unwrap();
    assert_eq!(result.coverage, Coverage::Complete);
    assert_eq!(result.records.len(), 4);
    assert_eq!(
        result
            .records
            .iter()
            .map(|r| &r.external_id)
            .collect::<std::collections::BTreeSet<_>>()
            .len(),
        4
    );
    assert_eq!(result.records[2].payload.location, "另一个合成商户");
    assert_eq!(fake.requests.lock().unwrap().len(), 4);
    let bad = Offline::new(&[csrf, page, csrf, b"malformed"]);
    assert!(
        FudanCampusClient::new(bad)
            .ecard_statement(&source(), on(), on())
            .await
            .is_err()
    );
}

struct Reply {
    status: u16,
    body: Vec<u8>,
    final_url: Option<&'static str>,
}
#[derive(Clone, Default)]
struct Offline {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    replies: Arc<Mutex<VecDeque<Result<Reply, ConnectorError>>>>,
}
impl Offline {
    fn new(bodies: &[&[u8]]) -> Self {
        Self {
            replies: Arc::new(Mutex::new(
                bodies
                    .iter()
                    .map(|b| {
                        Ok(Reply {
                            status: 200,
                            body: b.to_vec(),
                            final_url: None,
                        })
                    })
                    .collect(),
            )),
            ..Self::default()
        }
    }
    fn error(status: u16, body: &[u8], final_url: Option<&'static str>) -> Self {
        Self {
            replies: Arc::new(Mutex::new(VecDeque::from([Ok(Reply {
                status,
                body: body.to_vec(),
                final_url,
            })]))),
            ..Self::default()
        }
    }
}
#[async_trait]
impl ConnectorTransport for Offline {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        let url = request.url.clone();
        self.requests.lock().unwrap().push(request);
        let reply = self
            .replies
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected I/O: no offline response queued")?;
        Ok(ConnectorResponse {
            status: reply.status,
            final_url: reply
                .final_url
                .map(|v| Url::parse(v).unwrap())
                .unwrap_or(url),
            headers: vec![],
            body: reply.body,
        })
    }
}

#[test]
fn exam_html_preserves_status_and_category_without_fabricating_unknown_rows() {
    let rows = parse_exams(fixture!("exams.html")).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].course_code, "SYNTH001.01");
    assert_eq!(rows[0].category, "闭卷");
    assert_eq!(rows[0].room.as_deref(), Some("TEST101"));
    assert!(!rows[0].finished);
    assert!(rows[1].finished);
    assert!(parse_exams(b"<table></table>").is_err());
    assert!(parse_exams(br#"<table class="exam-table"><tbody><tr class="tr-empty"><td>No exams</td></tr></tbody></table>"#).unwrap().is_empty());
}

#[test]
fn three_grade_sources_preserve_credits_null_gp_and_explicit_pg_total() {
    let ug = parse_undergraduate_grades(fixture!("grades_ug.json"), "901").unwrap();
    assert_eq!(ug[0].grade_point, Some(4.0));
    assert_eq!(ug[0].credits, None); // Not supplied by this pinned UG mapping.
    assert_eq!(ug[1].course_name, "Synthetic pass course");
    assert_eq!(ug[1].grade_point, None);
    assert!(parse_undergraduate_grades(fixture!("grades_ug.json"), "902").is_err());
    let all = parse_data_center_grades(fixture!("grades_all.json")).unwrap();
    assert_eq!(all[0].credits, Some(0.5));
    assert!(all[1].grade_point.is_none());
    let (pg, total) = parse_graduate_grades(fixture!("grades_pg.json")).unwrap();
    assert_eq!(total, Some(3));
    assert_eq!(pg.len(), 2);
    assert_eq!(pg[1].credits, Some(0.5));
    let mut raw: Value = serde_json::from_slice(fixture!("grades_pg.json")).unwrap();
    raw["code"] = json!("failure");
    assert!(parse_graduate_grades(&serde_json::to_vec(&raw).unwrap()).is_err());
}

#[test]
fn gpa_numeric_year_rank_and_nullable_values_are_typed() {
    let rows = parse_gpa(fixture!("gpa.json")).unwrap();
    assert_eq!(rows[0].entry_year.as_deref(), Some("2026"));
    assert_eq!(rows[0].credits, Some(12.5));
    assert_eq!(rows[0].ranking, Some(2));
    let mut raw: Value = serde_json::from_slice(fixture!("gpa.json")).unwrap();
    raw["data"][0]["gpa"] = Value::Null;
    assert!(
        parse_gpa(&serde_json::to_vec(&raw).unwrap()).unwrap()[0]
            .gpa
            .is_none()
    );
}

#[test]
fn ecard_money_is_exact_signed_cents_and_shanghai_time_becomes_utc() {
    let balance = parse_ecard_balance(fixture!("ecard_balance.html")).unwrap();
    assert_eq!(balance.balance.cents, 4205);
    assert_eq!(balance.balance.currency, "CNY");
    assert_eq!(balance.holder_name.as_deref(), Some("虚构用户"));
    let (rows, total) = parse_ecard_transactions(fixture!("ecard_transactions.xml")).unwrap();
    assert_eq!(total, 2);
    assert_eq!(rows[0].amount.cents, -1205);
    assert_eq!(rows[1].amount.cents, 550);
    assert_eq!(rows[0].at.to_rfc3339(), "2026-11-01T04:30:01+00:00");
    assert_eq!(rows[0].location, "合成商户");
    let bad = String::from_utf8(fixture!("ecard_balance.html").to_vec())
        .unwrap()
        .replace("42.05", "42.005");
    assert!(parse_ecard_balance(bad.as_bytes()).is_err());
    assert!(parse_ecard_transactions(b"<response>not a table</response>").is_err());
}

#[test]
fn ecard_current_seven_column_table_preserves_legacy_fields() {
    let legacy = String::from_utf8(fixture!("ecard_transactions.xml").to_vec()).unwrap();
    // Synthetic values only. The three new cells must never become the amount.
    let current = legacy
        .replace("</tr>", "<td>88.88</td><td>交易成功</td><td>详情</td></tr>")
        .replace("span", "div")
        .replace("12:30:01", "12:30")
        .replace("08:00:00", "08:00");
    let (actual, pages) = parse_ecard_transactions(current.as_bytes()).unwrap();
    let (expected, legacy_pages) = parse_ecard_transactions(legacy.as_bytes()).unwrap();
    assert_eq!(actual[0].amount, expected[0].amount);
    assert_eq!(actual[0].location, expected[0].location);
    assert_eq!(actual[0].transaction_type, expected[0].transaction_type);
    assert_eq!(actual[0].at.to_rfc3339(), "2026-11-01T04:30:00+00:00");
    assert_eq!(actual[1], expected[1]);
    assert_eq!(pages, legacy_pages);
    let unknown = legacy.replace("</tr>", "<td>unknown</td></tr>");
    assert!(parse_ecard_transactions(unknown.as_bytes()).is_err());
}

#[test]
fn dorm_electricity_excludes_unknown_personal_fields_and_retains_source_update_time() {
    let row = parse_electricity(fixture!("electricity.json")).unwrap();
    assert_eq!(row.room, "701");
    assert_eq!(row.remaining_kwh, 8.75);
    assert_eq!(
        row.updated_at.unwrap().to_rfc3339(),
        "2026-10-31T16:00:00+00:00"
    );
    let mut no_time: serde_json::Value =
        serde_json::from_slice(fixture!("electricity.json")).unwrap();
    no_time["d"]["fj_update_time"] = serde_json::json!("");
    let row_without_time = parse_electricity(&serde_json::to_vec(&no_time).unwrap()).unwrap();
    assert_eq!(row_without_time.updated_at, None);
    assert_eq!(row_without_time.remaining_kwh, row.remaining_kwh);
    assert!(
        !serde_json::to_string(&row)
            .unwrap()
            .contains("DO-NOT-PERSIST")
    );
    let bad = String::from_utf8(fixture!("electricity.json").to_vec())
        .unwrap()
        .replace("8.75", "NaN");
    assert!(parse_electricity(bad.as_bytes()).is_err());
}

#[test]
fn occupancy_parsers_handle_strings_numbers_js_escapes_and_reporting_hours() {
    let libraries = parse_library_occupancy(fixture!("library.json")).unwrap();
    assert_eq!(libraries[0].inside, 123);
    assert_eq!(libraries[1].inside, 0);
    let dining = parse_dining_occupancy(fixture!("dining.html"), 0).unwrap();
    assert_eq!(dining[0].name, "合成楼-食堂");
    assert_eq!(dining[1].name, "Synthetic O'Brien");
    assert_eq!(dining[0].current, 12);
    assert_eq!(dining[0].capacity, 100);
    assert_eq!(
        parse_dining_occupancy(fixture!("dining.html"), 1).unwrap()[0].current,
        3
    );
    assert!(matches!(
        parse_dining_occupancy("<html>仅供就餐时间查看</html>".as_bytes(), 0),
        Err(CampusError::OutsideReportingHours)
    ));
    assert!(
        parse_dining_occupancy(b"<script>var x=['x'];var y=[];var z=[1];</script>", 0).is_err()
    );
    assert!(
        parse_library_occupancy(br#"{"data":[{"campusName":"Synthetic","inNum":-1}]}"#).is_err()
    );
}

#[test]
fn mixed_classroom_script_is_not_executed_and_slot_drift_fails_closed() {
    let rows = parse_empty_classrooms(
        fixture!("empty_status.txt"),
        fixture!("empty_details.html"),
        on(),
    )
    .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].room, "SYNTH]101");
    assert_eq!(rows[0].seats, Some(30));
    assert_eq!(rows[0].busy_units.len(), 13);
    assert!(rows[0].busy_units[1]);
    assert_eq!(rows[0].busy_units.iter().filter(|b| **b).count(), 1);
    let bad = String::from_utf8(fixture!("empty_details.html").to_vec())
        .unwrap()
        .replacen("<td style=\"background-color: green\"></td>", "", 1);
    assert!(parse_empty_classrooms(fixture!("empty_status.txt"), bad.as_bytes(), on()).is_err());
    assert!(parse_empty_classrooms(b"garbage", b"", on()).is_err());
    let extra = String::from_utf8(fixture!("empty_details.html").to_vec())
        .unwrap()
        .replacen(
            "<td style=",
            "<td style=\"background-color: gray\"><div>\nlegend\n</div></td><td style=",
            1,
        );
    let with_legend =
        parse_empty_classrooms(fixture!("empty_status.txt"), extra.as_bytes(), on()).unwrap();
    assert_eq!(with_legend[0].busy_units, rows[0].busy_units);
}

#[test]
fn pe_parser_retains_counts_unknown_count_and_assessment_columns() {
    let rows = parse_pe_records(fixture!("pe.html")).unwrap();
    assert_eq!(rows.len(), 3);
    assert!(matches!(&rows[0],PeRecord::Count{times:Some(12),title} if title=="合成刷锻"));
    assert!(matches!(&rows[1], PeRecord::Count { times: None, .. }));
    assert!(matches!(&rows[2],PeRecord::Assessment{score,result,..} if score=="90"&&result=="8.5"));
    assert!(parse_pe_records(b"<html>wrong table layout</html>").is_err());
}

#[test]
fn bus_notices_and_qr_state_follow_source_shapes_without_credential_export() {
    let rows = parse_bus(fixture!("bus.json")).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        rows[0].starts_at,
        Some(NaiveTime::from_hms_opt(8, 30, 0).unwrap())
    );
    assert_eq!(rows[0].direction, BusDirection::Forward);
    assert_eq!(rows[1].direction, BusDirection::Backward);
    assert!(rows[1].starts_at.is_none());
    assert!(rows[1].holiday);
    let ug = parse_aao_notices(fixture!("aao_ug.html"), AaoKind::Undergraduate).unwrap();
    assert_eq!(
        ug[0].url,
        "https://jwc.fudan.edu.cn/synthetic/notice/page.htm"
    );
    let pg = parse_aao_notices(fixture!("aao_pg.html"), AaoKind::Postgraduate).unwrap();
    assert_eq!(pg[0].published_on, on().succ_opt().unwrap());
    assert!(matches!(
        parse_aao_notices(b"Under Maintenance", AaoKind::Undergraduate),
        Err(CampusError::MaintenanceOrCampusNetwork)
    ));
    assert_eq!(
        parse_qr_state(fixture!("qr_ready.html")).unwrap(),
        QrState::Ready
    );
    assert_eq!(
        parse_qr_state(fixture!("qr_terms.html")).unwrap(),
        QrState::TermsNotAccepted
    );
    assert!(
        !serde_json::to_string(&parse_qr_state(fixture!("qr_ready.html")).unwrap())
            .unwrap()
            .contains("SYNTHETIC")
    );
    assert!(parse_qr_state(b"<html>unknown layout</html>").is_err());
}

#[test]
fn unknown_json_envelopes_are_schema_drift_not_successful_empty_lists() {
    for body in [
        b"{}".as_slice(),
        br#"{"error":"SYNTHETIC-SECRET"}"#,
        br#"{"data":null}"#,
    ] {
        assert!(parse_gpa(body).is_err());
        assert!(parse_data_center_grades(body).is_err());
        assert!(parse_library_occupancy(body).is_err());
        assert!(parse_electricity(body).is_err());
        assert!(parse_bus(body).is_err());
        let error = parse_graduate_grades(body).unwrap_err();
        assert!(!format!("{error:?}").contains("SYNTHETIC-SECRET"));
    }
    assert!(
        parse_library_occupancy(br#"{"data":[]}"#)
            .unwrap()
            .is_empty()
    );
    assert!(parse_gpa(br#"{"data":[]}"#).unwrap().is_empty());
}

#[tokio::test]
async fn academic_services_use_source_student_association_and_native_http_session() {
    let fake = Offline::new(&[
        br#"{"studentTableVms":[{"id":7101}]}"#,
        fixture!("exams.html"),
        fixture!("grades_ug.json"),
        fixture!("grades_pg.json"),
    ]);
    let client = FudanCampusClient::new(fake.clone());
    let source = source();
    assert_eq!(
        client
            .student_association(&source, "901")
            .await
            .unwrap()
            .payload,
        "7101"
    );
    let exams = client.exams(&source, "7101", false).await.unwrap();
    assert_eq!(exams.records.len(), 1);
    assert_eq!(exams.records[0].account_id, source.account_id);
    assert_eq!(exams.records[0].observed_at, source.observed_at);
    assert_eq!(exams.source_revision, DANXI_REVISION);
    assert_eq!(
        client
            .undergraduate_grades(&source, "7101", "901")
            .await
            .unwrap()
            .records
            .len(),
        2
    );
    let pg = client.graduate_grades(&source).await.unwrap();
    assert_eq!(
        pg.coverage,
        Coverage::UnsupportedRemainder {
            reported_total: 3,
            returned: 2
        }
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    assert_eq!(
        requests[1].url.path(),
        "/student/for-std/exam-arrange/info/7101"
    );
    assert_eq!(requests[2].url.query(), Some("semester=901"));
    assert!(requests[3].url.query().is_none());
    assert!(requests.iter().all(
        |q| matches!(q.auth, TransportAuth::HostSession { .. }) && q.method == HttpMethod::Get
    ));
}

#[tokio::test]
async fn gpa_search_is_two_source_requests_and_does_not_export_search_form() {
    let fake = Offline::new(&[fixture!("gpa_index.html"), fixture!("gpa.json")]);
    let result = FudanCampusClient::new(fake.clone())
        .gpa(&source(), "7101")
        .await
        .unwrap();
    assert_eq!(result.records[0].payload.gpa, Some(3.75));
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    let query: std::collections::HashMap<_, _> = requests[1].url.query_pairs().collect();
    assert_eq!(query["studentAssoc"], "7101");
    assert_eq!(query["grade"], "2026");
    assert_eq!(query["departmentAssoc"], "7001");
    assert!(query.contains_key("majorAssoc"));
}

#[tokio::test]
async fn data_tables_pages_use_reported_totals_not_a_hardcoded_hundred_grade_cutoff() {
    let last=json!({"recordsTotal":3,"recordsFiltered":3,"data":[["SYNTH003","2025-2026","2025-2026学年2学期","合成课程丙",2,"B",3]]}).to_string();
    let fake = Offline::new(&[fixture!("grades_all.json"), last.as_bytes()]);
    let client = FudanCampusClient::new(fake.clone());
    let first = client
        .data_center_grades(&source(), PageWindow { offset: 0, size: 2 })
        .await
        .unwrap();
    assert_eq!(
        first.coverage,
        Coverage::Page {
            next: Some(2),
            total: Some(3)
        }
    );
    assert_eq!(
        client
            .data_center_grades(&source(), PageWindow { offset: 2, size: 2 })
            .await
            .unwrap()
            .coverage,
        Coverage::Page {
            next: None,
            total: Some(3)
        }
    );
    {
        let requests = fake.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].method.as_str(), "POST");
        let body: Value = serde_json::from_slice(requests[1].body.as_ref().unwrap()).unwrap();
        assert_eq!(body, json!({"start":2,"length":2}));
    }
    let inconsistent = Offline::new(&[br#"{"recordsTotal":3,"data":[]}"#]);
    assert!(matches!(
        FudanCampusClient::new(inconsistent)
            .data_center_grades(&source(), PageWindow { offset: 0, size: 2 })
            .await,
        Err(CampusError::PaginationInconsistent)
    ));
}

#[tokio::test]
async fn ecard_csrf_is_request_only_and_transaction_page_is_bounded() {
    let fake = Offline::new(&[
        fixture!("ecard_balance.html"),
        fixture!("ecard_csrf.html"),
        fixture!("ecard_transactions.xml"),
    ]);
    let client = FudanCampusClient::new(fake.clone());
    assert_eq!(
        client
            .ecard_balance(&source())
            .await
            .unwrap()
            .payload
            .balance
            .cents,
        4205
    );
    let transactions = client
        .ecard_transactions(&source(), on(), on().succ_opt().unwrap(), 1)
        .await
        .unwrap();
    assert_eq!(
        transactions.coverage,
        Coverage::Page {
            next: Some(2),
            total: None
        }
    );
    assert!(
        !serde_json::to_string(&transactions)
            .unwrap()
            .contains("SYNTHETIC-CSRF")
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[2].url.path(), "/epay/consume/query");
    assert_eq!(requests[2].method, HttpMethod::Post);
    let form: std::collections::HashMap<_, _> =
        url::form_urlencoded::parse(requests[2].body.as_ref().unwrap()).collect();
    assert_eq!(form["pageNo"], "1");
    assert_eq!(form["pager.offset"], "10");
    assert_eq!(form["_csrf"], "SYNTHETIC-CSRF-NOT-A-CREDENTIAL");
    assert_eq!(form["starttime"], "2026-11-01");
    assert!(!format!("{:?}", requests[2]).contains("SYNTHETIC-CSRF"));
    assert!(
        requests
            .iter()
            .all(|q| matches!(q.auth, TransportAuth::HostSession { .. }))
    );
}

#[tokio::test]
async fn dorm_public_library_and_source_bus_post_have_correct_auth_and_wire_shapes() {
    let fake = Offline::new(&[
        fixture!("electricity.json"),
        fixture!("library.json"),
        fixture!("bus.json"),
        fixture!("dining.html"),
    ]);
    let client = FudanCampusClient::new(fake.clone());
    let dorm = client.electricity(&source()).await.unwrap();
    assert_eq!(dorm.updated_at, dorm.payload.updated_at);
    assert_eq!(
        client
            .library_occupancy(&source())
            .await
            .unwrap()
            .records
            .len(),
        2
    );
    assert_eq!(client.bus(&source(), true).await.unwrap().records.len(), 2);
    assert_eq!(
        client
            .dining_occupancy(&source(), 0)
            .await
            .unwrap()
            .records
            .len(),
        2
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests[1].auth, TransportAuth::Anonymous);
    assert_eq!(requests[1].method, HttpMethod::Post);
    assert!(requests[1].body.is_none());
    assert_eq!(requests[1].url.path(), "/api/common/h5/getspaceseat");
    assert!(
        requests[2]
            .headers
            .iter()
            .any(|(k, v)| k == "Content-Type" && v.starts_with("multipart/form-data; boundary="))
    );
    let body = std::str::from_utf8(requests[2].body.as_ref().unwrap()).unwrap();
    assert!(body.contains("name=\"holiday\"\r\n\r\n1\r\n"));
    assert!(matches!(
        requests[3].auth,
        TransportAuth::HostSession { .. }
    ));
}

#[tokio::test]
async fn lan_classroom_routing_is_explicit_and_building_query_cannot_inject_parameters() {
    let fake = Offline::new(&[fixture!("empty_status.txt"), fixture!("empty_details.html")]);
    assert_eq!(
        FudanCampusClient::new(fake.clone())
            .empty_classrooms(&source(), "合成楼 &day=2000", on())
            .await
            .unwrap()
            .records
            .len(),
        2
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert!(
        requests
            .iter()
            .all(|q| q.url.host_str() == Some("10.64.130.6") && q.auth == TransportAuth::Anonymous)
    );
    let query: std::collections::HashMap<_, _> = requests[0].url.query_pairs().collect();
    assert_eq!(query["b"], "合成楼 &day=2000");
    assert_eq!(query["day"], "2026-11-01");
}

#[tokio::test]
async fn notice_pages_pe_and_qr_state_are_read_only_with_opaque_source_tracking() {
    let fake = Offline::new(&[
        fixture!("aao_ug.html"),
        fixture!("aao_pg.html"),
        fixture!("pe.html"),
        fixture!("qr_ready.html"),
        fixture!("qr_terms.html"),
    ]);
    let client = FudanCampusClient::new(fake.clone());
    assert!(matches!(
        client
            .aao_notices(&source(), AaoKind::Undergraduate, 2)
            .await
            .unwrap()
            .coverage,
        Coverage::Window { .. }
    ));
    client
        .aao_notices(&source(), AaoKind::Postgraduate, 1)
        .await
        .unwrap();
    assert_eq!(client.pe_records(&source()).await.unwrap().records.len(), 3);
    let qr = client.qr_state(&source()).await.unwrap();
    assert_eq!(qr.payload, QrState::Ready);
    assert!(!format!("{qr:?}").contains("SYNTHETIC-QR"));
    assert_eq!(
        client.qr_state(&source()).await.unwrap().payload,
        QrState::TermsNotAccepted
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests[0].url.path(), "/9397/list2.htm");
    assert_eq!(requests[1].url.path(), "/tzgg/list.htm");
    assert!(
        matches!(&requests[0].auth,TransportAuth::OptionalSession{account_id} if account_id=="synthetic-account")
    );
    assert!(
        matches!(&requests[1].auth,TransportAuth::OptionalSession{account_id} if account_id=="synthetic-account")
    );
    assert!(matches!(
        &requests[2].auth,
        TransportAuth::HostSession { .. }
    ));
    assert!(requests.iter().all(|q| q.method == HttpMethod::Get));
}

#[tokio::test]
async fn campus_auth_failures_schema_changes_and_timeout_never_fall_back_or_retry() {
    for (status, body, final_url) in [
        (401, b"{}".as_slice(), None),
        (302, b"{}".as_slice(), None),
        (
            200,
            br#"<html><form><input type="password"></form></html>"#.as_slice(),
            None,
        ),
        (200, b"{}".as_slice(), Some("https://id.fudan.edu.cn/login")),
        (200, br#"{"code":401}"#.as_slice(), None),
    ] {
        let fake = Offline::error(status, body, final_url);
        let error = FudanCampusClient::new(fake.clone())
            .ecard_balance(&source())
            .await
            .unwrap_err();
        assert!(
            matches!(error,CampusError::Transport(ConnectorError::AuthRequired(ref c)) if c.mode==AuthMode::HttpSession)
        );
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
    let fake = Offline::error(403, b"SYNTHETIC-SECRET", None);
    assert!(matches!(
        FudanCampusClient::new(fake).ecard_balance(&source()).await,
        Err(CampusError::Transport(ConnectorError::PermissionDenied))
    ));
    let fake = Offline::default();
    fake.replies
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::Timeout));
    assert!(matches!(
        FudanCampusClient::new(fake.clone())
            .bus(&source(), false)
            .await,
        Err(CampusError::Transport(ConnectorError::Timeout))
    ));
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn invalid_queries_and_bad_csrf_stop_before_further_io() {
    let fake = Offline::default();
    let client = FudanCampusClient::new(fake.clone());
    assert!(client.exams(&source(), "../wrong", false).await.is_err());
    assert!(
        client
            .undergraduate_grades(&source(), "1", "?wrong")
            .await
            .is_err()
    );
    assert!(
        client
            .ecard_transactions(&source(), on(), on(), 0)
            .await
            .is_err()
    );
    assert!(
        client
            .aao_notices(&source(), AaoKind::Undergraduate, 0)
            .await
            .is_err()
    );
    assert!(
        client
            .data_center_grades(
                &source(),
                PageWindow {
                    offset: 0,
                    size: 101
                }
            )
            .await
            .is_err()
    );
    assert!(client.dining_occupancy(&source(), 16).await.is_err());
    assert!(fake.requests.lock().unwrap().is_empty());
    let fake = Offline::new(&[b"<html>changed CSRF layout</html>"]);
    assert!(
        FudanCampusClient::new(fake.clone())
            .ecard_transactions(&source(), on(), on(), 1)
            .await
            .is_err()
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
}

#[test]
fn community_models_ignore_auth_fields_preserve_deletions_and_raw_rating_directions() {
    let hole: TeaHole = serde_json::from_slice(fixture!("tea_hole.json")).unwrap();
    assert_eq!(hole.hole_id, 101);
    assert!(
        !serde_json::to_string(&hole)
            .unwrap()
            .contains("UNKNOWN-FIELD")
    );
    let floors = parse_tea_floors(fixture!("tea_floors.json")).unwrap();
    assert_eq!(floors[1].deleted, Some(true));
    assert!(floors[1].content.is_none());
    assert_eq!(
        parse_tea_divisions(fixture!("tea_divisions.json")).unwrap()[0].name,
        "合成分区"
    );
    let groups = parse_danke_search(fixture!("danke_search.json")).unwrap();
    assert_eq!(groups.items.len(), 2);
    assert_eq!(groups.items[0].credits.as_ref().unwrap()[0], 0.5);
    assert_eq!(
        parse_danke_group(fixture!("danke_group.json"))
            .unwrap()
            .course_list
            .unwrap()[0]
            .semester,
        Some(3)
    );
    let reviews = parse_danke_reviews(fixture!("danke_reviews.json")).unwrap();
    assert_eq!(reviews[0].rank.as_ref().unwrap().content, Some(2));
    assert!(
        !serde_json::to_string(&reviews)
            .unwrap()
            .contains("UNKNOWN-FIELD")
    );
}

#[tokio::test]
async fn tea_reads_use_token_transport_without_view_count_patch_and_preserve_unzoned_time() {
    let holes = format!(
        "[{}]",
        std::str::from_utf8(fixture!("tea_hole.json")).unwrap()
    );
    let fake = Offline::new(&[
        fixture!("tea_divisions.json"),
        fixture!("tea_hole.json"),
        holes.as_bytes(),
        fixture!("tea_floors.json"),
    ]);
    let client = CommunityClient::new(fake.clone());
    client.tea_divisions(&source()).await.unwrap();
    let hole = client.tea_hole(&source(), 101).await.unwrap();
    assert_eq!(
        hole.updated_at.unwrap().to_rfc3339(),
        "2026-11-02T10:00:00+00:00"
    );
    assert!(matches!(
        client
            .tea_holes(
                &source(),
                Some(1),
                source().observed_at,
                2,
                TeaOrder::LastReplied
            )
            .await
            .unwrap()
            .coverage,
        Coverage::Window { .. }
    ));
    let floors = client
        .tea_floors(&source(), 101, PageWindow { offset: 0, size: 2 })
        .await
        .unwrap();
    assert_eq!(
        floors.coverage,
        Coverage::Page {
            next: Some(2),
            total: None
        }
    );
    assert!(floors.records[1].updated_at.is_none());
    assert_eq!(
        floors.records[1].payload.time_updated.as_deref(),
        Some("2026-11-02T11:00:00")
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    assert!(
        requests
            .iter()
            .all(|q| q.method == HttpMethod::Get
                && matches!(q.auth, TransportAuth::HostToken { .. }))
    );
    assert!(requests.iter().all(|q| {
        q.headers
            .iter()
            .all(|(k, _)| !k.eq_ignore_ascii_case("authorization"))
    }));
    assert_eq!(requests[3].url.path(), "/api/holes/101/floors");
    assert!(
        requests[2]
            .url
            .query()
            .unwrap()
            .contains("order=time_updated")
    );
}

#[tokio::test]
async fn tea_hole_windows_respect_upstream_ten_item_limit_and_preserve_cursor() {
    let hole: Value = serde_json::from_slice(fixture!("tea_hole.json")).unwrap();
    for requested in [2, 10, 20, 100] {
        let expected = requested.min(10);
        let rows: Vec<Value> = (0..expected)
            .map(|index| {
                let mut row = hole.clone();
                row["hole_id"] = json!(101 + index);
                row
            })
            .collect();
        let body = serde_json::to_vec(&rows).unwrap();
        let fake = Offline::new(&[&body]);
        let before = source().observed_at;
        let result = CommunityClient::new(fake.clone())
            .tea_holes_with_tag(
                &source(),
                Some(1),
                before,
                requested,
                TeaOrder::LastCreated,
                Some("合成"),
            )
            .await
            .unwrap();
        assert_eq!(result.records.len(), usize::from(expected));
        assert_eq!(
            result.coverage,
            Coverage::Window {
                position: before.to_rfc3339()
            }
        );
        let requests = fake.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        let query: std::collections::BTreeMap<_, _> = requests[0].url.query_pairs().collect();
        assert_eq!(query["size"], expected.to_string());
        assert_eq!(query["length"], expected.to_string());
        assert_eq!(query["start_time"], before.to_rfc3339());
        assert_eq!(query["division_id"], "1");
        assert_eq!(query["order"], "time_created");
        assert_eq!(query["tag"], "合成");
    }

    // Validate against the actual upstream page size, even for older clients requesting 20.
    let oversized = serde_json::to_vec(&vec![hole; 11]).unwrap();
    let result = CommunityClient::new(Offline::new(&[&oversized]))
        .tea_holes(
            &source(),
            None,
            source().observed_at,
            20,
            TeaOrder::LastReplied,
        )
        .await;
    assert!(matches!(result, Err(CampusError::PaginationInconsistent)));
}

#[tokio::test]
async fn danke_random_review_carries_its_course_and_group() {
    let fake = Offline::new(&[fixture!("danke_random.json")]);
    let client = CommunityClient::new(fake.clone());
    let record = client.danke_random(&source()).await.unwrap();
    assert_eq!(record.external_id, "Danke-random:602");
    assert_eq!(record.payload.review.title.as_deref(), Some("随机合成评课"));
    assert_eq!(record.payload.group_id, Some(301));
    let course = record.payload.course.as_ref().unwrap();
    assert_eq!(course.teachers.as_deref(), Some("合成老师"));
    assert_eq!(course.credit, Some(2.0));
    let text = serde_json::to_string(&record.payload).unwrap();
    assert!(!text.contains("UNKNOWN-FIELD"));
    // Flattened back into one review object, as DanXi reads it.
    assert!(text.contains(r#""timeCreated""#));
    assert_eq!(
        fake.requests.lock().unwrap()[0].url.path(),
        "/api/reviews/random"
    );
}

#[tokio::test]
async fn danke_search_group_and_reviews_use_verified_v3_v1_routes_and_bounded_pages() {
    let fake = Offline::new(&[
        fixture!("danke_search.json"),
        fixture!("danke_group.json"),
        fixture!("danke_reviews.json"),
    ]);
    let client = CommunityClient::new(fake.clone());
    let groups = client
        .danke_search(&source(), "合成 &page=999", 1, 2)
        .await
        .unwrap();
    assert_eq!(
        groups.coverage,
        Coverage::Page {
            next: Some(2),
            total: None
        }
    );
    assert_eq!(
        client.danke_group(&source(), 301).await.unwrap().payload.id,
        301
    );
    assert_eq!(
        client.danke_reviews(&source(), 401).await.unwrap().records[0].external_id,
        "Danke-review:601"
    );
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[0].url.path(), "/api/v3/course_groups/search");
    assert_eq!(requests[1].url.path(), "/api/v3/course_groups/301");
    assert_eq!(requests[2].url.path(), "/api/courses/401/reviews");
    let query: std::collections::HashMap<_, _> = requests[0].url.query_pairs().collect();
    assert_eq!(query["query"], "合成 &page=999");
    assert_eq!(query["page"], "1");
}

#[tokio::test]
async fn community_auth_drift_and_paging_errors_remain_explicit_without_token_refresh() {
    let fake = Offline::error(401, b"SYNTHETIC-SECRET", None);
    assert!(
        matches!(CommunityClient::new(fake.clone()).tea_divisions(&source()).await,Err(CampusError::Transport(ConnectorError::AuthRequired(ref c))) if c.mode==AuthMode::Token)
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
    let fake = Offline::new(&[br#"{"items":[]}"#]);
    assert!(
        CommunityClient::new(fake)
            .danke_search(&source(), "test", 1, 10)
            .await
            .is_err()
    );
    let mut raw: Value = serde_json::from_slice(fixture!("danke_search.json")).unwrap();
    raw["page"] = json!(2);
    let bytes = serde_json::to_vec(&raw).unwrap();
    let fake = Offline::new(&[&bytes]);
    assert!(matches!(
        CommunityClient::new(fake)
            .danke_search(&source(), "test", 1, 2)
            .await,
        Err(CampusError::PaginationInconsistent)
    ));
    let fake = Offline::default();
    let client = CommunityClient::new(fake.clone());
    assert!(
        client
            .tea_floors(&source(), 101, PageWindow { offset: 0, size: 0 })
            .await
            .is_err()
    );
    assert!(client.danke_search(&source(), "", 1, 10).await.is_err());
    assert!(client.tea_hole(&source(), 0).await.is_err());
    assert!(fake.requests.lock().unwrap().is_empty());
    assert!(
        CommunityClient::new(Offline::default())
            .with_origins(
                "https://user:pass@forum.example.invalid",
                "https://danke.example.invalid"
            )
            .is_err()
    );
    // Dedicated verified origins accepted
    assert!(
        CommunityClient::new(Offline::default())
            .with_origins("https://forum.fduhole.com", "https://danke.fduhole.com")
            .is_ok()
    );
    // Legacy DanXi server address normalized
    assert!(
        CommunityClient::new(Offline::default())
            .with_origins("https://www.fduhole.com", "https://danke.fduhole.com")
            .is_ok()
    );
    // Arbitrary unverified origins rejected
    assert!(
        CommunityClient::new(Offline::default())
            .with_origins("https://evil.example.com", "https://danke.fduhole.com")
            .is_err()
    );
}

#[test]
fn all_new_client_futures_are_send_for_host_service_registry() {
    fn send(_: impl Send) {}
    let client = FudanCampusClient::new(Offline::default());
    let source = source();
    send(client.gpa(&source, "7101"));
    send(client.ecard_transactions(&source, on(), on(), 1));
    send(client.empty_classrooms(&source, "合成楼", on()));
    send(client.bus(&source, false));
    send(CommunityClient::new(Offline::default()).danke_search(&source, "test", 1, 10));
}

#[test]
fn source_failure_flags_holder_auth_signal_and_untrusted_notice_links_fail_closed() {
    assert!(parse_library_occupancy(br#"{"success":false,"data":[]}"#).is_err());
    assert!(
        parse_ecard_balance(
            br#"<html><div class="payway-box-bottom-item"><p>0.00</p></div></html>"#
        )
        .is_err()
    );
    let notice = String::from_utf8(fixture!("aao_ug.html").to_vec())
        .unwrap()
        .replace(
            "/synthetic/notice/page.htm",
            "https://evil.example.invalid/?token=SYNTHETIC-SECRET",
        );
    let error = parse_aao_notices(notice.as_bytes(), AaoKind::Undergraduate).unwrap_err();
    assert!(matches!(
        error,
        CampusError::Transport(ConnectorError::UnsafeUrl)
    ));
    assert!(!format!("{error:?}").contains("SYNTHETIC-SECRET"));
    let oversized = vec![b' '; 8 * 1024 * 1024 + 1];
    assert!(matches!(
        parse_library_occupancy(&oversized),
        Err(CampusError::Transport(ConnectorError::LimitExceeded))
    ));
}

#[tokio::test]
async fn short_data_table_page_uses_total_and_json_auth_codes_keep_their_meaning() {
    let short=json!({"recordsTotal":3,"data":[["SYNTH001","2025-2026","Synthetic term","Synthetic course",1,"A",4]]}).to_string();
    let fake = Offline::new(&[short.as_bytes()]);
    assert_eq!(
        FudanCampusClient::new(fake)
            .data_center_grades(&source(), PageWindow { offset: 0, size: 2 })
            .await
            .unwrap()
            .coverage,
        Coverage::Page {
            next: Some(1),
            total: Some(3)
        }
    );
    let fake = Offline::new(&[br#"{"code":"403","data":[]}"#]);
    assert!(matches!(
        FudanCampusClient::new(fake).ecard_balance(&source()).await,
        Err(CampusError::Transport(ConnectorError::PermissionDenied))
    ));
    let fake = Offline::new(&[br#"{"code":"401","success":false,"data":[]}"#]);
    assert!(matches!(
        CommunityClient::new(fake.clone())
            .tea_divisions(&source())
            .await,
        Err(CampusError::Transport(ConnectorError::AuthRequired(_)))
    ));
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn an_explicit_empty_observation_still_retains_account_source_time_and_revision() {
    let fake = Offline::new(&[br#"{"data":[]}"#]);
    let context = source();
    let result = FudanCampusClient::new(fake)
        .library_occupancy(&context)
        .await
        .unwrap();
    assert!(result.records.is_empty());
    assert_eq!(result.source, context);
    assert_eq!(result.source_revision, DANXI_REVISION);
    assert_eq!(result.coverage, Coverage::Complete);
}

#[test]
fn notice_attachments_keep_same_site_cms_files_only() {
    let page = Url::parse("https://gs.fudan.edu.cn/0d/ac/c12939a789932/page.htm").unwrap();
    let html = r#"<html><body><div class="wp_articlecontent">
<p><a href="/_upload/article/files/aa/bb/uuid-1/f1.pdf" sudyfile-attr="{'title':'报名通知.pdf'}">报名通知.pdf</a></p>
<p><a href="/_upload/article/files/aa/bb/uuid-1/f1.pdf">duplicate</a></p>
<p><a href="https://evil.test/_upload/article/files/x/y/z.pdf">elsewhere</a></p>
<p><a href="/_upload/tpl/0c/41/3137/template3137/css/index.css">template</a></p>
<p><a href="/_upload/article/files/cc/dd/uuid-2/%E8%A1%A8.docx">附件</a></p>
<div class="wp_pdf_player" pdfsrc="/_upload/article/files/ee/ff/uuid-3/scan.pdf"></div>
</div></body></html>"#;
    let found = parse_notice_attachments(html.as_bytes(), &page).unwrap();
    let names: Vec<_> = found.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, ["报名通知.pdf", "表.docx", "scan.pdf"]);
    assert!(found.iter().all(|a| {
        a.url
            .starts_with("https://gs.fudan.edu.cn/_upload/article/files/")
    }));
    assert!(notice_page("https://jwc.fudan.edu.cn/28/3d/c25325a796733/page.htm").is_ok());
    assert!(notice_page("http://jwc.fudan.edu.cn/a/page.htm").is_err());
    assert!(notice_page("https://evil.test/a/page.htm").is_err());
    assert!(notice_attachment_url("https://gs.fudan.edu.cn/_upload/tpl/x.css").is_err());
    assert!(
        notice_attachment_url("https://gs.fudan.edu.cn/_upload/article/files/a/b.pdf?x=1").is_err()
    );
}
