//! Persistent, bounded native reads. No arbitrary Engine RPC is executable here.
use super::*;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use tokio::sync::watch;

pub(super) type Running = HashMap<String, (String, watch::Sender<bool>)>;
const MAX_INPUT: usize = 1024 * 1024;
const MAX_RESULT: usize = 4 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    version: u32,
    owner: Principal,
    method: String,
    capability: String,
    account_id: String,
    input_sha256: String,
    read_capabilities: BTreeSet<String>,
    source_ids: BTreeSet<String>,
}

pub(super) fn is_native(job: &Value) -> bool {
    let data = &job["data"];
    // Legacy plugin jobs could contain arbitrary extra keys. A kind string must
    // never convert such a job's uncertain external write into a safe read.
    data["kind"] == "service" && data.get("plugin_id").is_none() && data.get("action").is_none()
}

fn read_capability(cap: &str) -> CoreResult<String> {
    if cap.ends_with(".read") {
        Ok(cap.into())
    } else if let Some(prefix) = cap.strip_suffix(".sync") {
        Ok(format!("{prefix}.read"))
    } else {
        Err(CoreError::new(
            "ServiceJobNotReadOnly",
            "service capability is not a read or sync capability",
        ))
    }
}

fn same_principal(a: &Principal, b: &Principal) -> bool {
    a.id == b.id && a.kind == b.kind
}

fn augment(binding: &mut Binding, grant: &Grant) {
    binding.read_capabilities.extend(
        grant
            .capabilities
            .iter()
            .filter(|cap| {
                cap.ends_with(".read") && !matches!(cap.as_str(), "storage.read" | "sources.read")
            })
            .cloned(),
    );
    binding.source_ids.extend(grant.source_ids.iter().cloned());
}

impl Engine {
    fn native_method_capability(&self, method: &str) -> CoreResult<String> {
        let cap = self
            .services
            .read()
            .map_err(|_| CoreError::new("InternalError", "service registry unavailable"))?
            .get(method)
            .map(|(cap, _)| cap.clone())
            .ok_or_else(|| {
                CoreError::new(
                    "ServiceJobUnavailable",
                    "job method is not a registered native service",
                )
            })?;
        read_capability(&cap)?;
        if method.split('.').any(|part| {
            matches!(
                part,
                "configure"
                    | "send"
                    | "set_flags"
                    | "save"
                    | "write"
                    | "set"
                    | "create"
                    | "delete"
                    | "remove"
                    | "update"
                    | "submit"
                    | "cancel"
                    | "reconcile"
            )
        }) {
            return Err(CoreError::new(
                "ServiceJobNotReadOnly",
                "mutating service methods cannot be scheduled as reads",
            ));
        }
        Ok(cap)
    }

    fn native_binding(&self, job: &Value) -> CoreResult<Binding> {
        if !is_native(job) {
            return Err(CoreError::invalid("not a native service job"));
        }
        let data = &job["data"];
        let binding: Binding = serde_json::from_value(data["_native"].clone()).map_err(|_| {
            CoreError::new(
                "InvalidServiceJob",
                "native job binding is missing or invalid",
            )
        })?;
        let principal: Principal = serde_json::from_value(job["owner"].clone())?;
        let method = required_string(data, "method")?;
        let account = required_string(&data["input"], "account_id")?;
        let cap = self.native_method_capability(method)?;
        // Serialized required_capability/readOnly claims are never consulted.
        // The receipt must also still agree with the live trusted directory.
        if binding.version != 1
            || !same_principal(&principal, &binding.owner)
            || binding.method != method
            || binding.capability != cap
            || binding.account_id != account
            || account.len() > 256
            || account.chars().any(char::is_control)
            || binding.input_sha256 != input_hash(&data["input"])
            || !data["input"].is_object()
            || serde_json::to_vec(&data["input"])?.len() > MAX_INPUT
            || binding
                .read_capabilities
                .iter()
                .any(|cap| !cap.ends_with(".read"))
        {
            return Err(CoreError::new(
                "InvalidServiceJob",
                "native job method, identity or account binding changed",
            ));
        }
        if let Some(interval) = data.get("interval_seconds")
            && interval
                .as_u64()
                .is_none_or(|v| !(15..=365 * 86400).contains(&v))
        {
            return Err(CoreError::new(
                "InvalidServiceJob",
                "invalid recurring service job interval",
            ));
        }
        let run = DateTime::parse_from_rfc3339(required_string(job, "run_at")?)
            .map_err(|_| CoreError::new("InvalidServiceJob", "invalid service job run time"))?;
        let deadline = DateTime::parse_from_rfc3339(required_string(data, "deadline_at")?)
            .map_err(|_| CoreError::new("InvalidServiceJob", "invalid service job deadline"))?;
        let window = (deadline - run).num_seconds();
        if !(1..=86400).contains(&window)
            || (data.get("interval_seconds").is_some()
                && data["_deadline_window_seconds"].as_i64() != Some(window))
        {
            return Err(CoreError::new(
                "InvalidServiceJob",
                "invalid service job deadline window",
            ));
        }
        Ok(binding)
    }

    fn check_native_read_scope(
        &self,
        principal: &Principal,
        grant: &Grant,
        binding: &Binding,
    ) -> CoreResult<()> {
        grant.check_account(principal, Some(&binding.account_id))?;
        grant.check(principal, &read_capability(&binding.capability)?)?;
        if principal.is_owner() {
            return Ok(());
        }
        for cap in &binding.read_capabilities {
            grant.check(principal, cap)?;
        }
        if !binding.source_ids.is_subset(&grant.source_ids) {
            return Err(CoreError::new(
                "PermissionDenied",
                "native job source scope was revoked",
            ));
        }
        // Sources can acquire stricter labels after a result was produced.
        let labels: Vec<String> = self.store.with(|db| {
            let mut labels = Vec::new();
            for source in &binding.source_ids {
                let mut stmt =
                    db.prepare("SELECT capabilities FROM source_access WHERE source_id=?")?;
                for row in stmt.query_map([source], |r| r.get::<_, String>(0))? {
                    labels.push(row?);
                }
            }
            Ok(labels)
        })?;
        for labels in labels {
            for cap in serde_json::from_str::<BTreeSet<String>>(&labels)? {
                grant.check(principal, &cap)?;
            }
        }
        Ok(())
    }

    pub(super) fn authorize_native_visibility(
        &self,
        viewer: &Principal,
        job: &Value,
    ) -> CoreResult<()> {
        let binding = self.native_binding(job)?;
        if !viewer.is_owner() && !same_principal(viewer, &binding.owner) {
            return Err(CoreError::new("NotFound", "job not found"));
        }
        self.check_native_read_scope(viewer, &self.store.grant(&viewer.id)?, &binding)
    }

    pub(super) fn authorize_native_execution(&self, job: &Value) -> CoreResult<()> {
        let binding = self.native_binding(job)?;
        let grant = self.store.grant(&binding.owner.id)?;
        grant.check(&binding.owner, "jobs.schedule")?;
        grant.check(&binding.owner, &binding.capability)?;
        self.check_native_read_scope(&binding.owner, &grant, &binding)
    }

    pub(super) async fn schedule_native_job(
        self: &Arc<Self>,
        principal: &Principal,
        grant: &Grant,
        mut data: Value,
    ) -> CoreResult<Value> {
        let allowed = [
            "kind",
            "method",
            "input",
            "run_at",
            "deadline_at",
            "deadline_window_seconds",
            "interval_seconds",
            "dedup_key",
            "prepare_at",
            "wake_precision",
        ];
        let object = data
            .as_object()
            .ok_or_else(|| CoreError::invalid("service schedule must be an object"))?;
        if object.keys().any(|key| !allowed.contains(&key.as_str())) {
            return Err(CoreError::invalid("unknown service job schedule field"));
        }
        let method = required_string(&data, "method")?.to_owned();
        let capability = self.native_method_capability(&method)?;
        let account = required_string(&data["input"], "account_id")?.to_owned();
        if account.len() > 256
            || account.chars().any(char::is_control)
            || !data["input"].is_object()
            || serde_json::to_vec(&data["input"])?.len() > MAX_INPUT
        {
            return Err(CoreError::invalid(
                "invalid native job account or input size",
            ));
        }
        let parse_time = |value: &Value| -> CoreResult<DateTime<Utc>> {
            DateTime::parse_from_rfc3339(
                value
                    .as_str()
                    .ok_or_else(|| CoreError::invalid("job time must be RFC3339"))?,
            )
            .map(|v| v.with_timezone(&Utc))
            .map_err(|_| CoreError::invalid("invalid job time"))
        };
        let run = data
            .get("run_at")
            .map(parse_time)
            .transpose()?
            .unwrap_or_else(Utc::now);
        let window = if let Some(deadline) = data.get("deadline_at") {
            (parse_time(deadline)? - run).num_seconds()
        } else {
            data.get("deadline_window_seconds")
                .map(|v| {
                    v.as_i64()
                        .ok_or_else(|| CoreError::invalid("invalid deadline window"))
                })
                .transpose()?
                .unwrap_or(60)
        };
        if !(1..=86400).contains(&window) {
            return Err(CoreError::invalid(
                "deadline window must be 1 second to 24 hours",
            ));
        }
        if let Some(interval) = data.get("interval_seconds")
            && interval
                .as_u64()
                .is_none_or(|v| !(15..=365 * 86400).contains(&v))
        {
            return Err(CoreError::invalid(
                "interval must be 15 seconds to 365 days",
            ));
        }
        let deadline = run
            .checked_add_signed(chrono::Duration::seconds(window))
            .ok_or_else(|| CoreError::invalid("deadline overflow"))?;
        if let Some(prepare) = data.get("prepare_at")
            && parse_time(prepare)? > run
        {
            return Err(CoreError::invalid("prepare time must not follow run time"));
        }
        if let Some(precision) = data.get("wake_precision")
            && !matches!(precision.as_str(), Some("exact" | "inexact"))
        {
            return Err(CoreError::invalid("invalid wake precision"));
        }
        let custom = data
            .get("dedup_key")
            .map(|v| {
                v.as_str()
                    .ok_or_else(|| CoreError::invalid("invalid dedup key"))
            })
            .transpose()?;
        if custom.is_some_and(|v| v.is_empty() || v.len() > 256 || v.chars().any(char::is_control))
        {
            return Err(CoreError::invalid("invalid dedup key"));
        }
        let dedup = format!(
            "native-service:{}",
            input_hash(&json!({"method":method,"account":account,
            "input":if custom.is_none(){data["input"].clone()}else{Value::Null},"key":custom,"interval":data["interval_seconds"]}))
        );
        let mut binding = Binding {
            version: 1,
            owner: principal.clone(),
            method,
            capability,
            account_id: account,
            input_sha256: input_hash(&data["input"]),
            read_capabilities: BTreeSet::new(),
            source_ids: BTreeSet::new(),
        };
        augment(&mut binding, grant);
        data["dedup_key"] = json!(dedup);
        data["deadline_at"] = json!(deadline.to_rfc3339());
        if data.get("interval_seconds").is_some() {
            data["_deadline_window_seconds"] = json!(window);
        }
        data["_native"] = serde_json::to_value(&binding)?;
        let probe = json!({"owner":principal,"data":data,"run_at":run.to_rfc3339()});
        self.authorize_native_execution(&probe)?;
        let id = self.store.create_job(principal, &data, &run.to_rfc3339())?;
        let job = self
            .store
            .job(&id)?
            .ok_or_else(|| CoreError::new("NotFound", "job not found"))?;
        let existing = self.native_binding(&job)?;
        if existing.method != binding.method
            || existing.account_id != binding.account_id
            || existing.input_sha256 != binding.input_sha256
        {
            return Err(CoreError::new(
                "JobDedupConflict",
                "dedup key already belongs to different service inputs",
            ));
        }
        self.authorize_native_visibility(principal, &job)?;
        let wake = self.schedule_wake(&job).await;
        let _ = self.store.event(
            "job_scheduled",
            &json!({"principal":principal.id,"job_id":id,"kind":"service"}),
        );
        Ok(
            json!({"job_id":id,"kind":"service","run_at":job["run_at"],"state":job["state"],"wake_up":wake}),
        )
    }

    pub(super) fn recover_native_jobs(&self) -> CoreResult<()> {
        let query = |cursor: &str| -> CoreResult<Vec<String>> {
            self.store.with(|db| {
            let mut stmt = db.prepare("SELECT id FROM jobs WHERE state='needs_reconciliation' AND json_extract(data,'$.kind')='service' AND id>? ORDER BY id LIMIT 64")?;
            Ok(stmt.query_map([cursor], |r| r.get(0))?.collect::<Result<Vec<_>, _>>()?)
        })
        };
        let saved = self.store.kv_get("core:native-jobs", "recovery_cursor")?;
        let cursor = saved.as_str().unwrap_or("");
        let mut ids = query(cursor)?;
        if ids.is_empty() && !cursor.is_empty() {
            ids = query("")?;
        }
        let last = ids.last().cloned();
        for id in ids {
            let Some(job) = self.store.job(&id)? else {
                continue;
            };
            if !is_native(&job) || self.native_binding(&job).is_err() {
                continue;
            }
            let (state, body) = match self.authorize_native_execution(&job) {
                Ok(()) => ("scheduled", json!({"recovered_native_read":true})),
                Err(_) => (
                    "waiting_for_approval",
                    json!({"error":{"code":"PermissionDenied","message":"native read permission must be restored before resume"}}),
                ),
            };
            self.store.with(|db| {
                db.execute("UPDATE jobs SET state=?,result=?,lease=NULL,updated_at=? WHERE id=? AND state='needs_reconciliation' AND lease IS NULL",
                    params![state, body.to_string(), Utc::now().to_rfc3339(), id])?;
                Ok(())
            })?;
        }
        self.store.kv_set(
            "core:native-jobs",
            "recovery_cursor",
            &json!(last.unwrap_or_default()),
        )?;
        Ok(())
    }

    pub(super) async fn cancel_native_job(&self, job: &Value) -> CoreResult<Value> {
        self.native_binding(job)?; // A kind/readOnly claim alone cannot erase uncertainty.
        let id = required_string(job, "id")?;
        self.store.with(|db| {
            db.execute("UPDATE jobs SET state='cancelled',result=?,lease=NULL,updated_at=? WHERE id=? AND state IN ('scheduled','running','waiting_for_auth','waiting_for_approval','needs_reconciliation')",
                params![json!({"error":{"code":"Cancelled","message":"native read cancelled"}}).to_string(), Utc::now().to_rfc3339(), id])?;
            Ok(())
        })?;
        if let Some((_, cancel)) = self
            .native_running
            .lock()
            .map_err(|_| CoreError::new("InternalError", "native runner lock unavailable"))?
            .get(id)
        {
            let _ = cancel.send(true);
        }
        self.cancel_wake(job).await;
        Ok(json!({"job_id":id,"state":self.store.job(id)?.map(|job|job["state"].clone())}))
    }

    fn native_lease_active(&self, id: &str, lease: &str) -> CoreResult<bool> {
        self.store.with(|db| {
            Ok(db.query_row(
                "SELECT EXISTS(SELECT 1 FROM jobs WHERE id=? AND lease=? AND state='running')",
                params![id, lease],
                |r| r.get(0),
            )?)
        })
    }

    pub(super) async fn run_native_job(self: &Arc<Self>, id: &str) -> CoreResult<Value> {
        let _slot = self
            .native_slots
            .acquire()
            .await
            .map_err(|_| CoreError::new("Shutdown", "native executor stopped"))?;
        let mut job = self
            .store
            .job(id)?
            .ok_or_else(|| CoreError::new("NotFound", "job not found"))?;
        let mut binding = self.native_binding(&job)?;
        let lease = self
            .store
            .claim_job(id)?
            .ok_or_else(|| CoreError::new("JobNotRunnable", "job is not due or already claimed"))?;
        let guard = NativeGuard {
            engine: Arc::downgrade(self),
            id: id.into(),
            lease: lease.clone(),
        };
        let (cancel, mut cancelled) = watch::channel(false);
        self.native_running
            .lock()
            .map_err(|_| CoreError::new("InternalError", "native runner lock unavailable"))?
            .insert(id.into(), (lease.clone(), cancel));
        let result: CoreResult<Value> = async {
            self.authorize_native_execution(&job)?;
            let deadline = DateTime::parse_from_rfc3339(required_string(&job["data"], "deadline_at")?).map_err(|_| CoreError::invalid("invalid deadline"))?;
            let remaining = (deadline.with_timezone(&Utc) - Utc::now()).to_std()
                .map_err(|_| CoreError::new("DeadlineExceeded", "native read deadline expired"))?;
            let execution_grant = self.store.grant(&binding.owner.id)?;
            augment(&mut binding, &execution_grant);
            job["data"]["_native"] = serde_json::to_value(&binding)?;
            self.store.with(|db| {
                db.execute("UPDATE jobs SET data=? WHERE id=? AND lease=? AND state='running'", params![job["data"].to_string(), id, lease])?;
                Ok(())
            })?;
            if !self.native_lease_active(id, &lease)? { return Err(CoreError::new("Cancelled", "native read is no longer active")); }
            let call = self.handle(binding.owner.clone(), Request { id: format!("job:{id}"), method: binding.method.clone(), params: job["data"]["input"].clone() });
            tokio::pin!(call);
            let deadline = tokio::time::sleep(remaining); tokio::pin!(deadline);
            let mut checks = tokio::time::interval(std::time::Duration::from_millis(100));
            loop {
                tokio::select! { biased;
                    _ = cancelled.changed() => return Err(CoreError::new("Cancelled", "native read cancelled")),
                    _ = &mut deadline => return Err(CoreError::new("DeadlineExceeded", "native read deadline expired")),
                    _ = checks.tick() => {
                        if !self.native_lease_active(id, &lease)? { return Err(CoreError::new("Cancelled", "native read is no longer active")); }
                        self.authorize_native_execution(&job)?;
                    },
                    response = &mut call => {
                        self.authorize_native_execution(&job)?;
                        if let Some(error) = response.error { return Err(error); }
                        let value = response.result.unwrap_or(Value::Null);
                        if serde_json::to_vec(&value)?.len() > MAX_RESULT { return Err(CoreError::new("JobResultTooLarge", "native read result exceeds 4 MiB")); }
                        return Ok(value);
                    }
                }
            }
        }.await;
        let (state, body) = match &result {
            Ok(value) => ("succeeded", value.clone()),
            Err(error) => (
                match error.code.as_str() {
                    "AuthenticationRequired" => "waiting_for_auth",
                    "PermissionDenied" | "ApprovalRequired" => "waiting_for_approval",
                    "Cancelled" => "cancelled",
                    "DeadlineExceeded" => "expired",
                    _ => "failed",
                },
                json!({"error":error}),
            ),
        };
        let next = if result.is_ok() {
            job["data"]["interval_seconds"]
                .as_i64()
                .and_then(|s| Utc::now().checked_add_signed(chrono::Duration::seconds(s)))
                .map(|v| v.to_rfc3339())
        } else {
            None
        };
        self.store.finish_job(
            id,
            &lease,
            if next.is_some() { "scheduled" } else { state },
            &body,
            next.as_deref(),
        )?;
        let current = self
            .store
            .job(id)?
            .ok_or_else(|| CoreError::new("NotFound", "job not found"))?;
        if current["state"] == "cancelled" && result.is_ok() {
            return Err(CoreError::new(
                "Cancelled",
                "native read cancelled before its result was committed",
            ));
        }
        if next.is_some() && current["state"] == "scheduled" {
            let _ = self.schedule_wake(&current).await;
        }
        if result.is_ok() {
            self.authorize_native_execution(&current)?;
        }
        let _ = self.store.event(
            "job_finished",
            &json!({"principal":binding.owner.id,"job_id":id,"kind":"service","state":state}),
        );
        drop(guard);
        result
    }
}

struct NativeGuard {
    engine: std::sync::Weak<Engine>,
    id: String,
    lease: String,
}
impl Drop for NativeGuard {
    fn drop(&mut self) {
        if let Some(engine) = self.engine.upgrade() {
            // Only this validated read lease can be replayed. Plugin JobGuard
            // remains unchanged and conservatively records write uncertainty.
            let _ = engine.store.finish_job(
                &self.id,
                &self.lease,
                "scheduled",
                &json!({"error":{"code":"Interrupted","message":"native read will resume"}}),
                None,
            );
            if let Ok(mut running) = engine.native_running.lock()
                && running
                    .get(&self.id)
                    .is_some_and(|(lease, _)| lease == &self.lease)
                && let Some((_, cancel)) = running.remove(&self.id)
            {
                let _ = cancel.send(true);
            }
        }
    }
}
