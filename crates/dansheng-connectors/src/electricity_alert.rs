// SPDX-License-Identifier: GPL-3.0-or-later
//! Per-account low-electricity rule and durable notification outbox. No Android/UI dependencies.
use dansheng_core::{CoreError, CoreResult, store::Store};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
const NS: &str = "official:fudan:electricity-alert:v1";
static STATE_LOCK: Mutex<()> = Mutex::new(());
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct AlertState {
    pub check_interval_seconds: u32,
    pub enabled: bool,
    pub threshold_kwh: f64,
    pub revision: u64,
    pub armed: bool,
    pub last_checked_ms: Option<i64>,
    pub remaining_kwh: Option<f64>,
    pub last_error: Option<String>,
    pub pending_delivery: Option<String>,
    pub last_notified_ms: Option<i64>,
}
impl Default for AlertState {
    fn default() -> Self {
        Self {
            check_interval_seconds: 3600,
            enabled: false,
            threshold_kwh: 5.0,
            revision: 0,
            armed: true,
            last_checked_ms: None,
            remaining_kwh: None,
            last_error: None,
            pending_delivery: None,
            last_notified_ms: None,
        }
    }
}
fn load(store: &Store, account: &str) -> CoreResult<AlertState> {
    let value = store.kv_get(NS, account)?;
    if value.is_null() {
        Ok(AlertState::default())
    } else {
        Ok(serde_json::from_value(value)?)
    }
}
fn save(store: &Store, account: &str, state: &AlertState) -> CoreResult<()> {
    store.kv_set(NS, account, &serde_json::to_value(state)?)
}
fn lock() -> CoreResult<std::sync::MutexGuard<'static, ()>> {
    STATE_LOCK.lock().map_err(|_| {
        CoreError::new(
            "MonitorUnavailable",
            "electricity monitor state unavailable",
        )
    })
}
pub fn get(store: &Store, account: &str) -> CoreResult<AlertState> {
    let _guard = lock()?;
    load(store, account)
}
pub fn configure(
    store: &Store,
    account: &str,
    enabled: bool,
    threshold: f64,
) -> CoreResult<AlertState> {
    if !threshold.is_finite() || threshold <= 0.0 || threshold > 1_000_000.0 {
        return Err(CoreError::invalid("invalid electricity threshold"));
    }
    let _guard = lock()?;
    let mut state = load(store, account)?;
    if state.enabled != enabled || state.threshold_kwh != threshold {
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or_else(|| CoreError::invalid("monitor revision overflow"))?;
        state.armed = true;
        state.pending_delivery = None;
    }
    state.enabled = enabled;
    state.threshold_kwh = threshold;
    save(store, account, &state)?;
    Ok(state)
}
pub fn observe(
    store: &Store,
    account: &str,
    revision: u64,
    value: CoreResult<f64>,
    now: i64,
) -> CoreResult<AlertState> {
    let _guard = lock()?;
    let mut state = load(store, account)?;
    if !state.enabled || state.revision != revision {
        return Ok(state);
    }
    state.last_checked_ms = Some(now);
    match value {
        Ok(remaining) if remaining.is_finite() => {
            state.remaining_kwh = Some(remaining);
            state.last_error = None;
            if remaining > state.threshold_kwh {
                state.armed = true;
                state.pending_delivery = None;
            } else if state.armed && state.pending_delivery.is_none() {
                state.pending_delivery = Some(uuid::Uuid::new_v4().to_string());
            }
        }
        Ok(_) => state.last_error = Some("InvalidBalance".into()),
        Err(error) => state.last_error = Some(error.code),
    }
    save(store, account, &state)?;
    Ok(state)
}
pub fn acknowledge(
    store: &Store,
    account: &str,
    delivery: &str,
    now: i64,
) -> CoreResult<AlertState> {
    let _guard = lock()?;
    let mut state = load(store, account)?;
    if state.enabled && state.pending_delivery.as_deref() == Some(delivery) {
        state.pending_delivery = None;
        state.armed = false;
        state.last_notified_ms = Some(now);
        save(store, account, &state)?;
    }
    Ok(state)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn low_episode_notifies_once_and_rearms_after_recharge() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let s = configure(&store, "a", true, 5.0).unwrap();
        let first = observe(&store, "a", s.revision, Ok(5.0), 1).unwrap();
        let key = first.pending_delivery.unwrap();
        assert_eq!(
            observe(&store, "a", s.revision, Ok(4.0), 2)
                .unwrap()
                .pending_delivery
                .as_deref(),
            Some(key.as_str())
        );
        acknowledge(&store, "a", &key, 3).unwrap();
        assert!(
            observe(&store, "a", s.revision, Ok(3.0), 4)
                .unwrap()
                .pending_delivery
                .is_none()
        );
        observe(&store, "a", s.revision, Ok(20.0), 5).unwrap();
        assert!(
            observe(&store, "a", s.revision, Ok(-2.0), 6)
                .unwrap()
                .pending_delivery
                .is_some()
        );
    }
    #[test]
    fn disable_account_isolation_failures_and_obsolete_reads_are_safe() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let s = configure(&store, "a", true, 5.0).unwrap();
        assert!(!get(&store, "b").unwrap().enabled);
        let failure = observe(
            &store,
            "a",
            s.revision,
            Err(CoreError::new("AuthenticationRequired", "not exported")),
            1,
        )
        .unwrap();
        assert!(failure.remaining_kwh.is_none());
        assert!(failure.pending_delivery.is_none());
        let changed = configure(&store, "a", false, 5.0).unwrap();
        assert!(
            observe(&store, "a", s.revision, Ok(0.0), 2)
                .unwrap()
                .pending_delivery
                .is_none()
        );
        assert!(!changed.enabled);
        assert!(configure(&store, "a", true, f64::NAN).is_err());
        assert!(configure(&store, "a", true, 0.0).is_err());
        let before = configure(&store, "a", true, 3.0).unwrap();
        configure(&store, "a", true, 8.0).unwrap();
        let stale = observe(&store, "a", before.revision, Ok(0.0), 3).unwrap();
        assert_eq!(stale.threshold_kwh, 8.0);
        assert!(stale.pending_delivery.is_none());
    }
    #[test]
    fn outbox_survives_reopen_until_delivery_acknowledgment() {
        let dir = tempfile::tempdir().unwrap();
        let key = {
            let store = Store::open(dir.path()).unwrap();
            let s = configure(&store, "a", true, 5.0).unwrap();
            observe(&store, "a", s.revision, Ok(1.0), 1)
                .unwrap()
                .pending_delivery
                .unwrap()
        };
        let store = Store::open(dir.path()).unwrap();
        assert_eq!(
            get(&store, "a").unwrap().pending_delivery,
            Some(key.clone())
        );
        acknowledge(&store, "a", &key, 2).unwrap();
        assert!(!get(&store, "a").unwrap().armed);
    }
}
