#![cfg(feature = "services")]

use dansheng_connectors::core_adapter::CampusService;
use dansheng_core::{
    Engine, Principal, PrincipalKind, Request, UnavailablePlatform, policy::Grant,
    services::CoreService,
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
                id: "qr-public-fixture".into(),
                method: method.into(),
                params,
            },
        )
        .await
}

#[tokio::test]
async fn qr_actual_campus_service_requires_owner_and_provider_and_cannot_be_a_native_job() {
    let dir = tempfile::tempdir().unwrap();
    let engine = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    let methods = CampusService.methods();
    assert!(methods.contains(&("fudan.qr.present", "fudan.identity.present")));
    assert!(methods.contains(&("fudan.qr.status", "fudan.identity.read")));
    // The existing MCP allow-list requires .read; no Host/MCP code is changed.
    assert!(
        !methods
            .iter()
            .find(|(m, _)| *m == "fudan.qr.present")
            .unwrap()
            .1
            .ends_with(".read")
    );

    // No session and no provider: must fail before attempting authentication/I/O.
    assert_eq!(
        call(
            &engine,
            Principal::owner(),
            "fudan.qr.present",
            json!({"account_id":"fixture"})
        )
        .await
        .error
        .unwrap()
        .code,
        "CapabilityUnavailable"
    );
    for kind in [
        PrincipalKind::Client,
        PrincipalKind::Mcp,
        PrincipalKind::Plugin,
    ] {
        let principal = Principal {
            id: "reader".into(),
            kind,
        };
        for capability in ["fudan.identity.read", "fudan.identity.present"] {
            let mut grant = Grant::default();
            grant.capabilities.insert(capability.into());
            grant.account_ids.insert("fixture".into());
            engine.store.set_grant("reader", &grant).unwrap();
            assert_eq!(
                call(
                    &engine,
                    principal.clone(),
                    "fudan.qr.present",
                    json!({"account_id":"fixture"})
                )
                .await
                .error
                .unwrap()
                .code,
                "PermissionDenied"
            );
        }
    }
    let scheduled = call(
        &engine,
        Principal::owner(),
        "jobs.schedule",
        json!({
            "kind":"service", "method":"fudan.qr.present", "input":{"account_id":"fixture"}
        }),
    )
    .await;
    assert_eq!(scheduled.error.unwrap().code, "ServiceJobNotReadOnly");
    assert!(engine.store.jobs().unwrap().is_empty());
    assert!(
        engine
            .store
            .records(&Principal::owner(), &Grant::default(), &json!({}), None)
            .unwrap()
            .is_empty()
    );
}
