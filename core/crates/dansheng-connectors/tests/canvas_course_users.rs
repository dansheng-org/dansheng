use async_trait::async_trait;
use chrono::Utc;
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth,
    canvas::{CanvasAccess, CanvasClient, CanvasLimits},
    models::SourceContext,
};
use serde_json::json;
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
use url::Url;

const ORIGIN: &str = "https://canvas-roster.invalid";
const PATH: &str = "/api/v1/courses/42/users?per_page=100&include%5B%5D=enrollments";
#[derive(Clone, Default)]
struct Fake {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    responses: Arc<Mutex<VecDeque<ConnectorResponse>>>,
}
#[async_trait]
impl ConnectorTransport for Fake {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        self.requests.lock().unwrap().push(request);
        Ok(self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected I/O"))
    }
}
fn source() -> SourceContext {
    SourceContext {
        account_id: "roster-account".into(),
        source_id: "roster-source".into(),
        observed_at: Utc::now(),
    }
}
fn response(path: &str, body: serde_json::Value, next: Option<&str>) -> ConnectorResponse {
    ConnectorResponse {
        status: 200,
        final_url: Url::parse(&format!("{ORIGIN}{path}")).unwrap(),
        body: serde_json::to_vec(&body).unwrap(),
        headers: next
            .map(|next| vec![("Link".into(), format!("<{next}>; rel=\"next\""))])
            .unwrap_or_default(),
    }
}
fn setup(responses: Vec<ConnectorResponse>) -> (Fake, CanvasClient<Fake>) {
    let fake = Fake {
        responses: Arc::new(Mutex::new(responses.into())),
        ..Default::default()
    };
    let client = CanvasClient::new(fake.clone(), ORIGIN, CanvasAccess::HostSession).unwrap();
    (fake, client)
}

#[tokio::test]
async fn roster_is_bounded_read_only_and_strips_nested_private_fields() {
    let path = format!("{PATH}&search_term=A%2BB+%26");
    let next = "/api/v1/courses/42/users?include[]=enrollments&search_term=A%2BB+%26&page=2";
    let (fake, client) = setup(vec![
        response(
            &path,
            json!([{"id":9007199254740993u64,"name":"PRIVATE-NAME","short_name":"A",
            "email":"DROP","login_id":"DROP","sis_user_id":"DROP","avatar_url":"DROP",
            "enrollments":[{"type":"TeacherEnrollment","role":"Teacher","role_id":4,
                "course_id":42,"user_id":9007199254740993u64,"course_section_id":5,
                "grades":{"score":"DROP"},"user":{"email":"DROP"},"sis_section_id":"DROP"}]}]),
            Some(next),
        ),
        response(
            next,
            json!([{"id":"900719925474099312345","name":"Other","enrollments":null}]),
            None,
        ),
    ]);
    let rows = client
        .course_users(&source(), "42", Some("A+B &"))
        .await
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].external_id, "course-user:42:9007199254740993");
    assert_eq!(rows[0].payload.id.0, "9007199254740993");
    assert_eq!(
        rows[0].payload.enrollments[0].enrollment_type,
        "TeacherEnrollment"
    );
    assert!(rows[1].payload.enrollments.is_empty());
    assert!(!serde_json::to_string(&rows).unwrap().contains("DROP"));
    assert!(!format!("{rows:?}").contains("PRIVATE-NAME"));
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert!(requests.iter().all(|request| request.method == HttpMethod::Get && request.body.is_none()
        && matches!(&request.auth, TransportAuth::HostSession { account_id } if account_id == "roster-account")));
    assert!(
        requests[0]
            .url
            .query_pairs()
            .any(|(key, value)| key == "search_term" && value == "A+B &")
    );
}

#[tokio::test]
async fn pagination_rejects_scope_changes_cross_origin_and_secret_query_before_next_request() {
    for next in [
        "https://evil.invalid/api/v1/courses/42/users?include[]=enrollments",
        "/api/v1/courses/43/users?include[]=enrollments",
        "/api/v1/courses/42/users?page=2",
        "/api/v1/courses/42/users?include[]=enrollments&search_term=other",
        "/api/v1/courses/42/users?include[]=enrollments&access_token=secret",
        "/api/v1/courses/42/users?include[]=email",
    ] {
        let (fake, client) = setup(vec![response(PATH, json!([]), Some(next))]);
        assert!(client.course_users(&source(), "42", None).await.is_err());
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn rejects_duplicate_ids_wrong_context_redirects_limits_and_later_page_failures() {
    for body in [
        json!([{"id":1,"name":"A"},{"id":1,"name":"B"}]),
        json!([{"id":1,"name":"A","enrollments":[{"type":"StudentEnrollment","course_id":43}]}]),
        json!([{"id":1,"name":"A","enrollments":[{"type":"StudentEnrollment","user_id":2}]}]),
    ] {
        let (_, client) = setup(vec![response(PATH, body, None)]);
        assert!(client.course_users(&source(), "42", None).await.is_err());
    }
    let next = format!("{PATH}&page=2");
    let mut failed = response(&next, json!([]), None);
    failed.status = 403;
    let (_, client) = setup(vec![
        response(PATH, json!([{"id":1,"name":"A"}]), Some(&next)),
        failed,
    ]);
    assert_eq!(
        client
            .course_users(&source(), "42", None)
            .await
            .unwrap_err(),
        ConnectorError::PermissionDenied
    );
    let (_, client) = setup(vec![response(PATH, json!([]), Some(PATH))]);
    assert_eq!(
        client
            .course_users(&source(), "42", None)
            .await
            .unwrap_err(),
        ConnectorError::PaginationCycle
    );
    let (_, client) = setup(vec![response(
        PATH,
        json!([{"id":1,"name":"A"},{"id":2,"name":"B"}]),
        None,
    )]);
    let client = client
        .with_limits(CanvasLimits {
            max_items: 1,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        client
            .course_users(&source(), "42", None)
            .await
            .unwrap_err(),
        ConnectorError::LimitExceeded
    );
    let (_, client) = setup(vec![response("/api/v1/courses/43/users", json!([]), None)]);
    assert_eq!(
        client
            .course_users(&source(), "42", None)
            .await
            .unwrap_err(),
        ConnectorError::UnsafeUrl
    );
}

#[tokio::test]
async fn invalid_inputs_never_dispatch() {
    let (fake, client) = setup(vec![]);
    for id in ["", "../42", "42/users", "sis_course_id:42"] {
        assert!(client.course_users(&source(), id, None).await.is_err());
    }
    for search in ["\r", "\0", &"x".repeat(257)] {
        assert!(
            client
                .course_users(&source(), "42", Some(search))
                .await
                .is_err()
        );
    }
    assert!(fake.requests.lock().unwrap().is_empty());
}
