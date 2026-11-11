// SPDX-License-Identifier: GPL-3.0-or-later
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth, campus, models,
};

use async_trait::async_trait;
use campus::{CampusError, Coverage};
use chrono::{TimeZone, Utc};
use dansheng_connectors::ehall::{
    APPLICATION_PATH, CATALOG_PATH, EHALL_ORIGIN, EhallAccessHint, EhallApplicationStatus,
    EhallClient, EhallPage, EhallReadBudget, EhallReadFailure, EhallReadStop, EhallTaskKind,
    MAX_RESPONSE_BYTES, TASK_PATH,
};
use models::SourceContext;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use url::Url;

const CATALOG: &[u8] = include_bytes!("../fixtures/ehall/catalog.json");
const TODO1: &[u8] = include_bytes!("../fixtures/ehall/todo-page1.json");
const TODO2: &[u8] = include_bytes!("../fixtures/ehall/todo-page2.json");
const APPLICATIONS: &[u8] = include_bytes!("../fixtures/ehall/applications.json");

fn source() -> SourceContext {
    SourceContext {
        account_id: "synthetic-account".into(),
        source_id: "official.fudan.ehall".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 9, 8, 0, 0).unwrap(),
    }
}

fn page() -> EhallPage {
    EhallPage {
        page: 1,
        page_size: 2,
    }
}

fn response(path: &str, body: &[u8]) -> Result<ConnectorResponse, ConnectorError> {
    Ok(ConnectorResponse {
        status: 200,
        final_url: Url::parse(&format!("{EHALL_ORIGIN}{path}")).unwrap(),
        headers: vec![("Content-Type".into(), "application/json".into())],
        body: body.into(),
    })
}

#[derive(Clone, Default)]
struct MockTransport {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    responses: Arc<Mutex<VecDeque<Result<ConnectorResponse, ConnectorError>>>>,
}

impl MockTransport {
    fn new(replies: impl IntoIterator<Item = Result<ConnectorResponse, ConnectorError>>) -> Self {
        Self {
            requests: Arc::default(),
            responses: Arc::new(Mutex::new(replies.into_iter().collect())),
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
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("offline response expected")
    }
}

#[tokio::test]
async fn catalog_ignored_limit_and_zero_total_remain_anonymous_bounded_window() {
    let transport = MockTransport::new([response(CATALOG_PATH, CATALOG)]);
    let batch = EhallClient::new(transport.clone())
        .catalog(&source(), 2)
        .await
        .unwrap();
    assert_eq!(batch.records.len(), 2);
    assert!(matches!(batch.coverage, Coverage::Window { .. }));
    assert_eq!(
        batch.records[0].payload.description.as_deref(),
        Some("公共目录样例")
    );
    assert_eq!(
        batch.records[0].payload.access_hint,
        EhallAccessHint::Advertised
    );
    assert_eq!(
        batch.records[1].payload.access_hint,
        EhallAccessHint::Restricted
    );
    let request = &transport.requests.lock().unwrap()[0];
    assert_eq!(request.auth, TransportAuth::Anonymous);
    assert_eq!(request.method, HttpMethod::Get);
    assert_eq!(request.url.path(), CATALOG_PATH);
    assert_eq!(
        request.url.query_pairs().collect::<Vec<_>>(),
        vec![("type".into(), "all".into()), ("limit".into(), "2".into())]
    );
    assert!(request.body.is_none());
    assert!(
        !serde_json::to_string(&batch)
            .unwrap()
            .contains("SYNTHETIC-CONTACT")
    );
}

#[tokio::test]
async fn catalog_links_reject_foreign_signed_and_credential_bearing_urls() {
    let transport = MockTransport::new([response(CATALOG_PATH, CATALOG)]);
    let batch = EhallClient::new(transport)
        .catalog(&source(), 3)
        .await
        .unwrap();
    assert!(batch.records[1].payload.pc_url.is_none());
    assert!(batch.records[1].payload.mobile_url.is_none());
    assert!(batch.records[2].payload.pc_url.is_none());
    assert_eq!(
        batch.records[2].payload.mobile_url.as_deref(),
        Some("https://booking.fudan.edu.cn/reservation/fe/site/special/special?id=48")
    );
    let encoded = serde_json::to_string(&batch).unwrap();
    assert!(!encoded.contains("SYNTHETIC-SIGNATURE"));
    assert!(!encoded.contains("SYNTHETIC-PASSWORD"));
    assert!(!format!("{batch:?}").contains("SYNTHETIC-SIGNATURE"));
}

#[tokio::test]
async fn todo_get_uses_account_session_and_discards_private_urls_and_person_fields() {
    let transport = MockTransport::new([response(TASK_PATH, TODO1)]);
    let batch = EhallClient::new(transport.clone())
        .tasks(&source(), EhallTaskKind::Todo, page())
        .await
        .unwrap();
    assert_eq!(batch.source, source());
    assert_eq!(batch.records[0].account_id, source().account_id);
    assert_eq!(batch.records[0].source_id, source().source_id);
    assert_eq!(
        batch.records[0].payload.current_step.as_deref(),
        Some("合成节点")
    );
    assert!(batch.records[0].payload.application_status.is_none());
    assert_eq!(
        batch.coverage,
        Coverage::Page {
            next: Some(2),
            total: Some(3)
        }
    );
    let wire = &transport.requests.lock().unwrap()[0];
    assert_eq!(wire.method, HttpMethod::Get);
    assert_eq!(
        wire.auth,
        TransportAuth::HostSession {
            account_id: source().account_id
        }
    );
    assert!(wire.body.is_none());
    assert_eq!(wire.url.query(), Some("type=todo&page=1&pageSize=2"));
    let encoded = serde_json::to_string(&batch).unwrap();
    assert!(!encoded.contains("form_url"));
    assert!(!encoded.contains("process_pic"));
    assert!(!encoded.contains("SYNTHETIC-SIGNATURE"));
    assert!(!encoded.contains("SYNTHETIC-PERSON"));
    assert!(!format!("{batch:?}").contains("https://"));
}

#[tokio::test]
async fn done_queue_retains_finished_time_without_claiming_application_completed() {
    let body = json!({"e":0,"d":{"total":1,"list":[{"id":"done-1","task_name":"合成已办","task_created":"2026-11-08 08:00:00","task_finished":"2026-11-09 09:00:00"}]}});
    let transport = MockTransport::new([response(TASK_PATH, &serde_json::to_vec(&body).unwrap())]);
    let batch = EhallClient::new(transport.clone())
        .tasks(&source(), EhallTaskKind::Done, page())
        .await
        .unwrap();
    let record = &batch.records[0].payload;
    assert_eq!(record.kind, EhallTaskKind::Done);
    assert_eq!(record.finished_at.as_deref(), Some("2026-11-09 09:00:00"));
    assert!(record.application_status.is_none());
    assert_eq!(
        transport.requests.lock().unwrap()[0].url.query(),
        Some("type=done&page=1&pageSize=2")
    );
}

#[tokio::test]
async fn applications_use_separate_get_and_preserve_unknown_status() {
    let transport = MockTransport::new([response(APPLICATION_PATH, APPLICATIONS)]);
    let batch = EhallClient::new(transport.clone())
        .tasks(&source(), EhallTaskKind::Application, page())
        .await
        .unwrap();
    assert_eq!(
        batch.records[0].payload.application_status,
        Some(EhallApplicationStatus::InProgress)
    );
    assert_eq!(
        batch.records[1].payload.application_status,
        Some(EhallApplicationStatus::Unknown {
            code: Some("awaiting_review_v2".into())
        })
    );
    assert_eq!(
        transport.requests.lock().unwrap()[0].url.path(),
        APPLICATION_PATH
    );
    assert_eq!(
        transport.requests.lock().unwrap()[0].url.query(),
        Some("type=all&page=1&pageSize=2")
    );
    assert!(
        !serde_json::to_string(&batch)
            .unwrap()
            .contains("SYNTHETIC-APPLICANT")
    );
}

#[tokio::test]
async fn internal_references_are_scoped_by_account_source_and_queue() {
    let transport = MockTransport::new([
        response(TASK_PATH, TODO1),
        response(TASK_PATH, TODO1),
        response(TASK_PATH, TODO1),
        response(TASK_PATH, TODO1),
    ]);
    let client = EhallClient::new(transport);
    let a = client
        .tasks(&source(), EhallTaskKind::Todo, page())
        .await
        .unwrap();
    let mut other = source();
    other.account_id = "another-synthetic-account".into();
    let b = client
        .tasks(&other, EhallTaskKind::Todo, page())
        .await
        .unwrap();
    other = source();
    other.source_id = "another-source".into();
    let c = client
        .tasks(&other, EhallTaskKind::Todo, page())
        .await
        .unwrap();
    let d = client
        .tasks(&source(), EhallTaskKind::Done, page())
        .await
        .unwrap();
    let refs = [
        a.records[0].payload.internal_ref.clone(),
        b.records[0].payload.internal_ref.clone(),
        c.records[0].payload.internal_ref.clone(),
        d.records[0].payload.internal_ref.clone(),
    ];
    assert_eq!(
        refs.iter().collect::<std::collections::HashSet<_>>().len(),
        4
    );
}

#[tokio::test]
async fn consistent_two_page_collection_can_report_complete() {
    let transport = MockTransport::new([response(TASK_PATH, TODO1), response(TASK_PATH, TODO2)]);
    let collection = EhallClient::new(transport.clone())
        .collect_tasks(
            &source(),
            EhallTaskKind::Todo,
            2,
            EhallReadBudget::default(),
        )
        .await
        .unwrap();
    assert!(collection.complete);
    assert_eq!(collection.batch.coverage, Coverage::Complete);
    assert_eq!(collection.batch.records.len(), 3);
    assert_eq!(collection.pages_read, 2);
    assert_eq!(collection.bytes_read, TODO1.len() + TODO2.len());
    assert_eq!(collection.stop, EhallReadStop::EndOfReportedList);
    assert!(collection.next_page.is_none());
    assert_eq!(transport.requests.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn second_page_timeout_preserves_partial_records_and_never_reports_complete() {
    let transport = MockTransport::new([response(TASK_PATH, TODO1), Err(ConnectorError::Timeout)]);
    let collection = EhallClient::new(transport)
        .collect_tasks(
            &source(),
            EhallTaskKind::Todo,
            2,
            EhallReadBudget::default(),
        )
        .await
        .unwrap();
    assert!(!collection.complete);
    assert_eq!(collection.batch.records.len(), 2);
    assert_eq!(collection.pages_read, 1);
    assert!(matches!(collection.batch.coverage, Coverage::Window { .. }));
    assert_eq!(collection.next_page, Some(2));
    assert_eq!(
        collection.stop,
        EhallReadStop::Interrupted {
            failure: EhallReadFailure::Timeout
        }
    );
}

#[tokio::test]
async fn duplicate_page_is_rejected_without_appending_or_deletion_claims() {
    let transport = MockTransport::new([response(TASK_PATH, TODO1), response(TASK_PATH, TODO1)]);
    let collection = EhallClient::new(transport)
        .collect_tasks(
            &source(),
            EhallTaskKind::Todo,
            2,
            EhallReadBudget::default(),
        )
        .await
        .unwrap();
    assert!(!collection.complete);
    assert_eq!(collection.batch.records.len(), 2);
    assert_eq!(collection.stop, EhallReadStop::DuplicateId);
    assert_eq!(collection.next_page, Some(2));
}

#[tokio::test]
async fn changing_total_stops_before_adding_unstable_page() {
    let mut value: Value = serde_json::from_slice(TODO2).unwrap();
    value["d"]["total"] = json!(4);
    let transport = MockTransport::new([
        response(TASK_PATH, TODO1),
        response(TASK_PATH, &serde_json::to_vec(&value).unwrap()),
    ]);
    let collection = EhallClient::new(transport)
        .collect_tasks(
            &source(),
            EhallTaskKind::Todo,
            2,
            EhallReadBudget::default(),
        )
        .await
        .unwrap();
    assert!(!collection.complete);
    assert_eq!(collection.batch.records.len(), 2);
    assert_eq!(collection.stop, EhallReadStop::InconsistentPagination);
}

#[tokio::test]
async fn page_and_item_budgets_stop_before_an_extra_request() {
    for budget in [
        EhallReadBudget {
            max_pages: 1,
            ..EhallReadBudget::default()
        },
        EhallReadBudget {
            max_items: 3,
            ..EhallReadBudget::default()
        },
    ] {
        let transport = MockTransport::new([response(TASK_PATH, TODO1)]);
        let collection = EhallClient::new(transport.clone())
            .collect_tasks(&source(), EhallTaskKind::Todo, 2, budget)
            .await
            .unwrap();
        assert!(!collection.complete);
        assert_eq!(collection.batch.records.len(), 2);
        assert_eq!(collection.stop, EhallReadStop::Budget);
        assert_eq!(transport.requests.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn cumulative_byte_budget_preserves_prior_page_on_oversized_next_response() {
    let transport = MockTransport::new([response(TASK_PATH, TODO1), response(TASK_PATH, TODO2)]);
    let budget = EhallReadBudget {
        max_bytes: TODO1.len() + TODO2.len() - 1,
        ..EhallReadBudget::default()
    };
    let collection = EhallClient::new(transport)
        .collect_tasks(&source(), EhallTaskKind::Todo, 2, budget)
        .await
        .unwrap();
    assert!(!collection.complete);
    assert_eq!(collection.batch.records.len(), 2);
    assert_eq!(
        collection.stop,
        EhallReadStop::Interrupted {
            failure: EhallReadFailure::Limit
        }
    );
}

#[tokio::test]
async fn login_redirect_html_and_nonzero_envelope_are_never_empty_successes() {
    let mut redirect = response(TASK_PATH, b"").unwrap();
    redirect.status = 302;
    redirect.headers = vec![(
        "Location".into(),
        "https://id.fudan.edu.cn/login?token=SYNTHETIC-SECRET".into(),
    )];
    for reply in [Ok(redirect), response(TASK_PATH, b"<html><form><input type=password>login</form></html>"), response(TASK_PATH, br#"{"e":401,"m":"https://secret.example.invalid?token=SYNTHETIC-SECRET","d":{"list":[]}}"#)] {
        let transport = MockTransport::new([reply]);
        let error = EhallClient::new(transport).tasks(&source(), EhallTaskKind::Todo, page()).await.unwrap_err();
        assert!(matches!(error, CampusError::Transport(ConnectorError::AuthRequired(_))));
        assert!(!format!("{error:?}").contains("SYNTHETIC-SECRET"));
    }
    let transport = MockTransport::new([response(
        TASK_PATH,
        br#"{"e":9,"m":"SYNTHETIC-SECRET","d":{"list":[]}}"#,
    )]);
    let error = EhallClient::new(transport)
        .tasks(&source(), EhallTaskKind::Todo, page())
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        CampusError::SchemaChanged {
            field: "envelope.e",
            ..
        }
    ));
    assert!(!format!("{error:?}").contains("SYNTHETIC-SECRET"));
}

#[tokio::test]
async fn cross_origin_response_is_rejected_and_never_followed_by_connector() {
    let mut reply = response(TASK_PATH, TODO1).unwrap();
    reply.final_url =
        Url::parse("https://foreign.example.invalid/?token=SYNTHETIC-SECRET").unwrap();
    let transport = MockTransport::new([Ok(reply)]);
    let error = EhallClient::new(transport.clone())
        .tasks(&source(), EhallTaskKind::Todo, page())
        .await
        .unwrap_err();
    assert_eq!(error, CampusError::Transport(ConnectorError::UnsafeUrl));
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn malformed_missing_ids_duplicates_and_ignored_personal_page_size_fail_closed() {
    for body in [
        json!({"e":0,"d":{"list":[{"task_name":"no id"}],"total":1}}),
        json!({"e":0,"d":{"list":[{"id":"x","task_name":"one"},{"id":"x","task_name":"two"}],"total":2}}),
        json!({"e":0,"d":{"list":[{"id":"x","task_name":"one"},{"id":"y","task_name":"two"},{"id":"z","task_name":"three"}],"total":3}}),
        json!({"e":0,"d":{"list":"not an array"}}),
    ] {
        let transport =
            MockTransport::new([response(TASK_PATH, &serde_json::to_vec(&body).unwrap())]);
        assert!(
            EhallClient::new(transport)
                .tasks(&source(), EhallTaskKind::Todo, page())
                .await
                .is_err()
        );
    }
    let transport = MockTransport::new([response(TASK_PATH, &vec![b' '; MAX_RESPONSE_BYTES + 1])]);
    assert_eq!(
        EhallClient::new(transport)
            .tasks(&source(), EhallTaskKind::Todo, page())
            .await
            .unwrap_err(),
        CampusError::Transport(ConnectorError::LimitExceeded)
    );
}

#[tokio::test]
async fn zero_or_unknown_total_nonempty_rows_do_not_become_full_snapshots() {
    for reported in [json!(0), Value::Null] {
        let body = json!({"e":0,"d":{"total":reported,"list":[{"id":"synthetic-1","task_name":"合成任务"}]}});
        let transport =
            MockTransport::new([response(TASK_PATH, &serde_json::to_vec(&body).unwrap())]);
        let collection = EhallClient::new(transport)
            .collect_tasks(
                &source(),
                EhallTaskKind::Todo,
                2,
                EhallReadBudget::default(),
            )
            .await
            .unwrap();
        assert!(!collection.complete);
        assert_eq!(collection.batch.records.len(), 1);
        assert_eq!(collection.stop, EhallReadStop::UnverifiedEnd);
        assert!(matches!(collection.batch.coverage, Coverage::Window { .. }));
    }
}

#[tokio::test]
async fn legitimate_empty_list_retains_source_but_missing_schema_is_error() {
    let transport =
        MockTransport::new([response(TASK_PATH, br#"{"e":0,"d":{"total":0,"list":[]}}"#)]);
    let collection = EhallClient::new(transport)
        .collect_tasks(
            &source(),
            EhallTaskKind::Todo,
            2,
            EhallReadBudget::default(),
        )
        .await
        .unwrap();
    assert!(collection.complete);
    assert!(collection.batch.records.is_empty());
    assert_eq!(collection.batch.source, source());
    let transport = MockTransport::new([response(TASK_PATH, br#"{"e":0,"d":{}}"#)]);
    assert!(
        EhallClient::new(transport)
            .tasks(&source(), EhallTaskKind::Todo, page())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn invalid_arguments_fail_before_io() {
    let transport = MockTransport::default();
    let client = EhallClient::new(transport.clone());
    for bad in [
        EhallPage {
            page: 0,
            page_size: 2,
        },
        EhallPage {
            page: 1,
            page_size: 51,
        },
        EhallPage {
            page: 10001,
            page_size: 2,
        },
    ] {
        assert!(
            client
                .tasks(&source(), EhallTaskKind::Todo, bad)
                .await
                .is_err()
        );
    }
    assert!(client.catalog(&source(), 0).await.is_err());
    assert!(client.catalog(&source(), 101).await.is_err());
    let mut bad_source = source();
    bad_source.account_id.clear();
    assert!(client.catalog(&bad_source, 1).await.is_err());
    assert!(
        client
            .collect_tasks(
                &source(),
                EhallTaskKind::Todo,
                2,
                EhallReadBudget {
                    max_pages: 0,
                    ..EhallReadBudget::default()
                }
            )
            .await
            .is_err()
    );
    assert!(
        client
            .collect_tasks(
                &source(),
                EhallTaskKind::Todo,
                2,
                EhallReadBudget {
                    max_items: 1,
                    ..EhallReadBudget::default()
                }
            )
            .await
            .is_err()
    );
    assert!(transport.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn catalog_duplicate_ids_fail_even_outside_requested_window() {
    let mut value: Value = serde_json::from_slice(CATALOG).unwrap();
    value["d"]["list"][2]["id"] = value["d"]["list"][0]["id"].clone();
    let transport =
        MockTransport::new([response(CATALOG_PATH, &serde_json::to_vec(&value).unwrap())]);
    assert_eq!(
        EhallClient::new(transport)
            .catalog(&source(), 1)
            .await
            .unwrap_err(),
        CampusError::Transport(ConnectorError::PaginationCycle)
    );
}

#[tokio::test]
async fn catalog_route_selectors_cannot_disguise_signatures_or_ambiguity() {
    for url in [
        "https://my.fudan.edu.cn/view?id=SYNTHETIC-SIGNATURE",
        "https://my.fudan.edu.cn/view?type=SYNTHETIC-SIGNATURE",
        "https://my.fudan.edu.cn/view?id=1&id=2",
        "https://my.fudan.edu.cn/view#SYNTHETIC-SIGNATURE",
        "https://my.fudan.edu.cn:8443/view",
        "https://my.fudan.edu.cn.attacker.example.invalid/view",
    ] {
        let body = json!({"e":0,"d":{"total":1,"list":[{"id":"safe-id","name":"合成服务","extra_url":{"pc_url":url}}]}});
        let transport =
            MockTransport::new([response(CATALOG_PATH, &serde_json::to_vec(&body).unwrap())]);
        let batch = EhallClient::new(transport)
            .catalog(&source(), 1)
            .await
            .unwrap();
        assert!(batch.records[0].payload.pc_url.is_none());
        assert!(
            !serde_json::to_string(&batch)
                .unwrap()
                .contains("SYNTHETIC-SIGNATURE")
        );
    }
}

#[tokio::test]
async fn second_page_authentication_failure_is_redacted_and_preserves_first_page() {
    let transport = MockTransport::new([
        response(TASK_PATH, TODO1),
        response(
            TASK_PATH,
            br#"{"e":401,"m":"SYNTHETIC-SECRET","d":{"list":[]}}"#,
        ),
    ]);
    let collection = EhallClient::new(transport)
        .collect_tasks(
            &source(),
            EhallTaskKind::Todo,
            2,
            EhallReadBudget::default(),
        )
        .await
        .unwrap();
    assert!(!collection.complete);
    assert_eq!(collection.batch.records.len(), 2);
    assert_eq!(
        collection.stop,
        EhallReadStop::Interrupted {
            failure: EhallReadFailure::Authentication
        }
    );
    assert!(
        !serde_json::to_string(&collection)
            .unwrap()
            .contains("SYNTHETIC-SECRET")
    );
}

#[tokio::test]
async fn long_or_url_bearing_public_descriptions_do_not_drop_the_catalog_entry() {
    let mut wire: Value = serde_json::from_slice(CATALOG).unwrap();
    let rows = wire["d"]["list"].as_array_mut().unwrap();
    rows[0]["dsc"] = json!("Synthetic prose ".repeat(700));
    rows[1]["dsc"] = json!("Official help https://ehall.fudan.edu.cn/help?token=SYNTHETIC-SECRET");
    rows[2]["dsc"] = json!("<script>SYNTHETIC-SECRET</script><p>Safe visible explanation</p>");
    let transport = MockTransport::new([response(CATALOG_PATH, wire.to_string().as_bytes())]);
    let batch = EhallClient::new(transport)
        .catalog(&source(), 3)
        .await
        .unwrap();
    assert_eq!(batch.records.len(), 3);
    assert_eq!(
        batch.records[0].payload.description_state,
        dansheng_connectors::ehall::EhallDescriptionState::OmittedTooLarge
    );
    assert_eq!(
        batch.records[1].payload.description_state,
        dansheng_connectors::ehall::EhallDescriptionState::OmittedUnsafe
    );
    assert_eq!(
        batch.records[2].payload.description.as_deref(),
        Some("Safe visible explanation")
    );
    assert!(
        !serde_json::to_string(&batch)
            .unwrap()
            .contains("SYNTHETIC-SECRET")
    );
}

#[tokio::test]
async fn observed_ajax_login_envelope_is_authentication_not_success_or_schema_loss() {
    let transport = MockTransport::new([response(TASK_PATH, br#"{"e":10013,"m":"SYNTHETIC-SECRET","d":{"loginUrl":"https://ehall.fudan.edu.cn/manage/common/login/index?redirect=SYNTHETIC-SECRET"}}"#)]);
    let error = EhallClient::new(transport.clone())
        .tasks(&source(), EhallTaskKind::Todo, page())
        .await
        .unwrap_err();
    assert!(matches!(
        &error,
        CampusError::Transport(ConnectorError::AuthRequired(_))
    ));
    assert!(!format!("{error:?}").contains("SYNTHETIC-SECRET"));
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn reflected_private_url_in_summary_text_fails_without_leaking_error_content() {
    let body = json!({"e":0,"d":{"total":1,"list":[{"id":"task-1","task_name":"https://myform.fudan.edu.cn/view?token=SYNTHETIC-SECRET"}]}});
    let transport = MockTransport::new([response(TASK_PATH, &serde_json::to_vec(&body).unwrap())]);
    let error = EhallClient::new(transport)
        .tasks(&source(), EhallTaskKind::Todo, page())
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        CampusError::SchemaChanged { field: "text", .. }
    ));
    assert!(!format!("{error:?}").contains("SYNTHETIC-SECRET"));
}
