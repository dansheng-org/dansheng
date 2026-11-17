use async_trait::async_trait;
use dansheng_core::{
    CoreResult, Engine, PlatformPort, Principal, PrincipalKind, Request, Response,
};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::Notify;

struct Gate {
    entered: Notify,
    release: Notify,
    calls: AtomicUsize,
}
#[async_trait]
impl PlatformPort for Gate {
    fn capabilities(&self) -> Vec<String> {
        vec!["notifications.show".into()]
    }
    async fn call(&self, _: &str, _: Value) -> CoreResult<Value> {
        if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
            self.entered.notify_one();
            self.release.notified().await;
        }
        Ok(json!({}))
    }
}
struct Harness {
    engine: Arc<Engine>,
    gate: Arc<Gate>,
    _profile: tempfile::TempDir,
    _package: tempfile::TempDir,
}
async fn rpc(e: &Arc<Engine>, p: Principal, method: &str, params: Value) -> Response {
    e.handle(
        p,
        Request {
            id: "claim-fixture".into(),
            method: method.into(),
            params,
        },
    )
    .await
}
async fn setup() -> Harness {
    let profile = tempfile::tempdir().unwrap();
    let package = tempfile::tempdir().unwrap();
    let gate = Arc::new(Gate {
        entered: Notify::new(),
        release: Notify::new(),
        calls: AtomicUsize::new(0),
    });
    let engine = Engine::open(profile.path(), gate.clone()).unwrap();
    let caps = json!(["notifications.show", "storage.read", "storage.write"]);
    std::fs::write(package.path().join("manifest.json"),json!({"id":"claim-fixture","version":"1.0.0","api_version":1,"entry":"main.js","name":"Atomic invocation fixture","capabilities":caps,"network":[],"actions":{"hold":{"description":"Block synthetic work","mutating":false},"increment":{"description":"Count local execution","mutating":false}}}).to_string()).unwrap();
    std::fs::write(package.path().join("main.js"),"export async function hold(ctx){await ctx.notifications.show({title:'fixture'});return 'held';} export async function increment(ctx){const value=(await ctx.storage.get({key:'count'})||0)+1;await ctx.storage.set({key:'count',value});return value;}").unwrap();
    for (method, input) in [
        ("plugins.install", json!({"path":package.path()})),
        (
            "permissions.set",
            json!({"subject":"plugin:claim-fixture","grant":{"capabilities":caps,"account_ids":["fixture"]}}),
        ),
        ("plugins.enable", json!({"plugin_id":"claim-fixture"})),
    ] {
        assert!(
            rpc(&engine, Principal::owner(), method, input)
                .await
                .error
                .is_none()
        );
    }
    Harness {
        engine,
        gate,
        _profile: profile,
        _package: package,
    }
}
fn invoke(e: &Arc<Engine>, p: Principal, action: &str) -> tokio::task::JoinHandle<Response> {
    let e = e.clone();
    let input = json!({"plugin_id":"claim-fixture","action":action,"input":{"account_id":"fixture","task_id":"same-workflow"}});
    tokio::spawn(async move { rpc(&e, p, "plugins.run", input).await })
}
async fn waiting(e: &Arc<Engine>, action: &str) -> Value {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(job) = e
                .store
                .jobs()
                .unwrap()
                .into_iter()
                .find(|job| job["data"]["action"] == action)
            {
                return job;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap()
}
async fn entered(gate: &Gate) {
    tokio::time::timeout(Duration::from_secs(5), gate.entered.notified())
        .await
        .unwrap();
}
async fn finish(task: tokio::task::JoinHandle<Response>) -> Response {
    tokio::time::timeout(Duration::from_secs(5), task)
        .await
        .unwrap()
        .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn immediate_invocation_is_reserved_before_waiting_for_workflow_and_tick_cannot_steal_it() {
    let h = setup().await;
    let first = invoke(&h.engine, Principal::owner(), "hold");
    entered(&h.gate).await;
    let second = invoke(&h.engine, Principal::owner(), "increment");
    let pending = waiting(&h.engine, "increment").await;
    assert_eq!(
        pending["state"], "running",
        "direct invocation must already own its durable lease"
    );
    assert!(h.engine.store.due_jobs().unwrap().is_empty());
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), h.engine.tick())
            .await
            .unwrap()
            .unwrap(),
        0
    );
    h.gate.release.notify_one();
    assert_eq!(finish(first).await.result, Some(json!("held")));
    assert_eq!(finish(second).await.result, Some(json!(1)));
    let job = h
        .engine
        .store
        .job(pending["id"].as_str().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(job["state"], "succeeded");
    assert_eq!(job["result"], 1);
    assert_eq!(h.gate.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn simultaneous_duplicate_invocations_do_not_reexecute_after_the_first_finishes() {
    let h = setup().await;
    let first = invoke(&h.engine, Principal::owner(), "hold");
    entered(&h.gate).await;
    let mut duplicate = invoke(&h.engine, Principal::owner(), "hold");
    assert!(
        tokio::time::timeout(Duration::from_millis(40), &mut duplicate)
            .await
            .is_err()
    );
    assert_eq!(h.engine.store.jobs().unwrap().len(), 1);
    h.gate.release.notify_one();
    assert_eq!(finish(first).await.result, Some(json!("held")));
    assert_eq!(
        finish(duplicate).await.error.unwrap().code,
        "JobNotRunnable"
    );
    assert_eq!(h.gate.calls.load(Ordering::SeqCst), 1);
    assert_eq!(h.engine.store.jobs().unwrap().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_a_reserved_invocation_retains_uncertainty_and_never_replays_it() {
    let h = setup().await;
    let first = invoke(&h.engine, Principal::owner(), "hold");
    entered(&h.gate).await;
    let second = invoke(&h.engine, Principal::owner(), "increment");
    let pending = waiting(&h.engine, "increment").await;
    assert_eq!(pending["state"], "running");
    second.abort();
    assert!(second.await.unwrap_err().is_cancelled());
    assert_eq!(
        h.engine
            .store
            .job(pending["id"].as_str().unwrap())
            .unwrap()
            .unwrap()["state"],
        "needs_reconciliation"
    );
    h.gate.release.notify_one();
    assert!(finish(first).await.error.is_none());
    assert_eq!(h.engine.tick().await.unwrap(), 0);
    assert!(
        h.engine
            .store
            .job(pending["id"].as_str().unwrap())
            .unwrap()
            .unwrap()["result"]["error"]
            .is_object()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reserved_invocation_rechecks_original_caller_authority_before_execution() {
    let h = setup().await;
    let client = Principal {
        id: "reader".into(),
        kind: PrincipalKind::Client,
    };
    assert!(rpc(&h.engine,Principal::owner(),"permissions.set",json!({"subject":"reader","grant":{"capabilities":["plugins.run","plugin:claim-fixture:increment","storage.read","storage.write"],"account_ids":["fixture"]}})).await.error.is_none());
    let first = invoke(&h.engine, Principal::owner(), "hold");
    entered(&h.gate).await;
    let second = invoke(&h.engine, client, "increment");
    let pending = waiting(&h.engine, "increment").await;
    assert_eq!(pending["state"], "running");
    assert!(
        rpc(
            &h.engine,
            Principal::owner(),
            "permissions.set",
            json!({"subject":"reader","grant":{}})
        )
        .await
        .error
        .is_none()
    );
    h.gate.release.notify_one();
    assert!(finish(first).await.error.is_none());
    assert_eq!(finish(second).await.error.unwrap().code, "PermissionDenied");
    assert_eq!(
        h.engine
            .store
            .job(pending["id"].as_str().unwrap())
            .unwrap()
            .unwrap()["state"],
        "waiting_for_approval"
    );
}

#[tokio::test]
async fn immediate_run_does_not_preempt_a_future_scheduled_duplicate() {
    let h = setup().await;
    let queued=rpc(&h.engine,Principal::owner(),"jobs.schedule",json!({"plugin_id":"claim-fixture","action":"increment","input":{"account_id":"fixture","task_id":"same-workflow"},"run_at":"2099-01-01T00:00:00Z"})).await;
    assert!(queued.error.is_none());
    let job_id = queued.result.unwrap()["job_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let response = finish(invoke(&h.engine, Principal::owner(), "increment")).await;
    assert_eq!(response.error.unwrap().code, "JobNotRunnable");
    assert_eq!(
        h.engine.store.job(&job_id).unwrap().unwrap()["state"],
        "scheduled"
    );
    assert_eq!(h.engine.store.jobs().unwrap().len(), 1);
    assert_eq!(h.gate.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_custom_dedup_collision_cannot_execute_a_different_action() {
    use sha2::{Digest, Sha256};
    let h = setup().await;
    let input = json!({"account_id":"fixture","task_id":"same-workflow"});
    let wanted = json!({"plugin_id":"claim-fixture","action":"increment","input":input,"interval_seconds":null});
    let dedup = hex::encode(Sha256::digest(wanted.to_string()));
    let queued = rpc(
        &h.engine,
        Principal::owner(),
        "jobs.schedule",
        json!({"plugin_id":"claim-fixture","action":"hold","input":input,"dedup_key":dedup}),
    )
    .await;
    assert!(queued.error.is_none());
    let response = finish(invoke(&h.engine, Principal::owner(), "increment")).await;
    assert_eq!(response.error.unwrap().code, "JobDefinitionConflict");
    assert_eq!(h.gate.calls.load(Ordering::SeqCst), 0);
    assert_eq!(h.engine.store.jobs().unwrap().len(), 1);
    assert_eq!(h.engine.store.jobs().unwrap()[0]["state"], "scheduled");
}
