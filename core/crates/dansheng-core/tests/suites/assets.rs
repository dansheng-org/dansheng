//! Offline integration evidence: all HTTP traffic terminates at a local synthetic server.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use dansheng_core::{
    CoreResult, Principal, PrincipalKind, assets, network::Network, policy::Grant, store::Store,
};
use rusqlite::Connection;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};

#[derive(Clone, Copy, Default)]
enum Mode {
    #[default]
    Normal,
    Interrupt,
    IgnoreRange,
    Stall,
    BadRange,
    UnknownLength,
}
struct Server {
    origin: String,
    requests: Arc<Mutex<Vec<String>>>,
    task: JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Server {
    async fn new(body: Vec<u8>, mime: &'static str, mode: Mode, etag: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let seen = requests.clone();
        let body = Arc::new(body);
        let gets = Arc::new(AtomicUsize::new(0));
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let seen = seen.clone();
                let body = body.clone();
                let gets = gets.clone();
                tokio::spawn(async move {
                    let mut data = Vec::new();
                    loop {
                        let mut buf = [0u8; 2048];
                        let n = socket.read(&mut buf).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        data.extend_from_slice(&buf[..n]);
                        if data.windows(4).any(|s| s == b"\r\n\r\n") {
                            break;
                        }
                        assert!(data.len() < 64 * 1024);
                    }
                    let request = String::from_utf8(data).unwrap();
                    seen.lock().unwrap().push(request.clone());
                    let lower = request.to_ascii_lowercase();
                    let head = request.starts_with("HEAD ");
                    let range = lower
                        .lines()
                        .find_map(|s| s.strip_prefix("range: bytes="))
                        .and_then(|v| v.trim_end_matches('-').trim().parse::<usize>().ok());
                    let resume = range.is_some() && !matches!(mode, Mode::IgnoreRange);
                    let start = if resume {
                        range.unwrap().min(body.len())
                    } else {
                        0
                    };
                    let content_range = if resume {
                        if matches!(mode, Mode::BadRange) {
                            format!(
                                "Content-Range: bytes {}-{}/{}\r\n",
                                start + 1,
                                body.len() - 1,
                                body.len()
                            )
                        } else {
                            format!(
                                "Content-Range: bytes {}-{}/{}\r\n",
                                start,
                                body.len() - 1,
                                body.len()
                            )
                        }
                    } else {
                        String::new()
                    };
                    let validator = if etag { "ETag: \"fixture-v1\"\r\n" } else { "" };
                    let status = if resume {
                        "206 Partial Content"
                    } else {
                        "200 OK"
                    };
                    let length = if matches!(mode, Mode::UnknownLength) {
                        String::new()
                    } else {
                        format!("Content-Length: {}\r\n", body.len() - start)
                    };
                    let header = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: {mime}\r\n{length}{validator}{content_range}Connection: close\r\n\r\n"
                    );
                    if socket.write_all(header.as_bytes()).await.is_err() || head {
                        return;
                    }
                    let number = gets.fetch_add(1, Ordering::SeqCst);
                    if number == 0
                        && matches!(
                            mode,
                            Mode::Interrupt | Mode::IgnoreRange | Mode::Stall | Mode::BadRange
                        )
                    {
                        let partial = (body.len() / 3).max(1);
                        let _ = socket.write_all(&body[..partial]).await;
                        let _ = socket.flush().await;
                        if matches!(mode, Mode::Stall) {
                            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                        }
                        let _ = socket.shutdown().await;
                    } else {
                        let _ = socket.write_all(&body[start..]).await;
                    }
                });
            }
        });
        Self {
            origin,
            requests,
            task,
        }
    }
}

struct Harness {
    dir: tempfile::TempDir,
    store: Arc<Store>,
    network: Arc<Network>,
    principal: Principal,
    grant: Grant,
}
impl Harness {
    fn new(server: &Server) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::open(dir.path()).unwrap());
        let principal = Principal {
            id: "plugin:fixture".into(),
            kind: PrincipalKind::Plugin,
        };
        let mut grant = Grant::default();
        grant.capabilities.extend(
            [
                "files.download",
                "files.list",
                "files.read",
                "files.delete",
                "files.index",
                "files.export",
                "http.request",
                "sources.write",
                "sources.read",
            ]
            .map(str::to_owned),
        );
        grant.origins.insert(server.origin.clone());
        grant.allow_private_network = true;
        Self {
            dir,
            store,
            network: Arc::new(Network::default()),
            principal,
            grant,
        }
    }
    async fn call(&self, method: &str, input: Value) -> CoreResult<Value> {
        assets::dispatch(
            &self.store,
            &self.network,
            &self.principal,
            &self.grant,
            method,
            input,
        )
        .await
    }
    async fn items(&self) -> Vec<Value> {
        self.call("files.list", json!({})).await.unwrap()["items"]
            .as_array()
            .unwrap()
            .clone()
    }
    fn db(&self) -> Connection {
        Connection::open(self.dir.path().join("dansheng.db")).unwrap()
    }
}

#[tokio::test]
async fn download_bounded_read_unicode_index_and_delete() {
    let text = "复旦大学 文档索引\nUnicode café 👩🏽‍💻 Ελληνικά\n";
    let server = Server::new(
        text.as_bytes().to_vec(),
        "text/plain; charset=utf-8",
        Mode::Normal,
        true,
    )
    .await;
    let h = Harness::new(&server);
    let url = format!("{}/notes?signature=synthetic-signed-value", server.origin);
    let asset = h.call("files.download",json!({"url":url,"name":"资料.txt","source_id":"fixture.documents","sha256":hex::encode(Sha256::digest(text.as_bytes()))})).await.unwrap();
    assert_eq!(asset["state"], "ready");
    assert_eq!(asset["size"], text.len());
    assert!(asset.get("path").is_none());
    assert!(!asset.to_string().contains("signature"));
    let id = asset["asset_id"].as_str().unwrap();
    assert!(h.dir.path().join("assets").join(id).is_file());
    assert!(
        !h.dir
            .path()
            .join("assets")
            .join(format!("{id}.part"))
            .exists()
    );
    let mut bytes = Vec::new();
    let mut offset = 0;
    loop {
        let chunk = h
            .call(
                "files.read",
                json!({"asset_id":id,"offset":offset,"length":7}),
            )
            .await
            .unwrap();
        bytes.extend(STANDARD.decode(chunk["data"].as_str().unwrap()).unwrap());
        offset = chunk["next_offset"].as_u64().unwrap();
        if chunk["eof"] == true {
            break;
        }
    }
    assert_eq!(bytes, text.as_bytes());
    let indexed = h.call("files.index", json!({"asset_id":id})).await.unwrap();
    assert_eq!(indexed["owner"], h.principal.id);
    assert_eq!(indexed["kind"], "document");
    let rows = h
        .store
        .records(&h.principal, &h.grant, &json!({}), Some("复旦"))
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["source_id"], "fixture.documents");
    assert!(
        rows[0]["data"]["text"]
            .as_str()
            .unwrap()
            .contains("café 👩🏽‍💻 Ελληνικά")
    );
    let persisted: String = h
        .db()
        .query_row(
            "SELECT url_hash||request_hash||session_hash||coalesce(etag,'') FROM managed_assets_v1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!persisted.contains("synthetic-signed-value"));
    assert!(!persisted.contains(&server.origin));
    h.call("files.delete", json!({"asset_id":id}))
        .await
        .unwrap();
    assert!(h.items().await.is_empty());
    assert!(!h.dir.path().join("assets").join(id).exists());
    assert!(
        h.store
            .records(&h.principal, &h.grant, &json!({}), Some("复旦"))
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        h.call("files.read", json!({"asset_id":id}))
            .await
            .unwrap_err()
            .code,
        "NotFound"
    );
}

#[tokio::test]
async fn interrupted_download_resumes_with_range_validator_and_cumulative_hash() {
    let body = "中文下载恢复🙂".repeat(16 * 1024).into_bytes();
    let server = Server::new(body.clone(), "text/plain", Mode::Interrupt, true).await;
    let h = Harness::new(&server);
    let url = format!("{}/document", server.origin);
    assert!(h.call("files.download", json!({"url":url})).await.is_err());
    let partial = h.items().await.remove(0);
    let id = partial["asset_id"].as_str().unwrap();
    assert_eq!(partial["state"], "partial");
    assert_eq!(partial["resumable"], true);
    let size = partial["size"].as_u64().unwrap();
    assert!(size > 0 && size < body.len() as u64);
    let ready = h
        .call(
            "files.download",
            json!({"url":url,"asset_id":id,"resume":true}),
        )
        .await
        .unwrap();
    assert_eq!(ready["size"], body.len());
    assert_eq!(ready["sha256"], hex::encode(Sha256::digest(&body)));
    assert_eq!(
        std::fs::read(h.dir.path().join("assets").join(id)).unwrap(),
        body
    );
    let requests = server.requests.lock().unwrap();
    assert!(requests.iter().any(|r| {
        r.to_ascii_lowercase()
            .contains(&format!("range: bytes={size}-"))
    }));
    assert!(
        requests
            .iter()
            .any(|r| r.to_ascii_lowercase().contains("if-range: \"fixture-v1\""))
    );
}

#[tokio::test]
async fn ignored_range_restarts_without_prefix_duplication() {
    let body = b"server-ignores-range\n".repeat(8192);
    let server = Server::new(body.clone(), "text/plain", Mode::IgnoreRange, true).await;
    let h = Harness::new(&server);
    let url = format!("{}/ignored", server.origin);
    assert!(h.call("files.download", json!({"url":url})).await.is_err());
    let id = h.items().await[0]["asset_id"].as_str().unwrap().to_owned();
    let ready = h
        .call(
            "files.download",
            json!({"url":url,"asset_id":id,"resume":true}),
        )
        .await
        .unwrap();
    assert_eq!(ready["size"], body.len());
    assert_eq!(
        std::fs::read(h.dir.path().join("assets").join(&id)).unwrap(),
        body
    );
}

#[tokio::test]
async fn unvalidated_partial_is_preserved_but_restarted() {
    let body = b"no-etag\n".repeat(8192);
    let server = Server::new(body.clone(), "text/plain", Mode::Interrupt, false).await;
    let h = Harness::new(&server);
    let url = format!("{}/no-validator", server.origin);
    assert!(h.call("files.download", json!({"url":url})).await.is_err());
    let partial = h.items().await.remove(0);
    assert_eq!(partial["resumable"], false);
    assert!(partial["size"].as_u64().unwrap() > 0);
    let id = partial["asset_id"].as_str().unwrap();
    h.call(
        "files.download",
        json!({"url":url,"asset_id":id,"resume":true}),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(h.dir.path().join("assets").join(id)).unwrap(),
        body
    );
    assert!(
        !server
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.to_ascii_lowercase().contains("\r\nrange:"))
    );
}

#[tokio::test]
async fn malformed_resume_range_is_rejected_and_partial_retained() {
    let body = b"bad-range\n".repeat(8192);
    let server = Server::new(body, "text/plain", Mode::BadRange, true).await;
    let h = Harness::new(&server);
    let url = format!("{}/bad-range", server.origin);
    assert!(h.call("files.download", json!({"url":url})).await.is_err());
    let partial = h.items().await.remove(0);
    let id = partial["asset_id"].as_str().unwrap();
    assert_eq!(
        h.call(
            "files.download",
            json!({"url":url,"asset_id":id,"resume":true})
        )
        .await
        .unwrap_err()
        .code,
        "InvalidResponse"
    );
    assert_eq!(h.items().await[0]["size"], partial["size"]);
}

#[tokio::test]
async fn future_cancellation_preserves_partial_progress_and_reservation_is_released() {
    let body = b"cancellation\n".repeat(8192);
    let server = Server::new(body.clone(), "text/plain", Mode::Stall, true).await;
    let h = Harness::new(&server);
    let url = format!("{}/cancel", server.origin);
    let store = h.store.clone();
    let network = h.network.clone();
    let principal = h.principal.clone();
    let grant = h.grant.clone();
    let task_url = url.clone();
    let task = tokio::spawn(async move {
        assets::dispatch(
            &store,
            &network,
            &principal,
            &grant,
            "files.download",
            json!({"url":task_url}),
        )
        .await
    });
    let mut partial = None;
    for _ in 0..200 {
        let items = h.items().await;
        if let Some(item) = items
            .first()
            .filter(|a| a["size"].as_u64().unwrap_or(0) > 0)
        {
            partial = Some(item.clone());
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let partial = partial.expect("stream must expose live progress");
    assert_eq!(partial["state"], "downloading");
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    let partial = h.items().await.remove(0);
    assert_eq!(partial["state"], "partial");
    let (size, reserved): (i64, i64) = h
        .db()
        .query_row(
            "SELECT size,reserved_bytes FROM managed_assets_v1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(size, reserved);
    let id = partial["asset_id"].as_str().unwrap();
    let ready = h
        .call(
            "files.download",
            json!({"url":url,"asset_id":id,"resume":true}),
        )
        .await
        .unwrap();
    assert_eq!(ready["sha256"], hex::encode(Sha256::digest(&body)));
}

#[tokio::test]
async fn owner_and_account_filters_are_enforced_for_every_asset_method() {
    let server = Server::new(
        b"account scoped document".to_vec(),
        "text/plain",
        Mode::Normal,
        true,
    )
    .await;
    let mut h = Harness::new(&server);
    h.grant.account_ids.insert("a".into());
    h.network
        .set_session("a", &server.origin, None, vec![])
        .unwrap();
    let asset = h
        .call(
            "files.download",
            json!({"url":format!("{}/a",server.origin),"account_id":"a"}),
        )
        .await
        .unwrap();
    let id = asset["asset_id"].as_str().unwrap();
    let other = Principal {
        id: "plugin:other".into(),
        kind: PrincipalKind::Plugin,
    };
    let result = assets::dispatch(
        &h.store,
        &h.network,
        &other,
        &h.grant,
        "files.list",
        json!({}),
    )
    .await
    .unwrap();
    assert!(result["items"].as_array().unwrap().is_empty());
    for method in ["files.read", "files.delete", "files.index", "files.export"] {
        assert_eq!(
            assets::dispatch(
                &h.store,
                &h.network,
                &other,
                &h.grant,
                method,
                json!({"asset_id":id})
            )
            .await
            .unwrap_err()
            .code,
            "NotFound"
        );
    }
    let mut revoked = h.grant.clone();
    revoked.account_ids.clear();
    assert!(
        assets::dispatch(
            &h.store,
            &h.network,
            &h.principal,
            &revoked,
            "files.list",
            json!({})
        )
        .await
        .unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &h.principal,
            &revoked,
            "files.read",
            json!({"asset_id":id})
        )
        .await
        .unwrap_err()
        .code,
        "NotFound"
    );
    assert_eq!(
        h.call("files.read", json!({"asset_id":id,"account_id":"b"}))
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &Principal::owner(),
            &Grant::default(),
            "files.list",
            json!({})
        )
        .await
        .unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        h.call("files.export", json!({"asset_id":id}))
            .await
            .unwrap_err()
            .code,
        "CapabilityUnavailable"
    );
    assert_eq!(
        h.call("files.export", json!({"asset_id":id,"path":"C:/outside"}))
            .await
            .unwrap_err()
            .code,
        "InvalidInput"
    );
}

#[tokio::test]
async fn ui_downloads_are_shared_with_mcp_only_by_source_account_and_operation_grants() {
    let body = "UI 下载的课程文件".as_bytes().to_vec();
    let server = Server::new(body.clone(), "text/plain", Mode::Normal, true).await;
    let h = Harness::new(&server);
    for account in ["a", "b"] {
        h.network
            .set_session(account, &server.origin, None, vec![])
            .unwrap();
    }
    let mut downloaded = Vec::new();
    for (suffix, account, source) in [
        ("a", Some("a"), "courses.materials"),
        ("b", Some("b"), "courses.materials"),
        ("anonymous", None, "courses.materials"),
        ("private", Some("a"), "private.notes"),
    ] {
        let mut input = json!({"url":format!("{}/{suffix}",server.origin),"source_id":source});
        if let Some(account) = account {
            input["account_id"] = json!(account);
        }
        downloaded.push(
            assets::dispatch(
                &h.store,
                &h.network,
                &Principal::owner(),
                &h.grant,
                "files.download",
                input,
            )
            .await
            .unwrap(),
        );
    }
    let id = downloaded[0]["asset_id"].as_str().unwrap();
    assert_eq!(downloaded[0]["owner"], "owner");
    let reader = Principal {
        id: "mcp:course-reader".into(),
        kind: PrincipalKind::Mcp,
    };
    let mut grant = Grant::default();
    grant
        .capabilities
        .extend(["files.list".into(), "files.read".into()]);
    grant.account_ids.insert("a".into());
    let input = json!({"asset_id":id});
    // Account access alone cannot reveal UI files, even with the read capability.
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.read",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NotFound"
    );
    assert!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.list",
            json!({})
        )
        .await
        .unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    // Source ids are exact SQL parameters; a prefix or SQL-looking string is no grant.
    for source in ["courses", "courses.materials') OR 1=1--"] {
        grant.source_ids.clear();
        grant.source_ids.insert(source.into());
        assert_eq!(
            assets::dispatch(
                &h.store,
                &h.network,
                &reader,
                &grant,
                "files.read",
                input.clone()
            )
            .await
            .unwrap_err()
            .code,
            "NotFound"
        );
    }
    grant.source_ids.clear();
    grant.source_ids.insert("courses.materials".into());
    grant.account_ids.clear();
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.read",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NotFound"
    );
    // Anonymous shared documents do not need a fabricated account grant.
    let anonymous = assets::dispatch(
        &h.store,
        &h.network,
        &reader,
        &grant,
        "files.read",
        json!({"asset_id":downloaded[2]["asset_id"]}),
    )
    .await
    .unwrap();
    assert_eq!(
        STANDARD
            .decode(anonymous["data"].as_str().unwrap())
            .unwrap(),
        body
    );
    grant.account_ids.insert("a".into());
    let read = assets::dispatch(
        &h.store,
        &h.network,
        &reader,
        &grant,
        "files.read",
        input.clone(),
    )
    .await
    .unwrap();
    assert_eq!(
        STANDARD.decode(read["data"].as_str().unwrap()).unwrap(),
        body
    );
    let listed = assets::dispatch(
        &h.store,
        &h.network,
        &reader,
        &grant,
        "files.list",
        json!({}),
    )
    .await
    .unwrap();
    assert_eq!(listed["items"].as_array().unwrap().len(), 2);
    for hidden in [&downloaded[1], &downloaded[3]] {
        assert_eq!(
            assets::dispatch(
                &h.store,
                &h.network,
                &reader,
                &grant,
                "files.read",
                json!({"asset_id":hidden["asset_id"]})
            )
            .await
            .unwrap_err()
            .code,
            "NotFound"
        );
    }
    let mut no_read = grant.clone();
    no_read.capabilities.remove("files.read");
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &no_read,
            "files.read",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.delete",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    assert_eq!(
        assets::export_descriptor(&h.store, &reader, &grant, input.clone())
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    grant.capabilities.insert("files.export".into());
    assert_eq!(
        assets::export_descriptor(&h.store, &reader, &grant, input.clone()).unwrap()["asset_id"],
        id
    );
    grant.capabilities.insert("files.delete".into());
    let mut no_source = grant.clone();
    no_source.source_ids.clear();
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &no_source,
            "files.delete",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NotFound"
    );
    assert_eq!(
        assets::dispatch(&h.store, &h.network, &reader, &grant, "files.delete", input)
            .await
            .unwrap()["deleted"],
        true
    );
    let remaining = assets::dispatch(
        &h.store,
        &h.network,
        &Principal::owner(),
        &Grant::default(),
        "files.list",
        json!({}),
    )
    .await
    .unwrap();
    assert_eq!(remaining["items"].as_array().unwrap().len(), 3);
}

#[tokio::test]
async fn cached_attachments_require_all_source_acl_labels_and_obey_revocation() {
    let body = b"synthetic cached sensitive attachment".to_vec();
    let server = Server::new(body.clone(), "text/plain", Mode::Normal, true).await;
    let mut h = Harness::new(&server);
    let source = "fixture.cached-attachments";
    h.grant.account_ids.insert("a".into());
    h.grant
        .capabilities
        .extend(["mail.read".into(), "calendar.read".into()]);
    h.network
        .set_session("a", &server.origin, None, vec![])
        .unwrap();
    // The host labels the source before caching, unioning all sensitive reads.
    h.store
        .require_source_capabilities(
            &h.principal.id,
            source,
            &["mail.read".into()].into_iter().collect(),
        )
        .unwrap();
    h.store
        .require_source_capabilities(
            &h.principal.id,
            source,
            &["calendar.read".into()].into_iter().collect(),
        )
        .unwrap();
    let asset=h.call("files.download",json!({"url":format!("{}/attachment",server.origin),"source_id":source,"account_id":"a"})).await.unwrap();
    let input = json!({"asset_id":asset["asset_id"]});
    h.call("files.index", input.clone()).await.unwrap();
    let reader = Principal {
        id: "mcp:attachment-reader".into(),
        kind: PrincipalKind::Mcp,
    };
    let mut grant = h.grant.clone();
    grant.source_ids.insert(source.into());
    grant.capabilities.remove("mail.read");
    grant.capabilities.remove("calendar.read");
    // Read/list/export and even delete/index capabilities do not bypass labels.
    for missing in [
        None,
        Some("mail.read"),
        Some("calendar.read"),
        Some("mail.*"),
    ] {
        let mut incomplete = grant.clone();
        if let Some(cap) = missing {
            incomplete.capabilities.insert(cap.into());
        }
        for method in ["files.read", "files.delete", "files.index", "files.export"] {
            assert_eq!(
                assets::dispatch(
                    &h.store,
                    &h.network,
                    &reader,
                    &incomplete,
                    method,
                    input.clone()
                )
                .await
                .unwrap_err()
                .code,
                "NotFound"
            );
        }
        assert!(
            assets::dispatch(
                &h.store,
                &h.network,
                &reader,
                &incomplete,
                "files.list",
                json!({})
            )
            .await
            .unwrap()["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            assets::export_descriptor(&h.store, &reader, &incomplete, input.clone())
                .unwrap_err()
                .code,
            "NotFound"
        );
        assert!(
            h.store
                .records(&reader, &incomplete, &json!({}), Some("sensitive"))
                .unwrap()
                .is_empty()
        );
    }
    grant
        .capabilities
        .extend(["mail.read".into(), "calendar.read".into()]);
    let read = assets::dispatch(
        &h.store,
        &h.network,
        &reader,
        &grant,
        "files.read",
        input.clone(),
    )
    .await
    .unwrap();
    assert_eq!(
        STANDARD.decode(read["data"].as_str().unwrap()).unwrap(),
        body
    );
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.list",
            json!({})
        )
        .await
        .unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        assets::export_descriptor(&h.store, &reader, &grant, input.clone()).unwrap()["asset_id"],
        asset["asset_id"]
    );
    assert_eq!(
        h.store
            .records(&reader, &grant, &json!({}), Some("sensitive"))
            .unwrap()
            .len(),
        1
    );
    for cap in ["mail.read", "calendar.read"] {
        let mut revoked = grant.clone();
        revoked.capabilities.remove(cap);
        assert_eq!(
            assets::dispatch(
                &h.store,
                &h.network,
                &reader,
                &revoked,
                "files.read",
                input.clone()
            )
            .await
            .unwrap_err()
            .code,
            "NotFound"
        );
        assert_eq!(
            assets::export_descriptor(&h.store, &reader, &revoked, input.clone())
                .unwrap_err()
                .code,
            "NotFound"
        );
        assert!(
            assets::dispatch(
                &h.store,
                &h.network,
                &reader,
                &revoked,
                "files.list",
                json!({})
            )
            .await
            .unwrap()["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    let mut owner_revoked = h.grant.clone();
    owner_revoked.capabilities.remove("mail.read");
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &h.principal,
            &owner_revoked,
            "files.read",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NotFound"
    );
    // The trusted profile owner retains management access to labeled assets.
    assert!(
        assets::dispatch(
            &h.store,
            &h.network,
            &Principal::owner(),
            &Grant::default(),
            "files.read",
            input.clone()
        )
        .await
        .is_ok()
    );
    assert!(
        assets::export_descriptor(
            &h.store,
            &Principal::owner(),
            &Grant::default(),
            input.clone()
        )
        .is_ok()
    );
    // ACL lookup is keyed by owner AND source, not merely the shared source name.
    let other = assets::dispatch(
        &h.store,
        &h.network,
        &Principal::owner(),
        &h.grant,
        "files.download",
        json!({"url":format!("{}/other-owner",server.origin),"source_id":source,"account_id":"a"}),
    )
    .await
    .unwrap();
    let mut unlabeled = grant.clone();
    unlabeled.capabilities.remove("mail.read");
    unlabeled.capabilities.remove("calendar.read");
    assert!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &unlabeled,
            "files.read",
            json!({"asset_id":other["asset_id"]})
        )
        .await
        .is_ok()
    );
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &unlabeled,
            "files.list",
            json!({})
        )
        .await
        .unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        assets::dispatch(&h.store, &h.network, &reader, &grant, "files.delete", input)
            .await
            .unwrap()["deleted"],
        true
    );
}

#[tokio::test]
async fn mail_source_fallback_requires_exact_mail_read_without_an_acl_row() {
    let server = Server::new(
        b"synthetic legacy mail attachment".to_vec(),
        "text/plain",
        Mode::Normal,
        true,
    )
    .await;
    let mut h = Harness::new(&server);
    h.grant.account_ids.insert("a".into());
    h.network
        .set_session("a", &server.origin, None, vec![])
        .unwrap();
    let source = "mail.inbox.attachments";
    let asset = assets::dispatch(
        &h.store,
        &h.network,
        &Principal::owner(),
        &h.grant,
        "files.download",
        json!({"url":format!("{}/legacy-mail",server.origin),"account_id":"a","source_id":source}),
    )
    .await
    .unwrap();
    let count: i64 = h
        .db()
        .query_row(
            "SELECT count(*) FROM source_access WHERE owner='owner' AND source_id=?",
            [source],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
    let reader = Principal {
        id: "mcp:legacy-mail-reader".into(),
        kind: PrincipalKind::Mcp,
    };
    let mut grant = h.grant.clone();
    grant.source_ids.insert(source.into());
    let input = json!({"asset_id":asset["asset_id"]});
    for alternate in [
        None,
        Some("mail.*"),
        Some("mail.read.extra"),
        Some("Mail.Read"),
    ] {
        let mut wrong = grant.clone();
        if let Some(cap) = alternate {
            wrong.capabilities.insert(cap.into());
        }
        assert_eq!(
            assets::dispatch(
                &h.store,
                &h.network,
                &reader,
                &wrong,
                "files.read",
                input.clone()
            )
            .await
            .unwrap_err()
            .code,
            "NotFound"
        );
        assert!(
            assets::dispatch(
                &h.store,
                &h.network,
                &reader,
                &wrong,
                "files.list",
                json!({})
            )
            .await
            .unwrap()["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            assets::export_descriptor(&h.store, &reader, &wrong, input.clone())
                .unwrap_err()
                .code,
            "NotFound"
        );
    }
    grant.capabilities.insert("mail.read".into());
    assert!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.read",
            input.clone()
        )
        .await
        .is_ok()
    );
    assert!(assets::export_descriptor(&h.store, &reader, &grant, input.clone()).is_ok());
    grant.capabilities.remove("mail.read");
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.read",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NotFound"
    );
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &reader,
            &grant,
            "files.delete",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NotFound"
    );
    grant.capabilities.insert("mail.read".into());
    assert_eq!(
        assets::dispatch(&h.store, &h.network, &reader, &grant, "files.delete", input)
            .await
            .unwrap()["deleted"],
        true
    );
}

#[tokio::test]
async fn url_hash_and_account_session_bindings_cannot_be_reused() {
    let server = Server::new(
        b"resume-binding\n".repeat(8192),
        "text/plain",
        Mode::Interrupt,
        true,
    )
    .await;
    let mut h = Harness::new(&server);
    h.grant.account_ids.insert("a".into());
    h.network
        .set_session("a", &server.origin, None, vec![])
        .unwrap();
    let url = format!("{}/bound?token=synthetic", server.origin);
    assert!(
        h.call("files.download", json!({"url":url,"account_id":"a"}))
            .await
            .is_err()
    );
    let id = h.items().await[0]["asset_id"].as_str().unwrap().to_owned();
    for changed in [
        json!({"url":format!("{}/other",server.origin),"account_id":"a"}),
        json!({"url":url,"account_id":"a","sha256":"0".repeat(64)}),
        json!({"url":url}),
    ] {
        let mut changed = changed;
        changed["asset_id"] = json!(id);
        changed["resume"] = json!(true);
        assert_eq!(
            h.call("files.download", changed).await.unwrap_err().code,
            "ResumeMismatch"
        );
    }
    h.network.clear_session("a").unwrap();
    h.network
        .set_session("a", &server.origin, None, vec![])
        .unwrap();
    assert_eq!(
        h.call(
            "files.download",
            json!({"url":url,"account_id":"a","asset_id":id,"resume":true})
        )
        .await
        .unwrap_err()
        .code,
        "ResumeMismatch"
    );
}

#[tokio::test]
async fn file_and_total_byte_quotas_and_deletion_reclaim() {
    let server = Server::new(vec![b'x'; 64], "text/plain", Mode::Normal, true).await;
    let h = Harness::new(&server);
    let url = format!("{}/quota", server.origin);
    assert_eq!(
        h.call(
            "files.download",
            json!({"url":url,"max_bytes":assets::MAX_FILE_BYTES+1})
        )
        .await
        .unwrap_err()
        .code,
        "QuotaExceeded"
    );
    assert_eq!(
        h.call("files.download", json!({"url":url,"max_bytes":16}))
            .await
            .unwrap_err()
            .code,
        "ResponseTooLarge"
    );
    let failed = h.items().await.remove(0);
    assert_eq!(failed["size"], 0);
    h.call("files.delete", json!({"asset_id":failed["asset_id"]}))
        .await
        .unwrap();
    let asset = h
        .call("files.download", json!({"url":url,"max_bytes":64}))
        .await
        .unwrap();
    let id = asset["asset_id"].as_str().unwrap();
    // Synthetic quota fixture avoids transmitting half a GiB. It models another retained sink.
    h.db()
        .execute(
            "UPDATE managed_assets_v1 SET reserved_bytes=? WHERE id=?",
            rusqlite::params![i64::try_from(assets::MAX_TOTAL_BYTES - 32).unwrap(), id],
        )
        .unwrap();
    assert_eq!(
        h.call("files.download", json!({"url":url,"max_bytes":64}))
            .await
            .unwrap_err()
            .code,
        "QuotaExceeded"
    );
    h.call("files.delete", json!({"asset_id":id}))
        .await
        .unwrap();
    assert!(
        h.call("files.download", json!({"url":url,"max_bytes":64}))
            .await
            .is_ok()
    );
}

#[tokio::test]
async fn html_entities_unicode_and_malformed_documents() {
    let html = "<!doctype html><html><head><title>hidden head</title><style>hidden style</style></head><body><p>复旦 &amp; 学习 &#x1F642;</p><script>hidden script</script><p>café Ελληνικά</p></body></html>";
    let server = Server::new(
        html.as_bytes().to_vec(),
        "text/html; charset=utf-8",
        Mode::Normal,
        true,
    )
    .await;
    let h = Harness::new(&server);
    let asset = h
        .call(
            "files.download",
            json!({"url":format!("{}/unicode",server.origin)}),
        )
        .await
        .unwrap();
    h.call("files.index", json!({"asset_id":asset["asset_id"]}))
        .await
        .unwrap();
    let rows = h
        .store
        .records(&h.principal, &h.grant, &json!({}), Some("学习"))
        .unwrap();
    let text = rows[0]["data"]["text"].as_str().unwrap();
    assert!(text.contains("复旦 & 学习 🙂"));
    assert!(text.contains("café Ελληνικά"));
    assert!(!text.contains("hidden"));
    for (body, mime, code) in [
        (vec![0xff, 0xfe, 0], "text/plain", "DocumentParseError"),
        (
            b"%PDF-1.7\nnot a real PDF".to_vec(),
            "application/pdf",
            if cfg!(feature = "pdf") {
                "DocumentParseError"
            } else {
                "CapabilityUnavailable"
            },
        ),
        (b"\0binary".to_vec(), "text/plain", "DocumentParseError"),
        (
            vec![b'x'; assets::MAX_TEXT_BYTES + 1],
            "text/plain",
            "DocumentTooLarge",
        ),
    ] {
        let server = Server::new(body, mime, Mode::Normal, true).await;
        let h = Harness::new(&server);
        let asset = h
            .call(
                "files.download",
                json!({"url":format!("{}/malformed",server.origin)}),
            )
            .await
            .unwrap();
        assert_eq!(
            h.call("files.index", json!({"asset_id":asset["asset_id"]}))
                .await
                .unwrap_err()
                .code,
            code
        );
        assert!(
            h.store
                .records(&h.principal, &h.grant, &json!({}), None)
                .unwrap()
                .is_empty()
        );
    }
}

#[tokio::test]
async fn capabilities_paths_read_bounds_and_integrity_are_checked() {
    let server = Server::new(b"integrity".to_vec(), "text/plain", Mode::Normal, true).await;
    let h = Harness::new(&server);
    let url = format!("{}/data", server.origin);
    let mut no_http = h.grant.clone();
    no_http.capabilities.remove("http.request");
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &h.principal,
            &no_http,
            "files.download",
            json!({"url":url})
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    assert_eq!(
        h.call("files.download", json!({"url":url,"path":"../outside"}))
            .await
            .unwrap_err()
            .code,
        "InvalidInput"
    );
    assert_eq!(
        h.call("files.download", json!({"url":url,"sha256":"0".repeat(64)}))
            .await
            .unwrap_err()
            .code,
        "IntegrityMismatch"
    );
    assert_eq!(h.items().await[0]["size"], 0);
    let asset = h.call("files.download", json!({"url":url})).await.unwrap();
    let id = asset["asset_id"].as_str().unwrap();
    for input in [
        json!({"asset_id":"../../outside"}),
        json!({"asset_id":id,"length":assets::MAX_READ_BYTES+1}),
        json!({"asset_id":id,"offset":100}),
    ] {
        assert_eq!(
            h.call("files.read", input).await.unwrap_err().code,
            "InvalidInput"
        );
    }
    std::fs::write(h.dir.path().join("assets").join(id), b"modified!").unwrap();
    assert_eq!(
        h.call("files.index", json!({"asset_id":id}))
            .await
            .unwrap_err()
            .code,
        "IntegrityMismatch"
    );
}

#[tokio::test]
async fn restart_recovers_stale_transfer_and_atomic_promotion() {
    let body = b"restart recovery\n".repeat(8192);
    let server = Server::new(body.clone(), "text/plain", Mode::Interrupt, true).await;
    let h = Harness::new(&server);
    let url = format!("{}/recover", server.origin);
    assert!(h.call("files.download", json!({"url":url})).await.is_err());
    let id = h.items().await[0]["asset_id"].as_str().unwrap().to_owned();
    h.db()
        .execute(
            "UPDATE managed_assets_v1 SET state='downloading',reserved_bytes=?",
            [i64::try_from(assets::MAX_FILE_BYTES).unwrap()],
        )
        .unwrap();
    let Harness {
        dir,
        store,
        network,
        principal,
        grant,
    } = h;
    drop(store);
    let store = Store::open(dir.path()).unwrap();
    let listed = assets::dispatch(
        &store,
        &network,
        &principal,
        &grant,
        "files.list",
        json!({}),
    )
    .await
    .unwrap();
    assert_eq!(listed["items"][0]["state"], "partial");
    assets::dispatch(
        &store,
        &network,
        &principal,
        &grant,
        "files.download",
        json!({"url":url,"asset_id":id,"resume":true}),
    )
    .await
    .unwrap();
    let db = Connection::open(dir.path().join("dansheng.db")).unwrap();
    db.execute(
        "UPDATE managed_assets_v1 SET state='promoting' WHERE id=?",
        [&id],
    )
    .unwrap();
    drop(db);
    drop(store);
    let store = Store::open(dir.path()).unwrap();
    let listed = assets::dispatch(
        &store,
        &network,
        &principal,
        &grant,
        "files.list",
        json!({}),
    )
    .await
    .unwrap();
    assert_eq!(listed["items"][0]["state"], "ready");
    assert_eq!(
        std::fs::read(dir.path().join("assets").join(&id)).unwrap(),
        body
    );
}

#[tokio::test]
async fn streaming_byte_quota_is_enforced_without_content_length() {
    let server = Server::new(vec![b'x'; 65536], "text/plain", Mode::UnknownLength, true).await;
    let h = Harness::new(&server);
    assert_eq!(
        h.call(
            "files.download",
            json!({"url":format!("{}/unbounded",server.origin),"max_bytes":1024})
        )
        .await
        .unwrap_err()
        .code,
        "ResponseTooLarge"
    );
    let partial = h.items().await.remove(0);
    assert_eq!(partial["state"], "partial");
    assert!(partial["size"].as_u64().unwrap() <= 1024);
    assert!(
        server
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.starts_with("GET "))
    );
}

#[tokio::test]
async fn index_limits_and_idempotent_store_records() {
    let server = Server::new(
        "Unicode 文档".as_bytes().to_vec(),
        "text/plain",
        Mode::Normal,
        true,
    )
    .await;
    let h = Harness::new(&server);
    let asset = h
        .call(
            "files.download",
            json!({"url":format!("{}/index",server.origin)}),
        )
        .await
        .unwrap();
    let input = json!({"asset_id":asset["asset_id"]});
    let mut no_write = h.grant.clone();
    no_write.capabilities.remove("sources.write");
    assert_eq!(
        assets::dispatch(
            &h.store,
            &h.network,
            &h.principal,
            &no_write,
            "files.index",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    h.call("files.index", input.clone()).await.unwrap();
    h.call("files.index", input).await.unwrap();
    assert_eq!(
        h.store
            .records(&h.principal, &h.grant, &json!({}), Some("Unicode"))
            .unwrap()
            .len(),
        1
    );
    for (body, mime, code) in [
        (
            vec![b'x'; assets::MAX_INDEX_BYTES as usize + 1],
            "text/plain",
            "DocumentTooLarge",
        ),
        (
            "<div>".repeat(16_385).into_bytes(),
            "text/html",
            "DocumentTooComplex",
        ),
    ] {
        let server = Server::new(body, mime, Mode::Normal, true).await;
        let h = Harness::new(&server);
        let asset = h
            .call(
                "files.download",
                json!({"url":format!("{}/limit",server.origin)}),
            )
            .await
            .unwrap();
        assert_eq!(
            h.call("files.index", json!({"asset_id":asset["asset_id"]}))
                .await
                .unwrap_err()
                .code,
            code
        );
    }
}

#[tokio::test]
async fn export_descriptor_is_internal_scoped_complete_and_integrity_checked() {
    let server = Server::new(
        b"trusted export fixture".to_vec(),
        "text/plain",
        Mode::Normal,
        true,
    )
    .await;
    let mut h = Harness::new(&server);
    h.grant.account_ids.insert("a".into());
    h.network
        .set_session("a", &server.origin, None, vec![])
        .unwrap();
    let asset = h
        .call(
            "files.download",
            json!({"url":format!("{}/export",server.origin),"account_id":"a","name":"资料.txt"}),
        )
        .await
        .unwrap();
    let id = asset["asset_id"].as_str().unwrap();
    let input = json!({"asset_id":id});
    let descriptor =
        assets::export_descriptor(&h.store, &h.principal, &h.grant, input.clone()).unwrap();
    assert_eq!(descriptor["name"], "资料.txt");
    assert_eq!(descriptor["mime_type"], "text/plain");
    let path = std::path::PathBuf::from(descriptor["path"].as_str().unwrap());
    assert!(path.is_absolute());
    assert_eq!(
        path,
        std::fs::canonicalize(h.dir.path().join("assets").join(id)).unwrap()
    );
    assert!(descriptor.get("url").is_none());
    // Public dispatch never returns the internal descriptor, even with export permission.
    assert_eq!(
        h.call("files.export", input.clone())
            .await
            .unwrap_err()
            .code,
        "CapabilityUnavailable"
    );
    let other = Principal {
        id: "plugin:other".into(),
        kind: PrincipalKind::Plugin,
    };
    assert_eq!(
        assets::export_descriptor(&h.store, &other, &h.grant, input.clone())
            .unwrap_err()
            .code,
        "NotFound"
    );
    let mut revoked = h.grant.clone();
    revoked.account_ids.clear();
    assert_eq!(
        assets::export_descriptor(&h.store, &h.principal, &revoked, input.clone())
            .unwrap_err()
            .code,
        "NotFound"
    );
    let mut denied = h.grant.clone();
    denied.capabilities.remove("files.export");
    assert_eq!(
        assets::export_descriptor(&h.store, &h.principal, &denied, input.clone())
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    for invalid in [
        json!({"asset_id":id,"path":"C:/outside"}),
        json!({"asset_id":id,"offset":1}),
        json!({"asset_id":"../../outside"}),
    ] {
        assert_eq!(
            assets::export_descriptor(&h.store, &h.principal, &h.grant, invalid)
                .unwrap_err()
                .code,
            "InvalidInput"
        );
    }
    assert!(
        assets::export_descriptor(
            &h.store,
            &Principal::owner(),
            &Grant::default(),
            input.clone()
        )
        .is_ok()
    );
    h.db()
        .execute(
            "UPDATE managed_assets_v1 SET state='partial' WHERE id=?",
            [id],
        )
        .unwrap();
    assert_eq!(
        assets::export_descriptor(&h.store, &h.principal, &h.grant, input.clone())
            .unwrap_err()
            .code,
        "AssetNotReady"
    );
    h.db()
        .execute(
            "UPDATE managed_assets_v1 SET state='ready' WHERE id=?",
            [id],
        )
        .unwrap();
    std::fs::write(&path, b"changed export fixture").unwrap();
    assert_eq!(
        assets::export_descriptor(&h.store, &h.principal, &h.grant, input.clone())
            .unwrap_err()
            .code,
        "IntegrityMismatch"
    );
    std::fs::remove_file(path).unwrap();
    assert_eq!(
        assets::export_descriptor(&h.store, &h.principal, &h.grant, input)
            .unwrap_err()
            .code,
        "AssetMissing"
    );
}

// Independently authored, tiny PDF 1.4 fixture with actual byte offsets/xref.
// No user files, network resources, fonts, office generator or renderer needed.
#[cfg(feature = "pdf")]
fn synthetic_pdf(content: &[u8], pages: usize, extra_objects: usize) -> Vec<u8> {
    let font = 3 + pages;
    let stream = font + 1;
    let kids = (3..font)
        .map(|id| format!("{id} 0 R"))
        .collect::<Vec<_>>()
        .join(" ");
    let mut objects = vec![
        b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
        format!("<< /Type /Pages /Kids [{kids}] /Count {pages} >>").into_bytes(),
    ];
    for _ in 0..pages {
        objects.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 {font} 0 R >> >> /Contents {stream} 0 R >>").into_bytes());
    }
    objects.push(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
            .to_vec(),
    );
    let mut contents = format!("<< /Length {} >>\nstream\n", content.len()).into_bytes();
    contents.extend_from_slice(content);
    contents.extend_from_slice(b"\nendstream");
    objects.push(contents);
    objects.extend((0..extra_objects).map(|_| b"null".to_vec()));
    let mut bytes = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n".to_vec();
    let mut offsets = vec![0];
    for (index, object) in objects.iter().enumerate() {
        offsets.push(bytes.len());
        bytes.extend_from_slice(format!("{} 0 obj\n", index + 1).as_bytes());
        bytes.extend_from_slice(object);
        bytes.extend_from_slice(b"\nendobj\n");
    }
    let xref = bytes.len();
    bytes.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", offsets.len()).as_bytes());
    for offset in offsets.iter().skip(1) {
        bytes.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }
    bytes.extend_from_slice(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            offsets.len()
        )
        .as_bytes(),
    );
    bytes
}

#[cfg(feature = "pdf")]
async fn pdf_index_result(bytes: Vec<u8>) -> (CoreResult<Value>, Harness) {
    let server = Server::new(bytes, "application/pdf", Mode::Normal, true).await;
    let h = Harness::new(&server);
    let asset = h
        .call(
            "files.download",
            json!({"url":format!("{}/synthetic.pdf",server.origin),"name":"文档.pdf"}),
        )
        .await
        .unwrap();
    let result = h
        .call("files.index", json!({"asset_id":asset["asset_id"]}))
        .await;
    (result, h)
}

#[cfg(feature = "pdf")]
#[tokio::test]
async fn pdf_text_and_compressed_streams_are_indexed_with_unicode() {
    let mut content = b"BT /F1 12 Tf 20 100 Td (".to_vec();
    content.extend_from_slice(&b"PDF fixture caf\xe9 ".repeat(16));
    content.extend_from_slice(b") Tj ET");
    let bytes = synthetic_pdf(&content, 2, 0);
    assert!(bytes.len() < 2048);
    let mut compressed = pdf_extract::Document::load_mem(&bytes).unwrap();
    compressed.compress();
    assert!(
        compressed
            .objects
            .values()
            .filter_map(|o| o.as_stream().ok())
            .any(|s| s.dict.has(b"Filter"))
    );
    let mut packed = Vec::new();
    compressed.save_to(&mut packed).unwrap();
    for bytes in [bytes, packed] {
        let (result, h) = pdf_index_result(bytes).await;
        assert!(result.is_ok(), "{:?}", result);
        let rows = h
            .store
            .records(&h.principal, &h.grant, &json!({}), Some("café"))
            .unwrap();
        assert_eq!(rows.len(), 1);
        let text = rows[0]["data"]["text"].as_str().unwrap();
        assert_eq!(text.matches("PDF fixture café").count(), 32);
        assert_eq!(result.unwrap()["owner"], h.principal.id);
        let owner: String = h
            .db()
            .query_row("SELECT owner FROM records WHERE kind='document'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(owner, h.principal.id);
    }
}

#[cfg(feature = "pdf")]
#[tokio::test]
async fn pdf_corrupt_encrypted_and_no_text_fail_without_store_records() {
    let plain = synthetic_pdf(b"BT /F1 12 Tf (synthetic) Tj ET", 1, 0);
    let mut encrypted = pdf_extract::Document::load_mem(&plain).unwrap();
    encrypted.trailer.set(
        "ID",
        pdf_extract::Object::Array(vec![
            pdf_extract::Object::string_literal(vec![7; 16]),
            pdf_extract::Object::string_literal(vec![7; 16]),
        ]),
    );
    let state = pdf_extract::EncryptionState::try_from(pdf_extract::EncryptionVersion::V2 {
        document: &encrypted,
        owner_password: "synthetic-owner",
        user_password: "synthetic-reader",
        key_length: 128,
        permissions: pdf_extract::Permissions::all(),
    })
    .unwrap();
    encrypted.encrypt(&state).unwrap();
    let mut locked = Vec::new();
    encrypted.save_to(&mut locked).unwrap();
    for (bytes, code) in [
        (b"%PDF-1.4\ncorrupt".to_vec(), "DocumentParseError"),
        (locked, "EncryptedDocument"),
        (synthetic_pdf(b"0 0 m 10 10 l S", 1, 0), "NoExtractableText"),
    ] {
        let (result, h) = pdf_index_result(bytes).await;
        let error = result.unwrap_err();
        assert_eq!(error.code, code);
        assert!(!error.message.contains("synthetic-reader"));
        assert!(
            h.store
                .records(&h.principal, &h.grant, &json!({}), None)
                .unwrap()
                .is_empty()
        );
    }
}

#[cfg(feature = "pdf")]
#[tokio::test]
async fn pdf_pages_objects_operations_and_output_are_bounded() {
    let mut text = b"BT /F1 12 Tf (".to_vec();
    text.extend(vec![b'x'; assets::MAX_TEXT_BYTES + 1]);
    text.extend_from_slice(b") Tj ET");
    for (bytes, code) in [
        (
            synthetic_pdf(b"", assets::MAX_PDF_PAGES + 1, 0),
            "DocumentTooComplex",
        ),
        (
            synthetic_pdf(b"", 1, assets::MAX_PDF_OBJECTS),
            "DocumentTooComplex",
        ),
        (
            synthetic_pdf("q Q\n".repeat(32769).as_bytes(), 1, 0),
            "DocumentTooComplex",
        ),
        (synthetic_pdf(&text, 1, 0), "DocumentTooLarge"),
        (
            synthetic_pdf(&vec![b' '; 4 * 1024 * 1024 + 1], 1, 0),
            "DocumentTooLarge",
        ),
    ] {
        let (result, h) = pdf_index_result(bytes).await;
        assert_eq!(result.unwrap_err().code, code);
        assert!(
            h.store
                .records(&h.principal, &h.grant, &json!({}), None)
                .unwrap()
                .is_empty()
        );
    }
}

#[cfg(feature = "pdf")]
#[tokio::test]
async fn pdf_forms_are_validated_and_images_do_not_trigger_ocr() {
    use pdf_extract::{Document, Object, Stream, dictionary};
    for (kind, expected) in [
        ("form", None),
        ("cycle", Some("DocumentParseError")),
        ("image", Some("NoExtractableText")),
        ("parent_cycle", Some("DocumentParseError")),
    ] {
        let mut doc = Document::load_mem(&synthetic_pdf(b"/Fixture Do", 1, 0)).unwrap();
        let mut dict = dictionary! {"Type"=>"XObject","Subtype"=>"Form","BBox"=>vec![0.into(),0.into(),200.into(),200.into()]};
        let content = if kind == "image" {
            dict.set("Subtype", "Image");
            dict.set("Width", 1);
            dict.set("Height", 1);
            dict.set("ColorSpace", "DeviceRGB");
            dict.set("BitsPerComponent", 8);
            vec![255, 255, 255]
        } else if kind == "cycle" {
            b"/Fixture Do".to_vec()
        } else {
            b"BT /F1 12 Tf 20 100 Td (Nested PDF text) Tj ET".to_vec()
        };
        let id = doc.add_object(Stream::new(dict, content));
        let page_id = doc.get_pages()[&1];
        let page = doc.get_object_mut(page_id).unwrap().as_dict_mut().unwrap();
        page.get_mut(b"Resources")
            .unwrap()
            .as_dict_mut()
            .unwrap()
            .set("XObject", dictionary! {"Fixture"=>Object::Reference(id)});
        if kind == "parent_cycle" {
            page.set("Parent", Object::Reference(page_id));
        }
        let mut bytes = Vec::new();
        doc.save_to(&mut bytes).unwrap();
        let (result, h) = pdf_index_result(bytes).await;
        if let Some(code) = expected {
            assert_eq!(result.unwrap_err().code, code);
        } else {
            assert!(result.is_ok(), "{:?}", result);
            assert_eq!(
                h.store
                    .records(&h.principal, &h.grant, &json!({}), Some("Nested PDF text"))
                    .unwrap()
                    .len(),
                1
            );
        }
    }
}
