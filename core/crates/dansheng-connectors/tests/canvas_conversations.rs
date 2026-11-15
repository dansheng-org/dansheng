// SPDX-License-Identifier: GPL-3.0-or-later
//! Synthetic fixtures only. No credentials, browser profiles or external I/O.
use async_trait::async_trait;
use chrono::Utc;
use dansheng_connectors::{canvas::*, models::SourceContext, *};
use serde_json::json;
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
use url::Url;

const ORIGIN: &str = "https://canvas.invalid";
const BIG: &str = "9007199254740993";
const PRIVATE: &str = "SYNTHETIC_PRIVATE_TEXT";

#[derive(Clone, Default)]
struct Fake {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    responses: Arc<Mutex<VecDeque<Result<ConnectorResponse, ConnectorError>>>>,
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
            .expect("unexpected I/O")
    }
}
fn transport(responses: Vec<Result<ConnectorResponse, ConnectorError>>) -> Fake {
    Fake {
        responses: Arc::new(Mutex::new(responses.into())),
        ..Default::default()
    }
}
fn source() -> SourceContext {
    SourceContext {
        account_id: "fixture".into(),
        source_id: "fixture-conversations".into(),
        observed_at: Utc::now(),
    }
}
fn response(path: &str, body: &str) -> ConnectorResponse {
    ConnectorResponse {
        status: 200,
        final_url: Url::parse(&format!("{ORIGIN}{path}")).unwrap(),
        headers: vec![],
        body: body.as_bytes().to_vec(),
    }
}
fn row() -> String {
    // Numeric IDs above JS safe integer; IDs larger than u64 arrive as strings.
    format!(
        r#"{{"id":{BIG},"subject":"{PRIVATE}","last_message":"{PRIVATE}",
        "avatar_url":"https://secret.invalid/?token=STRIP_ME","uuid":"STRIP_ME",
        "participants":[{{"id":18446744073709551615,"name":"{PRIVATE}","avatar_url":"STRIP_ME"}}],
        "audience":["9007199254740993123456789"],"messages":[{{"id":{BIG},"author_id":18446744073709551615,"body":"{PRIVATE}",
        "attachments":[{{"id":{BIG},"display_name":"file.txt","url":"STRIP_ME","uuid":"STRIP_ME"}}],
        "forwarded_messages":[{{"id":"9007199254740993123456789","body":"forwarded","media_comment":{{"url":"STRIP_ME"}}}}]}}]}}"#
    )
}
fn client(fake: Fake) -> CanvasClient<Fake> {
    CanvasClient::new(fake, ORIGIN, CanvasAccess::HostToken).unwrap()
}

#[tokio::test]
async fn filtered_pagination_preserves_ids_and_private_data_has_redacted_debug() {
    let path = "/api/v1/conversations?per_page=100&filter%5B%5D=course_42";
    let mut first = response(path, &format!("[{}]", row()));
    first.headers.push((
        "Link".into(),
        "</api/v1/conversations?filter%5B%5D=course_42&cursor=opaque>; rel=\"next\"".into(),
    ));
    let fake = transport(vec![
        Ok(first),
        Ok(response(
            "/api/v1/conversations?filter%5B%5D=course_42&cursor=opaque",
            "[{\"id\":\"7\"}]",
        )),
    ]);
    let rows = client(fake.clone())
        .conversations(&source(), Some("42"))
        .await
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].payload.id.0, BIG);
    assert_eq!(rows[0].payload.participants[0].id.0, "18446744073709551615");
    assert_eq!(rows[0].payload.audience[0].0, "9007199254740993123456789");
    assert!(!serde_json::to_string(&rows).unwrap().contains("STRIP_ME"));
    assert!(!format!("{rows:?}").contains(PRIVATE));
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, HttpMethod::Get);
    assert!(
        requests[0]
            .url
            .query_pairs()
            .any(|(k, v)| k == "filter[]" && v == "course_42")
    );
}

#[tokio::test]
async fn all_inbox_and_detail_are_read_only() {
    let fake = transport(vec![
        Ok(response("/api/v1/conversations?per_page=100", "[]")),
        Ok(response(
            &format!("/api/v1/conversations/{BIG}?auto_mark_as_read=false"),
            &row(),
        )),
    ]);
    let client = client(fake.clone());
    assert!(
        client
            .conversations(&source(), None)
            .await
            .unwrap()
            .is_empty()
    );
    let result = client.conversation(&source(), BIG).await.unwrap();
    assert_eq!(
        result.payload.messages[0].author_id.as_ref().unwrap().0,
        "18446744073709551615"
    );
    let requests = fake.requests.lock().unwrap();
    assert!(
        requests[1]
            .url
            .query_pairs()
            .any(|(k, v)| k == "auto_mark_as_read" && v == "false")
    );
    assert!(
        requests
            .iter()
            .all(|r| r.method == HttpMethod::Get && r.body.is_none())
    );
}

#[tokio::test]
async fn search_is_paginated_user_only_and_query_encoded() {
    let query = "A & B/课程";
    let mut url = Url::parse(&format!("{ORIGIN}/api/v1/search/recipients?per_page=100")).unwrap();
    url.query_pairs_mut()
        .append_pair("context", "course_42")
        .append_pair("type", "user")
        .append_pair("search", query);
    let mut first = response(
        "/api/v1/search/recipients",
        "[{\"id\":9007199254740993,\"common_courses\":{\"42\":[\"StudentEnrollment\"]},\"avatar_url\":\"STRIP_ME\"}]",
    );
    first.final_url = url.clone();
    url.query_pairs_mut().append_pair("cursor", "opaque");
    first
        .headers
        .push(("Link".into(), format!("<{url}>; rel=next")));
    let mut second = response("/api/v1/search/recipients", "[]");
    second.final_url = url;
    let fake = transport(vec![Ok(first), Ok(second)]);
    let rows = client(fake.clone())
        .recipients(&source(), "42", query)
        .await
        .unwrap();
    assert_eq!(rows[0].payload.id.0, BIG);
    assert!(!serde_json::to_string(&rows).unwrap().contains("STRIP_ME"));
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert!(
        requests[0]
            .url
            .query_pairs()
            .any(|(k, v)| k == "search" && v == query)
    );
    assert!(
        requests[0]
            .url
            .query_pairs()
            .any(|(k, v)| k == "type" && v == "user")
    );
}

#[tokio::test]
async fn unsafe_or_widened_pagination_never_dispatches_next_page() {
    for target in [
        "https://evil.invalid/api/v1/conversations",
        "/api/v1/conversations?cursor=2",
        "/api/v1/conversations?filter[]=course_43",
        "/api/v1/conversations?filter[]=course_42&access_token=STRIP_ME",
        "/api/v1/users?filter[]=course_42",
    ] {
        let mut first = response("/api/v1/conversations?filter[]=course_42", "[]");
        first
            .headers
            .push(("Link".into(), format!("<{target}>; rel=next")));
        let fake = transport(vec![Ok(first)]);
        assert!(
            client(fake.clone())
                .conversations(&source(), Some("42"))
                .await
                .is_err()
        );
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn pagination_failures_and_limits_never_return_partial_results() {
    let mut first = response(
        "/api/v1/conversations?per_page=100",
        &format!("[{}]", row()),
    );
    first.headers.push((
        "Link".into(),
        "</api/v1/conversations?cursor=next>; rel=next".into(),
    ));
    let fake = transport(vec![Ok(first.clone()), Err(ConnectorError::Timeout)]);
    assert_eq!(
        client(fake)
            .conversations(&source(), None)
            .await
            .unwrap_err(),
        ConnectorError::Timeout
    );
    let fake = transport(vec![Ok(first)]);
    let result = client(fake.clone())
        .with_limits(CanvasLimits {
            max_pages: 1,
            ..Default::default()
        })
        .unwrap()
        .conversations(&source(), None)
        .await;
    assert_eq!(result.unwrap_err(), ConnectorError::LimitExceeded);
    assert_eq!(fake.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn reply_and_create_are_one_post_with_exact_form_contract() {
    let fake = transport(vec![
        Ok(response(
            &format!("/api/v1/conversations/{BIG}/add_message"),
            &row(),
        )),
        Ok(response("/api/v1/conversations", &format!("[{}]", row()))),
    ]);
    let client = client(fake.clone());
    let body = "内容 & + =\nsecond line";
    assert_eq!(
        client
            .reply_conversation(&source(), BIG, body)
            .await
            .unwrap()
            .payload
            .id
            .0,
        BIG
    );
    let created = client
        .create_conversation(
            &source(),
            "42",
            &[CanvasId(BIG.into()), CanvasId("7".into())],
            "subject",
            body,
        )
        .await
        .unwrap();
    assert_eq!(created.len(), 1);
    let requests = fake.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert!(
        requests
            .iter()
            .all(|r| r.method == HttpMethod::Post
                && matches!(r.auth, TransportAuth::HostToken { .. }))
    );
    let form = |i: usize| {
        url::form_urlencoded::parse(requests[i].body.as_ref().unwrap())
            .into_owned()
            .collect::<Vec<_>>()
    };
    assert_eq!(form(0), vec![("body".into(), body.into())]);
    let form = form(1);
    for pair in [
        ("context_code", "course_42"),
        ("group_conversation", "true"),
        ("force_new", "true"),
        ("recipients[]", BIG),
        ("recipients[]", "7"),
        ("body", body),
    ] {
        assert!(form.contains(&(pair.0.into(), pair.1.into())));
    }
    assert!(!requests[1].url.as_str().contains("subject"));
    assert!(!format!("{:?}", requests[1]).contains(body));
}

#[tokio::test]
async fn unknown_writes_are_never_retried_or_echoed() {
    for failure in [
        Err(ConnectorError::Timeout),
        Err(ConnectorError::TransportUnavailable),
        Err(ConnectorError::PermissionDenied),
        Ok(response(
            &format!("/api/v1/conversations/{BIG}/add_message"),
            PRIVATE,
        )),
        Ok(response("/api/v1/conversations/7/add_message", &row())),
    ] {
        let fake = transport(vec![failure]);
        let err = client(fake.clone())
            .reply_conversation(&source(), BIG, PRIVATE)
            .await
            .unwrap_err();
        assert!(matches!(err, CanvasWriteError::NeedsReconciliation));
        assert!(!format!("{err:?} {err}").contains(PRIVATE));
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
    for status in [202, 204, 302, 408, 500, 503] {
        let mut reply = response(&format!("/api/v1/conversations/{BIG}/add_message"), "{}");
        reply.status = status;
        let fake = transport(vec![Ok(reply)]);
        assert!(matches!(
            client(fake.clone())
                .reply_conversation(&source(), BIG, PRIVATE)
                .await
                .unwrap_err(),
            CanvasWriteError::NeedsReconciliation
        ));
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn definite_client_rejections_and_invalid_inputs_are_not_uncertain() {
    for status in [400, 401, 403, 404, 422, 429] {
        let mut reply = response(&format!("/api/v1/conversations/{BIG}/add_message"), PRIVATE);
        reply.status = status;
        let fake = transport(vec![Ok(reply)]);
        assert!(matches!(
            client(fake.clone())
                .reply_conversation(&source(), BIG, PRIVATE)
                .await
                .unwrap_err(),
            CanvasWriteError::Rejected(_)
        ));
        assert_eq!(fake.requests.lock().unwrap().len(), 1);
    }
    let fake = Fake::default();
    let client = client(fake.clone());
    assert!(
        client
            .reply_conversation(&source(), "../7", "test")
            .await
            .is_err()
    );
    assert!(
        client
            .reply_conversation(&source(), BIG, " \n ")
            .await
            .is_err()
    );
    assert!(
        client
            .create_conversation(&source(), "42", &[], "subject", "body")
            .await
            .is_err()
    );
    assert!(
        client
            .create_conversation(
                &source(),
                "42",
                &[CanvasId("course_42".into())],
                "subject",
                "body"
            )
            .await
            .is_err()
    );
    assert!(
        client
            .create_conversation(
                &source(),
                "42",
                &[CanvasId("7".into()), CanvasId("7".into())],
                "subject",
                "body"
            )
            .await
            .is_err()
    );
    for access in [CanvasAccess::BrowserSession, CanvasAccess::HostSession] {
        let client = CanvasClient::new(fake.clone(), ORIGIN, access).unwrap();
        assert!(matches!(
            client
                .reply_conversation(&source(), BIG, "body")
                .await
                .unwrap_err(),
            CanvasWriteError::Rejected(ConnectorError::CapabilityUnavailable)
        ));
    }
    assert!(fake.requests.lock().unwrap().is_empty());
}

#[test]
fn id_parser_rejects_rounded_numbers_and_preserves_decimal_strings() {
    assert!(serde_json::from_value::<CanvasId>(json!(9007199254740992.0)).is_err());
    assert_eq!(
        serde_json::from_value::<CanvasId>(json!(BIG)).unwrap().0,
        BIG
    );
}
