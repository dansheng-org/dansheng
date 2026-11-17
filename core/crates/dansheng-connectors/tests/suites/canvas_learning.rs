// SPDX-License-Identifier: GPL-3.0-or-later
use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use dansheng_connectors::canvas::*;
use dansheng_connectors::models::SourceContext;
use dansheng_connectors::{
    AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth,
};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use url::Url;

const CANVAS: &str = "https://canvas.example.invalid";
const QUIZZES: &str = include_str!("../../fixtures/canvas_learning/quizzes.json");
const TOPICS: &str = include_str!("../../fixtures/canvas_learning/topics.json");
const TOPIC: &str = include_str!("../../fixtures/canvas_learning/topic.json");
const VIEW: &str = include_str!("../../fixtures/canvas_learning/view.json");
const SUBMISSION: &str = include_str!("../../fixtures/canvas_learning/submission.json");
const ENROLLMENTS: &str = include_str!("../../fixtures/canvas_learning/enrollments.json");
const GROUPS: &str = include_str!("../../fixtures/canvas_learning/groups.json");
const USER: &str = "9007199254740993";

fn source() -> SourceContext {
    SourceContext {
        account_id: "account-fixture".into(),
        source_id: "canvas-fixture".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 9, 12, 0, 0).unwrap(),
    }
}
fn response(path: &str, body: &str) -> ConnectorResponse {
    ConnectorResponse {
        status: 200,
        final_url: Url::parse(&format!("{CANVAS}{path}")).unwrap(),
        headers: vec![],
        body: body.as_bytes().to_vec(),
    }
}
fn profile() -> ConnectorResponse {
    response(
        "/api/v1/users/self/profile",
        &format!(r#"{{"id":"{USER}","login_id":"SYNTHETIC_DO_NOT_PERSIST"}}"#),
    )
}
fn enrollment_path() -> String {
    format!("/api/v1/courses/81001/enrollments?user_id={USER}&per_page=100")
}

#[derive(Clone, Default)]
struct Fake {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    responses: Arc<Mutex<VecDeque<ConnectorResponse>>>,
}
impl Fake {
    fn new(responses: Vec<ConnectorResponse>) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into())),
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
        Ok(self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected request"))
    }
}
fn client(fake: Fake, access: CanvasAccess) -> CanvasClient<Fake> {
    CanvasClient::new(fake, CANVAS, access).unwrap()
}
fn no_secrets<T: serde::Serialize + std::fmt::Debug>(value: &T) {
    assert!(
        !serde_json::to_string(value)
            .unwrap()
            .contains("SYNTHETIC_DO_NOT_PERSIST")
    );
    assert!(!format!("{value:?}").contains("SYNTHETIC_DO_NOT_PERSIST"));
}

#[tokio::test]
async fn classic_quiz_metadata_keeps_large_ids_and_locked_state_without_launching() {
    let fake = Fake::new(vec![response(
        "/api/v1/courses/81001/quizzes?per_page=100",
        QUIZZES,
    )]);
    let rows = client(fake.clone(), CanvasAccess::BrowserSession)
        .quizzes(&source(), "81001")
        .await
        .unwrap();
    assert_eq!(rows[0].payload.id.0, "9007199254740993123456789");
    assert_eq!(rows[0].payload.allowed_attempts, Some(-1));
    assert_eq!(rows[0].payload.locked_for_user, Some(true));
    assert!(
        rows[0]
            .payload
            .description
            .as_ref()
            .unwrap()
            .contains("chapter one")
    );
    assert!(!rows[0].payload.description.as_ref().unwrap().contains('<'));
    no_secrets(&rows);
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, HttpMethod::Get);
    assert!(matches!(
        requests[0].auth,
        TransportAuth::BrowserSession { .. }
    ));
    // Classic /quizzes is deliberately distinct from New Quizzes/LTI and /take.
    assert!(requests[0].url.path().ends_with("/quizzes"));
}

#[tokio::test]
async fn discussions_preserve_unread_threads_but_strip_active_html_and_signed_attachments() {
    let fake = Fake::new(vec![
        response(
            "/api/v1/courses/81001/discussion_topics?per_page=100",
            TOPICS,
        ),
        response("/api/v1/courses/81001/discussion_topics/501", TOPIC),
        response("/api/v1/courses/81001/discussion_topics/501/view", VIEW),
    ]);
    let c = client(fake.clone(), CanvasAccess::HostToken);
    let topics = c.discussion_topics(&source(), "81001").await.unwrap();
    assert_eq!(topics.len(), 1);
    assert_eq!(topics[0].payload.read_state.as_deref(), Some("unread"));
    assert_eq!(
        topics[0].payload.attachments[0].filename.as_deref(),
        Some("reading.pdf")
    );
    no_secrets(&topics);
    let thread = c.discussion_view(&source(), "81001", "501").await.unwrap();
    assert_eq!(
        thread.payload.unread_entries[0].0,
        "9007199254740993123456789"
    );
    assert_eq!(thread.payload.participants[0].id.0, USER);
    assert!(
        thread.payload.view[0].replies[0]
            .message
            .as_ref()
            .unwrap()
            .contains("Second reply")
    );
    no_secrets(&thread);
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(
        requests
            .iter()
            .all(|r| r.method == HttpMethod::Get && r.body.is_none())
    );
    assert!(requests.iter().all(|r| !r.url.path().contains("/read")));
}

#[tokio::test]
async fn initial_post_and_locked_visibility_fail_without_posting_or_fetching_replies() {
    for field in ["user_can_see_posts", "locked_for_user"] {
        let mut topic: Value = serde_json::from_str(TOPIC).unwrap();
        topic[field] = json!(field == "locked_for_user");
        let fake = Fake::new(vec![response(
            "/api/v1/courses/81001/discussion_topics/501",
            &topic.to_string(),
        )]);
        assert_eq!(
            client(fake.clone(), CanvasAccess::HostSession)
                .discussion_view(&source(), "81001", "501")
                .await
                .unwrap_err(),
            ConnectorError::CourseAccessDenied
        );
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
    let mut denied = response(
        "/api/v1/courses/81001/discussion_topics/501/view",
        "require_initial_post",
    );
    denied.status = 403;
    let fake = Fake::new(vec![
        response("/api/v1/courses/81001/discussion_topics/501", TOPIC),
        denied,
    ]);
    assert_eq!(
        client(fake.clone(), CanvasAccess::HostSession)
            .discussion_view(&source(), "81001", "501")
            .await
            .unwrap_err(),
        ConnectorError::PermissionDenied
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn self_submission_checks_identity_and_excludes_private_fields() {
    let path = "/api/v1/courses/81001/assignments/82001/submissions/self?include[]=submission_comments&include[]=visibility";
    let fake = Fake::new(vec![profile(), response(path, SUBMISSION)]);
    let row = client(fake.clone(), CanvasAccess::HostToken)
        .self_submission(&source(), "81001", "82001")
        .await
        .unwrap();
    assert_eq!(row.payload.user_id.0, USER);
    assert_eq!(row.payload.score, Some(8.5));
    assert!(row.payload.html_url.is_none());
    assert_eq!(row.payload.attachments[0].id.as_ref().unwrap().0, "9");
    no_secrets(&row);
    {
        let requests = fake.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[1].url.path().ends_with("/submissions/self"));
        assert!(requests.iter().all(|r| r.method == HttpMethod::Get));
    }
    for (field, value, expected) in [
        ("user_id", json!("99"), ConnectorError::PermissionDenied),
        (
            "assignment_id",
            json!("99"),
            ConnectorError::Parse {
                source_name: "Canvas",
                field: "submission assignment_id",
            },
        ),
        (
            "assignment_visible",
            json!(false),
            ConnectorError::CourseAccessDenied,
        ),
    ] {
        let mut body: Value = serde_json::from_str(SUBMISSION).unwrap();
        body[field] = value;
        let fake = Fake::new(vec![profile(), response(path, &body.to_string())]);
        assert_eq!(
            client(fake, CanvasAccess::HostToken)
                .self_submission(&source(), "81001", "82001")
                .await
                .unwrap_err(),
            expected
        );
    }
}

#[tokio::test]
async fn self_grades_preserve_redacted_values_and_section_identity_without_unposted_data() {
    let fake = Fake::new(vec![profile(), response(&enrollment_path(), ENROLLMENTS)]);
    let rows = client(fake.clone(), CanvasAccess::HostSession)
        .self_grade_summary(&source(), "81001")
        .await
        .unwrap();
    assert_eq!(rows[0].payload.enrollment_id.0, "12");
    assert_eq!(rows[0].payload.user_id.0, USER);
    let grades = rows[0].payload.grades.as_ref().unwrap();
    assert_eq!(grades.current_score, Some(88.0));
    assert_eq!(grades.final_score, None);
    no_secrets(&rows);
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[1]
            .url
            .query_pairs()
            .find(|(k, _)| k == "user_id")
            .unwrap()
            .1,
        USER
    );
}

#[tokio::test]
async fn enrollment_query_cannot_expand_to_roster_on_later_pages_or_redirects() {
    for next in [
        "/api/v1/courses/81001/enrollments?page=2",
        "/api/v1/courses/81001/enrollments?user_id=99&page=2",
        "/api/v1/courses/81001/enrollments?user_id=9007199254740993&user_id=99&page=2",
        "/api/v1/courses/81001/enrollments?user_id=9007199254740993&user_id[]=99&page=2",
        "/api/v1/courses/99999/enrollments?user_id=9007199254740993&page=2",
    ] {
        let mut first = response(&enrollment_path(), ENROLLMENTS);
        first
            .headers
            .push(("Link".into(), format!("<{next}>; rel=\"next\"")));
        let fake = Fake::new(vec![profile(), first]);
        assert_eq!(
            client(fake.clone(), CanvasAccess::HostToken)
                .self_enrollments(&source(), "81001")
                .await
                .unwrap_err(),
            ConnectorError::UnsafeUrl
        );
        assert_eq!(fake.requests.lock().unwrap().len(), 2);
    }
    let fake = Fake::new(vec![
        profile(),
        response("/api/v1/courses/81001/enrollments", ENROLLMENTS),
    ]);
    assert_eq!(
        client(fake, CanvasAccess::HostToken)
            .self_enrollments(&source(), "81001")
            .await
            .unwrap_err(),
        ConnectorError::UnsafeUrl
    );
    let mut other: Value = serde_json::from_str(ENROLLMENTS).unwrap();
    other[0]["user_id"] = json!("99");
    let fake = Fake::new(vec![
        profile(),
        response(&enrollment_path(), &other.to_string()),
    ]);
    assert_eq!(
        client(fake, CanvasAccess::HostToken)
            .self_enrollments(&source(), "81001")
            .await
            .unwrap_err(),
        ConnectorError::PermissionDenied
    );
}

#[tokio::test]
async fn self_enrollment_pages_keep_filter_identity_and_fail_after_partial_data() {
    let mut first = response(&enrollment_path(), ENROLLMENTS);
    let next = format!("/api/v1/courses/81001/enrollments?user_id={USER}&page=2");
    first
        .headers
        .push(("Link".into(), format!("<{next}>; rel=\"next\"")));
    let mut second_body: Value = serde_json::from_str(ENROLLMENTS).unwrap();
    second_body[0]["id"] = json!(13);
    second_body[0]["course_section_id"] = json!(22);
    let second = response(&next, &second_body.to_string());
    let fake = Fake::new(vec![profile(), first.clone(), second.clone()]);
    let rows = client(fake, CanvasAccess::HostToken)
        .self_enrollments(&source(), "81001")
        .await
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1].payload.course_section_id.as_ref().unwrap().0, "22");
    let mut failure = second;
    failure.status = 403;
    let fake = Fake::new(vec![profile(), first, failure]);
    assert_eq!(
        client(fake.clone(), CanvasAccess::HostToken)
            .self_enrollments(&source(), "81001")
            .await
            .unwrap_err(),
        ConnectorError::PermissionDenied
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn quiz_detail_rejects_id_mismatch_and_another_canvas_origin_remains_separate() {
    let quiz: Value = serde_json::from_str::<Value>(QUIZZES).unwrap()[0].clone();
    let fake = Fake::new(vec![response(
        "/api/v1/courses/81001/quizzes/2",
        &quiz.to_string(),
    )]);
    assert!(
        client(fake, CanvasAccess::HostToken)
            .quiz(&source(), "81001", "2")
            .await
            .is_err()
    );
    let mut remote = response("/api/v1/courses/81001/quizzes?per_page=100", QUIZZES);
    remote.final_url = Url::parse(
        "https://canvas-another.example.invalid/api/v1/courses/81001/quizzes?per_page=100",
    )
    .unwrap();
    let fake = Fake::new(vec![remote]);
    let c = CanvasClient::new(
        fake.clone(),
        "https://canvas-another.example.invalid",
        CanvasAccess::HostToken,
    )
    .unwrap();
    let mut other_source = source();
    other_source.source_id = "canvas-another".into();
    let rows = c.quizzes(&other_source, "81001").await.unwrap();
    assert_eq!(rows[0].source_id, "canvas-another");
    assert!(rows[0].payload.html_url.is_none());
    assert_eq!(
        fake.requests.lock().unwrap()[0].url.host_str(),
        Some("canvas-another.example.invalid")
    );
}

#[tokio::test]
async fn assignment_groups_map_weights_and_rules_without_embedded_submissions() {
    let fake = Fake::new(vec![response(
        "/api/v1/courses/81001/assignment_groups?per_page=100",
        GROUPS,
    )]);
    let groups = client(fake, CanvasAccess::HostToken)
        .assignment_groups(&source(), "81001")
        .await
        .unwrap();
    assert_eq!(groups[0].payload.group_weight, Some(25.0));
    assert_eq!(
        groups[0].payload.rules.as_ref().unwrap().never_drop[0].0,
        "9007199254740993123456789"
    );
    no_secrets(&groups);
}

#[tokio::test]
async fn pagination_success_and_later_failure_never_return_partial_learning_snapshots() {
    let mut first = response("/api/v1/courses/81001/quizzes?per_page=100", QUIZZES);
    first.headers.push((
        "Link".into(),
        "</api/v1/courses/81001/quizzes?cursor=opaque>; rel=\"next\"".into(),
    ));
    let second = response(
        "/api/v1/courses/81001/quizzes?cursor=opaque",
        r#"[{"id":2,"title":"Quiz two"}]"#,
    );
    let fake = Fake::new(vec![first.clone(), second.clone()]);
    let rows = client(fake, CanvasAccess::HostToken)
        .quizzes(&source(), "81001")
        .await
        .unwrap();
    assert_eq!(rows.len(), 2);
    for status in [401, 403, 500] {
        let mut error = second.clone();
        error.status = status;
        let fake = Fake::new(vec![first.clone(), error]);
        assert!(
            client(fake.clone(), CanvasAccess::BrowserSession)
                .quizzes(&source(), "81001")
                .await
                .is_err()
        );
        assert_eq!(fake.requests.lock().unwrap().len(), 2);
    }
}

#[tokio::test]
async fn login_shell_and_permission_failures_keep_explicit_auth_mode_and_do_not_retry() {
    for (access, mode) in [
        (CanvasAccess::HostToken, AuthMode::Token),
        (CanvasAccess::HostSession, AuthMode::HttpSession),
        (CanvasAccess::BrowserSession, AuthMode::BrowserSession),
    ] {
        let shell = response(
            "/api/v1/courses/81001/quizzes?per_page=100",
            "<html><form><input name=\"password\">login</form></html>",
        );
        let fake = Fake::new(vec![shell]);
        let error = client(fake.clone(), access)
            .quizzes(&source(), "81001")
            .await
            .unwrap_err();
        assert!(matches!(error,ConnectorError::AuthRequired(challenge) if challenge.mode==mode));
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
    let fake = Fake::new(vec![response(
        "/api/v1/courses/81001/quizzes?per_page=100",
        r#"[{"id":1,"title":"Forbidden","permissions":{"read":false}}]"#,
    )]);
    assert_eq!(
        client(fake, CanvasAccess::HostToken)
            .quizzes(&source(), "81001")
            .await
            .unwrap_err(),
        ConnectorError::PermissionDenied
    );
}

#[tokio::test]
async fn resource_paths_course_mismatches_cross_origins_and_source_labels_are_checked() {
    let fake = Fake::default();
    let c = client(fake.clone(), CanvasAccess::HostToken);
    for id in ["../admin", "81001/quizzes", "", "123%2f456"] {
        assert!(c.quizzes(&source(), id).await.is_err());
        assert!(c.quiz(&source(), "81001", id).await.is_err());
        assert!(c.self_submission(&source(), "81001", id).await.is_err());
        assert!(c.self_enrollments(&source(), id).await.is_err());
    }
    assert!(fake.requests.lock().unwrap().is_empty());
    let mut other: Value = serde_json::from_str(QUIZZES).unwrap();
    other[0]["course_id"] = json!("99");
    let fake = Fake::new(vec![response(
        "/api/v1/courses/81001/quizzes?per_page=100",
        &other.to_string(),
    )]);
    assert!(
        client(fake, CanvasAccess::HostToken)
            .quizzes(&source(), "81001")
            .await
            .is_err()
    );
    let mut cross = response("/api/v1/courses/81001/quizzes?per_page=100", QUIZZES);
    cross.headers.push((
        "Link".into(),
        "<https://another.example.invalid/api/v1/courses/81001/quizzes?page=2>; rel=\"next\""
            .into(),
    ));
    let fake = Fake::new(vec![cross]);
    assert!(
        client(fake.clone(), CanvasAccess::HostToken)
            .quizzes(&source(), "81001")
            .await
            .is_err()
    );
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
    // The same remote decimal IDs remain distinct host sources/accounts; there is no fixed Fudan origin.
    let mut second_source = source();
    second_source.source_id = "canvas-other-campus".into();
    second_source.account_id = "other-fixture".into();
    let fake = Fake::new(vec![response(
        "/api/v1/courses/81001/quizzes?per_page=100",
        QUIZZES,
    )]);
    let rows = client(fake, CanvasAccess::HostToken)
        .quizzes(&second_source, "81001")
        .await
        .unwrap();
    assert_eq!(rows[0].source_id, "canvas-other-campus");
    assert_eq!(rows[0].account_id, "other-fixture");
}

#[tokio::test]
async fn empty_results_are_successful_but_invalid_views_duplicates_and_limits_fail_closed() {
    let fake = Fake::new(vec![
        response("/api/v1/courses/81001/quizzes?per_page=100", "[]"),
        response("/api/v1/courses/81001/discussion_topics?per_page=100", "[]"),
        response("/api/v1/courses/81001/assignment_groups?per_page=100", "[]"),
        profile(),
        response(&enrollment_path(), "[]"),
    ]);
    let c = client(fake, CanvasAccess::HostToken);
    assert!(c.quizzes(&source(), "81001").await.unwrap().is_empty());
    assert!(
        c.discussion_topics(&source(), "81001")
            .await
            .unwrap()
            .is_empty()
    );
    assert!(
        c.assignment_groups(&source(), "81001")
            .await
            .unwrap()
            .is_empty()
    );
    assert!(
        c.self_grade_summary(&source(), "81001")
            .await
            .unwrap()
            .is_empty()
    );
    for body in [
        r#"{"error":"not a view"}"#,
        r#"{"view":[{"id":1,"message":"a"},{"id":1,"message":"b"}]}"#,
    ] {
        let fake = Fake::new(vec![
            response("/api/v1/courses/81001/discussion_topics/501", TOPIC),
            response("/api/v1/courses/81001/discussion_topics/501/view", body),
        ]);
        assert!(
            client(fake, CanvasAccess::HostToken)
                .discussion_view(&source(), "81001", "501")
                .await
                .is_err()
        );
    }
    let fake = Fake::new(vec![response(
        "/api/v1/courses/81001/quizzes?per_page=100",
        QUIZZES,
    )]);
    assert_eq!(
        client(fake, CanvasAccess::HostToken)
            .with_limits(CanvasLimits {
                max_body_bytes: 8,
                ..Default::default()
            })
            .unwrap()
            .quizzes(&source(), "81001")
            .await
            .unwrap_err(),
        ConnectorError::LimitExceeded
    );
    let fake = Fake::new(vec![
        response("/api/v1/courses/81001/discussion_topics/501", TOPIC),
        response("/api/v1/courses/81001/discussion_topics/501/view", VIEW),
    ]);
    assert_eq!(
        client(fake, CanvasAccess::HostToken)
            .with_limits(CanvasLimits {
                max_items: 1,
                ..Default::default()
            })
            .unwrap()
            .discussion_view(&source(), "81001", "501")
            .await
            .unwrap_err(),
        ConnectorError::LimitExceeded
    );
}
