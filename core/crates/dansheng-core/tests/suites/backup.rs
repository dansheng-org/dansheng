//! Offline, temporary-profile evidence; no production restore operations.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use dansheng_core::{
    Principal, PrincipalKind, assets, backup, network::Network, plugins, policy::Grant,
    store::Store,
};
use fs2::FileExt;
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

fn snapshot(store: &Store) -> PathBuf {
    let result = backup::create(store).unwrap_or_else(|e| panic!("snapshot error: {}", e));
    assert_eq!(result["complete"], true);
    PathBuf::from(result["path"].as_str().unwrap())
}
#[test]
fn snapshots_do_not_export_account_gateway_routing_authority() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    store.kv_set("core:network-routes","fixture-account",&json!([{"provider":"test","origin":"https://campus.example","gateway_prefix":"https://gateway.example/encoded","mode":"gateway"}])).unwrap();
    let captured = snapshot(&store);
    let image = Connection::open(captured.join("dansheng.db")).unwrap();
    let count: i64 = image
        .query_row(
            "SELECT count(*) FROM kv WHERE namespace='core:network-routes'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
    assert!(
        !store
            .kv_get("core:network-routes", "fixture-account")
            .unwrap()
            .is_null()
    );
}

#[test]
fn credential_binding_epoch_is_local_atomic_and_never_inherited_from_snapshots() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    assert_eq!(store.credential_binding_epoch().unwrap(), None);
    let epochs = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..8)
            .map(|_| scope.spawn(|| store.ensure_credential_binding_epoch().unwrap()))
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    let epoch = &epochs[0];
    assert!(uuid::Uuid::parse_str(epoch).is_ok());
    assert!(epochs.iter().all(|value| value == epoch));
    store
        .kv_set(
            "core:credential-bindings",
            "future-control",
            &json!("untrusted"),
        )
        .unwrap();
    let captured = snapshot(&store);
    assert_eq!(
        store.credential_binding_epoch().unwrap().as_ref(),
        Some(epoch)
    );
    drop(store);
    let store = Store::open(&source).unwrap();
    assert_eq!(store.ensure_credential_binding_epoch().unwrap(), *epoch);
    {
        let image = db(&captured);
        assert_eq!(
            image
                .query_row(
                    "SELECT count(*) FROM kv WHERE namespace='core:credential-bindings'",
                    [],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        // A validly rehashed old/malicious snapshot may carry authority. Restore
        // must independently remove the entire namespace, including future keys.
        image
            .execute(
                "INSERT INTO kv VALUES('core:credential-bindings','epoch',?)",
                [json!(epoch).to_string()],
            )
            .unwrap();
        image
            .execute(
                "INSERT INTO kv VALUES('core:credential-bindings','future-control','true')",
                [],
            )
            .unwrap();
    }
    rehash(&captured, "dansheng.db");
    for existing in [false, true] {
        let target = temp
            .path()
            .join(if existing { "existing" } else { "fresh" });
        let previous_epoch = if existing {
            Some(
                Store::open(&target)
                    .unwrap()
                    .ensure_credential_binding_epoch()
                    .unwrap(),
            )
        } else {
            None
        };
        backup::restore(&target, &captured).unwrap();
        let restored = Store::open(&target).unwrap();
        assert_eq!(restored.credential_binding_epoch().unwrap(), None);
        assert!(
            restored
                .kv_get("core:credential-bindings", "future-control")
                .unwrap()
                .is_null()
        );
        drop(restored);
        let reopened = Store::open(&target).unwrap();
        assert_eq!(reopened.credential_binding_epoch().unwrap(), None);
        let fresh = reopened.ensure_credential_binding_epoch().unwrap();
        assert_ne!(&fresh, epoch);
        assert_ne!(Some(&fresh), previous_epoch.as_ref());
    }
}

fn db(root: &Path) -> Connection {
    Connection::open(root.join("dansheng.db")).unwrap()
}
fn manifest(root: &Path) -> Value {
    serde_json::from_slice(&fs::read(root.join("manifest.json")).unwrap()).unwrap()
}
fn write_manifest(root: &Path, value: &Value) {
    fs::write(
        root.join("manifest.json"),
        serde_json::to_vec(value).unwrap(),
    )
    .unwrap();
}
fn rehash(root: &Path, name: &str) {
    let mut value = manifest(root);
    let data = fs::read(root.join(name)).unwrap();
    let file = value["files"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|f| f["path"] == name)
        .unwrap();
    file["size"] = json!(data.len());
    file["sha256"] = json!(hex::encode(Sha256::digest(data)));
    write_manifest(root, &value);
}
fn assert_target(root: &Path, value: Value) {
    let store = Store::open(root).unwrap();
    assert_eq!(store.kv_get("personal", "marker").unwrap(), value);
}
fn sibling_recoveries(parent: &Path) -> usize {
    fs::read_dir(parent)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with(".dansheng-stage-") || n.starts_with(".dansheng-previous-"))
        .count()
}
async fn ready_asset(store: &Store, bytes: &[u8]) -> String {
    assets::dispatch(
        store,
        &Network::default(),
        &Principal::owner(),
        &Grant::default(),
        "files.list",
        json!({}),
    )
    .await
    .unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    fs::write(store.directory.join("assets").join(&id), bytes).unwrap();
    let hash = hex::encode(Sha256::digest(bytes));
    db(&store.directory).execute("INSERT INTO managed_assets_v1(id,owner,account_id,source_id,name,mime_type,state,size,max_bytes,reserved_bytes,url_hash,request_hash,session_hash,sha256,created_at,updated_at) VALUES(?,'owner','','fixtures','材料.txt','text/plain','ready',?,1024,?,'fixture-url','fixture-request','fixture-session',?,'2026-11-06T00:00:00Z','2026-11-06T00:00:00Z')",params![id,bytes.len() as i64,bytes.len() as i64,hash]).unwrap();
    id
}
fn install(store: &Store, source: &Path, id: &str, version: &str) -> plugins::InstalledPlugin {
    let value = json!({"id":id,"name":"Offline fixture","version":version,"api_version":1,"entry":"main.js","capabilities":["storage.read"],"network":[],"actions":{"read":{"description":"Read a local fixture","mutating":false}}});
    fs::write(source.join("manifest.json"), value.to_string()).unwrap();
    fs::write(
        source.join("main.js"),
        format!("export function read() {{ return '{version}'; }}"),
    )
    .unwrap();
    let receipt = plugins::install_local_package(source, store.directory.join("plugins")).unwrap();
    store
        .plugin_save(
            id,
            &receipt.package_dir,
            &serde_json::to_value(&receipt.manifest).unwrap(),
        )
        .unwrap();
    receipt
}

#[tokio::test]
async fn online_snapshot_and_offline_profile_swap_restore_assets_history_and_current_controls() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    let fixture = tempfile::tempdir().unwrap();
    let store = Store::open(&root).unwrap();
    let body = "离线材料 🦀".as_bytes();
    let asset = ready_asset(&store, body).await;
    let first = install(&store, fixture.path(), "fixture-plugin", "1.0.0");
    let second = install(&store, fixture.path(), "fixture-plugin", "2.0.0");
    store.plugin_enable("fixture-plugin", true).unwrap();
    store
        .record_upsert(
            "service:fixture",
            "school",
            "fixture.courses",
            "one",
            "course",
            &json!({"title":"非空索引资料"}),
        )
        .unwrap();
    let todo = dansheng_core::organizer::dispatch(
        &store,
        &Principal::owner(),
        &Grant::default(),
        "todo.create",
        json!({"title":"snapshot organizer","due_at":"2027-01-06T09:00:00Z"}),
    )
    .unwrap();
    dansheng_core::organizer::dispatch(
        &store,
        &Principal::owner(),
        &Grant::default(),
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2027-01-06T08:00:00Z"}),
    )
    .unwrap();
    let job = store
        .create_job(
            &Principal::owner(),
            &json!({"plugin_id":"fixture-plugin","action":"read"}),
            "2027-01-06T00:00:00Z",
        )
        .unwrap();
    store
        .kv_set("personal", "marker", &json!("snapshot value"))
        .unwrap();
    store
        .kv_set(
            "core:plugins",
            "trusted_publishers",
            &json!([{"publisher":{"id":"old","key_id":"old-key"},"public_key":vec![1u8;32]}]),
        )
        .unwrap();
    store
        .kv_set("core:plugins", "sequence:publisher:key", &json!(4))
        .unwrap();
    store
        .require_source_capabilities(
            "service:source",
            "source",
            &["read.old".to_string()].into_iter().collect(),
        )
        .unwrap();
    store
        .event("fixture", &json!({"principal":"owner"}))
        .unwrap();
    let captured = snapshot(&store);
    assert_eq!(
        fs::read(captured.join("assets").join(&asset)).unwrap(),
        body
    );
    assert!(captured.join("plugins/fixture-plugin/.history").is_dir());
    assert_eq!(manifest(&captured)["database_version"], 3);
    let current_keys =
        json!([{"publisher":{"id":"current","key_id":"current-key"},"public_key":vec![2u8;32]}]);
    store
        .kv_set("core:plugins", "trusted_publishers", &current_keys)
        .unwrap();
    store
        .kv_set("core:plugins", "sequence:publisher:key", &json!(91))
        .unwrap();
    store
        .kv_set("core:plugins", "key:immutable-id", &json!("f".repeat(64)))
        .unwrap();
    store
        .require_source_capabilities(
            "service:source",
            "source",
            &["read.new".to_string()].into_iter().collect(),
        )
        .unwrap();
    store
        .kv_set(
            "personal",
            "marker",
            &json!("current value retained in rollback"),
        )
        .unwrap();
    for _ in 0..12 {
        store
            .event("current", &json!({"principal":"owner"}))
            .unwrap();
    }
    let event_floor = db(&root)
        .query_row(
            "SELECT seq FROM sqlite_sequence WHERE name='events'",
            [],
            |r| r.get::<_, i64>(0),
        )
        .unwrap();
    drop(store);
    let result = backup::restore(&root, &captured).unwrap_or_else(|e| panic!("restore: {e}"));
    let previous = PathBuf::from(result["previous_profile"].as_str().unwrap());
    let canonical_parent = fs::canonicalize(root.parent().unwrap()).unwrap();
    assert_eq!(previous.parent(), Some(canonical_parent.as_path()));
    assert!(
        previous
            .join("backups")
            .join(captured.file_name().unwrap())
            .is_dir()
    );
    assert!(previous.join("dansheng.db").is_file());
    assert!(!root.join("host").exists());
    assert!(!root.join("vault").exists());
    let restored = Store::open(&root).unwrap();
    let restored_todo = dansheng_core::organizer::dispatch(
        &restored,
        &Principal::owner(),
        &Grant::default(),
        "todo.get",
        json!({"id":todo["id"]}),
    )
    .unwrap();
    assert_eq!(restored_todo["title"], "snapshot organizer");
    let future = dansheng_core::organizer::dispatch(
        &restored,
        &Principal::owner(),
        &Grant::default(),
        "reminders.list",
        json!({}),
    )
    .unwrap();
    assert_eq!(future["items"][0]["state"], "pending");
    assert_eq!(
        restored
            .jobs()
            .unwrap()
            .iter()
            .find(|j| j["id"] == job)
            .unwrap()["state"],
        "needs_reconciliation"
    );
    assert_eq!(
        restored
            .records(
                &Principal::owner(),
                &Grant::default(),
                &json!({}),
                Some("索引资料")
            )
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        restored.kv_get("personal", "marker").unwrap(),
        json!("snapshot value")
    );
    assert_eq!(
        restored
            .kv_get("core:plugins", "trusted_publishers")
            .unwrap(),
        current_keys
    );
    assert_eq!(
        restored
            .kv_get("core:plugins", "sequence:publisher:key")
            .unwrap(),
        91
    );
    assert_eq!(
        restored.kv_get("core:plugins", "key:immutable-id").unwrap(),
        "f".repeat(64)
    );
    assert!(
        restored
            .event("restored", &json!({"principal":"owner"}))
            .unwrap()
            > event_floor
    );
    let registry = restored.plugins().unwrap();
    assert_eq!(registry.len(), 1);
    assert_eq!(registry[0]["enabled"], false);
    let selected = plugins::installed_package(root.join("plugins"), "fixture-plugin").unwrap();
    assert_eq!(selected.manifest.version, "2.0.0");
    assert_eq!(
        Path::new(registry[0]["path"].as_str().unwrap()),
        selected.package_dir
    );
    assert!(
        root.join("plugins/fixture-plugin/versions")
            .join(first.package_dir.file_name().unwrap())
            .join("main.js")
            .is_file()
    );
    assert!(
        root.join("plugins/fixture-plugin/versions")
            .join(second.package_dir.file_name().unwrap())
            .join("manifest.json")
            .is_file()
    );
    let read = assets::dispatch(
        &restored,
        &Network::default(),
        &Principal::owner(),
        &Grant::default(),
        "files.read",
        json!({"asset_id":asset}),
    )
    .await
    .unwrap();
    assert_eq!(
        STANDARD.decode(read["data"].as_str().unwrap()).unwrap(),
        body
    );
    let labels:String=db(&root).query_row("SELECT capabilities FROM source_access WHERE owner='service:source' AND source_id='source'",[],|r|r.get(0)).unwrap();
    let labels: std::collections::BTreeSet<String> = serde_json::from_str(&labels).unwrap();
    assert_eq!(labels.len(), 2);
    assert_eq!(
        db(&previous)
            .query_row(
                "SELECT data FROM kv WHERE namespace='personal' AND key='marker'",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
        json!("current value retained in rollback").to_string()
    );
    let rolled = plugins::rollback_local_package(
        root.join("plugins"),
        "fixture-plugin",
        Some(first.package_dir.file_name().unwrap().to_str().unwrap()),
    )
    .unwrap();
    assert_eq!(rolled.manifest.version, "1.0.0");
    assert!(!rolled.enabled);
}

#[test]
fn credentials_and_policy_are_not_exported_and_nonowner_access_is_reset() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    let store = Store::open(&root).unwrap();
    fs::create_dir(root.join("host")).unwrap();
    fs::create_dir(root.join("vault")).unwrap();
    let token = "synthetic-owner-token-not-a-real-credential-123456789";
    let ciphertext = "synthetic-vault-ciphertext-not-a-real-credential";
    let legacy = "synthetic-legacy-session-not-a-real-credential";
    fs::write(root.join("host/owner-token"), token).unwrap();
    fs::write(root.join("host/mcp-token"), token).unwrap();
    fs::write(root.join("vault/fixture.dpapi"), ciphertext).unwrap();
    store
        .register_client("fixture-reader", PrincipalKind::Mcp, token)
        .unwrap();
    let mut grant = Grant::default();
    grant.capabilities.insert("fixture.sensitive.grant".into());
    store.set_grant("fixture-reader", &grant).unwrap();
    store
        .kv_set(
            "core:session-policy",
            "account",
            &json!({"legacy_session":legacy}),
        )
        .unwrap();
    let captured = snapshot(&store);
    let value = manifest(&captured);
    assert!(
        value["files"].as_array().unwrap().iter().all(|f| !f["path"]
            .as_str()
            .unwrap()
            .starts_with("host/")
            && !f["path"].as_str().unwrap().starts_with("vault/"))
    );
    assert!(!captured.join("host").exists());
    assert!(!captured.join("vault").exists());
    let bytes = fs::read(captured.join("dansheng.db")).unwrap();
    for value in [token, ciphertext, legacy, "fixture.sensitive.grant"] {
        assert!(!bytes.windows(value.len()).any(|s| s == value.as_bytes()));
    }
    {
        let image = db(&captured);
        assert_eq!(
            image
                .query_row("SELECT count(*) FROM clients", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            image
                .query_row("SELECT count(*) FROM grants", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
    assert!(store.authenticate(token).is_ok()); // Create did not revoke the live profile.
    assert!(
        !store
            .kv_get("core:session-policy", "account")
            .unwrap()
            .is_null()
    );
    drop(store);
    let result = backup::restore(&root, &captured).unwrap();
    let previous = PathBuf::from(result["previous_profile"].as_str().unwrap());
    assert_eq!(
        fs::read_to_string(previous.join("host/owner-token")).unwrap(),
        token
    );
    assert_eq!(
        fs::read_to_string(previous.join("vault/fixture.dpapi")).unwrap(),
        ciphertext
    );
    let restored = Store::open(&root).unwrap();
    assert_eq!(
        restored.authenticate(token).unwrap_err().code,
        "Unauthenticated"
    );
    assert!(
        restored
            .grant("fixture-reader")
            .unwrap()
            .capabilities
            .is_empty()
    );
    assert!(
        restored
            .kv_get("core:session-policy", "account")
            .unwrap()
            .is_null()
    );
    assert!(!root.join("host").exists());
    assert!(!root.join("vault").exists());
}

#[test]
fn restore_refuses_active_store_before_any_staging_or_swap() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    let store = Store::open(&root).unwrap();
    store
        .kv_set("personal", "marker", &json!("unchanged"))
        .unwrap();
    let captured = snapshot(&store);
    assert_eq!(
        backup::restore(&root, &captured).unwrap_err().code,
        "DataDirectoryInUse"
    );
    assert_eq!(store.kv_get("personal", "marker").unwrap(), "unchanged");
    assert_eq!(sibling_recoveries(temp.path()), 0);
}

#[test]
fn stable_parent_lock_prevents_a_start_attempt_from_recreating_the_swap_gap() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    fs::create_dir(&root).unwrap();
    let lock = Store::acquire_profile_lock(&root).unwrap();
    let previous = temp.path().join("offline-previous");
    fs::rename(&root, &previous).unwrap();
    assert_eq!(Store::open(&root).err().unwrap().code, "DataDirectoryInUse");
    assert!(
        !root.exists(),
        "a refused startup must not create a directory during restore's swap gap"
    );
    fs::rename(&previous, &root).unwrap();
    drop(lock);
    Store::open(&root).unwrap();
}

#[test]
fn manifest_paths_refuse_traversal_absolute_ads_and_secret_tree_injection() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    let captured = snapshot(&store);
    let original = manifest(&captured);
    let target = temp.path().join("new-profile");
    let outside = temp.path().join("outside.txt");
    fs::write(&outside, "keep").unwrap();
    for path in [
        "../outside.txt",
        "/outside.txt",
        r"C:\outside.txt",
        r"plugins\x\main.js",
        "plugins/x/../../outside.txt",
        "plugins/x/versions/a/main.js:stream",
        "plugins/%2e%2e/outside.txt",
        "host/owner-token",
        "vault/fixture.dpapi",
        "assets/../dansheng.db",
    ] {
        let mut value = original.clone();
        value["files"][0]["path"] = json!(path);
        write_manifest(&captured, &value);
        assert!(
            backup::restore(&target, &captured).is_err(),
            "accepted path {path}"
        );
        assert!(!target.exists());
        assert_eq!(fs::read_to_string(&outside).unwrap(), "keep");
    }
    write_manifest(&captured, &original);
    assert_eq!(sibling_recoveries(temp.path()), 0);
}

#[tokio::test]
async fn altered_missing_and_extra_files_are_rejected_before_target_changes() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    let asset = ready_asset(&store, b"original asset").await;
    let captured = snapshot(&store);
    let target = temp.path().join("target");
    {
        let target_store = Store::open(&target).unwrap();
        target_store
            .kv_set("personal", "marker", &json!("keep"))
            .unwrap();
    }
    let path = captured.join("assets").join(&asset);
    fs::write(&path, b"tampered asset").unwrap();
    assert!(backup::restore(&target, &captured).is_err());
    assert_target(&target, json!("keep"));
    fs::remove_file(&path).unwrap();
    assert!(backup::restore(&target, &captured).is_err());
    assert_target(&target, json!("keep"));
    fs::write(&path, b"original asset").unwrap();
    fs::write(captured.join("extra.txt"), "unlisted").unwrap();
    assert!(backup::restore(&target, &captured).is_err());
    assert_target(&target, json!("keep"));
    assert_eq!(sibling_recoveries(temp.path()), 0);
}

#[test]
fn future_database_and_injected_trigger_fail_even_with_recomputed_manifest_hashes() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    let captured = snapshot(&store);
    let target = temp.path().join("target");
    {
        let image = db(&captured);
        image.pragma_update(None, "user_version", 999).unwrap();
    }
    rehash(&captured, "dansheng.db");
    assert_eq!(
        backup::restore(&target, &captured).unwrap_err().code,
        "UnsupportedDatabaseVersion"
    );
    assert!(!target.exists());
    {
        let image = db(&captured);
        image.pragma_update(None, "user_version", 3).unwrap();
        image.execute_batch("CREATE TRIGGER injected_control AFTER DELETE ON clients BEGIN UPDATE kv SET data='null' WHERE namespace='core:plugins'; END;").unwrap();
    }
    rehash(&captured, "dansheng.db");
    assert_eq!(
        backup::restore(&target, &captured).unwrap_err().code,
        "UnsupportedSnapshotSchema"
    );
    assert!(!target.exists());
    assert_eq!(sibling_recoveries(temp.path()), 0);
}

#[test]
fn unrelated_existing_target_files_and_workspace_roots_are_never_moved() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    let captured = snapshot(&store);
    let target = temp.path().join("target");
    fs::create_dir(&target).unwrap();
    fs::write(target.join("my-notes.txt"), "user-owned").unwrap();
    assert_eq!(
        backup::restore(&target, &captured).unwrap_err().code,
        "UnsafeBackupPath"
    );
    assert_eq!(
        fs::read_to_string(target.join("my-notes.txt")).unwrap(),
        "user-owned"
    );
    assert!(backup::restore(temp.path(), &captured).is_err());
    assert!(source.join("dansheng.db").is_file());
    assert_eq!(sibling_recoveries(temp.path()), 0);
}

#[test]
fn fresh_target_gets_no_stale_publisher_trust_and_future_current_profile_is_preserved() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    store
        .kv_set(
            "core:plugins",
            "trusted_publishers",
            &json!(["snapshot-only"]),
        )
        .unwrap();
    store
        .kv_set("core:plugins", "sequence:old:key", &json!(100))
        .unwrap();
    let captured = snapshot(&store);
    let fresh = temp.path().join("fresh");
    backup::restore(&fresh, &captured).unwrap();
    {
        let restored = Store::open(&fresh).unwrap();
        assert!(
            restored
                .kv_get("core:plugins", "trusted_publishers")
                .unwrap()
                .is_null()
        );
        assert!(
            restored
                .kv_get("core:plugins", "sequence:old:key")
                .unwrap()
                .is_null()
        );
    }
    db(&fresh).pragma_update(None, "user_version", 999).unwrap();
    let before = fs::read(fresh.join("dansheng.db")).unwrap();
    assert_eq!(
        backup::restore(&fresh, &captured).unwrap_err().code,
        "UnsupportedDatabaseVersion"
    );
    assert_eq!(fs::read(fresh.join("dansheng.db")).unwrap(), before);
}

#[test]
fn busy_plugins_and_missing_generation_payload_never_produce_complete_snapshots() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    let fixture = tempfile::tempdir().unwrap();
    let store = Store::open(&root).unwrap();
    let installed = install(&store, fixture.path(), "fixture-plugin", "1.0.0");
    let lock = root.join("plugins/fixture-plugin/.install.lock");
    fs::write(&lock, []).unwrap();
    assert_eq!(backup::create(&store).unwrap_err().code, "SnapshotBusy");
    fs::remove_file(lock).unwrap();
    fs::remove_file(installed.package_dir.join("main.js")).unwrap();
    assert!(backup::create(&store).is_err());
    let completed = fs::read_dir(root.join("backups"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with(".incomplete-"))
        .count();
    assert_eq!(completed, 0);
}

#[test]
fn uninstalled_generations_and_history_are_retained_without_reactivation() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    let fixture = tempfile::tempdir().unwrap();
    let store = Store::open(&root).unwrap();
    let installed = install(&store, fixture.path(), "fixture-plugin", "1.0.0");
    plugins::uninstall_local_package(root.join("plugins"), "fixture-plugin").unwrap();
    store.plugin_remove("fixture-plugin").unwrap();
    let captured = snapshot(&store);
    drop(store);
    backup::restore(&root, &captured).unwrap();
    let restored = Store::open(&root).unwrap();
    assert!(restored.plugins().unwrap().is_empty());
    assert!(
        root.join("plugins/fixture-plugin/versions")
            .join(installed.package_dir.file_name().unwrap())
            .join("main.js")
            .is_file()
    );
    assert!(plugins::installed_package(root.join("plugins"), "fixture-plugin").is_err());
    let recovered = plugins::rollback_local_package(
        root.join("plugins"),
        "fixture-plugin",
        Some(installed.package_dir.file_name().unwrap().to_str().unwrap()),
    )
    .unwrap();
    assert!(!recovered.enabled);
    assert_eq!(recovered.manifest.version, "1.0.0");
}

#[tokio::test]
async fn active_asset_lock_prevents_capture_and_partial_downloads_are_not_exported() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    let store = Store::open(&root).unwrap();
    let asset = ready_asset(&store, b"ready").await;
    let path = root.join("assets").join(format!("{asset}.lock"));
    fs::write(&path, []).unwrap();
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .unwrap();
    lock.try_lock_exclusive().unwrap();
    assert_eq!(backup::create(&store).unwrap_err().code, "SnapshotBusy");
    drop(lock);
    let incomplete = uuid::Uuid::new_v4().to_string();
    fs::write(
        root.join("assets").join(format!("{incomplete}.part")),
        "partial",
    )
    .unwrap();
    db(&root).execute("INSERT INTO managed_assets_v1 SELECT ? ,owner,account_id,source_id,name,mime_type,'partial',size,max_bytes,reserved_bytes,url_hash,request_hash,session_hash,expected_sha256,sha256,etag,created_at,updated_at,indexed_at,error_code FROM managed_assets_v1 WHERE id=?",params![incomplete,asset]).unwrap();
    let captured = snapshot(&store);
    assert!(
        !captured
            .join("assets")
            .join(format!("{incomplete}.part"))
            .exists()
    );
    assert_eq!(
        db(&captured)
            .query_row("SELECT count(*) FROM managed_assets_v1", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[cfg(any(unix, windows))]
#[test]
fn symlinked_snapshot_database_is_refused_before_target_creation() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let store = Store::open(&source).unwrap();
    let captured = snapshot(&store);
    let original = captured.join("dansheng.db");
    let outside = temp.path().join("outside.db");
    fs::copy(&original, &outside).unwrap();
    fs::remove_file(&original).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, &original).unwrap();
    #[cfg(windows)]
    if let Err(error) = std::os::windows::fs::symlink_file(&outside, &original) {
        if error.kind() == std::io::ErrorKind::PermissionDenied
            || error.raw_os_error() == Some(1314)
        {
            eprintln!("Windows symlink fixture unavailable without link privilege");
            return;
        }
        panic!("symlink fixture: {error}");
    }
    let target = temp.path().join("target");
    assert_eq!(
        backup::restore(&target, &captured).unwrap_err().code,
        "UnsafeBackupPath"
    );
    assert!(!target.exists());
    assert!(outside.is_file());
}

#[tokio::test]
async fn payload_copy_and_hashing_leave_live_store_apis_responsive_at_one_database_instant() {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    };
    use std::time::{Duration, Instant};
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("profile");
    let store = Arc::new(Store::open(&root).unwrap());
    let bytes = vec![0x5au8; 32 * 1024 * 1024];
    let asset = ready_asset(&store, &bytes).await;
    // This fixture exceeds the small download helper's default max_bytes only
    // in metadata; set a matching bounded completed-download reservation.
    db(&root)
        .execute(
            "UPDATE managed_assets_v1 SET max_bytes=size WHERE id=?",
            [&asset],
        )
        .unwrap();
    drop(bytes);
    store
        .kv_set("personal", "marker", &json!("captured instant"))
        .unwrap();
    let complete = Arc::new(AtomicBool::new(false));
    let copy_store = store.clone();
    let copy_done = complete.clone();
    let worker = std::thread::spawn(move || {
        let result = backup::create(&copy_store);
        copy_done.store(true, Ordering::SeqCst);
        result
    });
    let start = Instant::now();
    loop {
        let copying = fs::read_dir(root.join("backups"))
            .ok()
            .is_some_and(|entries| {
                entries
                    .filter_map(Result::ok)
                    .any(|e| e.path().join("assets").join(&asset).exists())
            });
        if copying {
            break;
        }
        assert!(
            !complete.load(Ordering::SeqCst),
            "snapshot finished before its payload phase could be observed"
        );
        assert!(
            start.elapsed() < Duration::from_secs(15),
            "snapshot did not reach payload copying"
        );
        std::thread::sleep(Duration::from_millis(1));
    }
    let (tx, rx) = mpsc::channel();
    let api_store = store.clone();
    let api_done = complete.clone();
    let api = std::thread::spawn(move || {
        let result = api_store.kv_set("personal", "marker", &json!("live update during copy"));
        tx.send((result, api_done.load(Ordering::SeqCst))).unwrap();
    });
    let (result, snapshot_finished) = rx
        .recv_timeout(Duration::from_secs(5))
        .expect("live Store API blocked during payload I/O");
    result.unwrap();
    assert!(
        !snapshot_finished,
        "payload copying/hashing must not retain the Store mutex"
    );
    api.join().unwrap();
    let result = worker.join().unwrap().unwrap();
    let captured = PathBuf::from(result["path"].as_str().unwrap());
    assert_eq!(
        store.kv_get("personal", "marker").unwrap(),
        "live update during copy"
    );
    let image = db(&captured);
    let saved: String = image
        .query_row(
            "SELECT data FROM kv WHERE namespace='personal' AND key='marker'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(saved, json!("captured instant").to_string());
}
