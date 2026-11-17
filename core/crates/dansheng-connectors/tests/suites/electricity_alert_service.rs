#![cfg(feature = "services")]
use dansheng_connectors::core_adapter::CampusService;
use dansheng_core::{Engine, Principal, PrincipalKind, Request, UnavailablePlatform};
use serde_json::json;
use std::sync::Arc;
#[tokio::test]
async fn reminders_persist_config_but_cannot_be_changed_by_a_readonly_plugin() {
    let dir = tempfile::tempdir().unwrap();
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    let req = |method: &str, params| Request {
        id: "fixture".into(),
        method: method.into(),
        params,
    };
    let owner = Principal::owner();
    let set = engine
        .handle(
            owner.clone(),
            req(
                "fudan.electricity.alert.set",
                json!({
                    "account_id":"fixture","enabled":true,"threshold_kwh":3.5
                }),
            ),
        )
        .await;
    assert!(set.error.is_none());
    assert_eq!(set.result.unwrap()["check_interval_seconds"], 3600);
    let get = engine
        .handle(
            owner.clone(),
            req(
                "fudan.electricity.alert.get",
                json!({"account_id":"fixture"}),
            ),
        )
        .await;
    assert_eq!(get.result.unwrap()["threshold_kwh"], 3.5);
    let plugin = Principal {
        id: "plugin:reader".into(),
        kind: PrincipalKind::Plugin,
    };
    engine
        .handle(
            owner,
            req(
                "permissions.set",
                json!({"subject":"plugin:reader","grant":{
                    "capabilities":["fudan.life.read"],"account_ids":["fixture"]
                }}),
            ),
        )
        .await;
    let denied = engine
        .handle(
            plugin,
            req(
                "fudan.electricity.alert.set",
                json!({"account_id":"fixture","enabled":false,"threshold_kwh":3.5}),
            ),
        )
        .await;
    assert_eq!(denied.error.unwrap().code, "PermissionDenied");
}
