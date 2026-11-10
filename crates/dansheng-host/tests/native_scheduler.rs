//! Real OS IPC and the production Host loop, with synthetic services and profiles.
//! There are no jobs.run calls, Engine.tick calls, remote requests or real vault use.
use async_trait::async_trait;
use chrono::{DateTime, Duration as ClockDelta, Utc};
use dansheng_core::{
    CoreResult, Principal, Response,
    policy::Grant,
    services::{CoreService, ServiceContext},
    store::Store,
};
use dansheng_host::{Client, HostPaths, ServeOptions, serve_with_options};
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    sync::{Semaphore, oneshot},
    task::JoinHandle,
};

const READER: &str = "synthetic-scheduler-reader";
const TOKEN: &str = "synthetic-scheduler-client-token-not-a-real-credential-0001";
const PRIVATE_RESULT: &str = "synthetic-scheduler-private-result";
const PRIVATE_INPUT: &str = "synthetic-scheduler-private-input";
const TICK: Duration = Duration::from_millis(20);

#[derive(Clone)]
struct Invocation {
    at: DateTime<Utc>,
    principal: Principal,
    account: String,
    method: String,
}
struct Source {
    calls: Mutex<Vec<Invocation>>,
    block: AtomicBool,
    active: AtomicUsize,
    aborted: AtomicUsize,
    entered: Semaphore,
    release: Semaphore,
}
impl Source {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            calls: Mutex::new(Vec::new()),
            block: AtomicBool::new(false),
            active: AtomicUsize::new(0),
            aborted: AtomicUsize::new(0),
            entered: Semaphore::new(0),
            release: Semaphore::new(0),
        })
    }
    fn count(&self) -> usize {
        self.calls.lock().unwrap().len()
    }
    async fn entered(&self) {
        tokio::time::timeout(Duration::from_secs(5), self.entered.acquire())
            .await
            .unwrap()
            .unwrap()
            .forget();
    }
}
struct InFlight<'a> {
    source: &'a Source,
    complete: bool,
}
impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.source.active.fetch_sub(1, Ordering::SeqCst);
        if !self.complete {
            self.source.aborted.fetch_add(1, Ordering::SeqCst);
        }
    }
}
#[async_trait]
impl CoreService for Source {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        vec![
            ("fixture.canvas.sync", "canvas.read"),
            ("fixture.campus.sync", "fudan.academic.read"),
            ("fixture.mail.sync", "mail.sync"),
            ("fixture.mail.read", "mail.read"),
        ]
    }
    async fn call(
        &self,
        _: ServiceContext<'_>,
        principal: &Principal,
        _: &Grant,
        method: &str,
        input: Value,
    ) -> CoreResult<Value> {
        self.active.fetch_add(1, Ordering::SeqCst);
        let mut active = InFlight {
            source: self,
            complete: false,
        };
        let sequence = {
            let mut calls = self.calls.lock().unwrap();
            calls.push(Invocation {
                at: Utc::now(),
                principal: principal.clone(),
                account: input["account_id"].as_str().unwrap().to_owned(),
                method: method.into(),
            });
            calls.len()
        };
        self.entered.add_permits(1);
        if self.block.load(Ordering::SeqCst) {
            self.release.acquire().await.unwrap().forget();
        }
        active.complete = true;
        Ok(
            json!({"sequence":sequence,"payload":PRIVATE_RESULT,"principal":principal,"account_id":input["account_id"]}),
        )
    }
}

fn grant() -> Grant {
    let mut grant = Grant::default();
    grant.capabilities.extend(
        [
            "jobs.schedule",
            "jobs.status",
            "jobs.cancel",
            "jobs.resume",
            "canvas.read",
            "fudan.academic.read",
            "mail.read",
            "mail.sync",
        ]
        .map(str::to_owned),
    );
    grant.account_ids.insert("synthetic-account".into());
    grant
}
async fn successful(client: &Client, method: &str, input: Value) -> Value {
    let response = tokio::time::timeout(Duration::from_secs(5), client.invoke(method, input))
        .await
        .unwrap()
        .unwrap();
    if let Some(error) = response.error {
        panic!("synthetic IPC {method} failed: {}", error.code);
    }
    response.result.unwrap_or(Value::Null)
}
async fn response(client: &Client, method: &str, input: Value) -> Response {
    tokio::time::timeout(Duration::from_secs(5), client.invoke(method, input))
        .await
        .unwrap()
        .unwrap()
}
struct Host {
    paths: HostPaths,
    owner: Client,
    stop: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<CoreResult<()>>>,
}
impl Host {
    async fn start(profile: &Path, source: Arc<Source>, grace: Duration) -> Self {
        let paths = HostPaths::new(profile).unwrap();
        let options = ServeOptions {
            services: vec![source],
            tick_interval: TICK,
            shutdown_grace: grace,
        };
        let (stop, stopped) = oneshot::channel();
        let server_paths = paths.clone();
        let task = tokio::spawn(async move {
            serve_with_options(server_paths, options, async {
                let _ = stopped.await;
            })
            .await
        });
        let owner = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Ok(owner) = Client::connect(&paths.owner).await {
                    break owner;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(owner.principal.is_owner());
        Self {
            paths,
            owner,
            stop: Some(stop),
            task: Some(task),
        }
    }
    async fn reader(&self) -> Client {
        Client::connect_token(&self.paths.owner.endpoint, TOKEN.into())
            .await
            .unwrap()
    }
    async fn provision_reader(&self) -> Client {
        successful(
            &self.owner,
            "clients.register",
            json!({"client_id":READER,"kind":"mcp","token":TOKEN}),
        )
        .await;
        self.permissions(grant()).await;
        self.reader().await
    }
    async fn permissions(&self, grant: Grant) {
        successful(
            &self.owner,
            "permissions.set",
            json!({"subject":READER,"grant":grant}),
        )
        .await;
    }
    async fn shutdown(&mut self) {
        self.stop.take().unwrap().send(()).unwrap();
        let task = self.task.take().unwrap();
        tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(task) = &self.task {
            task.abort();
        }
    }
}
fn schedule(method: &str) -> Value {
    json!({"kind":"service","method":method,"input":{"account_id":"synthetic-account","private_marker":PRIVATE_INPUT},"deadline_window_seconds":60})
}
async fn wait_job(client: &Client, id: &str, condition: impl Fn(&Value) -> bool) -> Value {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let status = successful(client, "jobs.status", json!({"job_id":id})).await;
            if condition(&status) {
                break status;
            }
            assert!(
                !matches!(
                    status["state"].as_str(),
                    Some("failed" | "expired" | "needs_reconciliation")
                ),
                "unexpected fixture job state {}",
                status["state"]
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap()
}

/// Test-clock injection ONLY: move this isolated profile's run/deadline together.
/// Never change job identity, input, period, state, lease or result. Host still
/// discovers the due row, claims it and dispatches its real CoreService itself.
fn advance_due(profile: &Path, id: &str, expected_state: &str) {
    let mut db = Connection::open(profile.join("dansheng.db")).unwrap();
    db.busy_timeout(Duration::from_secs(5)).unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();
    let (old, text): (String, String) = tx
        .query_row(
            "SELECT run_at,data FROM jobs WHERE id=? AND state=?",
            params![id, expected_state],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    let previous = DateTime::parse_from_rfc3339(&old)
        .unwrap()
        .with_timezone(&Utc);
    let due = Utc::now() - ClockDelta::seconds(1);
    let mut data: Value = serde_json::from_str(&text).unwrap();
    let deadline = DateTime::parse_from_rfc3339(data["deadline_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    data["deadline_at"] = json!((deadline + (due - previous)).to_rfc3339());
    assert_eq!(
        tx.execute(
            "UPDATE jobs SET run_at=?,data=? WHERE id=? AND state=? AND run_at=?",
            params![due.to_rfc3339(), data.to_string(), id, expected_state, old]
        )
        .unwrap(),
        1
    );
    tx.commit().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn authenticated_ipc_future_job_runs_on_host_timer_as_original_caller() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = host.provision_reader().await;
    let run_at = Utc::now() + ClockDelta::milliseconds(500);
    let mut input = schedule("fixture.canvas.sync");
    input["run_at"] = json!(run_at.to_rfc3339());
    let queued = successful(&reader, "jobs.schedule", input).await;
    let id = queued["job_id"].as_str().unwrap();
    let status = wait_job(&reader, id, |status| status["state"] == "succeeded").await;
    assert_eq!(status["result"]["payload"], PRIVATE_RESULT);
    assert_eq!(status["result"]["principal"]["id"], READER);
    assert_eq!(status["result"]["principal"]["kind"], "mcp");
    let calls = source.calls.lock().unwrap().clone();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].at >= run_at);
    assert_eq!(calls[0].principal.id, READER);
    assert_eq!(calls[0].account, "synthetic-account");
    assert_eq!(calls[0].method, "fixture.canvas.sync");
    let events = successful(&host.owner, "events.poll", json!({})).await;
    assert!(
        events["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|event| event["kind"] == "audit"
                && event["data"]["method"] == "fixture.canvas.sync")
    );
    assert!(!events.to_string().contains("jobs.run"));
    assert!(!events.to_string().contains(PRIVATE_INPUT));
    assert!(!events.to_string().contains(PRIVATE_RESULT));
    assert!(!profile.join("vault").exists());
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn periodic_mail_read_repeats_via_tick_with_due_clock_injection_then_cancels() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = host.provision_reader().await;
    let mut input = schedule("fixture.mail.sync");
    input["interval_seconds"] = json!(15);
    let queued = successful(&reader, "jobs.schedule", input).await;
    let id = queued["job_id"].as_str().unwrap();
    let first = wait_job(&reader, id, |job| {
        job["state"] == "scheduled" && job["result"]["sequence"] == 1
    })
    .await;
    let next = DateTime::parse_from_rfc3339(first["run_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    let deadline = DateTime::parse_from_rfc3339(first["data"]["deadline_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    assert_eq!((deadline - next).num_seconds(), 60);
    assert!(next > Utc::now() + ClockDelta::seconds(10));
    assert_eq!(first["data"]["interval_seconds"], 15);
    advance_due(&profile, id, "scheduled");
    let second = wait_job(&reader, id, |job| {
        job["state"] == "scheduled" && job["result"]["sequence"] == 2
    })
    .await;
    assert_eq!(second["data"]["interval_seconds"], 15);
    assert_eq!(source.count(), 2);
    successful(&reader, "jobs.cancel", json!({"job_id":id})).await;
    advance_due(&profile, id, "cancelled");
    tokio::time::sleep(TICK * 3).await;
    assert_eq!(
        successful(&reader, "jobs.status", json!({"job_id":id})).await["state"],
        "cancelled"
    );
    assert_eq!(source.count(), 2);
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restart_runs_an_unclaimed_persisted_job_without_run_rpc() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = host.provision_reader().await;
    let mut input = schedule("fixture.campus.sync");
    input["run_at"] = json!((Utc::now() + ClockDelta::seconds(60)).to_rfc3339());
    let queued = successful(&reader, "jobs.schedule", input).await;
    let id = queued["job_id"].as_str().unwrap().to_owned();
    host.shutdown().await;
    drop(reader);
    drop(host);
    assert_eq!(source.count(), 0);
    advance_due(&profile, &id, "scheduled");
    let mut restarted = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = restarted.reader().await;
    let done = wait_job(&reader, &id, |job| job["state"] == "succeeded").await;
    assert_eq!(done["owner"]["id"], READER);
    assert_eq!(done["result"]["principal"]["id"], READER);
    assert_eq!(source.count(), 1);
    restarted.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shutdown_aborts_background_read_releases_profile_and_restart_recovers_it() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    source.block.store(true, Ordering::SeqCst);
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(30)).await;
    let reader = host.provision_reader().await;
    let queued = successful(&reader, "jobs.schedule", schedule("fixture.mail.read")).await;
    let id = queued["job_id"].as_str().unwrap().to_owned();
    source.entered().await;
    tokio::time::timeout(Duration::from_secs(2), host.shutdown())
        .await
        .unwrap();
    assert_eq!(source.active.load(Ordering::SeqCst), 0);
    assert_eq!(source.aborted.load(Ordering::SeqCst), 1);
    let store = Store::open(&profile).unwrap();
    assert_eq!(store.job(&id).unwrap().unwrap()["state"], "scheduled");
    drop(store);
    drop(reader);
    drop(host);
    source.block.store(false, Ordering::SeqCst);
    let mut restarted = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = restarted.reader().await;
    let done = wait_job(&reader, &id, |job| job["state"] == "succeeded").await;
    assert_eq!(done["result"]["sequence"], 2);
    assert_eq!(done["result"]["principal"]["id"], READER);
    assert_eq!(source.count(), 2);
    assert_eq!(source.aborted.load(Ordering::SeqCst), 1);
    restarted.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn inflight_permission_revocation_over_ipc_aborts_tick_and_requires_explicit_resume() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    source.block.store(true, Ordering::SeqCst);
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = host.provision_reader().await;
    let queued = successful(&reader, "jobs.schedule", schedule("fixture.mail.read")).await;
    let id = queued["job_id"].as_str().unwrap();
    source.entered().await;
    let mut revoked = grant();
    revoked.capabilities.remove("mail.read");
    host.permissions(revoked).await;
    let paused = wait_job(&host.owner, id, |job| {
        job["state"] == "waiting_for_approval"
    })
    .await;
    assert!(!paused["result"].to_string().contains(PRIVATE_RESULT));
    assert_eq!(source.aborted.load(Ordering::SeqCst), 1);
    let hidden = response(&reader, "jobs.status", json!({"job_id":id})).await;
    assert_eq!(hidden.error.unwrap().code, "PermissionDenied");
    assert!(hidden.result.is_none());
    assert!(
        successful(&reader, "jobs.status", json!({}))
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
    host.permissions(grant()).await;
    source.block.store(false, Ordering::SeqCst);
    assert_eq!(
        successful(&reader, "jobs.status", json!({"job_id":id})).await["state"],
        "waiting_for_approval"
    );
    successful(&reader, "jobs.resume", json!({"job_id":id})).await;
    let done = wait_job(&reader, id, |job| job["state"] == "succeeded").await;
    assert_eq!(done["result"]["sequence"], 2);
    assert_eq!(source.count(), 2);
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn revoked_account_prevents_due_service_dispatch_and_completed_result_leakage() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = host.provision_reader().await;
    let mut input = schedule("fixture.canvas.sync");
    input["run_at"] = json!((Utc::now() + ClockDelta::seconds(60)).to_rfc3339());
    let queued = successful(&reader, "jobs.schedule", input).await;
    let id = queued["job_id"].as_str().unwrap();
    let mut revoked = grant();
    revoked.account_ids = ["another-account".into()].into();
    host.permissions(revoked.clone()).await;
    advance_due(&profile, id, "scheduled");
    wait_job(&host.owner, id, |job| {
        job["state"] == "waiting_for_approval"
    })
    .await;
    assert_eq!(source.count(), 0);
    host.permissions(grant()).await;
    successful(&reader, "jobs.resume", json!({"job_id":id})).await;
    let completed = wait_job(&reader, id, |job| job["state"] == "succeeded").await;
    assert_eq!(completed["result"]["payload"], PRIVATE_RESULT);
    host.permissions(revoked).await;
    let hidden = response(&reader, "jobs.status", json!({"job_id":id})).await;
    assert_eq!(hidden.error.unwrap().code, "PermissionDenied");
    assert!(hidden.result.is_none());
    assert!(
        successful(&reader, "jobs.status", json!({}))
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn idle_authenticated_clients_do_not_hold_host_open_for_shutdown_grace() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    let mut host = Host::start(&profile, source, Duration::from_secs(30)).await;
    let reader = host.provision_reader().await;
    successful(&reader, "core.info", json!({})).await;
    // Both owner and reader stay alive. Without the stop signal these idle
    // connections would use the full 30-second grace.
    tokio::time::timeout(Duration::from_secs(2), host.shutdown())
        .await
        .unwrap();
    let store = Store::open(&profile).unwrap();
    drop(store);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ipc_cancel_interrupts_an_active_background_read_without_resurrection() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    source.block.store(true, Ordering::SeqCst);
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = host.provision_reader().await;
    let queued = successful(&reader, "jobs.schedule", schedule("fixture.mail.read")).await;
    let id = queued["job_id"].as_str().unwrap();
    source.entered().await;
    assert_eq!(
        successful(&reader, "jobs.cancel", json!({"job_id":id})).await["state"],
        "cancelled"
    );
    tokio::time::timeout(Duration::from_secs(2), async {
        while source.active.load(Ordering::SeqCst) != 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(source.aborted.load(Ordering::SeqCst), 1);
    tokio::time::sleep(TICK * 3).await;
    assert_eq!(
        successful(&reader, "jobs.status", json!({"job_id":id})).await["state"],
        "cancelled"
    );
    assert_eq!(source.count(), 1);
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shutdown_still_drains_an_active_foreground_ipc_read_within_grace() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("p");
    let source = Source::new();
    source.block.store(true, Ordering::SeqCst);
    let mut host = Host::start(&profile, source.clone(), Duration::from_secs(2)).await;
    let reader = host.provision_reader().await;
    // This direct read tests foreground drain only. All scheduler tests above
    // queue jobs over IPC and let the host timer execute them independently.
    let request = tokio::spawn(async move {
        response(
            &reader,
            "fixture.mail.read",
            json!({"account_id":"synthetic-account"}),
        )
        .await
    });
    source.entered().await;
    host.stop.take().unwrap().send(()).unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    source.release.add_permits(1);
    let response = tokio::time::timeout(Duration::from_secs(2), request)
        .await
        .unwrap()
        .unwrap();
    assert!(response.error.is_none());
    assert_eq!(response.result.unwrap()["payload"], PRIVATE_RESULT);
    tokio::time::timeout(Duration::from_secs(2), host.task.take().unwrap())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(source.aborted.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn invalid_scheduler_options_fail_before_creating_a_profile() {
    let temp = tempfile::tempdir().unwrap();
    let profile = temp.path().join("not-created");
    let paths = HostPaths::new(&profile).unwrap();
    let options = ServeOptions {
        tick_interval: Duration::ZERO,
        ..ServeOptions::default()
    };
    let error = serve_with_options(paths, options, async {})
        .await
        .unwrap_err();
    assert_eq!(error.code, "InvalidInput");
    assert!(!profile.exists());
}
