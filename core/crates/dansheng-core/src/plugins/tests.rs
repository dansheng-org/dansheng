use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use async_trait::async_trait;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::Notify;

use super::*;

fn manifest() -> PluginManifest {
    PluginManifest {
        storage_schema: None,
        id: "example.offline".into(),
        version: "1.0.0".into(),
        api_version: 1,
        entry: "main.js".into(),
        name: "Offline fixture".into(),
        capabilities: vec![
            "storage.get".into(),
            "storage.set".into(),
            "http.request".into(),
        ],
        network: vec!["https://fixture.invalid".into()],
        actions: BTreeMap::from([(
            "run".into(),
            PluginAction {
                description: "Run a synthetic fixture".into(),
                mutating: false,
                input_schema: Some(json!({"type": "object"})),
            },
        )]),
        ui: Some(vec![serde_json::Map::from_iter([(
            "type".into(),
            json!("text"),
        )])]),
        publisher: None,
        integrity: None,
    }
}

fn write_package(path: &Path, manifest: &PluginManifest, source: &str) {
    fs::create_dir_all(path).unwrap();
    fs::write(
        path.join(MANIFEST_FILE),
        serde_json::to_vec(manifest).unwrap(),
    )
    .unwrap();
    fs::write(path.join(&manifest.entry), source).unwrap();
}

fn fixture(source: &str) -> (TempDir, PluginManifest) {
    let dir = tempfile::tempdir().unwrap();
    let manifest = manifest();
    write_package(dir.path(), &manifest, source);
    (dir, manifest)
}

#[derive(Default)]
struct RecordingHost {
    calls: Mutex<Vec<(String, String, Value, String)>>,
    storage: Mutex<BTreeMap<String, Value>>,
}

#[async_trait]
impl PluginHost for RecordingHost {
    async fn call(
        &self,
        plugin_id: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, PluginError> {
        self.calls.lock().unwrap().push((
            plugin_id.into(),
            method.into(),
            params.clone(),
            std::thread::current().name().unwrap_or("").into(),
        ));
        // Real asynchronous timer/I/O yielding, not an immediately ready mock.
        tokio::time::sleep(Duration::from_millis(2)).await;
        match method {
            "storage.set" => {
                self.storage.lock().unwrap().insert(
                    params["key"].as_str().unwrap().into(),
                    params["value"].clone(),
                );
                Ok(json!({"saved": true}))
            }
            "storage.get" => Ok(self
                .storage
                .lock()
                .unwrap()
                .get(params["key"].as_str().unwrap())
                .cloned()
                .unwrap_or(Value::Null)),
            "http.request" => Ok(json!({"status": 200, "body": {"items": ["offline"]}})),
            "auth.requireLogin" => Err(PluginError::new(
                "LOGIN_REQUIRED",
                "Synthetic host-private message",
            )),
            _ => Ok(json!({"method": method, "params": params})),
        }
    }
}

async fn run(source: &str, limits: PluginLimits) -> Result<Value, PluginError> {
    let (dir, manifest) = fixture(source);
    PluginRunner::run(
        dir.path().into(),
        manifest,
        "run".into(),
        json!({}),
        Arc::new(RecordingHost::default()),
        limits,
    )
    .await
}

#[test]
fn manifest_round_trip_and_defaults_are_explicit() {
    let expected = manifest();
    assert_eq!(
        PluginManifest::from_slice(&serde_json::to_vec(&expected).unwrap()).unwrap(),
        expected
    );
    let limits = PluginLimits::default();
    assert_eq!(limits.heap_bytes, 32 * 1024 * 1024);
    assert_eq!(limits.stack_bytes, 512 * 1024);
    assert_eq!(limits.wall_timeout, Duration::from_secs(30));
}

#[test]
fn malformed_manifests_and_ambiguous_keys_are_rejected() {
    for bytes in [
        b"{".as_slice(),
        b"null",
        b"{}",
        b"{\"id\":\"a\",\"id\":\"b\"}",
    ] {
        assert_eq!(
            PluginManifest::from_slice(bytes).unwrap_err().code,
            "INVALID_MANIFEST"
        );
    }
    let mut value = serde_json::to_value(manifest()).unwrap();
    for (field, malformed) in [
        ("id", json!("../escape")),
        ("id", json!("con.plugin")),
        ("api_version", json!(2)),
        ("entry", json!("../outside.js")),
        ("entry", json!("C:\\outside.js")),
        ("entry", json!("main.qjbc")),
        ("network", json!(["https://fixture.invalid/private"])),
        ("network", json!(["https://user:password@fixture.invalid"])),
        ("ui", json!(["not an object"])),
        ("unexpected_field", json!(true)),
    ] {
        let old = value
            .as_object_mut()
            .unwrap()
            .insert(field.into(), malformed);
        assert_eq!(
            PluginManifest::from_slice(&serde_json::to_vec(&value).unwrap())
                .unwrap_err()
                .code,
            "INVALID_MANIFEST",
            "{field}"
        );
        if let Some(old) = old {
            value[field] = old;
        } else {
            value.as_object_mut().unwrap().remove(field);
        }
    }
    assert_eq!(
        PluginManifest::from_slice(&vec![b' '; MAX_MANIFEST_BYTES + 1])
            .unwrap_err()
            .code,
        "INVALID_MANIFEST"
    );
    let text = serde_json::to_string(&manifest()).unwrap().replace(
        "\"description\":",
        "\"description\":\"duplicate\",\"description\":",
    );
    assert_eq!(
        PluginManifest::from_slice(text.as_bytes())
            .unwrap_err()
            .code,
        "INVALID_MANIFEST"
    );
}

#[test]
fn installation_promotes_validated_generations_and_retains_previous() {
    let (source, first_manifest) = fixture("export function run() { return 1; }");
    let destination = tempfile::tempdir().unwrap();
    let first = install_local_package(source.path(), destination.path()).unwrap();
    assert_eq!(
        installed_package(destination.path(), &first_manifest.id)
            .unwrap()
            .package_dir,
        first.package_dir
    );
    let mut second_manifest = first_manifest.clone();
    second_manifest.version = "1.1.0".into();
    write_package(
        source.path(),
        &second_manifest,
        "export function run() { return 2; }",
    );
    let second = install_local_package(source.path(), destination.path()).unwrap();
    assert_eq!(second.previous_package_dir, Some(first.package_dir.clone()));
    assert_eq!(
        fs::read_to_string(first.package_dir.join("main.js")).unwrap(),
        "export function run() { return 1; }"
    );
    assert_eq!(
        installed_package(destination.path(), &first_manifest.id)
            .unwrap()
            .manifest
            .version,
        "1.1.0"
    );
    // A reinstall also keeps the prior generation, rather than replacing it.
    let third = install_local_package(source.path(), destination.path()).unwrap();
    assert_eq!(third.previous_package_dir, Some(second.package_dir.clone()));
    assert_ne!(third.package_dir, second.package_dir);
    fs::write(source.path().join(MANIFEST_FILE), "{malformed}").unwrap();
    assert!(install_local_package(source.path(), destination.path()).is_err());
    assert_eq!(
        installed_package(destination.path(), &first_manifest.id)
            .unwrap()
            .package_dir,
        third.package_dir
    );
    assert!(
        !destination
            .path()
            .join(first_manifest.id)
            .join(".install.lock")
            .exists()
    );
}

#[test]
fn installer_rejects_bytecode_and_does_not_replace_current_on_failure() {
    let (source, manifest) = fixture("export function run() { return 1; }");
    let destination = tempfile::tempdir().unwrap();
    let installed = install_local_package(source.path(), destination.path()).unwrap();
    fs::write(source.path().join("unsafe.qjbc"), [0x02, 0xff, 0x00]).unwrap();
    assert_eq!(
        install_local_package(source.path(), destination.path())
            .unwrap_err()
            .code,
        "INVALID_PACKAGE"
    );
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap()
            .package_dir,
        installed.package_dir
    );
}

#[test]
fn concurrent_readers_always_observe_a_complete_installed_generation() {
    let (source, manifest) = fixture("export function run() { return {complete:true}; }");
    let destination = tempfile::tempdir().unwrap();
    install_local_package(source.path(), destination.path()).unwrap();
    let root = destination.path().to_path_buf();
    let source_path = source.path().to_path_buf();
    let running = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let writer_running = running.clone();
    let writer = std::thread::spawn(move || {
        for _ in 0..6 {
            install_local_package(&source_path, &root).unwrap();
        }
        writer_running.store(false, Ordering::SeqCst);
    });
    let mut reads = 0;
    while running.load(Ordering::SeqCst) {
        let package = installed_package(destination.path(), &manifest.id).unwrap();
        assert_eq!(package.manifest, manifest);
        assert!(
            fs::read_to_string(package.package_dir.join("main.js"))
                .unwrap()
                .contains("complete:true")
        );
        reads += 1;
    }
    writer.join().unwrap();
    assert!(reads > 0);
}

#[tokio::test]
async fn named_export_uses_mediated_async_host_io_and_relative_modules() {
    let (dir, manifest) = fixture(
        r#"
        import { decorate } from './helpers.mjs';
        export default function () { throw new Error('default must not be selected'); }
        export async function run(ctx, input) {
            const response = await ctx.http.request({url: 'https://fixture.invalid/data', method: 'GET'});
            await ctx.storage.set({key: 'cached', value: response.body.items});
            const cached = await ctx.storage.get({key: 'cached'});
            await ctx.ui.publish({type: 'text', text: decorate(cached[0])});
            return {cached, input, late: await (await import('./nested/late.js')).late()};
        }
    "#,
    );
    fs::write(
        dir.path().join("helpers.mjs"),
        "export const decorate = value => value.toUpperCase();",
    )
    .unwrap();
    fs::create_dir(dir.path().join("nested")).unwrap();
    fs::write(
        dir.path().join("nested/late.js"),
        "import {decorate} from '../helpers.mjs'; export const late = () => decorate('done');",
    )
    .unwrap();
    let host = Arc::new(RecordingHost::default());
    let result = PluginRunner::run(
        dir.path().into(),
        manifest.clone(),
        "run".into(),
        json!({"count": 3}),
        host.clone(),
        PluginLimits::default(),
    )
    .await
    .unwrap();
    assert_eq!(
        result,
        json!({"cached": ["offline"], "input": {"count": 3}, "late": "DONE"})
    );
    let calls = host.calls.lock().unwrap();
    assert_eq!(
        calls.iter().map(|c| c.1.as_str()).collect::<Vec<_>>(),
        ["http.request", "storage.set", "storage.get", "ui.publish"]
    );
    assert!(
        calls
            .iter()
            .all(|c| c.0 == manifest.id && c.3 == "dansheng-plugin")
    );
    assert_eq!(calls[3].2, json!({"type": "text", "text": "OFFLINE"}));
}

#[tokio::test]
async fn all_callable_permissions_delegate_to_host_and_errors_are_safe() {
    let output = run(r#"
        export async function run(ctx) {
            const methods = [ ['auth','status'], ['sources','upsert'], ['sources','query'],
                ['jobs','schedule'], ['jobs','cancel'], ['jobs','status'], ['notifications','show'],
                ['browser','request'], ['browser','evaluate'], ['capabilities','has'], ['storage','delete'],
                ['browser','open'], ['browser','navigate'], ['browser','login'], ['browser','close'] ];
            const seen = [];
            for (const [group, action] of methods) seen.push((await ctx[group][action]({sample: true})).method);
            try { await ctx.auth.requireLogin({}); } catch (e) { return {seen, code:e.code, message:e.message}; }
        }
    "#, PluginLimits::default()).await.unwrap();
    assert_eq!(output["seen"].as_array().unwrap().len(), 15);
    assert_eq!(output["seen"][9], "capabilities.has");
    assert_eq!(output["code"], "LOGIN_REQUIRED");
    assert!(!output.to_string().contains("host-private"));
    let error = run(
        "export async function run(ctx) { await ctx.auth.requireLogin(); }",
        PluginLimits::default(),
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "LOGIN_REQUIRED");
    let error = run("export function run() { const e = new Error('forged'); e.code = 'LOGIN_REQUIRED'; throw e; }", PluginLimits::default()).await.unwrap_err();
    assert_eq!(error.code, "PLUGIN_JS");
}

// The domain contract is intentionally enumerated independently of the runtime
// allowlist so omitting or exposing a method is observable at the JS boundary.
const DOMAIN_FACADE_METHODS: &[&str] = &[
    "files.download",
    "files.list",
    "files.read",
    "files.delete",
    "files.index",
    "files.export",
    "todo.list",
    "todo.get",
    "todo.create",
    "todo.update",
    "todo.complete",
    "todo.delete",
    "todo.link",
    "calendar.list",
    "calendar.get",
    "calendar.conflicts",
    "calendar.export_ics",
    "calendar.create",
    "calendar.update",
    "calendar.delete",
    "calendar.link",
    "activity.list",
    "activity.sync",
    "activity.read",
    "activity.archive",
    "activity.notifications",
    "reminders.list",
    "reminders.schedule",
    "reminders.cancel",
    "reminders.due",
];

#[tokio::test]
async fn domain_facades_delegate_every_method_with_bound_identity_and_single_json_parameter() {
    let source = r#"
        export async function run(ctx, input) {
            const replies = [];
            for (const method of input.methods) {
                const [group, operation] = method.split('.');
                replies.push(await ctx[group][operation]({marker: method, payload: input.payload}));
            }
            return {replies, defaultParams: await ctx.files.list(), nullParams: await ctx.todo.list(null)};
        }
    "#;
    let (dir, mut manifest) = fixture(source);
    manifest.capabilities = DOMAIN_FACADE_METHODS
        .iter()
        .map(|method| crate::policy::capability_for(method).to_owned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    write_package(dir.path(), &manifest, source);
    let payload = json!({"text": "合成数据", "nested": [false, null, {"value": 3}], "method": "plugins.install"});
    let host = Arc::new(RecordingHost::default());
    let output = PluginRunner::run(
        dir.path().into(),
        manifest.clone(),
        "run".into(),
        json!({"methods": DOMAIN_FACADE_METHODS, "payload": payload}),
        host.clone(),
        PluginLimits::default(),
    )
    .await
    .unwrap();
    let calls = host.calls.lock().unwrap();
    assert_eq!(calls.len(), DOMAIN_FACADE_METHODS.len() + 2);
    for (index, &method) in DOMAIN_FACADE_METHODS.iter().enumerate() {
        let params = json!({"marker": method, "payload": payload});
        assert_eq!(calls[index].0, manifest.id);
        assert_eq!(calls[index].1, method);
        assert_eq!(calls[index].2, params);
        assert_eq!(calls[index].3, "dansheng-plugin");
        assert_eq!(
            output["replies"][index],
            json!({"method": method, "params": params})
        );
    }
    assert_eq!(
        output["defaultParams"],
        json!({"method": "files.list", "params": {}})
    );
    assert_eq!(
        output["nullParams"],
        json!({"method": "todo.list", "params": null})
    );
}

#[tokio::test]
async fn domain_facades_are_frozen_and_expose_no_generic_or_admin_host_access() {
    let output = run(r#"
        export async function run(ctx) {
            const groups = ['files', 'todo', 'calendar', 'activity', 'reminders'];
            const surfaces = groups.map(group => ({group, keys: Object.keys(ctx[group]), frozen: Object.isFrozen(ctx[group])}));
            const exposed = [typeof ctx.invoke, typeof ctx.admin, typeof globalThis.bridge,
                typeof ctx.jobs.reconcile, typeof ctx.jobs.resume,
                ...groups.flatMap(group => [typeof ctx[group].invoke, typeof ctx[group].admin])];
            let blocked = 0;
            for (const group of groups) {
                try { ctx[group].invoke = () => true; } catch (e) { blocked++; }
                try { await ctx[group].invoke('plugins.install', {}); } catch (e) { blocked++; }
            }
            return {surfaces, exposed, blocked};
        }
    "#, PluginLimits::default()).await.unwrap();
    assert_eq!(output["blocked"], 10);
    assert!(
        output["exposed"]
            .as_array()
            .unwrap()
            .iter()
            .all(|value| value == "undefined")
    );
    for surface in output["surfaces"].as_array().unwrap() {
        assert_eq!(surface["frozen"], true);
        let prefix = format!("{}.", surface["group"].as_str().unwrap());
        let expected: Vec<_> = DOMAIN_FACADE_METHODS
            .iter()
            .filter_map(|method| method.strip_prefix(&prefix))
            .collect();
        assert_eq!(surface["keys"], json!(expected));
    }
}

struct OrganizerGrantHost {
    plugin_id: String,
    declared: BTreeSet<String>,
    granted: BTreeSet<String>,
    writes: AtomicUsize,
}

#[async_trait]
impl PluginHost for OrganizerGrantHost {
    async fn call(
        &self,
        plugin_id: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, PluginError> {
        assert_eq!(plugin_id, self.plugin_id);
        // Exercise the parent-owned capability map, rather than inventing
        // method-name permissions in the JS runtime or treating params as grants.
        let capability = crate::organizer::required_capability(method).unwrap();
        if !self.declared.contains(capability) || !self.granted.contains(capability) {
            return Err(PluginError::new(
                "PERMISSION_DENIED",
                "Synthetic private authorization detail",
            ));
        }
        self.writes.fetch_add(1, Ordering::SeqCst);
        Ok(json!({"method": method, "params": params}))
    }
}

#[tokio::test]
async fn organizer_facades_preserve_host_read_write_grants_and_permission_denials() {
    let source = "export async function run(ctx, input) { return await ctx.todo.create(input); }";
    for (declared, granted, allowed) in [
        ("todo.read", "todo.write", false),
        ("todo.write", "todo.read", false),
        ("todo.write", "todo.write", true),
    ] {
        let (dir, mut manifest) = fixture(source);
        manifest.capabilities = vec![declared.into()];
        write_package(dir.path(), &manifest, source);
        let host = Arc::new(OrganizerGrantHost {
            plugin_id: manifest.id.clone(),
            declared: BTreeSet::from([declared.into()]),
            granted: BTreeSet::from([granted.into()]),
            writes: AtomicUsize::new(0),
        });
        let params = json!({"title": "Synthetic task", "principal": "owner", "grants": ["*"]});
        let result = PluginRunner::run(
            dir.path().into(),
            manifest,
            "run".into(),
            params.clone(),
            host.clone(),
            PluginLimits::default(),
        )
        .await;
        if allowed {
            assert_eq!(
                result.unwrap(),
                json!({"method": "todo.create", "params": params})
            );
            assert_eq!(host.writes.load(Ordering::SeqCst), 1);
        } else {
            let error = result.unwrap_err();
            assert_eq!(error.code, "PERMISSION_DENIED");
            assert!(!error.message.contains("private authorization"));
            assert_eq!(host.writes.load(Ordering::SeqCst), 0);
        }
    }
}

#[tokio::test]
async fn only_declared_callable_named_exports_can_run() {
    let error = run(
        "export default function () { return 1; }",
        PluginLimits::default(),
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "PLUGIN_ACTION");
    let error = run("export const run = 42;", PluginLimits::default())
        .await
        .unwrap_err();
    assert_eq!(error.code, "PLUGIN_ACTION");
    let (dir, manifest) = fixture("export function other() { return 1; }");
    assert_eq!(
        PluginRunner::run(
            dir.path().into(),
            manifest,
            "other".into(),
            json!({}),
            Arc::new(RecordingHost::default()),
            PluginLimits::default()
        )
        .await
        .unwrap_err()
        .code,
        "PLUGIN_ACTION"
    );
}

#[tokio::test]
async fn infinite_js_and_microtasks_and_never_settling_promises_hit_wall_deadline() {
    for source in [
        "export function run() { while (true) {} }",
        "while (true) {} export function run() {}",
        "export async function run() { while (true) await Promise.resolve(); }",
        "export function run() { return /(a+)+$/.test('a'.repeat(40) + '!'); }",
        "export function run() { return new Promise(() => {}); }",
        "await new Promise(() => {}); export function run() {}",
    ] {
        let limits = PluginLimits {
            wall_timeout: Duration::from_millis(120),
            ..PluginLimits::default()
        };
        let start = Instant::now();
        let (dir, manifest) = fixture(source);
        let host = Arc::new(RecordingHost::default());
        let error = PluginRunner::run(
            dir.path().into(),
            manifest,
            "run".into(),
            json!({}),
            host.clone(),
            limits,
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, "PLUGIN_TIMEOUT", "{source}");
        assert!(start.elapsed() < Duration::from_secs(2));
        // Prove the execution thread released its VM/host, rather than merely
        // timing out the caller while an orphaned interpreter keeps running.
        tokio::time::timeout(Duration::from_secs(2), async {
            while Arc::strong_count(&host) > 1 {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn heap_and_stack_caps_are_enforced_by_the_vm() {
    let limits = PluginLimits {
        heap_bytes: 2 * 1024 * 1024,
        ..PluginLimits::default()
    };
    let error = run(
        "export function run() { return new ArrayBuffer(64 * 1024 * 1024); }",
        limits,
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "PLUGIN_MEMORY");
    let limits = PluginLimits {
        stack_bytes: 64 * 1024,
        ..PluginLimits::default()
    };
    let error = run(
        "export function run() { function recurse() { return 1 + recurse(); } return recurse(); }",
        limits,
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "PLUGIN_STACK");
}

#[tokio::test]
async fn node_browser_and_blocking_shared_memory_apis_are_absent() {
    let output = run("export function run() { return [typeof process, typeof require, typeof fetch, typeof document, typeof Atomics, typeof SharedArrayBuffer]; }", PluginLimits::default()).await.unwrap();
    assert_eq!(
        output,
        json!([
            "undefined",
            "undefined",
            "undefined",
            "undefined",
            "undefined",
            "undefined"
        ])
    );
}

#[tokio::test]
async fn imports_cannot_escape_or_select_native_or_remote_loaders() {
    for import in [
        "../outside.js",
        "./../outside.js",
        "node:fs",
        "https://fixture.invalid/x.js",
        "/outside.js",
        "C:\\outside.js",
        "./native.dll",
        "./sub/../../outside.js",
    ] {
        for source in [
            format!("import '{import}'; export function run() {{ return 1; }}"),
            format!(
                "export async function run() {{ await import({}); return 1; }}",
                serde_json::to_string(import).unwrap()
            ),
        ] {
            let error = run(&source, PluginLimits::default()).await.unwrap_err();
            assert_eq!(error.code, "PATH_ESCAPE", "{import}");
        }
    }
}

#[test]
fn symlinked_modules_and_directory_escapes_are_rejected() {
    let (dir, _) = fixture("export function run() { return 1; }");
    let outside = tempfile::tempdir().unwrap();
    fs::write(
        outside.path().join("outside.js"),
        "export const privateValue = 1;",
    )
    .unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(outside.path(), dir.path().join("escape")).unwrap();
    #[cfg(windows)]
    {
        // Junctions are reparse points and do not require Developer Mode/admin.
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(dir.path().join("escape"))
            .arg(outside.path())
            .output()
            .unwrap();
        assert!(status.status.success(), "Could not create fixture junction");
    }
    assert_eq!(
        validate_package(dir.path()).unwrap_err().code,
        "PATH_ESCAPE"
    );
    assert!(outside.path().join("outside.js").exists());
}

#[tokio::test]
async fn host_call_count_and_pending_and_payload_quotas_apply() {
    let limits = PluginLimits {
        max_host_calls: 1,
        ..PluginLimits::default()
    };
    let output = run("export async function run(ctx) { await ctx.auth.status(); try { await ctx.auth.status(); } catch (e) { return e.code; } }", limits).await.unwrap();
    assert_eq!(output, "HOST_QUOTA");
    let limits = PluginLimits {
        max_pending_host_calls: 1,
        ..PluginLimits::default()
    };
    let output = run("export async function run(ctx) { return await Promise.allSettled([ctx.auth.status(),ctx.auth.status()]).then(v=>[v[0].status,v[1].reason.code]); }", limits).await.unwrap();
    assert_eq!(output, json!(["fulfilled", "HOST_QUOTA"]));
    let limits = PluginLimits {
        max_host_payload_bytes: 128,
        ..PluginLimits::default()
    };
    let output = run("export async function run(ctx) { try { await ctx.auth.status({data:'x'.repeat(129)}); } catch (e) { return e.code; } }", limits).await.unwrap();
    assert_eq!(output, "HOST_QUOTA");
    let limits = PluginLimits {
        max_host_payload_bytes: 32,
        ..PluginLimits::default()
    };
    let output = run("export async function run(ctx) { try { await ctx.http.request({}); } catch (e) { return e.code; } }", limits).await.unwrap();
    assert_eq!(output, "HOST_QUOTA");
    let limits = PluginLimits {
        max_total_host_bytes: 70,
        ..PluginLimits::default()
    };
    let output = run("export async function run(ctx) { try { await ctx.auth.status(); await ctx.auth.status(); } catch (e) { return e.code; } }", limits).await.unwrap();
    assert_eq!(output, "HOST_QUOTA");
}

#[tokio::test]
async fn unbounded_vm_settings_and_manifest_identity_substitution_are_rejected() {
    let error = run(
        "export function run() { return 1; }",
        PluginLimits {
            heap_bytes: 0,
            ..PluginLimits::default()
        },
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "INVALID_LIMITS");
    let (dir, mut manifest) = fixture(
        "export async function run(ctx) { return await ctx.storage.set({key:'x',value:1}); }",
    );
    manifest.id = "different.identity".into();
    let host = Arc::new(RecordingHost::default());
    let error = PluginRunner::run(
        dir.path().into(),
        manifest,
        "run".into(),
        json!({}),
        host.clone(),
        PluginLimits::default(),
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "INVALID_MANIFEST");
    assert!(host.calls.lock().unwrap().is_empty());
}

#[derive(Default)]
struct WaitingHost {
    started: Notify,
    dropped: Notify,
    writes: AtomicUsize,
    active: AtomicUsize,
}

struct ActiveCall<'a>(&'a WaitingHost);
impl Drop for ActiveCall<'_> {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::SeqCst);
        self.0.dropped.notify_one();
    }
}

#[async_trait]
impl PluginHost for WaitingHost {
    async fn call(&self, _: &str, method: &str, _: Value) -> Result<Value, PluginError> {
        if method == "storage.set" {
            self.writes.fetch_add(1, Ordering::SeqCst);
            return Ok(Value::Null);
        }
        self.active.fetch_add(1, Ordering::SeqCst);
        let _guard = ActiveCall(self);
        self.started.notify_one();
        std::future::pending().await
    }
}

const AFTER_WAIT_WRITE: &str = "export async function run(ctx) { try { await ctx.auth.status(); } catch (e) {} await ctx.storage.set({key:'must-not-write',value:1}); return 1; }";

#[tokio::test]
async fn pending_host_io_has_its_own_timeout_without_retries() {
    let (dir, manifest) = fixture(
        "export async function run(ctx) { try { await ctx.auth.status(); } catch (e) { return e.code; } }",
    );
    let host = Arc::new(WaitingHost::default());
    let limits = PluginLimits {
        host_call_timeout: Duration::from_millis(40),
        ..PluginLimits::default()
    };
    let output = PluginRunner::run(
        dir.path().into(),
        manifest,
        "run".into(),
        json!({}),
        host.clone(),
        limits,
    )
    .await
    .unwrap();
    assert_eq!(output, "HOST_TIMEOUT");
    assert_eq!(host.active.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn wall_deadline_cancels_pending_host_io_without_followup_writes() {
    let (dir, manifest) = fixture(AFTER_WAIT_WRITE);
    let host = Arc::new(WaitingHost::default());
    let limits = PluginLimits {
        wall_timeout: Duration::from_millis(100),
        ..PluginLimits::default()
    };
    let error = PluginRunner::run(
        dir.path().into(),
        manifest,
        "run".into(),
        json!({}),
        host.clone(),
        limits,
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "PLUGIN_TIMEOUT");
    tokio::time::timeout(Duration::from_secs(2), host.dropped.notified())
        .await
        .unwrap();
    assert_eq!(host.active.load(Ordering::SeqCst), 0);
    assert_eq!(host.writes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn dropping_or_explicitly_cancelling_a_run_prevents_followup_writes() {
    for explicit in [false, true] {
        let (dir, manifest) = fixture(AFTER_WAIT_WRITE);
        let host = Arc::new(WaitingHost::default());
        let token = PluginCancellation::new();
        let task = tokio::spawn(PluginRunner::run_with_cancellation(
            dir.path().into(),
            manifest,
            "run".into(),
            json!({}),
            host.clone(),
            PluginLimits::default(),
            token.clone(),
        ));
        tokio::time::timeout(Duration::from_secs(2), host.started.notified())
            .await
            .unwrap();
        if explicit {
            token.cancel();
            assert_eq!(task.await.unwrap().unwrap_err().code, "PLUGIN_CANCELLED");
        } else {
            task.abort();
            assert!(task.await.unwrap_err().is_cancelled());
        }
        tokio::time::timeout(Duration::from_secs(2), host.dropped.notified())
            .await
            .unwrap();
        assert_eq!(host.active.load(Ordering::SeqCst), 0);
        assert_eq!(host.writes.load(Ordering::SeqCst), 0);
    }
}

#[tokio::test]
async fn exceptions_are_redacted_and_each_run_has_a_fresh_global_scope() {
    let error = run(
        "export function run() { throw new Error('synthetic-secret-not-for-diagnostics'); }",
        PluginLimits::default(),
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "PLUGIN_JS");
    assert!(
        !serde_json::to_string(&error)
            .unwrap()
            .contains("synthetic-secret")
    );
    let error = run("export async function run() { try { await import('../outside.js'); } catch (e) {} throw new Error('different error'); }", PluginLimits::default()).await.unwrap_err();
    assert_eq!(error.code, "PLUGIN_JS");
    for _ in 0..2 {
        assert_eq!(run("export function run() { return globalThis.counter = (globalThis.counter || 0) + 1; }", PluginLimits::default()).await.unwrap(), 1);
    }
}
