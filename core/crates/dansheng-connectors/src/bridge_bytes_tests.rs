// SPDX-License-Identifier: GPL-3.0-or-later
//! Synthetic loopback checks of the real connector-to-Core byte bridge.
use super::BoundTransport;
use crate::{ConnectorRequest, ConnectorTransport, HttpMethod, TransportAuth};
use dansheng_core::{
    Principal, PrincipalKind, UnavailablePlatform, network::Network, policy::Grant, store::Store,
};
use std::collections::BTreeMap;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Notify;
use url::Url;

async fn fixture(payload: Vec<u8>) -> (String, tokio::task::JoinHandle<(String, Vec<u8>)>) {
    fixture_with_gate(payload, None).await
}
#[derive(Default)]
struct ResponseGate {
    entered: Notify,
    release: Notify,
}
async fn fixture_with_gate(
    payload: Vec<u8>,
    gate: Option<Arc<ResponseGate>>,
) -> (String, tokio::task::JoinHandle<(String, Vec<u8>)>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0u8; 1024];
        let start = loop {
            if let Some(index) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                break index + 4;
            }
            let count = socket.read(&mut buffer).await.unwrap();
            assert!(count > 0 && bytes.len() < 32_768);
            bytes.extend_from_slice(&buffer[..count]);
        };
        let headers = String::from_utf8(bytes[..start].to_vec()).unwrap();
        let length = headers
            .lines()
            .find_map(|line| {
                let (key, value) = line.split_once(':')?;
                key.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().unwrap())
            })
            .unwrap_or(0);
        while bytes.len() - start < length {
            let count = socket.read(&mut buffer).await.unwrap();
            assert!(count > 0);
            bytes.extend_from_slice(&buffer[..count]);
        }
        if let Some(gate) = gate {
            gate.entered.notify_one();
            gate.release.notified().await;
        }
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nX-Fixture-Token: SYNTHETIC-SERVER-ECHO\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        socket.write_all(response.as_bytes()).await.unwrap();
        socket.write_all(&payload).await.unwrap();
        (headers, bytes[start..start + length].to_vec())
    });
    (origin, task)
}
fn authority(store: &Store, origin: &str) -> (Principal, Grant) {
    let principal = Principal {
        id: "fixture-byte-reader".into(),
        kind: PrincipalKind::Mcp,
    };
    let grant = Grant {
        capabilities: ["fixture.bytes.read", "http.request", "http.write"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        account_ids: ["synthetic-account".to_owned()].into_iter().collect(),
        origins: [origin.to_owned()].into_iter().collect(),
        allow_private_network: true,
        ..Default::default()
    };
    store.set_grant(&principal.id, &grant).unwrap();
    (principal, grant)
}

#[tokio::test]
async fn explicit_proto_body_is_not_text_encoded_by_connector_adapter() {
    let expected = vec![0, 255, 254, 0, 1, 128];
    let response = vec![0x0a, 0xff, 0x00, 0x1a, 0xfe];
    let (origin, server) = fixture(response.clone()).await;
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let (principal, grant) = authority(&store, &origin);
    let transport = BoundTransport {
        network: &network,
        platform: &UnavailablePlatform,
        principal: &principal,
        grant: &grant,
        account: "synthetic-account",
        store: &store,
        source_capability: "fixture.bytes.read",
        credential_lease: Default::default(),
    };
    let received = transport
        .execute(ConnectorRequest {
            method: HttpMethod::Post,
            url: Url::parse(&format!("{origin}/synthetic-proto")).unwrap(),
            headers: vec![("Content-Type".into(), "application/x-protobuf".into())],
            body: Some(expected.clone()),
            auth: TransportAuth::Anonymous,
        })
        .await
        .unwrap();
    assert_eq!(received.body, response);
    let (headers, body) = server.await.unwrap();
    assert!(headers.starts_with("POST /synthetic-proto "));
    assert_eq!(body, expected);
}

#[tokio::test]
async fn byte_bridge_preserves_explicit_secret_header_mode_without_exporting_headers() {
    let response = vec![0, 255, 0, 128];
    let (origin, server) = fixture(response.clone()).await;
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    network
        .set_session_with_headers(
            "synthetic-account",
            &origin,
            None,
            vec![],
            BTreeMap::from([("x-fixture-token".into(), "SYNTHETIC-CLIENT-TOKEN".into())]),
        )
        .unwrap();
    let (principal, grant) = authority(&store, &origin);
    let transport = BoundTransport {
        network: &network,
        platform: &UnavailablePlatform,
        principal: &principal,
        grant: &grant,
        account: "synthetic-account",
        store: &store,
        source_capability: "fixture.bytes.read",
        credential_lease: Default::default(),
    };
    let received = transport
        .execute(ConnectorRequest {
            method: HttpMethod::Get,
            url: Url::parse(&format!("{origin}/synthetic-proto")).unwrap(),
            headers: vec![("Accept".into(), "application/x-protobuf".into())],
            body: None,
            auth: TransportAuth::HostHeaders {
                account_id: "synthetic-account".into(),
            },
        })
        .await
        .unwrap();
    assert_eq!(received.body, response);
    assert!(
        !received
            .headers
            .iter()
            .any(|(name, value)| name.eq_ignore_ascii_case("x-fixture-token")
                || value.contains("SYNTHETIC-SERVER-ECHO"))
    );
    let (headers, body) = server.await.unwrap();
    assert!(headers.contains("SYNTHETIC-CLIENT-TOKEN"));
    assert!(body.is_empty());
    assert!(!format!("{received:?}").contains("SYNTHETIC"));
    // The reader-info/next-page boundary cannot silently pick up a new subject.
    network
        .set_session_with_headers(
            "synthetic-account",
            &origin,
            None,
            vec![],
            BTreeMap::from([(
                "x-fixture-token".into(),
                "SYNTHETIC-REPLACEMENT-TOKEN".into(),
            )]),
        )
        .unwrap();
    let changed = transport
        .execute(ConnectorRequest {
            method: HttpMethod::Get,
            url: Url::parse(&format!("{origin}/next")).unwrap(),
            headers: vec![("Accept".into(), "application/x-protobuf".into())],
            body: None,
            auth: TransportAuth::HostHeaders {
                account_id: "synthetic-account".into(),
            },
        })
        .await
        .unwrap_err();
    assert!(matches!(changed, crate::ConnectorError::AuthRequired(_)));
}

#[tokio::test]
async fn credential_replacement_during_response_prevents_data_leaving_the_bridge() {
    let gate = Arc::new(ResponseGate::default());
    let (origin, server) = fixture_with_gate(vec![0, 255, 0], Some(gate.clone())).await;
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let headers = |token: &str| BTreeMap::from([("x-fixture-token".into(), token.into())]);
    network
        .set_session_with_headers(
            "synthetic-account",
            &origin,
            None,
            vec![],
            headers("SYNTHETIC-A"),
        )
        .unwrap();
    let (principal, grant) = authority(&store, &origin);
    let transport = BoundTransport {
        network: &network,
        platform: &UnavailablePlatform,
        principal: &principal,
        grant: &grant,
        account: "synthetic-account",
        store: &store,
        source_capability: "fixture.bytes.read",
        credential_lease: Default::default(),
    };
    let request = ConnectorRequest {
        method: HttpMethod::Get,
        url: Url::parse(&format!("{origin}/data")).unwrap(),
        headers: vec![("Accept".into(), "application/x-protobuf".into())],
        body: None,
        auth: TransportAuth::HostHeaders {
            account_id: "synthetic-account".into(),
        },
    };
    let (result, ()) = tokio::join!(transport.execute(request), async {
        gate.entered.notified().await;
        network
            .set_session_with_headers(
                "synthetic-account",
                &origin,
                None,
                vec![],
                headers("SYNTHETIC-B"),
            )
            .unwrap();
        gate.release.notify_one();
    });
    assert!(matches!(
        result.unwrap_err(),
        crate::ConnectorError::AuthRequired(_)
    ));
    server.await.unwrap();
}

#[tokio::test]
async fn native_permission_revocation_during_response_prevents_data_return() {
    let gate = Arc::new(ResponseGate::default());
    let (origin, server) = fixture_with_gate(vec![0, 255, 0], Some(gate.clone())).await;
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let (principal, grant) = authority(&store, &origin);
    let transport = BoundTransport {
        network: &network,
        platform: &UnavailablePlatform,
        principal: &principal,
        grant: &grant,
        account: "synthetic-account",
        store: &store,
        source_capability: "fixture.bytes.read",
        credential_lease: Default::default(),
    };
    let request = ConnectorRequest {
        method: HttpMethod::Get,
        url: Url::parse(&format!("{origin}/data")).unwrap(),
        headers: vec![("Accept".into(), "application/x-protobuf".into())],
        body: None,
        auth: TransportAuth::Anonymous,
    };
    let (result, ()) = tokio::join!(transport.execute(request), async {
        gate.entered.notified().await;
        store.set_grant(&principal.id, &Grant::default()).unwrap();
        gate.release.notify_one();
    });
    assert_eq!(result.unwrap_err(), crate::ConnectorError::PermissionDenied);
    server.await.unwrap();
}
