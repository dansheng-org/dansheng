//! All accounts, data and services are synthetic; no network, vault or user profile.
use async_trait::async_trait;
use chrono::{Duration, Utc};
use dansheng_core::{
    CoreError, CoreResult, Engine, Principal, PrincipalKind, Request, UnavailablePlatform,
    policy::Grant,
    services::{CoreService, ServiceContext},
};
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration as StdDuration,
};
use tokio::sync::Semaphore;

const PAYLOAD: &str = "synthetic-private-mail-result";
const INPUT_MARKER: &str = "synthetic-private-job-input";

struct Fixture {
    calls: AtomicUsize,
    mode: AtomicUsize,
    entered: Semaphore,
    release: Semaphore,
    dropped: AtomicUsize,
}
impl Fixture {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            calls: AtomicUsize::new(0),
            mode: AtomicUsize::new(0),
            entered: Semaphore::new(0),
            release: Semaphore::new(0),
            dropped: AtomicUsize::new(0),
        })
    }
    async fn entered(&self) {
        tokio::time::timeout(StdDuration::from_secs(5), self.entered.acquire())
            .await
            .unwrap()
            .unwrap()
            .forget();
    }
}
struct DropSignal<'a>(&'a AtomicUsize);
impl Drop for DropSignal<'_> {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}
#[async_trait]
impl CoreService for Fixture {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        vec![
            ("canvas.courses.sync", "canvas.read"),
            ("fudan.timetable.sync", "fudan.academic.read"),
            ("mail.sync", "mail.sync"),
            ("mail.read", "mail.read"),
            ("mail.send", "mail.send"),
            ("mail.set_flags", "mail.write"),
            ("fixture.configure", "fixture.read"),
        ]
    }
    async fn call(
        &self,
        _: ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        input: Value,
    ) -> CoreResult<Value> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.entered.add_permits(1);
        let _signal = DropSignal(&self.dropped);
        match self.mode.load(Ordering::SeqCst) {
            1 => {
                self.release.acquire().await.unwrap().forget();
            }
            2 => {
                return Err(CoreError::new(
                    "AuthenticationRequired",
                    "synthetic authentication needs explicit intervention",
                ));
            }
            3 => return Ok(json!({"payload":"x".repeat(4*1024*1024+1)})),
            _ => {}
        }
        Ok(
            json!({"payload":PAYLOAD,"principal":principal,"account_id":input["account_id"],"method":method,
            "granted_accounts":grant.account_ids,"granted_sources":grant.source_ids}),
        )
    }
}

struct DirectoryFixture {
    fixture: Arc<Fixture>,
    entries: Vec<(&'static str, &'static str)>,
}
#[async_trait]
impl CoreService for DirectoryFixture {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        self.entries.clone()
    }
    async fn call(
        &self,
        context: ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        input: Value,
    ) -> CoreResult<Value> {
        self.fixture
            .call(context, principal, grant, method, input)
            .await
    }
}

fn client() -> Principal {
    Principal {
        id: "synthetic-native-reader".into(),
        kind: PrincipalKind::Mcp,
    }
}
fn permissions() -> Grant {
    let mut grant = Grant::default();
    grant.capabilities.extend(
        [
            "jobs.schedule",
            "jobs.run",
            "jobs.status",
            "jobs.cancel",
            "jobs.resume",
            "mail.read",
            "mail.sync",
            "canvas.read",
            "fudan.academic.read",
            "fixture.read",
        ]
        .map(str::to_owned),
    );
    grant.account_ids.insert("alpha".into());
    grant
}
fn setup() -> (tempfile::TempDir, Arc<Engine>, Arc<Fixture>) {
    let dir = tempfile::tempdir().unwrap();
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    let fixture = Fixture::new();
    engine.register_service(fixture.clone()).unwrap();
    engine
        .store
        .set_grant(&client().id, &permissions())
        .unwrap();
    (dir, engine, fixture)
}

async fn direct_service_after_grant_change(
    principal: Principal,
    changed: Grant,
) -> dansheng_core::api::Response {
    let (_dir, engine, fixture) = setup();
    fixture.mode.store(1, Ordering::SeqCst);
    let runner = engine.clone();
    let caller = principal.clone();
    let request = tokio::spawn(async move {
        runner
            .handle(
                caller,
                Request {
                    id: "synthetic-direct-read".into(),
                    method: "mail.read".into(),
                    params: json!({"account_id":"alpha","marker":INPUT_MARKER}),
                },
            )
            .await
    });
    fixture.entered().await;
    engine.store.set_grant(&principal.id, &changed).unwrap();
    fixture.release.add_permits(1);
    let response = tokio::time::timeout(StdDuration::from_secs(5), request)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    assert_eq!(fixture.dropped.load(Ordering::SeqCst), 1);
    let audit = serde_json::to_string(&engine.store.events(0).unwrap()).unwrap();
    assert!(!audit.contains(INPUT_MARKER));
    assert!(!audit.contains(PAYLOAD));
    response
}

#[tokio::test]
async fn direct_service_rechecks_capability_after_final_response_await() {
    let mut changed = permissions();
    changed.capabilities.remove("mail.read");
    let response = direct_service_after_grant_change(client(), changed).await;
    assert_eq!(response.error.unwrap().code, "PermissionDenied");
    assert!(response.result.is_none());
}

#[tokio::test]
async fn direct_service_rechecks_account_after_final_response_await() {
    let mut changed = permissions();
    changed.account_ids = ["beta".into()].into();
    let response = direct_service_after_grant_change(client(), changed).await;
    assert_eq!(response.error.unwrap().code, "PermissionDenied");
    assert!(response.result.is_none());
}

#[tokio::test]
async fn direct_service_rejects_a_grant_expired_during_its_await() {
    let mut changed = permissions();
    changed.expires_at = Some("2000-01-01T00:00:00Z".into());
    let response = direct_service_after_grant_change(client(), changed).await;
    assert_eq!(response.error.unwrap().code, "PermissionDenied");
    assert!(response.result.is_none());
}

#[tokio::test]
async fn direct_service_postcheck_preserves_intrinsic_owner_authority() {
    let changed = Grant {
        expires_at: Some("2000-01-01T00:00:00Z".into()),
        ..Grant::default()
    };
    let response = direct_service_after_grant_change(Principal::owner(), changed).await;
    assert!(response.error.is_none());
    let result = response.result.unwrap();
    assert_eq!(result["payload"], PAYLOAD);
    assert_eq!(result["principal"]["id"], "owner");
    assert_eq!(result["principal"]["kind"], "owner");
}

async fn invoke(
    engine: &Arc<Engine>,
    principal: Principal,
    method: &str,
    params: Value,
) -> CoreResult<Value> {
    let response = engine
        .handle(
            principal,
            Request {
                id: uuid::Uuid::new_v4().to_string(),
                method: method.into(),
                params,
            },
        )
        .await;
    match response.error {
        Some(error) => Err(error),
        None => Ok(response.result.unwrap()),
    }
}
async fn call(engine: &Arc<Engine>, method: &str, params: Value) -> Value {
    invoke(engine, client(), method, params).await.unwrap()
}
fn schedule(method: &str) -> Value {
    json!({"kind":"service","method":method,"input":{"account_id":"alpha","marker":INPUT_MARKER},
        "run_at":(Utc::now()-Duration::seconds(1)).to_rfc3339(),"deadline_window_seconds":60})
}
async fn job(engine: &Arc<Engine>, method: &str) -> String {
    call(engine, "jobs.schedule", schedule(method)).await["job_id"]
        .as_str()
        .unwrap()
        .into()
}
fn edit_job(dir: &std::path::Path, id: &str, edit: impl FnOnce(&mut Value)) {
    let db = Connection::open(dir.join("dansheng.db")).unwrap();
    let text: String = db
        .query_row("SELECT data FROM jobs WHERE id=?", [id], |r| r.get(0))
        .unwrap();
    let mut data: Value = serde_json::from_str(&text).unwrap();
    edit(&mut data);
    db.execute(
        "UPDATE jobs SET data=? WHERE id=?",
        params![data.to_string(), id],
    )
    .unwrap();
}

#[tokio::test]
async fn persistent_reads_and_crashed_leases_restart_as_original_caller() {
    let (dir, engine, fixture) = setup();
    let canvas = job(&engine, "canvas.courses.sync").await;
    let mail = job(&engine, "mail.sync").await;
    engine.store.claim_job(&mail).unwrap().unwrap(); // crash after durable claim
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
    drop(engine);
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    assert_eq!(
        engine.store.job(&mail).unwrap().unwrap()["state"],
        "needs_reconciliation"
    );
    engine.register_service(fixture.clone()).unwrap();
    assert_eq!(engine.tick().await.unwrap(), 2);
    for id in [canvas, mail] {
        let status = call(&engine, "jobs.status", json!({"job_id":id})).await;
        assert_eq!(status["state"], "succeeded");
        assert_eq!(status["result"]["principal"]["id"], client().id);
        assert_eq!(status["result"]["principal"]["kind"], "mcp");
        assert_eq!(status["result"]["granted_accounts"], json!(["alpha"]));
    }
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 2);
    let audit = serde_json::to_string(&engine.store.events(0).unwrap()).unwrap();
    assert!(!audit.contains(INPUT_MARKER));
    assert!(!audit.contains(PAYLOAD));
}

#[tokio::test]
async fn trusted_directory_rejects_builtin_write_and_claimed_readonly_rpc() {
    let (_dir, engine, fixture) = setup();
    for method in [
        "mail.send",
        "mail.set_flags",
        "fixture.configure",
        "http.request",
        "permissions.set",
        "jobs.schedule",
        "unregistered.read",
    ] {
        let response = invoke(
            &engine,
            Principal::owner(),
            "jobs.schedule",
            schedule(method),
        )
        .await;
        assert!(response.is_err(), "must reject {method}");
    }
    for field in [
        "readOnly",
        "required_capability",
        "owner",
        "principal",
        "plugin_id",
        "_native",
    ] {
        let mut input = schedule("mail.read");
        input[field] = json!("forged");
        assert!(
            invoke(&engine, Principal::owner(), "jobs.schedule", input)
                .await
                .is_err()
        );
    }
    let mut input = schedule("mail.read");
    input["input"]["account_id"] = json!("beta");
    assert_eq!(
        invoke(&engine, client(), "jobs.schedule", input)
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    assert!(engine.store.jobs().unwrap().is_empty());
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn native_dedup_includes_method_account_and_checks_explicit_input_conflicts() {
    let (_dir, engine, _fixture) = setup();
    let original = call(&engine, "jobs.schedule", schedule("mail.read")).await;
    let duplicate = call(&engine, "jobs.schedule", schedule("mail.read")).await;
    assert_eq!(original["job_id"], duplicate["job_id"]);
    let distinct = call(&engine, "jobs.schedule", schedule("mail.sync")).await;
    assert_ne!(original["job_id"], distinct["job_id"]);
    let mut explicit = schedule("mail.read");
    explicit["dedup_key"] = json!("synthetic-key");
    call(&engine, "jobs.schedule", explicit.clone()).await;
    explicit["input"]["marker"] = json!("different input");
    assert_eq!(
        invoke(&engine, client(), "jobs.schedule", explicit)
            .await
            .unwrap_err()
            .code,
        "JobDedupConflict"
    );
}

#[tokio::test]
async fn cached_results_recheck_mail_source_permissions_accounts_and_owner() {
    let (_dir, engine, _fixture) = setup();
    let id = job(&engine, "mail.sync").await;
    call(&engine, "jobs.run", json!({"job_id":id})).await;
    let mut revoked = permissions();
    revoked.capabilities.remove("mail.read");
    engine.store.set_grant(&client().id, &revoked).unwrap();
    assert_eq!(
        invoke(&engine, client(), "jobs.status", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    assert!(
        call(&engine, "jobs.status", json!({}))
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
    let mut foreign = permissions();
    foreign.account_ids = ["beta".into()].into();
    engine.store.set_grant(&client().id, &foreign).unwrap();
    assert_eq!(
        invoke(&engine, client(), "jobs.status", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    let outsider = Principal {
        id: "another-reader".into(),
        kind: PrincipalKind::Mcp,
    };
    engine
        .store
        .set_grant(&outsider.id, &permissions())
        .unwrap();
    assert_eq!(
        invoke(&engine, outsider, "jobs.status", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "NotFound"
    );
    engine
        .store
        .set_grant(&client().id, &permissions())
        .unwrap();
    assert_eq!(
        call(&engine, "jobs.status", json!({"job_id":id})).await["result"]["payload"],
        PAYLOAD
    );
}

#[tokio::test]
async fn source_scope_revocation_and_new_source_labels_hide_existing_results() {
    let (_dir, engine, _fixture) = setup();
    let mut granted = permissions();
    granted.source_ids.insert("mail.synthetic".into());
    engine.store.set_grant(&client().id, &granted).unwrap();
    let id = job(&engine, "mail.read").await;
    call(&engine, "jobs.run", json!({"job_id":id})).await;
    engine
        .store
        .set_grant(&client().id, &permissions())
        .unwrap();
    assert!(
        invoke(&engine, client(), "jobs.status", json!({"job_id":id}))
            .await
            .is_err()
    );
    engine.store.set_grant(&client().id, &granted).unwrap();
    engine
        .store
        .require_source_capabilities(
            "service:fixture",
            "mail.synthetic",
            &["private.read".into()].into(),
        )
        .unwrap();
    assert_eq!(
        invoke(&engine, client(), "jobs.status", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    granted.capabilities.insert("private.read".into());
    engine.store.set_grant(&client().id, &granted).unwrap();
    assert_eq!(
        call(&engine, "jobs.status", json!({"job_id":id})).await["result"]["payload"],
        PAYLOAD
    );
}

#[tokio::test]
async fn revoked_owner_authority_is_not_elevated_by_tick_or_owner_run() {
    let (_dir, engine, fixture) = setup();
    let id = job(&engine, "mail.read").await;
    let mut revoked = permissions();
    revoked.capabilities.remove("mail.read");
    engine.store.set_grant(&client().id, &revoked).unwrap();
    assert_eq!(
        invoke(
            &engine,
            Principal::owner(),
            "jobs.run",
            json!({"job_id":id})
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "waiting_for_approval"
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
    assert_eq!(engine.tick().await.unwrap(), 0);
    engine
        .store
        .set_grant(&client().id, &permissions())
        .unwrap();
    call(&engine, "jobs.resume", json!({"job_id":id})).await;
    engine.tick().await.unwrap();
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn imported_bindings_and_serialized_capabilities_do_not_authorize_recovery() {
    let (dir, engine, fixture) = setup();
    let id = job(&engine, "mail.read").await;
    engine.store.claim_job(&id).unwrap().unwrap();
    edit_job(dir.path(), &id, |data| {
        data["required_capability"] = json!("jobs.status");
    });
    engine
        .store
        .set_grant(&client().id, &Grant::default())
        .unwrap();
    drop(engine);
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine.register_service(fixture.clone()).unwrap();
    assert_eq!(engine.tick().await.unwrap(), 0);
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "waiting_for_approval"
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
    engine
        .store
        .set_grant(&client().id, &permissions())
        .unwrap();
    call(&engine, "jobs.resume", json!({"job_id":id})).await;
    engine.store.claim_job(&id).unwrap().unwrap();
    edit_job(dir.path(), &id, |data| {
        data["method"] = json!("mail.send");
        data["_native"]["method"] = json!("mail.send");
        data["_native"]["capability"] = json!("mail.read");
    });
    drop(engine);
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine.register_service(fixture.clone()).unwrap();
    engine.tick().await.unwrap();
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "needs_reconciliation"
    );
    assert!(
        invoke(
            &engine,
            Principal::owner(),
            "jobs.cancel",
            json!({"job_id":id})
        )
        .await
        .is_err()
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn recovery_waits_for_a_live_matching_service_directory() {
    let (dir, engine, fixture) = setup();
    let id = job(&engine, "fudan.timetable.sync").await;
    engine.store.claim_job(&id).unwrap().unwrap();
    drop(engine);
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    assert_eq!(engine.tick().await.unwrap(), 0);
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "needs_reconciliation"
    );
    engine.register_service(fixture.clone()).unwrap();
    assert_eq!(engine.tick().await.unwrap(), 1);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn changed_directory_capability_cannot_reauthorize_an_old_receipt() {
    let (dir, engine, fixture) = setup();
    let id = job(&engine, "mail.read").await;
    engine.store.claim_job(&id).unwrap().unwrap();
    drop(engine);
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine
        .register_service(Arc::new(DirectoryFixture {
            fixture: fixture.clone(),
            entries: vec![("mail.read", "canvas.read")],
        }))
        .unwrap();
    assert_eq!(engine.tick().await.unwrap(), 0);
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "needs_reconciliation"
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn recovery_cursor_prevents_missing_services_starving_other_native_reads() {
    let (dir, engine, fixture) = setup();
    let db = Connection::open(dir.path().join("dansheng.db")).unwrap();
    for index in 0..65 {
        let mut input = schedule("mail.read");
        input["input"]["index"] = json!(index);
        let id = call(&engine, "jobs.schedule", input).await["job_id"]
            .as_str()
            .unwrap()
            .to_owned();
        engine.store.claim_job(&id).unwrap().unwrap();
        db.execute(
            "UPDATE jobs SET id=? WHERE id=?",
            params![format!("a-blocked-{index:03}"), id],
        )
        .unwrap();
    }
    let ready = job(&engine, "canvas.courses.sync").await;
    engine.store.claim_job(&ready).unwrap().unwrap();
    db.execute("UPDATE jobs SET id='z-ready' WHERE id=?", [ready])
        .unwrap();
    drop(db);
    drop(engine);
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine
        .register_service(Arc::new(DirectoryFixture {
            fixture: fixture.clone(),
            entries: vec![("canvas.courses.sync", "canvas.read")],
        }))
        .unwrap();
    assert_eq!(engine.tick().await.unwrap(), 0);
    assert_eq!(engine.tick().await.unwrap(), 1);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        engine.store.job("z-ready").unwrap().unwrap()["state"],
        "succeeded"
    );
}

#[tokio::test]
async fn actual_snapshot_restore_keeps_service_jobs_paused_until_explicit_regrant() {
    let (_source, engine, fixture) = setup();
    let id = job(&engine, "mail.sync").await;
    let snapshot = dansheng_core::backup::create(&engine.store).unwrap();
    let target = tempfile::tempdir().unwrap();
    let profile = target.path().join("synthetic-restored-profile");
    dansheng_core::backup::restore(
        &profile,
        std::path::Path::new(snapshot["path"].as_str().unwrap()),
    )
    .unwrap();
    let restored = Engine::open(&profile, Arc::new(UnavailablePlatform)).unwrap();
    restored.register_service(fixture.clone()).unwrap();
    assert!(
        restored
            .store
            .grant(&client().id)
            .unwrap()
            .capabilities
            .is_empty()
    );
    assert_eq!(restored.tick().await.unwrap(), 0);
    assert_eq!(
        restored.store.job(&id).unwrap().unwrap()["state"],
        "waiting_for_approval"
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
    restored
        .store
        .set_grant(&client().id, &permissions())
        .unwrap();
    assert_eq!(restored.tick().await.unwrap(), 0);
    call(&restored, "jobs.resume", json!({"job_id":id})).await;
    assert_eq!(restored.tick().await.unwrap(), 1);
    assert_eq!(
        call(&restored, "jobs.status", json!({"job_id":id})).await["result"]["principal"]["id"],
        client().id
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancellation_drops_read_future_and_competing_leases_do_not_duplicate_calls() {
    let (_dir, engine, fixture) = setup();
    fixture.mode.store(1, Ordering::SeqCst);
    let id = job(&engine, "mail.read").await;
    let runner = engine.clone();
    let run_id = id.clone();
    let first = tokio::spawn(async move {
        invoke(&runner, client(), "jobs.run", json!({"job_id":run_id})).await
    });
    fixture.entered().await;
    assert_eq!(
        invoke(&engine, client(), "jobs.run", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "JobNotRunnable"
    );
    assert_eq!(
        call(&engine, "jobs.cancel", json!({"job_id":id})).await["state"],
        "cancelled"
    );
    assert_eq!(
        tokio::time::timeout(StdDuration::from_secs(5), first)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err()
            .code,
        "Cancelled"
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    assert_eq!(fixture.dropped.load(Ordering::SeqCst), 1);
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "cancelled"
    );
    assert_eq!(engine.tick().await.unwrap(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn inflight_permission_revocation_aborts_read_and_never_returns_cached_payload() {
    let (_dir, engine, fixture) = setup();
    fixture.mode.store(1, Ordering::SeqCst);
    let id = job(&engine, "mail.read").await;
    let runner = engine.clone();
    let run_id = id.clone();
    let running = tokio::spawn(async move {
        invoke(&runner, client(), "jobs.run", json!({"job_id":run_id})).await
    });
    fixture.entered().await;
    let mut revoked = permissions();
    revoked.account_ids.clear();
    engine.store.set_grant(&client().id, &revoked).unwrap();
    let response = tokio::time::timeout(StdDuration::from_secs(5), running)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(response.unwrap_err().code, "PermissionDenied");
    let stored = engine.store.job(&id).unwrap().unwrap();
    assert_eq!(stored["state"], "waiting_for_approval");
    assert!(!stored["result"].to_string().contains(PAYLOAD));
    assert_eq!(fixture.dropped.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn read_revocation_does_not_prevent_cancelling_owned_future_work() {
    let (_dir, engine, fixture) = setup();
    let id = job(&engine, "mail.read").await;
    let mut revoked = permissions();
    revoked.capabilities.remove("mail.read");
    revoked.account_ids.clear();
    engine.store.set_grant(&client().id, &revoked).unwrap();
    assert!(
        invoke(&engine, client(), "jobs.status", json!({"job_id":id}))
            .await
            .is_err()
    );
    let receipt = call(&engine, "jobs.cancel", json!({"job_id":id})).await;
    assert_eq!(receipt["state"], "cancelled");
    assert!(receipt.get("data").is_none());
    assert!(receipt.get("result").is_none());
    assert_eq!(engine.tick().await.unwrap(), 0);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropped_job_rpc_requeues_only_read_lease_and_can_resume() {
    let (_dir, engine, fixture) = setup();
    fixture.mode.store(1, Ordering::SeqCst);
    let id = job(&engine, "mail.read").await;
    let runner = engine.clone();
    let run_id = id.clone();
    let running = tokio::spawn(async move {
        invoke(&runner, client(), "jobs.run", json!({"job_id":run_id})).await
    });
    fixture.entered().await;
    running.abort();
    let _ = running.await;
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "scheduled"
    );
    fixture.mode.store(0, Ordering::SeqCst);
    assert_eq!(engine.tick().await.unwrap(), 1);
    assert_eq!(
        call(&engine, "jobs.status", json!({"job_id":id})).await["state"],
        "succeeded"
    );
}

#[tokio::test]
async fn authentication_pause_requires_explicit_resume_and_has_no_password_retry() {
    let (_dir, engine, fixture) = setup();
    fixture.mode.store(2, Ordering::SeqCst);
    let id = job(&engine, "canvas.courses.sync").await;
    assert_eq!(
        invoke(&engine, client(), "jobs.run", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "AuthenticationRequired"
    );
    assert_eq!(
        engine.store.job(&id).unwrap().unwrap()["state"],
        "waiting_for_auth"
    );
    for _ in 0..3 {
        assert_eq!(engine.tick().await.unwrap(), 0);
    }
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    fixture.mode.store(0, Ordering::SeqCst);
    call(&engine, "jobs.resume", json!({"job_id":id})).await;
    engine.tick().await.unwrap();
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn periodic_reads_move_deadline_window_and_cancel_prevents_another_period() {
    let (dir, engine, fixture) = setup();
    let mut input = schedule("mail.sync");
    input["interval_seconds"] = json!(15);
    input["deadline_window_seconds"] = json!(10);
    let id = call(&engine, "jobs.schedule", input).await["job_id"]
        .as_str()
        .unwrap()
        .to_owned();
    engine.tick().await.unwrap();
    let current = engine.store.job(&id).unwrap().unwrap();
    assert_eq!(current["state"], "scheduled");
    let run = chrono::DateTime::parse_from_rfc3339(current["run_at"].as_str().unwrap()).unwrap();
    let deadline =
        chrono::DateTime::parse_from_rfc3339(current["data"]["deadline_at"].as_str().unwrap())
            .unwrap();
    assert_eq!((deadline - run).num_seconds(), 10);
    assert_eq!(engine.tick().await.unwrap(), 0);
    // Advance only this synthetic DB's schedule, without waiting 15 wall seconds.
    let due = Utc::now() - Duration::seconds(1);
    edit_job(dir.path(), &id, |data| {
        data["deadline_at"] = json!((due + Duration::seconds(10)).to_rfc3339())
    });
    Connection::open(dir.path().join("dansheng.db"))
        .unwrap()
        .execute(
            "UPDATE jobs SET run_at=? WHERE id=?",
            params![due.to_rfc3339(), id],
        )
        .unwrap();
    engine.tick().await.unwrap();
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 2);
    call(&engine, "jobs.cancel", json!({"job_id":id})).await;
    assert_eq!(engine.tick().await.unwrap(), 0);
}

#[tokio::test]
async fn expired_deadlines_and_large_results_are_bounded() {
    let (_dir, engine, fixture) = setup();
    let mut expired = schedule("mail.read");
    expired["run_at"] = json!((Utc::now() - Duration::seconds(3)).to_rfc3339());
    expired["deadline_window_seconds"] = json!(1);
    let id = call(&engine, "jobs.schedule", expired).await["job_id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        invoke(&engine, client(), "jobs.run", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "DeadlineExceeded"
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
    fixture.mode.store(3, Ordering::SeqCst);
    let id = job(&engine, "mail.read").await;
    assert_eq!(
        invoke(&engine, client(), "jobs.run", json!({"job_id":id}))
            .await
            .unwrap_err()
            .code,
        "JobResultTooLarge"
    );
    assert_eq!(engine.store.job(&id).unwrap().unwrap()["state"], "failed");
    assert!(
        engine.store.job(&id).unwrap().unwrap()["result"]
            .to_string()
            .len()
            < 1024
    );
}

#[tokio::test]
async fn default_plugin_job_and_old_uncertain_plugin_state_remain_compatible() {
    let (_dir, engine, _fixture) = setup();
    let package = tempfile::tempdir().unwrap();
    std::fs::write(package.path().join("manifest.json"), json!({"id":"native-jobs-fixture","name":"Offline fixture","version":"1.0.0","api_version":1,
        "entry":"main.js","capabilities":[],"network":[],"actions":{"read":{"description":"Synthetic local read","mutating":false}}}).to_string()).unwrap();
    std::fs::write(
        package.path().join("main.js"),
        "export async function read(ctx,input){return {synthetic:true};}",
    )
    .unwrap();
    invoke(
        &engine,
        Principal::owner(),
        "plugins.install",
        json!({"path":package.path()}),
    )
    .await
    .unwrap();
    invoke(
        &engine,
        Principal::owner(),
        "plugins.enable",
        json!({"plugin_id":"native-jobs-fixture"}),
    )
    .await
    .unwrap();
    let scheduled = invoke(
        &engine,
        Principal::owner(),
        "jobs.schedule",
        json!({"plugin_id":"native-jobs-fixture","action":"read","input":{}}),
    )
    .await
    .unwrap();
    invoke(
        &engine,
        Principal::owner(),
        "jobs.run",
        json!({"job_id":scheduled["job_id"]}),
    )
    .await
    .unwrap();
    assert_eq!(
        engine
            .store
            .job(scheduled["job_id"].as_str().unwrap())
            .unwrap()
            .unwrap()["result"]["synthetic"],
        true
    );
    let legacy = engine.store.create_job(&client(), &json!({"kind":"service","plugin_id":"old-write","action":"send","input":{"account_id":"alpha"},"readOnly":true}), &(Utc::now()-Duration::seconds(1)).to_rfc3339()).unwrap();
    let lease = engine.store.claim_job(&legacy).unwrap().unwrap();
    engine
        .store
        .finish_job(&legacy, &lease, "needs_reconciliation", &json!({}), None)
        .unwrap();
    assert_eq!(
        invoke(&engine, client(), "jobs.cancel", json!({"job_id":legacy}))
            .await
            .unwrap_err()
            .code,
        "NeedsReconciliation"
    );
    engine.tick().await.unwrap();
    assert_eq!(
        engine.store.job(&legacy).unwrap().unwrap()["state"],
        "needs_reconciliation"
    );
}
