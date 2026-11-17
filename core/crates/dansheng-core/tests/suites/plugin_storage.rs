use dansheng_core::{Engine, Principal, PrincipalKind, Request, Response, UnavailablePlatform};
use serde_json::{Value, json};
use std::{path::Path, sync::Arc};

const ID: &str = "fixture_storage";
async fn rpc(engine: &Arc<Engine>, method: &str, params: Value) -> Response {
    engine
        .handle(
            Principal::owner(),
            Request {
                id: "fixture".into(),
                method: method.into(),
                params,
            },
        )
        .await
}
async fn ok(engine: &Arc<Engine>, method: &str, params: Value) -> Value {
    let response = rpc(engine, method, params).await;
    assert!(response.error.is_none(), "{method}: {:?}", response.error);
    response.result.unwrap()
}
fn package(path: &Path, version: u32, schema: Option<Value>) {
    let mut manifest = json!({"id":ID,"name":"Synthetic storage fixture","version":format!("{version}.0.0"),"api_version":1,"entry":"main.js","capabilities":["storage.read","storage.write"],"network":[],"actions":{"run":{"description":"Private fixture read/write","mutating":false}}});
    if let Some(schema) = schema {
        manifest["storage_schema"] = schema;
    }
    std::fs::write(path.join("manifest.json"), manifest.to_string()).unwrap();
    std::fs::write(
        path.join("main.js"),
        r#"export async function run(ctx,input) {
        if(Object.hasOwn(input,'value')) await ctx.storage.set({key:input.key,value:input.value});
        return await ctx.storage.get({key:input.key});
    }"#,
    )
    .unwrap();
}
async fn install(engine: &Arc<Engine>, path: &Path) {
    ok(engine, "plugins.install", json!({"path":path})).await;
}
async fn enable(engine: &Arc<Engine>) -> Value {
    ok(engine, "plugins.enable", json!({"plugin_id":ID})).await
}
async fn run(engine: &Arc<Engine>, account: &str, key: &str, value: Option<Value>) -> Value {
    let mut input = json!({"account_id":account,"key":key});
    if let Some(value) = value {
        input["value"] = value;
    }
    ok(
        engine,
        "plugins.run",
        json!({"plugin_id":ID,"action":"run","input":input}),
    )
    .await
}
async fn setup(path: &Path) -> Arc<Engine> {
    let engine = Engine::open(path, Arc::new(UnavailablePlatform)).unwrap();
    ok(&engine,"permissions.set",json!({"subject":format!("plugin:{ID}"),"grant":{"capabilities":["storage.read","storage.write"],"account_ids":["a","b"]}})).await;
    engine
}
fn upgrade() -> Value {
    json!({"version":1,"migrations":[{"from":0,"to":1,"operations":[
        {"op":"rename_key","from":"old","to":"current"},
        {"op":"patch_object","key":"current","rename_fields":{"title":"name"},"defaults":{"count":0},"remove_fields":["obsolete"]},
        {"op":"set_default","key":"settings","value":{"enabled":true}},
        {"op":"delete_key","key":"removed"}
    ]}]})
}

#[tokio::test]
async fn real_js_scopes_migrate_restart_rollback_and_restore_without_merging_accounts() {
    let profile = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let mut engine = setup(profile.path()).await;
    package(source.path(), 1, None);
    install(&engine, source.path()).await;
    enable(&engine).await;
    for account in ["a", "b"] {
        run(
            &engine,
            account,
            "old",
            Some(json!({"title":account,"obsolete":true})),
        )
        .await;
        run(&engine, account, "removed", Some(json!("discardable"))).await;
    }
    let neighbor = format!("plugin-state:fixtureXstorage:{}", "a".repeat(64));
    engine
        .store
        .kv_set(&neighbor, "old", &json!("other plugin"))
        .unwrap();
    engine
        .store
        .kv_set("core:sentinel", "old", &json!("host data"))
        .unwrap();
    package(source.path(), 2, Some(upgrade()));
    install(&engine, source.path()).await;
    let enabled = enable(&engine).await;
    let original = enabled["storage"]["snapshot_id"]
        .as_str()
        .unwrap()
        .to_owned();
    for account in ["a", "b"] {
        assert_eq!(run(&engine, account, "old", None).await, Value::Null);
        assert_eq!(
            run(&engine, account, "current", None).await,
            json!({"name":account,"count":0})
        );
        assert_eq!(run(&engine, account, "removed", None).await, Value::Null);
    }
    assert_eq!(
        engine.store.kv_get(&neighbor, "old").unwrap(),
        json!("other plugin")
    );
    assert_eq!(
        engine.store.kv_get("core:sentinel", "old").unwrap(),
        json!("host data")
    );
    run(
        &engine,
        "a",
        "current",
        Some(json!({"name":"after upgrade"})),
    )
    .await;
    drop(engine);
    engine = Engine::open(profile.path(), Arc::new(UnavailablePlatform)).unwrap();
    assert!(enable(&engine).await["storage"]["snapshot_id"].is_null());
    let list = ok(
        &engine,
        "plugins.storage.snapshots",
        json!({"plugin_id":ID}),
    )
    .await;
    assert_eq!(list["snapshots"].as_array().unwrap().len(), 1);
    assert_eq!(list["snapshots"][0]["scopes"], 2);
    assert_eq!(list["snapshots"][0]["entries"], 4);
    ok(&engine, "plugins.rollback", json!({"plugin_id":ID})).await;
    assert_eq!(
        rpc(&engine, "plugins.enable", json!({"plugin_id":ID}))
            .await
            .error
            .unwrap()
            .code,
        "PluginStorageVersionMismatch"
    );
    let restored = ok(
        &engine,
        "plugins.storage.restore",
        json!({"plugin_id":ID,"snapshot_id":original}),
    )
    .await;
    let reverse = restored["recovery_snapshot_id"].clone();
    enable(&engine).await;
    assert_eq!(
        run(&engine, "a", "old", None).await,
        json!({"title":"a","obsolete":true})
    );
    assert_eq!(
        run(&engine, "b", "old", None).await,
        json!({"title":"b","obsolete":true})
    );
    ok(&engine, "plugins.rollback", json!({"plugin_id":ID})).await;
    ok(
        &engine,
        "plugins.storage.restore",
        json!({"plugin_id":ID,"snapshot_id":reverse}),
    )
    .await;
    enable(&engine).await;
    assert_eq!(
        run(&engine, "a", "current", None).await,
        json!({"name":"after upgrade"})
    );
    assert_eq!(
        run(&engine, "b", "current", None).await,
        json!({"name":"b","count":0})
    );
}

#[tokio::test]
async fn failure_in_later_scope_rolls_back_every_scope_snapshot_and_version() {
    let profile = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let engine = setup(profile.path()).await;
    package(source.path(), 1, None);
    install(&engine, source.path()).await;
    enable(&engine).await;
    let first = format!("plugin-state:{ID}:{}", "0".repeat(64));
    let second = format!("plugin-state:{ID}:{}", "f".repeat(64));
    for namespace in [&first, &second] {
        engine
            .store
            .kv_set(namespace, "old", &json!({"title":"synthetic"}))
            .unwrap();
    }
    engine
        .store
        .kv_set(&second, "current", &json!("collision"))
        .unwrap();
    package(source.path(), 2, Some(upgrade()));
    install(&engine, source.path()).await;
    assert_eq!(
        rpc(&engine, "plugins.enable", json!({"plugin_id":ID}))
            .await
            .error
            .unwrap()
            .code,
        "PluginStorageConflict"
    );
    for namespace in [&first, &second] {
        assert_eq!(
            engine.store.kv_get(namespace, "old").unwrap(),
            json!({"title":"synthetic"})
        );
    }
    assert_eq!(engine.store.kv_get(&first, "current").unwrap(), Value::Null);
    let state = ok(
        &engine,
        "plugins.storage.snapshots",
        json!({"plugin_id":ID}),
    )
    .await;
    assert_eq!(state["version"], 0);
    assert_eq!(state["snapshots"], json!([]));
    assert_eq!(engine.store.plugins().unwrap()[0]["enabled"], false);
    ok(&engine, "plugins.rollback", json!({"plugin_id":ID})).await;
    enable(&engine).await;
}

#[tokio::test]
async fn missing_step_or_wrong_type_cannot_be_hidden_by_reinstalling_or_enabling() {
    let profile = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let engine = setup(profile.path()).await;
    package(source.path(), 1, None);
    install(&engine, source.path()).await;
    enable(&engine).await;
    run(&engine, "a", "old", Some(json!(7))).await;
    package(
        source.path(),
        2,
        Some(json!({"version":2,"migrations":[{"from":1,"to":2,"operations":[]}]})),
    );
    install(&engine, source.path()).await;
    assert_eq!(
        rpc(&engine, "plugins.enable", json!({"plugin_id":ID}))
            .await
            .error
            .unwrap()
            .code,
        "PluginStorageMigrationMissing"
    );
    package(source.path(), 3, Some(upgrade()));
    install(&engine, source.path()).await;
    assert_eq!(
        rpc(&engine, "plugins.enable", json!({"plugin_id":ID}))
            .await
            .error
            .unwrap()
            .code,
        "PluginStorageTypeMismatch"
    );
    assert_eq!(
        ok(
            &engine,
            "plugins.storage.snapshots",
            json!({"plugin_id":ID})
        )
        .await["snapshots"],
        json!([])
    );
}

#[tokio::test]
async fn snapshot_restore_is_owner_only_version_matched_and_integrity_checked() {
    let profile = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let engine = setup(profile.path()).await;
    package(source.path(), 1, None);
    install(&engine, source.path()).await;
    enable(&engine).await;
    let namespace = format!("plugin-state:{ID}:{}", "a".repeat(64));
    engine
        .store
        .kv_set(&namespace, "old", &json!({"title":"synthetic"}))
        .unwrap();
    package(source.path(), 2, Some(upgrade()));
    install(&engine, source.path()).await;
    let snapshot = enable(&engine).await["storage"]["snapshot_id"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(
        &engine,
        "permissions.set",
        json!({"subject":"intruder","grant":{"capabilities":["*"]}}),
    )
    .await;
    for method in [
        "plugins.storage.snapshots",
        "plugins.storage.restore",
        "plugins.storage.discard",
    ] {
        let result = engine
            .handle(
                Principal {
                    id: "intruder".into(),
                    kind: PrincipalKind::Client,
                },
                Request {
                    id: "x".into(),
                    method: method.into(),
                    params: json!({"plugin_id":ID,"snapshot_id":snapshot}),
                },
            )
            .await;
        assert_eq!(result.error.unwrap().code, "PermissionDenied");
    }
    assert_eq!(
        rpc(
            &engine,
            "plugins.storage.restore",
            json!({"plugin_id":ID,"snapshot_id":snapshot})
        )
        .await
        .error
        .unwrap()
        .code,
        "PluginMustBeDisabled"
    );
    ok(&engine, "plugins.disable", json!({"plugin_id":ID})).await;
    assert_eq!(
        rpc(
            &engine,
            "plugins.storage.restore",
            json!({"plugin_id":ID,"snapshot_id":snapshot})
        )
        .await
        .error
        .unwrap()
        .code,
        "PluginStorageVersionMismatch"
    );
    ok(&engine, "plugins.rollback", json!({"plugin_id":ID})).await;
    engine
        .store
        .kv_set(
            &format!("plugin-storage-snapshot:{ID}:{snapshot}:{}", "a".repeat(64)),
            "old",
            &json!({"title":"tampered"}),
        )
        .unwrap();
    assert_eq!(
        rpc(
            &engine,
            "plugins.storage.restore",
            json!({"plugin_id":ID,"snapshot_id":snapshot})
        )
        .await
        .error
        .unwrap()
        .code,
        "PluginStorageSnapshotCorrupt"
    );
    assert_eq!(
        engine.store.kv_get(&namespace, "current").unwrap(),
        json!({"name":"synthetic","count":0})
    );
    assert_eq!(
        ok(
            &engine,
            "plugins.storage.snapshots",
            json!({"plugin_id":ID})
        )
        .await["snapshots"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(
        rpc(
            &engine,
            "plugins.storage.restore",
            json!({"plugin_id":ID,"snapshot_id":"../../other"})
        )
        .await
        .error
        .is_some()
    );
}

#[tokio::test]
async fn snapshot_budget_requires_explicit_discard_and_does_not_lose_old_data() {
    let profile = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let engine = setup(profile.path()).await;
    package(source.path(), 1, None);
    install(&engine, source.path()).await;
    enable(&engine).await;
    for version in 1..=9 {
        package(
            source.path(),
            version + 1,
            Some(
                json!({"version":version,"migrations":[{"from":version-1,"to":version,"operations":[]}]}),
            ),
        );
        install(&engine, source.path()).await;
        let result = rpc(&engine, "plugins.enable", json!({"plugin_id":ID})).await;
        if version <= 8 {
            assert!(result.error.is_none());
        } else {
            assert_eq!(result.error.unwrap().code, "PluginStorageSnapshotLimit");
        }
    }
    let state = ok(
        &engine,
        "plugins.storage.snapshots",
        json!({"plugin_id":ID}),
    )
    .await;
    assert_eq!(state["version"], 8);
    assert_eq!(state["snapshots"].as_array().unwrap().len(), 8);
    ok(
        &engine,
        "plugins.storage.discard",
        json!({"plugin_id":ID,"snapshot_id":state["snapshots"][0]["snapshot_id"]}),
    )
    .await;
    assert_eq!(enable(&engine).await["storage"]["version"], 9);
}

#[tokio::test]
async fn namespace_quota_failure_rolls_back_the_recovery_copy_and_transform() {
    let profile = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let engine = setup(profile.path()).await;
    package(source.path(), 1, None);
    install(&engine, source.path()).await;
    enable(&engine).await;
    let namespace = format!("plugin-state:{ID}:{}", "a".repeat(64));
    let value = json!("a".repeat(1024 * 1024 - 2));
    for index in 0..16 {
        engine
            .store
            .kv_set(&namespace, &index.to_string(), &value)
            .unwrap();
    }
    package(
        source.path(),
        2,
        Some(
            json!({"version":1,"migrations":[{"from":0,"to":1,"operations":[{"op":"set_default","key":"extra","value":1}]}]}),
        ),
    );
    install(&engine, source.path()).await;
    assert_eq!(
        rpc(&engine, "plugins.enable", json!({"plugin_id":ID}))
            .await
            .error
            .unwrap()
            .code,
        "PluginStorageQuotaExceeded"
    );
    assert_eq!(
        engine.store.kv_get(&namespace, "extra").unwrap(),
        Value::Null
    );
    assert_eq!(
        ok(
            &engine,
            "plugins.storage.snapshots",
            json!({"plugin_id":ID})
        )
        .await["snapshots"],
        json!([])
    );
}

#[test]
fn manifest_rejects_ambiguous_or_executable_storage_migrations() {
    let source = tempfile::tempdir().unwrap();
    for schema in [
        json!({"version":0}),
        json!({"version":1,"migrations":[{"from":0,"to":2,"operations":[]}]}),
        json!({"version":1,"migrations":[{"from":0,"to":1,"operations":[{"op":"eval","code":"for(;;){}"}]}]}),
        json!({"version":1,"migrations":[{"from":0,"to":1,"operations":[{"op":"rename_key","from":"x","to":"x"}]}]}),
        json!({"version":1,"migrations":[{"from":0,"to":1,"operations":[]},{"from":0,"to":1,"operations":[]}]}),
    ] {
        package(source.path(), 1, Some(schema));
        assert!(dansheng_core::plugins::validate_package(source.path()).is_err());
    }
}

struct WaitingPlatform {
    entered: tokio::sync::Notify,
    release: tokio::sync::Notify,
}
#[async_trait::async_trait]
impl dansheng_core::PlatformPort for WaitingPlatform {
    fn capabilities(&self) -> Vec<String> {
        vec!["notifications.show".into()]
    }
    async fn call(&self, _: &str, _: Value) -> dansheng_core::api::CoreResult<Value> {
        self.entered.notify_one();
        self.release.notified().await;
        Ok(json!({}))
    }
}

#[tokio::test]
async fn update_cancels_old_generation_without_waiting_for_its_platform_await() {
    use std::time::Duration;
    let profile = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let platform = Arc::new(WaitingPlatform {
        entered: tokio::sync::Notify::new(),
        release: tokio::sync::Notify::new(),
    });
    let engine = Engine::open(profile.path(), platform.clone()).unwrap();
    package(source.path(), 1, None);
    let mut manifest: Value =
        serde_json::from_slice(&std::fs::read(source.path().join("manifest.json")).unwrap())
            .unwrap();
    manifest["capabilities"]
        .as_array_mut()
        .unwrap()
        .push(json!("notifications.show"));
    std::fs::write(source.path().join("manifest.json"), manifest.to_string()).unwrap();
    std::fs::write(
        source.path().join("main.js"),
        r#"export async function run(ctx,input) {
        await ctx.notifications.show({title:'fixture'});
        await ctx.storage.set({key:'stale',value:'old generation'});
        return true;
    }"#,
    )
    .unwrap();
    install(&engine, source.path()).await;
    ok(&engine,"permissions.set",json!({"subject":format!("plugin:{ID}"),"grant":{"capabilities":["storage.read","storage.write","notifications.show"],"account_ids":["a"]}})).await;
    enable(&engine).await;
    let running = engine.clone();
    let task = tokio::spawn(async move {
        rpc(
            &running,
            "plugins.run",
            json!({"plugin_id":ID,"action":"run","input":{"account_id":"a"}}),
        )
        .await
    });
    tokio::time::timeout(Duration::from_secs(5), platform.entered.notified())
        .await
        .unwrap();
    package(source.path(), 2, Some(upgrade()));
    tokio::time::timeout(Duration::from_secs(5), install(&engine, source.path()))
        .await
        .unwrap();
    enable(&engine).await;
    platform.release.notify_one();
    assert!(
        tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap()
            .error
            .is_some()
    );
    assert_eq!(run(&engine, "a", "stale", None).await, Value::Null);
}

#[tokio::test]
async fn full_profile_backup_retains_migration_recovery_but_resets_plugin_authority() {
    let root = tempfile::tempdir().unwrap();
    let source = tempfile::tempdir().unwrap();
    let engine = setup(&root.path().join("original")).await;
    package(source.path(), 1, None);
    install(&engine, source.path()).await;
    enable(&engine).await;
    run(&engine, "a", "old", Some(json!({"title":"backed up"}))).await;
    package(source.path(), 2, Some(upgrade()));
    install(&engine, source.path()).await;
    let snapshot = enable(&engine).await["storage"]["snapshot_id"].clone();
    let backup = dansheng_core::backup::create(&engine.store).unwrap();
    let destination = root.path().join("restored");
    dansheng_core::backup::restore(&destination, Path::new(backup["path"].as_str().unwrap()))
        .unwrap();
    let restored = Engine::open(&destination, Arc::new(UnavailablePlatform)).unwrap();
    assert_eq!(restored.store.plugins().unwrap()[0]["enabled"], false);
    assert!(
        restored
            .store
            .grant(&format!("plugin:{ID}"))
            .unwrap()
            .capabilities
            .is_empty()
    );
    assert_eq!(
        ok(
            &restored,
            "plugins.storage.snapshots",
            json!({"plugin_id":ID})
        )
        .await["version"],
        1
    );
    ok(&restored, "plugins.rollback", json!({"plugin_id":ID})).await;
    ok(
        &restored,
        "plugins.storage.restore",
        json!({"plugin_id":ID,"snapshot_id":snapshot}),
    )
    .await;
    enable(&restored).await;
    assert_eq!(
        rpc(
            &restored,
            "plugins.run",
            json!({"plugin_id":ID,"action":"run","input":{"account_id":"a","key":"old"}})
        )
        .await
        .error
        .unwrap()
        .code,
        "PermissionDenied"
    );
    ok(&restored,"permissions.set",json!({"subject":format!("plugin:{ID}"),"grant":{"capabilities":["storage.read","storage.write"],"account_ids":["a","b"]}})).await;
    // Restored authority is intentionally not enough to replay a paused job:
    // the existing task also requires an explicit resume after the regrant.
    let paused = restored
        .store
        .jobs()
        .unwrap()
        .into_iter()
        .find(|job| job["state"] == "waiting_for_approval" && job["data"]["plugin_id"] == ID)
        .unwrap();
    ok(&restored, "jobs.resume", json!({"job_id":paused["id"]})).await;
    assert_eq!(
        run(&restored, "a", "old", None).await,
        json!({"title":"backed up"})
    );
}
