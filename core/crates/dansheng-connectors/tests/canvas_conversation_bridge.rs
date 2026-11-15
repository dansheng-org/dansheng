// SPDX-License-Identifier: GPL-3.0-or-later
#![cfg(feature = "services")]
use async_trait::async_trait;
use dansheng_connectors::core_adapter::CampusService;
use dansheng_core::{
    CoreResult, Engine, PlatformPort, Principal, PrincipalKind, Request, Response, policy::Grant,
    services::CoreService,
};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

const ORIGIN: &str = "https://canvas-bridge.invalid";
const ACCOUNT: &str = "synthetic-account";
struct Page {
    requests: Mutex<Vec<Value>>,
}
#[async_trait]
impl PlatformPort for Page {
    fn capabilities(&self) -> Vec<String> {
        vec!["browser.evaluate".into(), "browser.request".into()]
    }
    async fn call(&self, capability: &str, value: Value) -> CoreResult<Value> {
        let grant: Grant = serde_json::from_value(value["grant"].clone()).unwrap();
        assert!(!grant.capabilities.contains("browser.write"));
        let input = &value["input"];
        match capability {
            "browser.evaluate" => Ok(
                json!({"account_id":ACCOUNT,"origin":ORIGIN,"authenticated":true,"session_handle":"synthetic-handle"}),
            ),
            "browser.request" => {
                assert_eq!(input["method"], "GET");
                self.requests.lock().unwrap().push(input.clone());
                let url = url::Url::parse(input["url"].as_str().unwrap()).unwrap();
                let body = if url.path() == "/api/v1/conversations/9007199254740993" {
                    assert!(
                        url.query_pairs()
                            .any(|(k, v)| k == "auto_mark_as_read" && v == "false")
                    );
                    r#"{"id":9007199254740993,"messages":[{"id":"9","body":"synthetic-message"}]}"#
                } else if url.path() == "/api/v1/courses/42/users" {
                    assert!(
                        url.query_pairs()
                            .any(|(k, v)| k == "include[]" && v == "enrollments")
                    );
                    r#"[{"id":9007199254740993,"name":"roster-user","email":"DROP","login_id":"DROP","enrollments":[{"type":"StudentEnrollment","role":"Student","course_id":42}]}]"#
                } else if url.path() == "/api/v1/search/recipients" {
                    assert!(
                        url.query_pairs()
                            .any(|(k, v)| k == "context" && v == "course_42")
                    );
                    r#"[{"id":9007199254740993,"name":"synthetic-user"}]"#
                } else {
                    r#"[{"id":9007199254740993,"subject":"synthetic-subject"}]"#
                };
                Ok(json!({"status":200,"url":url.to_string(),"body":body,"headers":{}}))
            }
            _ => panic!("unexpected platform action"),
        }
    }
}
fn reader() -> Principal {
    Principal {
        id: "synthetic-reader".into(),
        kind: PrincipalKind::Mcp,
    }
}
async fn call(engine: &Arc<Engine>, principal: Principal, method: &str, params: Value) -> Response {
    engine
        .handle(
            principal,
            Request {
                id: "fixture".into(),
                method: method.into(),
                params,
            },
        )
        .await
}
fn setup(path: &std::path::Path) -> (Arc<Engine>, Arc<Page>) {
    let page = Arc::new(Page {
        requests: Mutex::default(),
    });
    let engine = Engine::open(path, page.clone()).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    engine
        .store
        .set_grant(
            &reader().id,
            &Grant {
                capabilities: ["canvas.read".into()].into_iter().collect(),
                account_ids: [ACCOUNT.into()].into_iter().collect(),
                ..Default::default()
            },
        )
        .unwrap();
    engine
        .store
        .kv_set(
            "service:canvas",
            ACCOUNT,
            &json!({"origin":ORIGIN,"access":"browser_session"}),
        )
        .unwrap();
    (engine, page)
}

#[tokio::test]
async fn registered_reads_forward_source_records_without_requiring_course_for_detail() {
    let temp = tempfile::tempdir().unwrap();
    let (engine, page) = setup(temp.path());
    let list = call(
        &engine,
        reader(),
        "canvas.conversations.sync",
        json!({"account_id":ACCOUNT}),
    )
    .await;
    assert!(list.error.is_none(), "{:?}", list.error);
    let list = list.result.unwrap();
    assert_eq!(list[0]["payload"]["id"], "9007199254740993");
    assert_eq!(list[0]["source_id"], "official.canvas.conversations:all");
    let scoped = call(
        &engine,
        reader(),
        "canvas.conversations.sync",
        json!({"account_id":ACCOUNT,"course_id":"42"}),
    )
    .await;
    assert!(scoped.error.is_none(), "{:?}", scoped.error);
    assert_eq!(
        scoped.result.unwrap()[0]["source_id"],
        "official.canvas.conversations:42"
    );
    let detail = call(
        &engine,
        reader(),
        "canvas.conversation.read",
        json!({"account_id":ACCOUNT,"conversation_id":"9007199254740993"}),
    )
    .await;
    assert!(detail.error.is_none(), "{:?}", detail.error);
    assert_eq!(
        detail.result.unwrap()["payload"]["messages"][0]["body"],
        "synthetic-message"
    );
    let search = call(
        &engine,
        reader(),
        "canvas.recipients.search",
        json!({"account_id":ACCOUNT,"course_id":"42","search":""}),
    )
    .await;
    assert!(search.error.is_none(), "{:?}", search.error);
    assert_eq!(
        search.result.unwrap()[0]["payload"]["id"],
        "9007199254740993"
    );
    assert_eq!(page.requests.lock().unwrap().len(), 4);
}

#[tokio::test]
async fn write_capability_account_isolation_and_token_preflight_fail_before_io() {
    let temp = tempfile::tempdir().unwrap();
    let (engine, page) = setup(temp.path());
    for method in ["canvas.conversation.reply", "canvas.conversation.create"] {
        let result=call(&engine,reader(),method,json!({"account_id":ACCOUNT,"conversation_id":"9","body":"synthetic","course_id":"42","recipients":["7"],"subject":"subject"})).await;
        assert_eq!(result.error.unwrap().code, "PermissionDenied");
    }
    let wrong = call(
        &engine,
        reader(),
        "canvas.conversations.sync",
        json!({"account_id":"other-account"}),
    )
    .await;
    assert_eq!(wrong.error.unwrap().code, "PermissionDenied");
    for mode in ["host_session", "browser_session"] {
        engine
            .store
            .kv_set(
                "service:canvas",
                ACCOUNT,
                &json!({"origin":ORIGIN,"access":mode}),
            )
            .unwrap();
        let result = call(
            &engine,
            Principal::owner(),
            "canvas.conversation.reply",
            json!({"account_id":ACCOUNT,"conversation_id":"9","body":"synthetic"}),
        )
        .await;
        assert_eq!(result.error.unwrap().code, "CapabilityUnavailable");
    }
    assert!(page.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn sends_are_not_schedulable_read_jobs() {
    let temp = tempfile::tempdir().unwrap();
    let (engine, page) = setup(temp.path());
    for method in ["canvas.conversation.reply", "canvas.conversation.create"] {
        assert_eq!(
            CampusService
                .methods()
                .into_iter()
                .find(|(name, _)| *name == method)
                .unwrap()
                .1,
            "canvas.write"
        );
        let result=call(&engine,Principal::owner(),"jobs.schedule",json!({"kind":"service","method":method,"account_id":ACCOUNT,"input":{"account_id":ACCOUNT,"body":"synthetic"},"run_at":"2099-01-01T00:00:00Z"})).await;
        assert!(result.error.is_some());
    }
    assert!(page.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn roster_read_registration_grants_account_and_payload_contract() {
    let temp = tempfile::tempdir().unwrap();
    let (engine, page) = setup(temp.path());
    let roster = call(
        &engine,
        reader(),
        "canvas.course_users.sync",
        json!({"account_id":ACCOUNT,"course_id":"42","search":"name"}),
    )
    .await;
    assert!(roster.error.is_none(), "{:?}", roster.error);
    let rows = roster.result.unwrap();
    assert_eq!(rows[0]["source_id"], "official.canvas.course_users:42");
    assert_eq!(rows[0]["external_id"], "course-user:42:9007199254740993");
    assert_eq!(
        rows[0]["payload"]["enrollments"][0]["type"],
        "StudentEnrollment"
    );
    assert!(!rows.to_string().contains("DROP"));
    for params in [
        json!({"account_id":"wrong","course_id":"42"}),
        json!({"account_id":ACCOUNT,"course_id":"42","search":3}),
    ] {
        assert!(
            call(&engine, reader(), "canvas.course_users.sync", params)
                .await
                .error
                .is_some()
        );
    }
    assert_eq!(page.requests.lock().unwrap().len(), 1);
    assert_eq!(
        CampusService
            .methods()
            .into_iter()
            .find(|(method, _)| *method == "fudan.postgraduate.semester")
            .unwrap()
            .1,
        "fudan.catalog.read"
    );
    assert_eq!(
        call(
            &engine,
            reader(),
            "fudan.postgraduate.semester",
            json!({"account_id":ACCOUNT})
        )
        .await
        .error
        .unwrap()
        .code,
        "PermissionDenied"
    );
}

#[tokio::test]
async fn native_session_missing_csrf_is_definitely_unsent_without_browser_fallback() {
    let temp = tempfile::tempdir().unwrap();
    let (engine, page) = setup(temp.path());
    let origin = "https://elearning.fudan.edu.cn";
    engine
        .store
        .kv_set(
            "service:canvas",
            ACCOUNT,
            &json!({"origin":origin,"access":"host_session"}),
        )
        .unwrap();
    // No CSRF cookie: real transport rejects before DNS or send, no remote contact.
    let imported = call(
        &engine,
        Principal::owner(),
        "auth.session.set",
        json!({
            "account_id":ACCOUNT, "origin":origin, "persist":false,
            "cookies":["SID=synthetic; Path=/; Secure"]
        }),
    )
    .await;
    assert!(imported.error.is_none());
    for method in ["canvas.conversation.reply", "canvas.conversation.create"] {
        let result = call(&engine, Principal::owner(), method,
            json!({"account_id":ACCOUNT,"course_id":"42","conversation_id":"9","recipients":["7"],"subject":"fixture","body":"never-dispatched"})).await;
        assert_eq!(result.error.unwrap().code, "CanvasCsrfRequired");
    }
    assert!(page.requests.lock().unwrap().is_empty());
}
