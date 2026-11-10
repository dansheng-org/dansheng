use dansheng_core::{Engine, PrincipalKind, Response, UnavailablePlatform};
use dansheng_host::{Client, HostPaths, frame, mcp::McpAdapter, serve_connection};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};

#[tokio::test]
async fn first_frame_authentication_and_malformed_requests() {
    let temp = tempfile::tempdir().unwrap();
    let engine = Engine::open(temp.path(), Arc::new(UnavailablePlatform)).unwrap();
    let token = "offline-contract-client-token-32-characters";
    engine
        .register_client("test-mcp", PrincipalKind::Mcp, token)
        .unwrap();
    for first in [
        json!({"id":"x","method":"core.info"}),
        json!({"token":"wrong"}),
        json!({"token":token,"principal":{"id":"owner","kind":"owner"}}),
    ] {
        let (mut client, server) = tokio::io::duplex(8192);
        let engine = engine.clone();
        let task = tokio::spawn(async move { serve_connection(server, engine).await });
        frame::write_json(&mut client, &first).await.unwrap();
        let response: Response = frame::read_json(&mut client).await.unwrap();
        assert_eq!(response.error.unwrap().code, "Unauthenticated");
        task.await.unwrap().unwrap();
    }
    let (mut client, server) = tokio::io::duplex(8192);
    let task = tokio::spawn(async move { serve_connection(server, engine).await });
    frame::write_json(&mut client, &json!({"token":token}))
        .await
        .unwrap();
    let auth: Response = frame::read_json(&mut client).await.unwrap();
    assert_eq!(auth.result.unwrap()["principal"]["id"], "test-mcp");
    frame::write_json(&mut client, &json!({"malformed":true}))
        .await
        .unwrap();
    assert_eq!(
        frame::read_json::<_, Response>(&mut client)
            .await
            .unwrap()
            .error
            .unwrap()
            .code,
        "InvalidInput"
    );
    frame::write_json(&mut client, &json!({"id":"spoof","method":"permissions.set","principal":{"id":"owner","kind":"owner"},"params":{"principal":"owner","subject":"test-mcp","grant":{"capabilities":["sources.read"]}}})).await.unwrap();
    assert_eq!(
        frame::read_json::<_, Response>(&mut client)
            .await
            .unwrap()
            .error
            .unwrap()
            .code,
        "PermissionDenied"
    );
    frame::write_json(&mut client, &json!({"id":"health","method":"core.info"}))
        .await
        .unwrap();
    assert_eq!(
        frame::read_json::<_, Response>(&mut client)
            .await
            .unwrap()
            .result
            .unwrap()["principal"],
        "test-mcp"
    );
    drop(client);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn offline_cli_restore_rejects_invalid_snapshot_without_creating_host_files() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("not-created");
    let snapshot = temp.path().join("missing-snapshot");
    let output = tokio::process::Command::new(env!("CARGO_BIN_EXE_dansheng-host"))
        .arg("restore")
        .arg(&snapshot)
        .arg("--data-dir")
        .arg(&target)
        // Offline restore must never try to read IPC client configuration.
        .arg("--client-config")
        .arg(temp.path().join("missing-client.json"))
        .output()
        .await
        .unwrap();
    assert!(!output.status.success());
    assert!(
        !target.exists(),
        "invalid snapshot must not create the target or host artifacts"
    );
    let error: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert!(error["error"]["code"].is_string());
}

#[tokio::test]
async fn offline_cli_restore_requires_a_closed_profile_and_returns_core_receipt() {
    use dansheng_core::store::Store;
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let target = temp.path().join("target");
    let source_store = Store::open(&source).unwrap();
    source_store
        .kv_set("fixture", "proof", &json!({"snapshot":true}))
        .unwrap();
    let snapshot = dansheng_core::backup::create(&source_store).unwrap();
    let path = std::path::Path::new(snapshot["path"].as_str().unwrap());
    drop(source_store);
    let target_store = Store::open(&target).unwrap();
    target_store
        .kv_set("fixture", "after", &json!({"current":true}))
        .unwrap();
    let blocked = tokio::process::Command::new(env!("CARGO_BIN_EXE_dansheng-host"))
        .arg("restore")
        .arg(path)
        .arg("--data-dir")
        .arg(&target)
        .output()
        .await
        .unwrap();
    assert!(!blocked.status.success());
    let error: Value = serde_json::from_slice(&blocked.stderr).unwrap();
    assert_eq!(error["error"]["code"], "DataDirectoryInUse");
    assert_eq!(
        target_store.kv_get("fixture", "after").unwrap()["current"],
        true
    );
    assert!(!target.join("host").exists());
    drop(target_store);

    let restored = tokio::process::Command::new(env!("CARGO_BIN_EXE_dansheng-host"))
        .arg("restore")
        .arg(path)
        .arg("--data-dir")
        .arg(&target)
        .output()
        .await
        .unwrap();
    if !restored.status.success() {
        let error: Value = serde_json::from_slice(&restored.stderr).unwrap();
        panic!(
            "offline restore failed with code {}",
            error["error"]["code"]
        );
    }
    let receipt: Value = serde_json::from_slice(&restored.stdout).unwrap();
    assert_eq!(receipt["restored"], true);
    assert!(std::path::Path::new(receipt["previous_profile"].as_str().unwrap()).is_dir());
    assert!(
        !target.join("host").exists(),
        "restore must not provision IPC tokens or start a service"
    );
    let reopened = Store::open(&target).unwrap();
    assert_eq!(
        reopened.kv_get("fixture", "proof").unwrap()["snapshot"],
        true
    );
    assert!(reopened.kv_get("fixture", "after").unwrap().is_null());
}

async fn successful(client: &Client, method: &str, params: Value) -> Value {
    let response = client.invoke(method, params).await.unwrap();
    assert!(response.error.is_none(), "{response:?}");
    response.result.unwrap_or(Value::Null)
}

async fn rpc(
    stdin: &mut tokio::process::ChildStdin,
    stdout: &mut tokio::io::Lines<tokio::io::BufReader<tokio::process::ChildStdout>>,
    request: Value,
) -> Value {
    use tokio::io::AsyncWriteExt;
    let mut line = request.to_string().into_bytes();
    line.push(b'\n');
    stdin.write_all(&line).await.unwrap();
    stdin.flush().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let line = stdout.next_line().await.unwrap().expect("MCP stdout ended");
            let response: Value =
                serde_json::from_str(&line).expect("MCP stdout must contain only JSON-RPC");
            if response["id"] == request["id"] {
                break response;
            }
        }
    })
    .await
    .unwrap()
}

async fn exercise_cli_and_mcp_stdio(paths: &HostPaths) {
    use std::process::Stdio;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let binary = env!("CARGO_BIN_EXE_dansheng-host");
    let output = tokio::process::Command::new(binary)
        .arg("call")
        .arg("core.info")
        .arg("--data-dir")
        .arg(&paths.data)
        .output()
        .await
        .unwrap();
    assert!(output.status.success(), "CLI failed");
    let response: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(response["result"]["principal"], "owner");

    let mut process = tokio::process::Command::new(binary)
        .arg("mcp")
        .arg("--data-dir")
        .arg(&paths.data)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = process.stdin.take().unwrap();
    let mut stdout = tokio::io::BufReader::new(process.stdout.take().unwrap()).lines();
    let response = rpc(&mut stdin,&mut stdout,json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"offline-contract","version":"1"}}})).await;
    assert!(
        response["result"]["capabilities"]["tools"].is_object(),
        "{response}"
    );
    stdin
        .write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
        .await
        .unwrap();
    let response = rpc(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}),
    )
    .await;
    assert!(
        response["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .any(|tool| tool["name"] == "core_call")
    );
    let response = rpc(&mut stdin,&mut stdout,json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sources_query","arguments":{}}})).await;
    assert_ne!(response["result"]["isError"], true, "{response}");
    let response = rpc(&mut stdin,&mut stdout,json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"core_call","arguments":{"method":"permissions.set","params":{"principal":"owner"}}}})).await;
    assert_eq!(response["result"]["isError"], true, "{response}");
    let response = rpc(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":5,"method":"resources/list","params":{}}),
    )
    .await;
    assert!(
        response["result"]["resources"]
            .as_array()
            .unwrap()
            .iter()
            .any(|resource| resource["uri"] == "dansheng://schema")
    );
    let response = rpc(&mut stdin,&mut stdout,json!({"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"dansheng://schema"}})).await;
    let schema: Value =
        serde_json::from_str(response["result"]["contents"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(schema["ipc"]["maxFrameBytes"], frame::MAX_FRAME);
    let response = rpc(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":7,"method":"resources/templates/list","params":{}}),
    )
    .await;
    assert!(
        response["result"]["resourceTemplates"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value["uriTemplate"] == "dansheng://mail/{account_id}/messages")
    );
    let response=rpc(&mut stdin,&mut stdout,json!({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"core_call","arguments":{"method":"todo.list","params":{}}}})).await;
    assert_ne!(response["result"]["isError"], true, "{response}");
    #[cfg(feature = "services")]
    {
        let response=rpc(&mut stdin,&mut stdout,json!({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"core_call","arguments":{"method":"mail.status","params":{"account_id":"offline-mail"}}}})).await;
        let core: Value =
            serde_json::from_str(response["result"]["content"][0]["text"].as_str().unwrap())
                .unwrap();
        assert_eq!(core["result"]["configured"], false);
        let response=rpc(&mut stdin,&mut stdout,json!({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"core_call","arguments":{"method":"vault.get","params":{"key":"never-expose"}}}})).await;
        assert_eq!(response["result"]["isError"], true);
    }
    drop(stdin);
    assert!(
        tokio::time::timeout(Duration::from_secs(5), process.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_local_transport_grants_scheduler_and_token_restart() {
    let temp = tempfile::tempdir().unwrap();
    let paths = HostPaths::new(temp.path()).unwrap();
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let server_paths = paths.clone();
    let server = tokio::spawn(async move {
        dansheng_host::serve(server_paths, async {
            let _ = stopped.await;
        })
        .await
    });
    let owner = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            match Client::connect(&paths.owner).await {
                Ok(c) => break c,
                Err(_) => tokio::time::sleep(Duration::from_millis(25)).await,
            }
        }
    })
    .await
    .unwrap();
    assert!(owner.principal.is_owner());
    let original = std::fs::read(&paths.owner.token_file).unwrap();
    let bad = Client::connect_token(&paths.owner.endpoint, "invalid-offline-token".into()).await;
    assert_eq!(bad.err().unwrap().code, "Unauthenticated");
    assert!(McpAdapter::connect(&paths.owner).await.is_err());
    let mcp = McpAdapter::connect(&paths.mcp).await.unwrap();
    assert_eq!(
        mcp.dispatch("sources.query", json!({}))
            .await
            .unwrap()
            .error
            .unwrap()
            .code,
        "PermissionDenied"
    );
    successful(&owner,"permissions.set",json!({"subject":"desktop-mcp","grant":{"capabilities":["sources.read","permissions.set","jobs.status","todo.read","mail.read"],"account_ids":["offline-mail"]}})).await;
    assert!(
        mcp.dispatch("sources.query", json!({}))
            .await
            .unwrap()
            .error
            .is_none()
    );
    assert_eq!(
        mcp.dispatch("permissions.set", json!({}))
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    let raw_mcp = Client::connect(&paths.mcp).await.unwrap();
    assert_eq!(raw_mcp.invoke("permissions.set",json!({"principal":{"id":"owner","kind":"owner"},"subject":"desktop-mcp","grant":{"capabilities":["http.request"]}})).await.unwrap().error.unwrap().code,"PermissionDenied");

    exercise_cli_and_mcp_stdio(&paths).await;

    // A real local JS fixture exercises the host scheduler, without external services.
    let package = temp.path().join("fixture-package");
    std::fs::create_dir(&package).unwrap();
    std::fs::write(package.join("manifest.json"),json!({"id":"host-fixture","version":"1.0.0","api_version":1,"entry":"index.js","name":"Host scheduler offline fixture","capabilities":["storage.write"],"network":[],"actions":{"record":{"description":"write local fixture","mutating":false}}}).to_string()).unwrap();
    std::fs::write(package.join("index.js"),"export async function record(ctx, input) { await ctx.storage.set({key:'scheduler-proof',value:input}); return {recorded:true}; }").unwrap();
    successful(&owner, "plugins.install", json!({"path":package})).await;
    successful(
        &owner,
        "plugins.enable",
        json!({"plugin_id":"host-fixture"}),
    )
    .await;
    successful(
        &owner,
        "permissions.set",
        json!({"subject":"plugin:host-fixture","grant":{"capabilities":["storage.write"]}}),
    )
    .await;
    let job = successful(
        &owner,
        "jobs.schedule",
        json!({"plugin_id":"host-fixture","action":"record","input":{"offline":true}}),
    )
    .await;
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let status = successful(&owner, "jobs.status", json!({"job_id":job["job_id"]})).await;
            if status["state"] == "succeeded" {
                break;
            }
            assert_ne!(status["state"], "failed", "{status}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .unwrap();
    drop(owner);
    drop(mcp);
    drop(raw_mcp);
    stop.send(()).unwrap();
    server.await.unwrap().unwrap();
    assert!(std::fs::read(&paths.owner.token_file).unwrap() == original);
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let server_paths = paths.clone();
    let server = tokio::spawn(async move {
        dansheng_host::serve(server_paths, async {
            let _ = stopped.await;
        })
        .await
    });
    let client = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Ok(client) = Client::connect(&paths.owner).await {
                break client;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .unwrap();
    assert!(
        successful(&client, "core.info", json!({}))
            .await
            .is_object()
    );
    drop(client);
    stop.send(()).unwrap();
    server.await.unwrap().unwrap();
}
#[test]
fn a_missing_profile_and_its_created_form_have_the_same_ipc_endpoint() {
    let parent = tempfile::tempdir().unwrap();
    let profile = parent.path().join("new-profile");
    let before = dansheng_host::HostPaths::new(&profile).unwrap();
    assert!(!profile.exists());
    std::fs::create_dir_all(&profile).unwrap();
    let after = dansheng_host::HostPaths::new(&profile).unwrap();
    assert_eq!(before.owner.endpoint, after.owner.endpoint);
}

#[tokio::test]
async fn host_start_does_not_recreate_a_profile_during_offline_restore_swap() {
    let parent = tempfile::tempdir().unwrap();
    let profile = parent.path().join("profile");
    drop(dansheng_core::store::Store::open(&profile).unwrap());
    let guard = dansheng_core::store::Store::acquire_profile_lock(&profile).unwrap();
    let previous = parent.path().join("previous");
    std::fs::rename(&profile, &previous).unwrap();
    let paths = dansheng_host::HostPaths::new(&profile).unwrap();
    let error = dansheng_host::serve(paths, async {}).await.unwrap_err();
    assert_eq!(error.code, "DataDirectoryInUse");
    assert!(!profile.exists());
    std::fs::rename(previous, profile).unwrap();
    drop(guard);
}
