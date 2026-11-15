// SPDX-License-Identifier: GPL-3.0-or-later
//! Real loopback HTTP/managed-asset regressions; no campus service or credentials.
use super::*;
use crate::{ConnectorTransport, HttpMethod};
use dansheng_core::{PrincipalKind, UnavailablePlatform, store::Store};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::Notify,
};

#[derive(Default)]
struct Gate {
    entered: Notify,
    release: Notify,
}

async fn read_request(socket: &mut tokio::net::TcpStream) -> String {
    let mut data = Vec::new();
    let mut buf = [0; 4096];
    let start = loop {
        if let Some(i) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        let n = socket.read(&mut buf).await.unwrap();
        assert!(n > 0 && data.len() < 32768);
        data.extend_from_slice(&buf[..n]);
    };
    let headers = String::from_utf8(data[..start].to_vec()).unwrap();
    let size = headers
        .lines()
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().unwrap())
        })
        .unwrap_or(0);
    while data.len() - start < size {
        let n = socket.read(&mut buf).await.unwrap();
        assert!(n > 0);
        data.extend_from_slice(&buf[..n]);
    }
    headers
}

async fn response_server(
    raw: Vec<u8>,
    gate: Option<Arc<Gate>>,
) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        read_request(&mut socket).await;
        if let Some(gate) = gate {
            gate.entered.notify_one();
            gate.release.notified().await;
        }
        socket.write_all(&raw).await.unwrap();
        let _ = socket.shutdown().await;
    });
    (origin, task)
}

fn authority(store: &Store, origin: &str) -> (Principal, Grant) {
    let principal = Principal {
        id: "synthetic-drive-caller".into(),
        kind: PrincipalKind::Mcp,
    };
    let grant = Grant {
        capabilities: ["webdav.write", "http.request", "http.write"]
            .map(str::to_owned)
            .into(),
        account_ids: ["a".into()].into(),
        origins: [origin.into()].into(),
        allow_private_network: true,
        ..Default::default()
    };
    store.set_grant(&principal.id, &grant).unwrap();
    (principal, grant)
}

fn transport<'a>(
    store: &'a Store,
    network: &'a Network,
    principal: &'a Principal,
    grant: &'a Grant,
) -> BoundTransport<'a> {
    BoundTransport {
        store,
        network,
        principal,
        grant,
        platform: &UnavailablePlatform,
        account: "a",
        source_capability: "webdav.write",
        credential_lease: Default::default(),
    }
}

fn request(origin: &str, binary: bool, method: HttpMethod) -> ConnectorRequest {
    ConnectorRequest {
        method,
        url: format!("{origin}/file").parse().unwrap(),
        headers: vec![(
            "Accept".into(),
            if binary {
                "application/x-protobuf"
            } else {
                "text/plain"
            }
            .into(),
        )],
        body: method.is_mutating().then(|| b"synthetic".to_vec()),
        auth: TransportAuth::HostToken {
            account_id: "a".into(),
        },
    }
}

#[tokio::test]
async fn drive_network_uncertainty_survives_both_bridge_paths() {
    for binary in [false, true] {
        for raw in [
            b"HTTP/1.1 500 Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
            b"HTTP/1.1 200 OK\r\nContent-Length: 30\r\nConnection: close\r\n\r\npartial".to_vec(),
        ] {
            let (origin, server) = response_server(raw, None).await;
            let temp = tempfile::tempdir().unwrap();
            let store = Store::open(temp.path()).unwrap();
            let network = Network::default();
            network
                .set_session("a", &origin, Some("SYNTHETIC-A".into()), vec![])
                .unwrap();
            let (principal, grant) = authority(&store, &origin);
            let result = transport(&store, &network, &principal, &grant)
                .execute(request(&origin, binary, HttpMethod::Put))
                .await;
            assert_eq!(
                source_error(result.unwrap_err()).code,
                "NeedsReconciliation"
            );
            server.await.unwrap();
        }
    }
    // Decoding a complete but non-text success also happens after dispatch.
    let (origin, server) = response_server(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n\xff\x00".to_vec(), None).await;
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    network
        .set_session("a", &origin, Some("SYNTHETIC-A".into()), vec![])
        .unwrap();
    let (principal, grant) = authority(&store, &origin);
    let result = transport(&store, &network, &principal, &grant)
        .execute(request(&origin, false, HttpMethod::Delete))
        .await;
    assert_eq!(
        source_error(result.unwrap_err()).code,
        "NeedsReconciliation"
    );
    server.await.unwrap();
}

#[tokio::test]
async fn drive_late_revocation_or_identity_replacement_is_uncertain_only_for_writes() {
    for binary in [false, true] {
        for replace_session in [false, true] {
            for method in [HttpMethod::Get, HttpMethod::Put] {
                let gate = Arc::new(Gate::default());
                let (origin, server) = response_server(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_vec(),
                    Some(gate.clone()),
                )
                .await;
                let temp = tempfile::tempdir().unwrap();
                let store = Store::open(temp.path()).unwrap();
                let network = Network::default();
                network
                    .set_session("a", &origin, Some("SYNTHETIC-A".into()), vec![])
                    .unwrap();
                let (principal, grant) = authority(&store, &origin);
                let bound = transport(&store, &network, &principal, &grant);
                let (result, ()) =
                    tokio::join!(bound.execute(request(&origin, binary, method)), async {
                        gate.entered.notified().await;
                        if replace_session {
                            network
                                .set_session("a", &origin, Some("SYNTHETIC-B".into()), vec![])
                                .unwrap();
                        } else {
                            store.set_grant(&principal.id, &Grant::default()).unwrap();
                        }
                        gate.release.notify_one();
                    });
                let expected = if method.is_mutating() {
                    "NeedsReconciliation"
                } else if replace_session {
                    "AuthenticationRequired"
                } else {
                    "PermissionDenied"
                };
                assert_eq!(source_error(result.unwrap_err()).code, expected);
                server.await.unwrap();
            }
        }
    }
}

#[tokio::test]
async fn drive_preflight_rejection_does_not_become_uncertain_or_dispatch() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let (principal, grant) = authority(&store, "http://127.0.0.1:1");
    store.set_grant(&principal.id, &Grant::default()).unwrap();
    let error = transport(&store, &network, &principal, &grant)
        .execute(request("http://127.0.0.1:1", true, HttpMethod::Put))
        .await
        .unwrap_err();
    assert_eq!(source_error(error).code, "PermissionDenied");
}

async fn asset_server(
    gate: Option<Arc<Gate>>,
) -> (url::Url, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap())
        .parse()
        .unwrap();
    let count = Arc::new(AtomicUsize::new(0));
    let observed = count.clone();
    let task = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let headers = read_request(&mut socket).await;
            observed.fetch_add(1, Ordering::SeqCst);
            let is_get = headers.starts_with("GET ");
            if is_get && let Some(gate) = &gate {
                gate.entered.notify_one();
                gate.release.notified().await;
            }
            let body = if headers.contains("SYNTHETIC-A") {
                "private-A"
            } else {
                "private-B"
            };
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                if is_get { body } else { "" }
            );
            let _ = socket.write_all(reply.as_bytes()).await;
            let _ = socket.shutdown().await;
        }
    });
    (base, count, task)
}

fn context<'a>(store: &'a Store, network: &'a Network) -> ServiceContext<'a> {
    ServiceContext {
        store,
        network,
        platform: &UnavailablePlatform,
    }
}

fn asset_contents(store: &Store, asset: &Value) -> Vec<u8> {
    let descriptor = dansheng_core::assets::export_descriptor(
        store,
        &Principal::owner(),
        &Grant::default(),
        json!({"asset_id": asset["asset_id"], "account_id": "a"}),
    )
    .unwrap();
    std::fs::read(descriptor["path"].as_str().unwrap()).unwrap()
}

#[tokio::test]
async fn drive_cache_is_reused_only_in_the_real_authenticated_session() {
    let (base, requests, server) = asset_server(None).await;
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let origin = base.origin().ascii_serialization();
    let grant = Grant {
        allow_private_network: true,
        ..Default::default()
    };
    let params = json!({"path": "/secret.txt"}); // metadata intentionally omitted
    network
        .set_session("a", &origin, Some("SYNTHETIC-A".into()), vec![])
        .unwrap();
    let session_a = DriveDownloadSession::capture(&network, "a").unwrap();
    let first = download_webdav_file(
        context(&store, &network),
        &Principal::owner(),
        &grant,
        "a",
        "server",
        &base,
        &params,
        &session_a,
    )
    .await
    .unwrap();
    assert_eq!(asset_contents(&store, &first), b"private-A");
    let cached = download_webdav_file(
        context(&store, &network),
        &Principal::owner(),
        &grant,
        "a",
        "server",
        &base,
        &params,
        &session_a,
    )
    .await
    .unwrap();
    assert_eq!(cached["asset_id"], first["asset_id"]);
    assert_eq!(requests.load(Ordering::SeqCst), 2);

    network
        .set_session("a", &origin, Some("SYNTHETIC-B".into()), vec![])
        .unwrap();
    // An old in-flight request must not adopt the replacement identity/cache.
    let error = download_webdav_file(
        context(&store, &network),
        &Principal::owner(),
        &grant,
        "a",
        "server",
        &base,
        &params,
        &session_a,
    )
    .await
    .unwrap_err();
    assert_eq!(error.code, "AuthenticationRequired");
    assert_eq!(requests.load(Ordering::SeqCst), 2);
    let session_b = DriveDownloadSession::capture(&network, "a").unwrap();
    let second = download_webdav_file(
        context(&store, &network),
        &Principal::owner(),
        &grant,
        "a",
        "server",
        &base,
        &params,
        &session_b,
    )
    .await
    .unwrap();
    assert_ne!(first["asset_id"], second["asset_id"]);
    assert_eq!(asset_contents(&store, &second), b"private-B");
    assert_eq!(requests.load(Ordering::SeqCst), 4);
    server.abort();
}

#[tokio::test]
async fn drive_identity_replacement_during_download_does_not_return_or_cache_the_file() {
    let gate = Arc::new(Gate::default());
    let (base, _, server) = asset_server(Some(gate.clone())).await;
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let origin = base.origin().ascii_serialization();
    network
        .set_session("a", &origin, Some("SYNTHETIC-A".into()), vec![])
        .unwrap();
    let session = DriveDownloadSession::capture(&network, "a").unwrap();
    let params = json!({"path": "/secret.txt"});
    let owner = Principal::owner();
    let grant = Grant {
        allow_private_network: true,
        ..Default::default()
    };
    let (result, ()) = tokio::join!(
        download_webdav_file(
            context(&store, &network),
            &owner,
            &grant,
            "a",
            "server",
            &base,
            &params,
            &session
        ),
        async {
            gate.entered.notified().await;
            network
                .set_session("a", &origin, Some("SYNTHETIC-B".into()), vec![])
                .unwrap();
            gate.release.notify_one();
        }
    );
    assert_eq!(result.unwrap_err().code, "AuthenticationRequired");
    use sha2::{Digest, Sha256};
    let key = hex_string(&Sha256::digest(
        serde_json::to_vec(&json!([
            session.fingerprint,
            "a",
            "server",
            "/secret.txt",
            null,
            null
        ]))
        .unwrap(),
    ));
    assert!(
        store
            .kv_get("service:webdav:files:a", &key)
            .unwrap()
            .is_null()
    );
    server.abort();
}
