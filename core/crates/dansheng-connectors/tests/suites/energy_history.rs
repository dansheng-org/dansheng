// SPDX-License-Identifier: GPL-3.0-or-later
use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use dansheng_connectors::campus::{CampusError, Coverage, PageWindow};
use dansheng_connectors::energy_history::{
    ELECTRICITY_HISTORY_PATH, ElectricityHistoryClient, ElectricityHistoryRecord, MY_ORIGIN,
    parse_electricity_history, parse_electricity_history_with_meta,
};
use dansheng_connectors::models::SourceContext;
use dansheng_connectors::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse,
    ConnectorTransport, HttpMethod, TransportAuth,
};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use url::Url;

fn test_source() -> SourceContext {
    SourceContext {
        account_id: "synthetic-student".into(),
        source_id: "official.fudan.electricity.history".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 8, 12, 0, 0).unwrap(),
    }
}

#[derive(Clone, Default)]
struct MockTransport {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    replies: Arc<Mutex<VecDeque<Result<ConnectorResponse, ConnectorError>>>>,
}

impl MockTransport {
    fn new_ok(body: &[u8]) -> Self {
        Self {
            requests: Arc::new(Mutex::new(Vec::new())),
            replies: Arc::new(Mutex::new(VecDeque::from([Ok(ConnectorResponse {
                status: 200,
                final_url: Url::parse(&format!("{MY_ORIGIN}{ELECTRICITY_HISTORY_PATH}")).unwrap(),
                headers: vec![],
                body: body.to_vec(),
            })]))),
        }
    }
}

#[async_trait]
impl ConnectorTransport for MockTransport {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        self.requests.lock().unwrap().push(request);
        self.replies
            .lock()
            .unwrap()
            .pop_front()
            .expect("offline response expected")
    }
}

#[test]
fn parse_json_data_tables_extracts_date_amount_dorm_name() {
    let fixture = r#"{
        "draw": 2,
        "recordsTotal": 2,
        "recordsFiltered": 2,
        "data": [
            ["1", "邯郸", "15号楼", "1501", "2024-06-01", "1.5"],
            ["2", "江湾", "1号楼", "202", "2024-06-02", "3.2"]
        ]
    }"#
    .as_bytes();

    let (records, total) = parse_electricity_history_with_meta(fixture, None).unwrap();
    assert_eq!(total, Some(2));
    assert_eq!(records.len(), 2);

    assert_eq!(
        records[0],
        ElectricityHistoryRecord {
            date: "2024-06-01".into(),
            amount: "1.5".into(),
            dorm_name: "邯郸/15号楼/1501".into(),
        }
    );
    assert_eq!(
        records[1],
        ElectricityHistoryRecord {
            date: "2024-06-02".into(),
            amount: "3.2".into(),
            dorm_name: "江湾/1号楼/202".into(),
        }
    );

    let serialized = serde_json::to_value(&records[0]).unwrap();
    assert_eq!(serialized["date"], "2024-06-01");
    assert_eq!(serialized["amount"], "1.5");
    assert_eq!(serialized["dorm_name"], "邯郸/15号楼/1501");
}

#[test]
fn parse_json_empty_distinguished_from_malformed() {
    let empty_fixture =
        r#"{"draw": 2, "recordsTotal": 0, "recordsFiltered": 0, "data": []}"#.as_bytes();
    let records = parse_electricity_history(empty_fixture).unwrap();
    assert!(records.is_empty());
}

#[test]
fn parse_html_table_extracts_records_and_trims_html_tags() {
    let fixture = r#"
    <!DOCTYPE html>
    <html>
    <head><title>用电情况</title></head>
    <body>
      <table>
        <thead>
          <tr><th>序号</th><th>校区</th><th>楼号</th><th>房间号</th><th>日期</th><th>用电量</th></tr>
        </thead>
        <tbody>
          <tr>
            <td>1</td>
            <td><span>邯郸</span></td>
            <td>15号楼</td>
            <td>1501</td>
            <td>2024-06-01</td>
            <td>1.5</td>
          </tr>
        </tbody>
      </table>
    </body>
    </html>"#.as_bytes();

    let records = parse_electricity_history(fixture).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].dorm_name, "邯郸/15号楼/1501");
    assert_eq!(records[0].date, "2024-06-01");
    assert_eq!(records[0].amount, "1.5");
}

#[test]
fn parse_html_table_empty_placeholder_distinguished() {
    let fixture = r#"
    <table>
      <tbody>
        <tr class="tr-empty"><td>暂无数据</td></tr>
      </tbody>
    </table>"#
        .as_bytes();

    let records = parse_electricity_history(fixture).unwrap();
    assert!(records.is_empty());
}

#[test]
fn login_html_redirect_detected_as_auth_required() {
    let login_page = r#"
    <!DOCTYPE html>
    <html>
    <head><title>统一身份认证 - 登录</title></head>
    <body>
      <form id="logon" action="https://uis.fudan.edu.cn/authserver/login">
        <input type="text" name="username">
        <input type="password" name="password">
      </form>
    </body>
    </html>"#
        .as_bytes();

    let challenge = AuthChallenge {
        connector: "fudan-campus".into(),
        origin: MY_ORIGIN.into(),
        account_id: "test-user".into(),
        mode: AuthMode::HttpSession,
    };

    let err = parse_electricity_history_with_meta(login_page, Some(&challenge)).unwrap_err();
    match err {
        CampusError::Transport(ConnectorError::AuthRequired(c)) => {
            assert_eq!(c.account_id, "test-user");
            assert_eq!(c.origin, MY_ORIGIN);
        }
        other => panic!("expected AuthRequired, got: {other:?}"),
    }
}

#[test]
fn login_json_401_envelope_detected_as_auth_required() {
    let json_401 = r#"{"code": "401", "msg": "未登录"}"#.as_bytes();
    let challenge = AuthChallenge {
        connector: "fudan-campus".into(),
        origin: MY_ORIGIN.into(),
        account_id: "test-user".into(),
        mode: AuthMode::HttpSession,
    };

    let err = parse_electricity_history_with_meta(json_401, Some(&challenge)).unwrap_err();
    match err {
        CampusError::Transport(ConnectorError::AuthRequired(c)) => {
            assert_eq!(c.account_id, "test-user");
        }
        other => panic!("expected AuthRequired, got: {other:?}"),
    }
}

#[test]
fn malformed_inputs_fail_closed_with_schema_changed() {
    // Missing "data" field in JSON
    assert!(matches!(
        parse_electricity_history(r#"{"recordsTotal": 10}"#.as_bytes()),
        Err(CampusError::SchemaChanged { field: "data", .. })
    ));

    // "data" is not an array
    assert!(matches!(
        parse_electricity_history(r#"{"data": "not-array"}"#.as_bytes()),
        Err(CampusError::SchemaChanged {
            field: "data_array",
            ..
        })
    ));

    // Row has too few columns (< 6)
    assert!(matches!(
        parse_electricity_history(r#"{"data": [["1", "邯郸", "15号楼"]]}"#.as_bytes()),
        Err(CampusError::SchemaChanged {
            field: "row_columns",
            ..
        })
    ));

    // HTML without table
    assert!(matches!(
        parse_electricity_history(
            r#"<html><body><h1>500 Internal Server Error</h1></body></html>"#.as_bytes()
        ),
        Err(CampusError::SchemaChanged { field: "table", .. })
    ));

    // Non-UTF8 encoding
    assert!(matches!(
        parse_electricity_history(b"\xff\xfe\xfd"),
        Err(CampusError::SchemaChanged {
            field: "encoding",
            ..
        })
    ));

    // Empty body
    assert!(matches!(
        parse_electricity_history(b""),
        Err(CampusError::SchemaChanged {
            field: "empty_body",
            ..
        })
    ));
}

#[test]
fn bounds_check_enforces_bounded_page_window() {
    let source = test_source();
    let transport = MockTransport::new_ok(br#"{"data": []}"#);
    let client = ElectricityHistoryClient::new(transport);

    // size = 0
    let err = tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(client.electricity_history(&source, PageWindow { offset: 0, size: 0 }))
        .unwrap_err();
    assert_eq!(err, CampusError::InvalidQuery("page window"));

    // size > 100
    let err = tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(client.electricity_history(
            &source,
            PageWindow {
                offset: 0,
                size: 101,
            },
        ))
        .unwrap_err();
    assert_eq!(err, CampusError::InvalidQuery("page window"));

    // offset > 1_000_000
    let err = tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(client.electricity_history(
            &source,
            PageWindow {
                offset: 1_000_001,
                size: 20,
            },
        ))
        .unwrap_err();
    assert_eq!(err, CampusError::InvalidQuery("page window"));
}

#[tokio::test]
async fn client_wire_protocol_matches_exact_read_only_post() {
    let fixture = r#"{
        "draw": 2,
        "recordsTotal": 50,
        "recordsFiltered": 50,
        "data": [
            ["1", "邯郸", "15号楼", "1501", "2024-06-01", "1.5"]
        ]
    }"#
    .as_bytes();
    let transport = MockTransport::new_ok(fixture);
    let client = ElectricityHistoryClient::new(transport.clone());
    let source = test_source();

    let batch = client
        .electricity_history(
            &source,
            PageWindow {
                offset: 0,
                size: 30,
            },
        )
        .await
        .unwrap();

    assert_eq!(batch.records.len(), 1);
    assert_eq!(batch.records[0].payload.date, "2024-06-01");
    assert_eq!(batch.records[0].payload.amount, "1.5");
    assert_eq!(batch.records[0].payload.dorm_name, "邯郸/15号楼/1501");
    assert_eq!(
        batch.records[0].external_id,
        "electricity-history:邯郸/15号楼/1501:2024-06-01:0"
    );

    match batch.coverage {
        Coverage::Page { next, total } => {
            assert_eq!(total, Some(50));
            assert_eq!(next, Some(1));
        }
        other => panic!("expected Coverage::Page, got: {other:?}"),
    }

    // Verify wire request
    let requests = transport.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    let req = &requests[0];
    assert_eq!(req.method, HttpMethod::Post);
    assert_eq!(
        req.url.as_str(),
        "https://my.fudan.edu.cn/data_tables/ykt_xszsqyydqk.json"
    );
    assert_eq!(
        req.auth,
        TransportAuth::HostSession {
            account_id: "synthetic-student".into()
        }
    );

    let content_type = req
        .headers
        .iter()
        .find(|(k, _)| k == "Content-Type")
        .map(|(_, v)| v.as_str())
        .unwrap();
    assert!(content_type.starts_with("multipart/form-data; boundary="));

    let body_str = String::from_utf8(req.body.as_ref().unwrap().clone()).unwrap();
    assert!(body_str.contains("name=\"draw\"\r\n\r\n2"));
    assert!(body_str.contains("name=\"start\"\r\n\r\n0"));
    assert!(body_str.contains("name=\"length\"\r\n\r\n30"));
}

#[tokio::test]
async fn client_pagination_inconsistency_fails_closed() {
    // recordsFiltered claims 5 total, but offset is 10
    let fixture = r#"{
        "draw": 2,
        "recordsTotal": 5,
        "recordsFiltered": 5,
        "data": [
            ["1", "邯郸", "15号楼", "1501", "2024-06-01", "1.5"]
        ]
    }"#
    .as_bytes();
    let transport = MockTransport::new_ok(fixture);
    let client = ElectricityHistoryClient::new(transport);
    let source = test_source();

    let err = client
        .electricity_history(
            &source,
            PageWindow {
                offset: 10,
                size: 20,
            },
        )
        .await
        .unwrap_err();
    assert_eq!(err, CampusError::PaginationInconsistent);
}

#[cfg(feature = "services")]
#[test]
fn core_adapter_registers_and_dispatches_electricity_history_only() {
    use dansheng_connectors::core_adapter::CampusService;
    use dansheng_core::services::CoreService;

    let service = CampusService;
    let methods = service.methods();

    let registered = methods
        .iter()
        .find(|(method, _)| *method == "fudan.electricity.history");
    assert!(
        registered.is_some(),
        "fudan.electricity.history must be registered"
    );
    assert_eq!(registered.unwrap().1, "fudan.life.read");

    // Ensure no dining or login methods were altered
    assert!(
        methods
            .iter()
            .any(|(m, c)| *m == "fudan.electricity" && *c == "fudan.life.read")
    );
    assert!(
        methods
            .iter()
            .any(|(m, c)| *m == "fudan.dining.occupancy" && *c == "fudan.life.read")
    );
}
