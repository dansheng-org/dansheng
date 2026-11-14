use dansheng_core::{
    Engine, Principal, PrincipalKind, Request, UnavailablePlatform, policy::Grant,
};
use serde_json::{Value, json};
use std::sync::Arc;

async fn call(
    engine: &Arc<Engine>,
    principal: Principal,
    method: &str,
    params: Value,
) -> dansheng_core::Response {
    engine
        .handle(
            principal,
            Request {
                id: "route-test".into(),
                method: method.into(),
                params,
            },
        )
        .await
}

#[tokio::test]
async fn routing_policy_requires_owner_and_survives_core_restart() {
    let temp = tempfile::tempdir().unwrap();
    let engine = Engine::open(temp.path(), Arc::new(UnavailablePlatform)).unwrap();
    let routes = json!([{"provider":"fixture","origin":"https://campus.example","gateway_prefix":"https://gateway.example/https/encoded","mode":"gateway"}]);
    let mut grant = Grant::default();
    grant.account_ids.insert("a".into());
    grant.capabilities.insert("http.routes.set".into());
    engine.store.set_grant("plugin:untrusted", &grant).unwrap();
    let untrusted = Principal {
        id: "plugin:untrusted".into(),
        kind: PrincipalKind::Plugin,
    };
    let denied = call(
        &engine,
        untrusted,
        "http.routes.set",
        json!({"account_id":"a","routes":routes}),
    )
    .await;
    assert_eq!(denied.error.unwrap().code, "PermissionDenied");
    assert!(
        call(
            &engine,
            Principal::owner(),
            "http.routes.set",
            json!({"account_id":"a","routes":routes})
        )
        .await
        .error
        .is_none()
    );
    drop(engine);
    let engine = Engine::open(temp.path(), Arc::new(UnavailablePlatform)).unwrap();
    let loaded = call(
        &engine,
        Principal::owner(),
        "http.routes.get",
        json!({"account_id":"a"}),
    )
    .await;
    assert_eq!(loaded.result.unwrap()["routes"], routes);
    let invalid=call(&engine,Principal::owner(),"http.routes.set",json!({"account_id":"a","routes":[{"provider":"fixture","origin":"https://campus.example","gateway_prefix":"http://gateway.example/unsafe","mode":"gateway"}]})).await;
    assert_eq!(invalid.error.unwrap().code, "InvalidInput");
    let unchanged = call(
        &engine,
        Principal::owner(),
        "http.routes.get",
        json!({"account_id":"a"}),
    )
    .await;
    assert_eq!(unchanged.result.unwrap()["routes"], routes);
}

#[tokio::test]
async fn logical_destination_grants_are_checked_before_gateway_io() {
    let temp = tempfile::tempdir().unwrap();
    let engine = Engine::open(temp.path(), Arc::new(UnavailablePlatform)).unwrap();
    let mut grant = Grant::default();
    grant.account_ids.insert("a".into());
    grant.capabilities.insert("http.request".into());
    grant.origins.insert("https://gateway.example".into());
    engine.store.set_grant("reader", &grant).unwrap();
    let routes = json!([{"provider":"fixture","origin":"https://campus.example","gateway_prefix":"https://gateway.example/https/encoded","mode":"gateway"}]);
    assert!(
        call(
            &engine,
            Principal::owner(),
            "http.routes.set",
            json!({"account_id":"a","routes":routes})
        )
        .await
        .error
        .is_none()
    );
    for url in [
        "https://campus.example/private",
        "https://gateway.example/https/encoded/private",
        "https://gateway.example/https/unregistered/private",
    ] {
        let response = call(
            &engine,
            Principal {
                id: "reader".into(),
                kind: PrincipalKind::Client,
            },
            "http.request",
            json!({"account_id":"a","url":url}),
        )
        .await;
        assert_eq!(response.error.unwrap().code, "PermissionDenied");
    }
}
