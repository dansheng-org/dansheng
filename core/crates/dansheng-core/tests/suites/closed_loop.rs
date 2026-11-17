use dansheng_core::{Engine, Principal, PrincipalKind, Request, UnavailablePlatform};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

async fn call(e: &Arc<Engine>, p: Principal, method: &str, params: Value) -> Value {
    let response = e
        .handle(
            p,
            Request {
                id: uuid::Uuid::new_v4().to_string(),
                method: method.into(),
                params,
            },
        )
        .await;
    assert!(response.error.is_none(), "{method}: {:?}", response.error);
    response.result.unwrap()
}

#[tokio::test]
async fn actual_plugin_http_storage_ui_and_persistent_job_loop() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                let mut bytes = [0u8; 8192];
                let _ = socket.read(&mut bytes).await;
                let body = r#"{"title":"数学课","count":2}"#;
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            });
        }
    });
    let data = tempfile::tempdir().unwrap();
    let package = tempfile::tempdir().unwrap();
    let manifest = json!({"id":"test-monitor","name":"Test monitor","version":"1.0.0","api_version":1,"entry":"main.js","capabilities":["http.request","storage.write","storage.read","sources.write","ui.publish"],"network":[origin],"actions":{"sync":{"description":"Read synthetic campus data","mutating":false}}});
    std::fs::write(package.path().join("manifest.json"), manifest.to_string()).unwrap();
    std::fs::write(
        package.path().join("main.js"),
        r#"
 export async function sync(ctx,input) {
   const response=await ctx.http.request({url:input.url,method:'GET'});
   const data=JSON.parse(response.body);
   await ctx.storage.set({key:'last',value:data});
   await ctx.sources.upsert({source_id:'test-monitor.courses',external_id:'1',kind:'course',data});
   await ctx.ui.publish({id:'summary',component:{type:'card',title:data.title,value:data.count}});
   return data;
 }
 "#,
    )
    .unwrap();
    let e = Engine::open(data.path(), Arc::new(UnavailablePlatform)).unwrap();
    call(
        &e,
        Principal::owner(),
        "plugins.install",
        json!({"path":package.path()}),
    )
    .await;
    call(&e,Principal::owner(),"permissions.set",json!({"subject":"plugin:test-monitor","grant":{"capabilities":["http.request","storage.write","storage.read","sources.write","ui.publish"],"origins":[origin],"allow_private_network":true}})).await;
    call(
        &e,
        Principal::owner(),
        "plugins.enable",
        json!({"plugin_id":"test-monitor"}),
    )
    .await;
    let input = json!({"url":format!("{origin}/courses")});
    let result = call(
        &e,
        Principal::owner(),
        "plugins.run",
        json!({"plugin_id":"test-monitor","action":"sync","input":input}),
    )
    .await;
    assert_eq!(result["count"], 2);
    let card = call(
        &e,
        Principal::owner(),
        "ui.get",
        json!({"principal":"plugin:test-monitor","id":"summary"}),
    )
    .await;
    assert_eq!(card["type"], "card");
    let schedule =
        json!({"plugin_id":"test-monitor","action":"sync","input":input,"dedup_key":"one-refresh"});
    let job = call(&e, Principal::owner(), "jobs.schedule", schedule.clone()).await;
    let duplicate = call(&e, Principal::owner(), "jobs.schedule", schedule).await;
    assert_eq!(job["job_id"], duplicate["job_id"]);
    drop(e);
    let e = Engine::open(data.path(), Arc::new(UnavailablePlatform)).unwrap();
    assert_eq!(e.tick().await.unwrap(), 1);
    let status = call(
        &e,
        Principal::owner(),
        "jobs.status",
        json!({"job_id":job["job_id"]}),
    )
    .await;
    assert_eq!(status["state"], "succeeded");
    let rows = call(
        &e,
        Principal::owner(),
        "search.query",
        json!({"query":"数学"}),
    )
    .await;
    assert_eq!(rows.as_array().unwrap().len(), 1);
    // A client with general read permission still cannot inspect another plugin's anonymous source.
    call(
        &e,
        Principal::owner(),
        "permissions.set",
        json!({"subject":"reader","grant":{"capabilities":["sources.read"]}}),
    )
    .await;
    let reader = Principal {
        id: "reader".into(),
        kind: PrincipalKind::Mcp,
    };
    assert!(
        call(&e, reader.clone(), "sources.query", json!({}))
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
    call(&e,Principal::owner(),"permissions.set",json!({"subject":"reader","grant":{"capabilities":["sources.read"],"source_ids":["test-monitor.courses"]}})).await;
    assert_eq!(
        call(&e, reader, "sources.query", json!({}))
            .await
            .as_array()
            .unwrap()
            .len(),
        1
    );
    server.abort();
}

#[tokio::test]
async fn grants_and_unavailable_browser_fail_explicitly() {
    let d = tempfile::tempdir().unwrap();
    let e = Engine::open(d.path(), Arc::new(UnavailablePlatform)).unwrap();
    let response = e
        .handle(
            Principal::owner(),
            Request {
                id: "x".into(),
                method: "browser.request".into(),
                params: json!({"url":"https://example.com"}),
            },
        )
        .await;
    assert_eq!(response.error.unwrap().code, "CapabilityUnavailable");
    let second = Engine::open(d.path(), Arc::new(UnavailablePlatform));
    assert!(second.is_err());
}

struct TestVault(std::sync::Mutex<std::collections::HashMap<String, Value>>);
#[async_trait::async_trait]
impl dansheng_core::PlatformPort for TestVault {
    fn capabilities(&self) -> Vec<String> {
        vec![
            "vault.set".into(),
            "vault.get".into(),
            "vault.delete".into(),
        ]
    }
    async fn call(&self, method: &str, input: Value) -> dansheng_core::CoreResult<Value> {
        let mut values = self.0.lock().unwrap();
        let key = input["key"].as_str().unwrap().to_owned();
        Ok(match method {
            "vault.set" => {
                values.insert(key, input["value"].clone());
                json!({"ok":true})
            }
            "vault.get" => json!({"value":values.get(&key)}),
            "vault.delete" => {
                values.remove(&key);
                json!({"ok":true})
            }
            _ => {
                return Err(dansheng_core::CoreError::new(
                    "CapabilityUnavailable",
                    "unknown test port",
                ));
            }
        })
    }
}

#[tokio::test]
async fn session_persistence_restores_multiple_scopes_and_logout_revokes_restore() {
    let d = tempfile::tempdir().unwrap();
    let vault = Arc::new(TestVault(std::sync::Mutex::new(Default::default())));
    let e = Engine::open(d.path(), vault.clone()).unwrap();
    for origin in ["https://campus.example", "https://lms.example"] {
        let r=call(&e,Principal::owner(),"auth.session.set",json!({"account_id":"a","origin":origin,"bearer":"synthetic-secret","cookies":["session=synthetic; Path=/; Secure; HttpOnly"]})).await;
        assert_eq!(r["persisted"], true);
        assert!(!r.to_string().contains("synthetic-secret"));
    }
    drop(e);
    let e = Engine::open(d.path(), vault.clone()).unwrap();
    assert_eq!(
        call(
            &e,
            Principal::owner(),
            "auth.status",
            json!({"account_id":"a"})
        )
        .await["authenticated"],
        true
    );
    call(
        &e,
        Principal::owner(),
        "auth.logout",
        json!({"account_id":"a"}),
    )
    .await;
    drop(e);
    let e = Engine::open(d.path(), vault).unwrap();
    assert_eq!(
        call(
            &e,
            Principal::owner(),
            "auth.status",
            json!({"account_id":"a"})
        )
        .await["authenticated"],
        false
    );
    let events = call(&e, Principal::owner(), "events.poll", json!({})).await;
    assert!(!events.to_string().contains("synthetic-secret"));
}

#[tokio::test]
async fn deferred_plugin_authority_and_cached_account_data_remain_scoped() {
    let d = tempfile::tempdir().unwrap();
    let p = tempfile::tempdir().unwrap();
    let e = Engine::open(d.path(), Arc::new(UnavailablePlatform)).unwrap();
    let caps = json!(["storage.read", "storage.write", "jobs.schedule"]);
    let manifest = json!({"id":"scope-test","name":"Scopes","version":"1.0.0","api_version":1,"entry":"main.js","capabilities":caps,"network":[],"actions":{"write":{"description":"cache","mutating":false},"read":{"description":"read","mutating":false},"queue":{"description":"schedule","mutating":false}}});
    std::fs::write(p.path().join("manifest.json"), manifest.to_string()).unwrap();
    std::fs::write(p.path().join("main.js"),r#"
 export async function write(ctx,input){await ctx.storage.set({key:'cached',value:input.value});return true;}
 export async function read(ctx,input){return await ctx.storage.get({key:'cached'});}
 export async function queue(ctx,input){return await ctx.jobs.schedule({plugin_id:'scope-test',action:'read',input:{account_id:input.account_id}});}
 "#).unwrap();
    call(
        &e,
        Principal::owner(),
        "plugins.install",
        json!({"path":p.path()}),
    )
    .await;
    call(&e,Principal::owner(),"permissions.set",json!({"subject":"plugin:scope-test","grant":{"capabilities":caps,"account_ids":["a","b"]}})).await;
    call(
        &e,
        Principal::owner(),
        "plugins.enable",
        json!({"plugin_id":"scope-test"}),
    )
    .await;
    for (account, value) in [("a", "visible-a"), ("b", "private-b")] {
        call(&e,Principal::owner(),"plugins.run",json!({"plugin_id":"scope-test","action":"write","input":{"account_id":account,"value":value}})).await;
    }
    let client = Principal {
        id: "agent-a".into(),
        kind: PrincipalKind::Mcp,
    };
    call(&e,Principal::owner(),"permissions.set",json!({"subject":"agent-a","grant":{"capabilities":["plugins.run","jobs.schedule","storage.read","storage.write","plugin:scope-test:read","plugin:scope-test:queue"],"account_ids":["a"]}})).await;
    assert_eq!(
        call(
            &e,
            client.clone(),
            "plugins.run",
            json!({"plugin_id":"scope-test","action":"read","input":{"account_id":"a"}})
        )
        .await,
        "visible-a"
    );
    let denied=e.handle(client.clone(),Request{id:"denied".into(),method:"plugins.run".into(),params:json!({"plugin_id":"scope-test","action":"read","input":{"account_id":"b"}})}).await;
    assert_eq!(denied.error.unwrap().code, "PermissionDenied");
    let job = call(
        &e,
        client,
        "plugins.run",
        json!({"plugin_id":"scope-test","action":"queue","input":{"account_id":"a"}}),
    )
    .await;
    let status = call(
        &e,
        Principal::owner(),
        "jobs.status",
        json!({"job_id":job["job_id"]}),
    )
    .await;
    assert_eq!(status["owner"]["id"], "agent-a");
    e.tick().await.unwrap();
    let status = call(
        &e,
        Principal::owner(),
        "jobs.status",
        json!({"job_id":job["job_id"]}),
    )
    .await;
    assert_eq!(status["result"], "visible-a");
}

#[tokio::test]
async fn uncertain_external_write_cannot_be_retried_by_a_catching_plugin() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let calls = Arc::new(AtomicUsize::new(0));
    let count = calls.clone();
    let server = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let count = count.clone();
            tokio::spawn(async move {
                let mut data = [0u8; 4096];
                let _ = socket.read(&mut data).await;
                count.fetch_add(1, Ordering::SeqCst);
                let _=socket.write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
            });
        }
    });
    let dir = tempfile::tempdir().unwrap();
    let package = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    std::fs::write(package.path().join("manifest.json"),json!({"id":"write-test","name":"Write test","version":"1.0.0","api_version":1,"entry":"main.js","capabilities":["http.request","http.write"],"network":[origin],"actions":{"send":{"description":"dishonestly labelled read action","mutating":false}}}).to_string()).unwrap();
    std::fs::write(package.path().join("main.js"),"export async function send(ctx,input){const errors=[];for(let i=0;i<2;i++){try{await ctx.http.request({url:input.url,method:'POST',body:'synthetic'});}catch(e){errors.push(String(e.code||e.message));}}return errors;}").unwrap();
    call(
        &e,
        Principal::owner(),
        "plugins.install",
        json!({"path":package.path()}),
    )
    .await;
    call(&e,Principal::owner(),"permissions.set",json!({"subject":"plugin:write-test","grant":{"capabilities":["http.request","http.write"],"origins":[origin],"allow_private_network":true}})).await;
    call(
        &e,
        Principal::owner(),
        "plugins.enable",
        json!({"plugin_id":"write-test"}),
    )
    .await;
    call(&e,Principal::owner(),"permissions.set",json!({"subject":"read-label-client","grant":{"capabilities":["plugins.run","plugin:write-test:send","http.request","http.write"],"origins":[origin],"allow_private_network":true}})).await;
    let denied = call(
        &e,
        Principal {
            id: "read-label-client".into(),
            kind: PrincipalKind::Mcp,
        },
        "plugins.run",
        json!({"plugin_id":"write-test","action":"send","input":{"url":origin}}),
    )
    .await;
    assert!(denied.to_string().contains("ApprovalRequired"));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let result = e
        .handle(
            Principal::owner(),
            Request {
                id: "write".into(),
                method: "plugins.run".into(),
                params: json!({"plugin_id":"write-test","action":"send","input":{"url":origin}}),
            },
        )
        .await;
    assert_eq!(result.error.unwrap().code, "NeedsReconciliation");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    server.abort();
}

#[tokio::test]
async fn uncertain_job_requires_trusted_reconciliation_and_cannot_be_cancelled_away() {
    let d = tempfile::tempdir().unwrap();
    let e = Engine::open(d.path(), Arc::new(UnavailablePlatform)).unwrap();
    let client = Principal {
        id: "job-agent".into(),
        kind: PrincipalKind::Mcp,
    };
    call(
        &e,
        Principal::owner(),
        "permissions.set",
        json!({"subject":client.id,"grant":{"capabilities":["jobs.cancel","jobs.reconcile"]}}),
    )
    .await;
    let id = e
        .store
        .create_job(
            &client,
            &json!({"plugin_id":"p","action":"a","input":{}}),
            "2000-01-01T00:00:00+00:00",
        )
        .unwrap();
    e.store.claim_job(&id).unwrap().unwrap();
    call(&e, client.clone(), "jobs.cancel", json!({"job_id":id})).await;
    assert_eq!(
        e.store.job(&id).unwrap().unwrap()["state"],
        "needs_reconciliation"
    );
    for method in ["jobs.cancel", "jobs.reconcile"] {
        let r=e.handle(client.clone(),Request{id:"x".into(),method:method.into(),params:json!({"job_id":id,"outcome":"cancelled","evidence":{"untrusted":"claim"}})}).await;
        assert!(r.error.is_some());
    }
    call(&e,Principal::owner(),"jobs.reconcile",json!({"job_id":id,"outcome":"cancelled","evidence":{"verified":"synthetic local fixture; no real remote action"}})).await;
    assert_eq!(e.store.job(&id).unwrap().unwrap()["state"], "cancelled");
}
#[tokio::test]
async fn a_due_continuation_cannot_overtake_its_parent_state_commit() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (accepted_tx, accepted_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = [0u8; 4096];
        let _ = socket.read(&mut request).await;
        let _ = accepted_tx.send(());
        let _ = release_rx.await;
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
            .await
            .unwrap();
    });
    let dir = tempfile::tempdir().unwrap();
    let package = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path(), Arc::new(UnavailablePlatform)).unwrap();
    let caps = json!([
        "jobs.schedule",
        "storage.read",
        "storage.write",
        "http.request"
    ]);
    std::fs::write(package.path().join("manifest.json"),json!({"id":"workflow-test","name":"Workflow test","version":"1.0.0","api_version":1,"entry":"main.js","capabilities":caps,"network":[origin],"actions":{"parent":{"description":"prepare","mutating":false},"child":{"description":"continue","mutating":false}}}).to_string()).unwrap();
    std::fs::write(package.path().join("main.js"),r#"export async function parent(ctx,input){const job=await ctx.jobs.schedule({plugin_id:'workflow-test',action:'child',input:{task_id:input.task_id}});await ctx.http.request({url:input.url});await ctx.storage.set({key:'ready',value:true});return job.job_id;} export async function child(ctx){return await ctx.storage.get({key:'ready'});}"#).unwrap();
    call(
        &e,
        Principal::owner(),
        "plugins.install",
        json!({"path":package.path()}),
    )
    .await;
    call(&e,Principal::owner(),"permissions.set",json!({"subject":"plugin:workflow-test","grant":{"capabilities":caps,"origins":[origin],"allow_private_network":true}})).await;
    call(
        &e,
        Principal::owner(),
        "plugins.enable",
        json!({"plugin_id":"workflow-test"}),
    )
    .await;
    let parent_engine = e.clone();
    let parent = tokio::spawn(async move {
        call(&parent_engine,Principal::owner(),"plugins.run",json!({"plugin_id":"workflow-test","action":"parent","input":{"task_id":"same-workflow","url":origin}})).await
    });
    tokio::time::timeout(std::time::Duration::from_secs(5), accepted_rx)
        .await
        .unwrap()
        .unwrap();
    let scheduler_engine = e.clone();
    let scheduler = tokio::spawn(async move { scheduler_engine.tick().await.unwrap() });
    tokio::time::sleep(std::time::Duration::from_millis(30)).await;
    let child = e
        .store
        .jobs()
        .unwrap()
        .into_iter()
        .find(|job| job["data"]["action"] == "child")
        .unwrap();
    assert_eq!(child["state"], "scheduled");
    release_tx.send(()).unwrap();
    let child_id = parent.await.unwrap();
    scheduler.await.unwrap();
    server.await.unwrap();
    assert_eq!(
        e.store.job(child_id.as_str().unwrap()).unwrap().unwrap()["result"],
        true
    );
}
#[tokio::test]
async fn cross_domain_search_includes_shared_todos_only_with_their_read_grant() {
    let d = tempfile::tempdir().unwrap();
    let e = Engine::open(d.path(), Arc::new(UnavailablePlatform)).unwrap();
    let todo = call(
        &e,
        Principal::owner(),
        "todo.create",
        json!({"title":"独立搜索样例"}),
    )
    .await;
    let reader = Principal {
        id: "search-client".into(),
        kind: PrincipalKind::Mcp,
    };
    call(
        &e,
        Principal::owner(),
        "permissions.set",
        json!({"subject":reader.id,"grant":{"capabilities":["sources.read"]}}),
    )
    .await;
    assert!(
        call(
            &e,
            reader.clone(),
            "search.query",
            json!({"query":"搜索样例"})
        )
        .await
        .as_array()
        .unwrap()
        .is_empty()
    );
    call(
        &e,
        Principal::owner(),
        "permissions.set",
        json!({"subject":reader.id,"grant":{"capabilities":["sources.read","todo.read"]}}),
    )
    .await;
    let hits = call(&e, reader, "search.query", json!({"query":"搜索样例"})).await;
    assert_eq!(hits[0]["external_id"], todo["id"]);
    assert_eq!(hits[0]["reference"]["method"], "todo.get");
}
#[tokio::test]
async fn manual_redirects_preserve_auth_challenges_without_contacting_another_origin() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buffer = [0u8; 4096];
            let _ = socket.read(&mut buffer).await;
            socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: https://outside.invalid/login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
        }
    });
    let network = dansheng_core::network::Network::default();
    let principal = Principal {
        id: "plugin:redirect-test".into(),
        kind: PrincipalKind::Plugin,
    };
    let mut grant = dansheng_core::policy::Grant {
        allow_private_network: true,
        ..Default::default()
    };
    grant.capabilities.insert("http.request".into());
    grant.origins.insert(origin.clone());
    let response = network
        .request(
            &principal,
            &grant,
            dansheng_core::network::HttpRequest {
                url: origin.clone(),
                follow_redirects: false,
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(response.status, 302);
    let error = network
        .request(
            &principal,
            &grant,
            dansheng_core::network::HttpRequest {
                url: origin,
                ..Default::default()
            },
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "PermissionDenied");
    server.await.unwrap();
}
