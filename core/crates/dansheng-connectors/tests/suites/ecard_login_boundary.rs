#![cfg(feature = "login")]

use dansheng_connectors::core_adapter::CampusService;
use dansheng_core::{Engine, Principal, PrincipalKind, Request, UnavailablePlatform};
use serde_json::{Value, json};
use std::sync::Arc;

#[tokio::test]
async fn card_login_is_owner_only_and_cannot_be_saved_as_a_native_job() {
    let temp = tempfile::tempdir().unwrap();
    let engine = Engine::open(temp.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    let request = |method: &str, params: Value| Request {
        id: "fixture".into(),
        method: method.into(),
        params,
    };
    let p = Principal {
        id: "plugin:fixture.reader".into(),
        kind: PrincipalKind::Plugin,
    };
    let owner = Principal::owner();
    let cap = json!({"capabilities":["fudan.card.login"],"account_ids":["sample"]});
    let allowed = engine
        .handle(
            owner.clone(),
            request("permissions.set", json!({"subject":p.id,"grant":cap})),
        )
        .await;
    assert!(allowed.error.is_none());
    let session = engine
        .handle(
            owner.clone(),
            request("fudan.ecard.session", json!({"account_id":"sample"})),
        )
        .await;
    assert_eq!(session.result.unwrap()["has_session"], false);
    for method in ["fudan.ecard.login", "fudan.ecard.session"] {
        let denied = engine
            .handle(p.clone(), request(method, json!({"account_id":"sample"})))
            .await;
        assert_eq!(denied.error.unwrap().code, "PermissionDenied");
    }
    let job = engine.handle(owner,request("jobs.schedule",json!({"kind":"service","method":"fudan.ecard.login","account_id":"sample","input":{"account_id":"sample"},"run_at":"2099-01-01T00:00:00Z"}))).await;
    assert!(job.error.is_some());
}
