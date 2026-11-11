// SPDX-License-Identifier: GPL-3.0-or-later
#![cfg(feature = "services")]
//! The registered Core service is exercised through a trusted fake page port.
//! No campus endpoint, browser profile or real credential is used.
use async_trait::async_trait;
use dansheng_connectors::core_adapter::CampusService;
use dansheng_core::{
    CoreError, CoreResult, Engine, PlatformPort, Principal, PrincipalKind, Request, Response,
    policy::Grant, services::CoreService,
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{
        Arc, Mutex, Weak,
        atomic::{AtomicUsize, Ordering},
    },
};

const ORIGIN: &str = "https://canvas-bridge.invalid";
const ACCOUNT: &str = "synthetic-account-a";
const USER: &str = "9007199254740993";
const QUIZZES: &str = include_str!("../fixtures/canvas_learning/quizzes.json");
const ENROLLMENTS: &str = include_str!("../fixtures/canvas_learning/enrollments.json");

struct PageReply {
    body: String,
    headers: Value,
    final_url: Option<String>,
    error: Option<CoreError>,
}
impl PageReply {
    fn body(body: impl Into<String>) -> Self {
        Self {
            body: body.into(),
            headers: json!({}),
            final_url: None,
            error: None,
        }
    }
}
struct Page {
    account: String,
    origin: String,
    replies: Mutex<VecDeque<PageReply>>,
    reads: Mutex<Vec<Value>>,
    status_calls: AtomicUsize,
    rotate_on_status: AtomicUsize,
    revoke_on_read: AtomicUsize,
    engine: Mutex<Option<Weak<Engine>>>,
}
impl Page {
    fn new(replies: Vec<PageReply>) -> Arc<Self> {
        Arc::new(Self {
            account: ACCOUNT.into(),
            origin: ORIGIN.into(),
            replies: Mutex::new(replies.into()),
            reads: Mutex::default(),
            status_calls: AtomicUsize::new(0),
            rotate_on_status: AtomicUsize::new(0),
            revoke_on_read: AtomicUsize::new(0),
            engine: Mutex::default(),
        })
    }
}
#[async_trait]
impl PlatformPort for Page {
    fn capabilities(&self) -> Vec<String> {
        vec!["browser.evaluate".into(), "browser.request".into()]
    }
    async fn call(&self, capability: &str, envelope: Value) -> CoreResult<Value> {
        assert!(envelope["principal"].is_object());
        let grant: Grant = serde_json::from_value(envelope["grant"].clone()).unwrap();
        assert!(!grant.capabilities.contains("browser.write"));
        assert!(!grant.capabilities.contains("browser.login"));
        let input = &envelope["input"];
        match capability {
            "browser.evaluate" => {
                let number = self.status_calls.fetch_add(1, Ordering::SeqCst) + 1;
                assert_eq!(input["operation"], "session.status");
                assert_eq!(input["require_authenticated"], true);
                let handle = if self.rotate_on_status.load(Ordering::SeqCst) == number {
                    "replacement-page-handle"
                } else {
                    "synthetic-page-handle"
                };
                Ok(json!({"account_id":self.account,"origin":self.origin,
                    "authenticated":true,"session_handle":handle}))
            }
            "browser.request" => {
                assert_eq!(input["account_id"], ACCOUNT);
                assert_eq!(input["session_handle"], "synthetic-page-handle");
                assert_eq!(input["method"], "GET");
                assert!(input.get("body").is_none());
                assert!(input.get("form_fields").is_none());
                assert!(input.get("mutation_key").is_none());
                assert!(
                    input["deadline_epoch_ms"].as_i64().unwrap()
                        > chrono::Utc::now().timestamp_millis()
                );
                assert!(
                    input["headers"]
                        .as_object()
                        .unwrap()
                        .keys()
                        .all(|k| k.eq_ignore_ascii_case("accept"))
                );
                let url = url::Url::parse(input["url"].as_str().unwrap()).unwrap();
                assert_eq!(url.origin().ascii_serialization(), ORIGIN);
                let number = {
                    let mut reads = self.reads.lock().unwrap();
                    reads.push(input.clone());
                    reads.len()
                };
                if self.revoke_on_read.load(Ordering::SeqCst) == number {
                    let engine = self
                        .engine
                        .lock()
                        .unwrap()
                        .as_ref()
                        .unwrap()
                        .upgrade()
                        .unwrap();
                    let mut grant = reader_grant();
                    grant.capabilities.remove("canvas.read");
                    engine.store.set_grant("fixture-reader", &grant).unwrap();
                }
                let reply = self
                    .replies
                    .lock()
                    .unwrap()
                    .pop_front()
                    .expect("unexpected page I/O");
                if let Some(error) = reply.error {
                    return Err(error);
                }
                Ok(
                    json!({"status":200,"url":reply.final_url.unwrap_or_else(|| url.to_string()),
                    "body":reply.body,"headers":reply.headers}),
                )
            }
            _ => panic!("unexpected platform call"),
        }
    }
}
fn reader() -> Principal {
    Principal {
        id: "fixture-reader".into(),
        kind: PrincipalKind::Mcp,
    }
}
fn reader_grant() -> Grant {
    Grant {
        capabilities: [
            "canvas.read",
            "sources.read",
            "search.read",
            "fudan.catalog.read",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        account_ids: [ACCOUNT.to_owned()].into_iter().collect(),
        ..Default::default()
    }
}
async fn invoke(
    engine: &Arc<Engine>,
    principal: Principal,
    method: &str,
    params: Value,
) -> Response {
    engine
        .handle(
            principal,
            Request {
                id: "bridge-fixture".into(),
                method: method.into(),
                params,
            },
        )
        .await
}
async fn setup(path: &std::path::Path, page: Arc<Page>) -> Arc<Engine> {
    let engine = Engine::open(path, page.clone()).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    engine
        .store
        .set_grant(&reader().id, &reader_grant())
        .unwrap();
    *page.engine.lock().unwrap() = Some(Arc::downgrade(&engine));
    let configured = invoke(
        &engine,
        Principal::owner(),
        "canvas.configure",
        json!({
            "account_id":ACCOUNT,"origin":ORIGIN,"access":"browser_session"
        }),
    )
    .await;
    assert!(configured.error.is_none(), "{configured:?}");
    assert!(
        !configured
            .result
            .unwrap()
            .to_string()
            .contains("synthetic-page-handle")
    );
    engine
}
async fn cached(engine: &Arc<Engine>, principal: Principal, source: &str) -> Value {
    invoke(
        engine,
        principal,
        "sources.query",
        json!({"account_id":ACCOUNT,"source_id":source}),
    )
    .await
    .result
    .unwrap()
}

#[test]
fn service_registration_contains_new_capabilities_without_mutations() {
    let methods = CampusService.methods();
    for (method, capability) in [
        ("fudan.catalog.semesters", "fudan.catalog.read"),
        ("fudan.catalog.course", "fudan.catalog.read"),
        ("fudan.ehall.catalog", "fudan.ehall.catalog.read"),
        ("fudan.ehall.tasks.sync", "fudan.ehall.tasks.read"),
        ("canvas.quizzes.sync", "canvas.read"),
        ("canvas.submission.self", "canvas.read"),
        ("canvas.grades.self", "canvas.read"),
    ] {
        assert!(methods.contains(&(method, capability)));
    }
    assert!(
        !methods
            .iter()
            .any(|(name, _)| name.starts_with("fudan.ehall.") && name.contains("submit"))
    );
}

#[tokio::test]
async fn page_handle_change_between_pages_cannot_mix_authenticated_contexts() {
    let temp = tempfile::tempdir().unwrap();
    let mut first = PageReply::body(QUIZZES);
    first.headers =
        json!({"link":format!("<{ORIGIN}/api/v1/courses/81001/quizzes?page=2>; rel=\"next\"")});
    let page = Page::new(vec![first]);
    let engine = setup(temp.path(), page.clone()).await;
    // configure status=1, first GET status=2, next-page status=3.
    page.rotate_on_status.store(3, Ordering::SeqCst);
    let result = invoke(
        &engine,
        reader(),
        "canvas.quizzes.sync",
        json!({"account_id":ACCOUNT,"course_id":"81001"}),
    )
    .await;
    assert_eq!(result.error.unwrap().code, "AuthenticationRequired");
    assert_eq!(page.reads.lock().unwrap().len(), 1);
    assert!(
        cached(&engine, Principal::owner(), "official.canvas.quizzes:81001")
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn page_pagination_flows_through_the_registered_service_and_same_cache() {
    let temp = tempfile::tempdir().unwrap();
    let mut first = PageReply::body(QUIZZES);
    first.headers = json!({
        "content-type":"application/json",
        "link":format!("<{ORIGIN}/api/v1/courses/81001/quizzes?page=2&per_page=100>; rel=\"next\""),
        "set-cookie":"SYNTHETIC_SECRET_MUST_NOT_EXPORT"
    });
    let page = Page::new(vec![first, PageReply::body("[]")]);
    let engine = setup(temp.path(), page.clone()).await;
    let response = invoke(
        &engine,
        reader(),
        "canvas.quizzes.sync",
        json!({"account_id":ACCOUNT,"course_id":"81001"}),
    )
    .await;
    assert!(response.error.is_none(), "{response:?}");
    let records = response.result.unwrap();
    assert_eq!(page.reads.lock().unwrap().len(), 2);
    assert_eq!(records[0]["source_id"], "official.canvas.quizzes:81001");
    assert!(
        !records
            .to_string()
            .contains("SYNTHETIC_SECRET_MUST_NOT_EXPORT")
    );
    let rows = cached(&engine, reader(), "official.canvas.quizzes:81001").await;
    assert_eq!(
        rows.as_array().unwrap().len(),
        records.as_array().unwrap().len()
    );
    assert_eq!(rows[0]["data"], records[0]["payload"]);
    let checkpoint = engine
        .store
        .kv_get(
            "checkpoint:service:canvas:official.canvas.quizzes:81001",
            ACCOUNT,
        )
        .unwrap();
    assert!(checkpoint["observed_at"].is_string());
    drop(engine);
    let engine = Engine::open(temp.path(), page).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    assert_eq!(
        cached(&engine, reader(), "official.canvas.quizzes:81001").await,
        rows
    );
}

#[tokio::test]
async fn later_page_failure_preserves_previous_records_and_checkpoint() {
    let temp = tempfile::tempdir().unwrap();
    let mut first = PageReply::body(QUIZZES);
    first.headers =
        json!({"link":format!("<{ORIGIN}/api/v1/courses/81001/quizzes?page=2>; rel=\"next\"")});
    let mut failed = PageReply::body("");
    failed.error = Some(CoreError::new("Timeout", "SYNTHETIC_PROVIDER_SECRET"));
    let page = Page::new(vec![first, failed]);
    let engine = setup(temp.path(), page).await;
    let source = "official.canvas.quizzes:81001";
    engine
        .store
        .require_source_capabilities(
            "service:canvas",
            source,
            &["canvas.read".to_owned()].into_iter().collect(),
        )
        .unwrap();
    engine
        .store
        .commit_source(
            "service:canvas",
            ACCOUNT,
            source,
            "lms_quiz",
            &[("old".into(), json!({"title":"Previous fixture"}))],
            &json!({"proof":"previous"}),
        )
        .unwrap();
    let failed = invoke(
        &engine,
        reader(),
        "canvas.quizzes.sync",
        json!({"account_id":ACCOUNT,"course_id":"81001"}),
    )
    .await;
    assert_eq!(failed.error.as_ref().unwrap().code, "Timeout");
    assert!(
        !serde_json::to_string(&failed)
            .unwrap()
            .contains("SYNTHETIC_PROVIDER_SECRET")
    );
    let rows = cached(&engine, reader(), source).await;
    assert_eq!(rows.as_array().unwrap().len(), 1);
    assert_eq!(rows[0]["external_id"], "old");
    assert_eq!(
        engine
            .store
            .kv_get(&format!("checkpoint:service:canvas:{source}"), ACCOUNT)
            .unwrap(),
        json!({"proof":"previous"})
    );
}

#[tokio::test]
async fn self_enrollment_identity_filter_is_retained_on_the_page_request() {
    let temp = tempfile::tempdir().unwrap();
    let page = Page::new(vec![
        PageReply::body(json!({"id":USER}).to_string()),
        PageReply::body(ENROLLMENTS),
    ]);
    let engine = setup(temp.path(), page.clone()).await;
    let response = invoke(
        &engine,
        reader(),
        "canvas.enrollments.self",
        json!({"account_id":ACCOUNT,"course_id":"81001"}),
    )
    .await;
    assert!(response.error.is_none(), "{response:?}");
    let reads = page.reads.lock().unwrap();
    let second = url::Url::parse(reads[1]["url"].as_str().unwrap()).unwrap();
    assert_eq!(
        second
            .query_pairs()
            .find(|(key, _)| key == "user_id")
            .unwrap()
            .1,
        USER
    );
    assert!(second.path().ends_with("/enrollments"));
    let rows = response.result.unwrap();
    assert!(
        rows.as_array()
            .unwrap()
            .iter()
            .all(|row| row["payload"]["user_id"] == USER)
    );
    assert!(!rows.to_string().contains("unposted"));
}

#[tokio::test]
async fn source_grants_do_not_allow_raw_browser_calls_or_cross_account_reads() {
    let temp = tempfile::tempdir().unwrap();
    let page = Page::new(vec![]);
    let engine = setup(temp.path(), page.clone()).await;
    for (method, params) in [
        (
            "browser.request",
            json!({"account_id":ACCOUNT,"url":format!("{ORIGIN}/api/v1/courses")}),
        ),
        (
            "canvas.quizzes.sync",
            json!({"account_id":"synthetic-account-b","course_id":"81001"}),
        ),
        ("fudan.ehall.catalog", json!({"account_id":ACCOUNT})),
    ] {
        assert_eq!(
            invoke(&engine, reader(), method, params)
                .await
                .error
                .unwrap()
                .code,
            "PermissionDenied"
        );
    }
    assert!(page.reads.lock().unwrap().is_empty());
}

#[tokio::test]
async fn revocation_after_page_io_prevents_return_and_cache_publication() {
    let temp = tempfile::tempdir().unwrap();
    let page = Page::new(vec![PageReply::body(QUIZZES)]);
    let engine = setup(temp.path(), page.clone()).await;
    page.revoke_on_read.store(1, Ordering::SeqCst);
    let response = invoke(
        &engine,
        reader(),
        "canvas.quizzes.sync",
        json!({"account_id":ACCOUNT,"course_id":"81001"}),
    )
    .await;
    assert_eq!(response.error.unwrap().code, "PermissionDenied");
    assert!(
        cached(&engine, Principal::owner(), "official.canvas.quizzes:81001")
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn wrong_origin_binding_and_unsafe_response_cannot_reach_native_http() {
    let temp = tempfile::tempdir().unwrap();
    let wrong = Arc::new(Page {
        origin: "https://another-page.invalid".into(),
        ..Arc::try_unwrap(Page::new(vec![])).ok().unwrap()
    });
    let engine = Engine::open(temp.path(), wrong.clone()).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    let configured = invoke(
        &engine,
        Principal::owner(),
        "canvas.configure",
        json!({"account_id":ACCOUNT,"origin":ORIGIN,"access":"browser_session"}),
    )
    .await;
    assert_eq!(configured.error.unwrap().code, "SourceError");
    assert!(
        engine
            .store
            .kv_get("service:canvas", ACCOUNT)
            .unwrap()
            .is_null()
    );
    assert!(wrong.reads.lock().unwrap().is_empty());
    drop(engine);

    let mut reply = PageReply::body(QUIZZES);
    reply.final_url = Some("https://unrelated.invalid/api/v1/courses/81001/quizzes".into());
    let page = Page::new(vec![reply]);
    let engine = setup(temp.path(), page.clone()).await;
    let response = invoke(
        &engine,
        reader(),
        "canvas.quizzes.sync",
        json!({"account_id":ACCOUNT,"course_id":"81001"}),
    )
    .await;
    assert_eq!(response.error.unwrap().code, "SourceError");
    assert_eq!(page.reads.lock().unwrap().len(), 1);
    assert!(
        cached(&engine, Principal::owner(), "official.canvas.quizzes:81001")
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn catalog_projection_is_cache_only_and_respects_account_and_source_acl() {
    let temp = tempfile::tempdir().unwrap();
    let page = Page::new(vec![]);
    let engine = setup(temp.path(), page.clone()).await;
    let source = "official.fudan.catalog.course:902";
    engine
        .store
        .require_source_capabilities(
            "service:fudan",
            source,
            &["fudan.catalog.read".to_owned()].into_iter().collect(),
        )
        .unwrap();
    engine
        .store
        .record_upsert(
            "service:fudan",
            ACCOUNT,
            source,
            "catalog_course:902:18446744073709551616000",
            "catalog_course",
            &json!({"course_id":"18446744073709551616000","name":"Synthetic course"}),
        )
        .unwrap();
    let params =
        json!({"account_id":ACCOUNT,"semester_id":"902","course_id":"18446744073709551616000"});
    let response = invoke(&engine, reader(), "fudan.catalog.course", params.clone()).await;
    assert!(response.error.is_none(), "{response:?}");
    let row = response.result.unwrap();
    assert_eq!(row["cache_state"], "cached_catalog_projection");
    assert_eq!(row["payload"]["course_id"], "18446744073709551616000");
    assert!(page.reads.lock().unwrap().is_empty());
    let mut grant = reader_grant();
    grant.capabilities.remove("fudan.catalog.read");
    engine.store.set_grant(&reader().id, &grant).unwrap();
    assert_eq!(
        invoke(&engine, reader(), "fudan.catalog.course", params)
            .await
            .error
            .unwrap()
            .code,
        "PermissionDenied"
    );
    assert!(
        cached(&engine, reader(), source)
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn library_reader_configuration_cannot_be_forged_through_read_params_or_mcp() {
    let temp = tempfile::tempdir().unwrap();
    let page = Page::new(vec![]);
    let engine = setup(temp.path(), page.clone()).await;
    let reference = format!("library-reader:{}", "a".repeat(64));
    let mut grant = reader_grant();
    grant.capabilities.extend([
        "fudan.library.configure".into(),
        "fudan.library.loans.read".into(),
    ]);
    engine.store.set_grant(&reader().id, &grant).unwrap();
    let params = json!({"account_id":ACCOUNT,"reader_ref":reference});
    for method in [
        "fudan.library.reader.observe",
        "fudan.library.reader.bind",
        "fudan.library.reader.clear",
    ] {
        assert_eq!(
            invoke(&engine, reader(), method, params.clone())
                .await
                .error
                .unwrap()
                .code,
            "PermissionDenied"
        );
    }
    // Read parameters cannot establish the host's binding or supply its identity.
    let unbound = invoke(
        &engine,
        reader(),
        "fudan.library.loans.current",
        params.clone(),
    )
    .await;
    assert_eq!(unbound.error.unwrap().code, "LibraryIdentityUnverified");
    assert!(
        engine
            .store
            .kv_get("service:fudan-library:reader-binding", ACCOUNT)
            .unwrap()
            .is_null()
    );
    let bound = invoke(
        &engine,
        Principal::owner(),
        "fudan.library.reader.bind",
        params,
    )
    .await;
    assert_eq!(
        bound.result.unwrap()["verification"],
        "owner_provided_fingerprint"
    );
    let changed = invoke(
        &engine,
        Principal::owner(),
        "fudan.library.reader.bind",
        json!({
            "account_id":ACCOUNT,"reader_ref":format!("library-reader:{}", "b".repeat(64))
        }),
    )
    .await;
    assert_eq!(changed.error.unwrap().code, "AccountBindingMismatch");
    // History is a separate source capability even when current loans are allowed.
    assert_eq!(
        invoke(
            &engine,
            reader(),
            "fudan.library.loans.history",
            json!({"account_id":ACCOUNT})
        )
        .await
        .error
        .unwrap()
        .code,
        "PermissionDenied"
    );
    let cleared = invoke(
        &engine,
        Principal::owner(),
        "fudan.library.reader.clear",
        json!({"account_id":ACCOUNT}),
    )
    .await;
    assert_eq!(cleared.result.unwrap()["bound"], false);
    assert!(page.reads.lock().unwrap().is_empty());
}

#[tokio::test]
async fn program_detail_requires_a_matching_account_catalog_and_rejects_unverified_filters() {
    let temp = tempfile::tempdir().unwrap();
    let page = Page::new(vec![]);
    let engine = setup(temp.path(), page.clone()).await;
    let mut grant = reader_grant();
    grant.capabilities.insert("fudan.programs.read".into());
    engine.store.set_grant(&reader().id, &grant).unwrap();
    let id = "9007199254740993123456789";
    // A caller-supplied ID or an entry cached for another account grants no access.
    engine
        .store
        .require_source_capabilities(
            "service:fudan",
            "official.fudan.programs.list",
            &["fudan.programs.read".to_owned()].into_iter().collect(),
        )
        .unwrap();
    engine
        .store
        .record_upsert(
            "service:fudan",
            "synthetic-account-b",
            "official.fudan.programs.list",
            &format!("program:2:{id}"),
            "public_program",
            &json!({"program_id":id}),
        )
        .unwrap();
    let response = invoke(
        &engine,
        reader(),
        "fudan.programs.detail",
        json!({"account_id":ACCOUNT,"program_id":id}),
    )
    .await;
    assert_eq!(response.error.unwrap().code, "ProgramNotInCachedCatalog");
    let filtered = invoke(
        &engine,
        reader(),
        "fudan.programs.list",
        json!({"account_id":ACCOUNT,"filters":{"YEARS":"2031"}}),
    )
    .await;
    assert_eq!(filtered.error.unwrap().code, "InvalidInput");
    assert!(page.reads.lock().unwrap().is_empty());
}
