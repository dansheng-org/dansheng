use async_trait::async_trait;
use chrono::{Datelike, TimeZone, Utc, Weekday};
use dansheng_connectors::academic_catalog::FudanAcademicCatalogClient;
use dansheng_connectors::campus::CampusError;
use dansheng_connectors::models::SourceContext;
use dansheng_connectors::postgraduate_calendar::{PostgraduateCalendarError, current_semester};
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use serde_json::json;
use std::sync::{Arc, Mutex};

#[derive(Clone)]
struct Fake {
    body: String,
    failure: Option<ConnectorError>,
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
}

#[async_trait]
impl ConnectorTransport for Fake {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        let final_url = request.url.clone();
        self.requests.lock().unwrap().push(request);
        if let Some(error) = &self.failure {
            return Err(error.clone());
        }
        Ok(ConnectorResponse {
            status: 200,
            final_url,
            headers: vec![("Content-Type".into(), "text/html".into())],
            body: self.body.as_bytes().to_vec(),
        })
    }
}

fn source() -> SourceContext {
    SourceContext {
        account_id: "synthetic-public-owner".into(),
        source_id: "synthetic-calendar".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 14, 0, 0, 0).unwrap(),
    }
}

fn fake(options: &str) -> Fake {
    Fake {
        body: format!("<select id=\"semester\">{options}</select>"),
        failure: None,
        requests: Arc::default(),
    }
}

#[tokio::test]
async fn current_default_preserves_dynamic_id_and_uses_one_anonymous_get() {
    for id in ["527", "987654"] {
        let transport = fake(&format!(
            "<option value=\"529\">2026-2027学年2学期</option>\
             <option value=\"{id}\" selected>2026-2027学年1学期</option>"
        ));
        let semester = current_semester(
            &FudanAcademicCatalogClient::new(transport.clone()),
            &source(),
        )
        .await
        .unwrap();
        assert_eq!(semester.starts_on.weekday(), Weekday::Mon);
        assert_eq!(
            serde_json::to_value(semester).unwrap(),
            json!({"external_id": id, "name": "2026-2027学年1学期", "starts_on": "2026-09-07"})
        );
        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].method, HttpMethod::Get);
        assert!(matches!(requests[0].auth, TransportAuth::Anonymous));
        assert!(requests[0].body.is_none());
        assert_eq!(
            requests[0].url.as_str(),
            "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search"
        );
    }
}

#[tokio::test]
async fn unavailable_default_never_falls_back_to_a_known_nondefault_term() {
    for name in [
        "2026-2027学年2学期",
        "2027-2028学年1学期",
        "2025-2026学年1学期",
        "2026-2027学年暑期",
        "2026-2027学年1学期（其他日历）",
    ] {
        let transport = fake(&format!(
            "<option value=\"1\">2026-2027学年1学期</option>\
             <option value=\"527\" selected>{name}</option>"
        ));
        assert_eq!(
            current_semester(&FudanAcademicCatalogClient::new(transport), &source()).await,
            Err(PostgraduateCalendarError::SemesterCalendarUnavailable)
        );
    }
}

#[tokio::test]
async fn catalog_schema_errors_are_not_calendar_unavailability() {
    for options in [
        "",
        "<option value=\"527\">2026-2027学年1学期</option>",
        "<option value=\"527\" selected>2026-2027学年1学期</option><option value=\"527\">duplicate</option>",
    ] {
        assert!(matches!(
            current_semester(&FudanAcademicCatalogClient::new(fake(options)), &source()).await,
            Err(PostgraduateCalendarError::Source(
                CampusError::SchemaChanged { .. }
            ))
        ));
    }
}

#[tokio::test]
async fn stale_defaults_are_rejected_at_shanghai_calendar_boundaries() {
    let transport = fake("<option value=\"527\" selected>2026-2027学年1学期</option>");
    let client = FudanAcademicCatalogClient::new(transport);
    for (timestamp, available) in [
        ("2026-08-29T15:59:59Z", false),
        ("2026-08-29T16:00:00Z", true),
        ("2026-09-06T16:00:00Z", true),
        ("2027-01-09T15:59:59Z", true),
        ("2027-01-09T16:00:00Z", false),
        ("2027-09-07T00:00:00Z", false),
        ("2040-11-14T00:00:00Z", false),
    ] {
        let mut source = source();
        source.observed_at = timestamp.parse().unwrap();
        let result = current_semester(&client, &source).await;
        if available {
            assert!(result.is_ok(), "{timestamp}: {result:?}");
        } else {
            assert_eq!(
                result,
                Err(PostgraduateCalendarError::SemesterCalendarUnavailable),
                "{timestamp}"
            );
        }
    }
}

#[tokio::test]
async fn second_semester_requires_its_own_verified_shanghai_interval() {
    let transport = fake(
        "<option value=\"527\">2026-2027学年1学期</option>\
         <option value=\"987655\" selected>2026-2027学年2学期</option>",
    );
    let client = FudanAcademicCatalogClient::new(transport);
    for (timestamp, available) in [
        ("2026-11-14T00:00:00Z", false),
        ("2027-02-13T15:59:59Z", false),
        ("2027-02-13T16:00:00Z", true),
        ("2027-02-21T16:00:00Z", true),
        ("2027-06-26T15:59:59Z", true),
        ("2027-06-26T16:00:00Z", false),
        ("2040-03-01T00:00:00Z", false),
    ] {
        let mut source = source();
        source.observed_at = timestamp.parse().unwrap();
        let result = current_semester(&client, &source).await;
        if available {
            let semester = result.unwrap();
            assert_eq!(semester.starts_on.weekday(), Weekday::Mon);
            assert_eq!(
                serde_json::to_value(semester).unwrap(),
                json!({"external_id": "987655", "name": "2026-2027学年2学期", "starts_on": "2027-02-22"}),
                "{timestamp}"
            );
        } else {
            assert_eq!(
                result,
                Err(PostgraduateCalendarError::SemesterCalendarUnavailable),
                "{timestamp}"
            );
        }
    }
}

#[tokio::test]
async fn catalog_transport_failure_is_preserved_without_retry() {
    let mut transport = fake("");
    transport.failure = Some(ConnectorError::UnsafeUrl);
    assert_eq!(
        current_semester(
            &FudanAcademicCatalogClient::new(transport.clone()),
            &source()
        )
        .await,
        Err(PostgraduateCalendarError::Source(CampusError::Transport(
            ConnectorError::UnsafeUrl
        )))
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
}
