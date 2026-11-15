//! Local TLS fixtures only. No public host or live credential is contacted.
use super::*;

fn policy(origin: &str) -> CookieCsrf {
    CookieCsrf {
        origin: origin.into(),
        cookie_name: "csrf_fixture".into(),
        header_name: "X-CSRF-Fixture".into(),
    }
}
fn request(origin: &str) -> HttpRequest {
    HttpRequest {
        url: format!("{origin}/messages"),
        method: "POST".into(),
        account_id: Some("a".into()),
        body: Some(Value::String("body=fixture".into())),
        follow_redirects: false,
        ..Default::default()
    }
}
fn authority(origin: &str) -> (Principal, Grant) {
    (
        Principal {
            id: "csrf-writer".into(),
            kind: crate::PrincipalKind::Mcp,
        },
        Grant {
            capabilities: ["http.request".into(), "http.write".into()].into(),
            account_ids: ["a".into()].into(),
            origins: [origin.into()].into(),
            allow_private_network: true,
            ..Default::default()
        },
    )
}
async fn fixture(
    reply: &'static str,
) -> (
    String,
    Network,
    Arc<Mutex<Vec<String>>>,
    tokio::task::JoinHandle<()>,
) {
    let cert = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
    let der = cert.cert.der().clone();
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
        cert.signing_key.serialize_der(),
    ));
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![der.clone()], key)
    .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("https://{}", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new()));
    let observed = requests.clone();
    let task = tokio::spawn(async move {
        loop {
            let (socket, _) = listener.accept().await.unwrap();
            let Ok(mut stream) = acceptor.accept(socket).await else {
                continue;
            };
            let mut data = Vec::new();
            let mut buffer = [0u8; 2048];
            loop {
                let n = stream.read(&mut buffer).await.unwrap();
                if n == 0 {
                    break;
                }
                data.extend_from_slice(&buffer[..n]);
                assert!(data.len() < 16384);
                if let Some(start) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                    let text = String::from_utf8_lossy(&data[..start]);
                    let len: usize = text
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse().unwrap())
                        })
                        .unwrap_or(0);
                    if data.len() >= start + 4 + len {
                        break;
                    }
                }
            }
            observed
                .lock()
                .unwrap()
                .push(String::from_utf8(data).unwrap());
            if !reply.is_empty() {
                let _ = stream.write_all(reply.as_bytes()).await;
            }
            let _ = stream.shutdown().await;
        }
    });
    let mut network = Network::default();
    network.test_roots.push(der);
    network
        .set_session(
            "a",
            &origin,
            Some("BEARER-MUST-NOT-SEND".into()),
            vec![
                "SID=account-a; Path=/; Secure".into(),
                "csrf_fixture=A%2BB+%2F%3D%252B; Path=/; Secure".into(),
            ],
        )
        .unwrap();
    (origin, network, requests, task)
}

#[test]
fn cookie_decodes_once_preserves_plus_and_rejects_missing_ambiguous_expired_or_invalid_values() {
    let url = Url::parse("https://fixture.invalid/messages").unwrap();
    let jar = SessionJar(Mutex::new(cookie_store::CookieStore::default()));
    for value in ["%", "%0", "%GG", "%0d%0a", "%00", "%FF", ""] {
        let mut store = cookie_store::CookieStore::default();
        store
            .parse(&format!("csrf_fixture={value}; Path=/; Secure"), &url)
            .unwrap();
        let jar = SessionJar(Mutex::new(store));
        let error = cookie_csrf_header(&jar, &url, "csrf_fixture").unwrap_err();
        assert_eq!(error.code, "CsrfRequired");
        assert!(!format!("{error:?}").contains("csrf_fixture="));
    }
    assert!(cookie_csrf_header(&jar, &url, "csrf_fixture").is_err());
    jar.0
        .lock()
        .unwrap()
        .parse("csrf_fixture=A%2BB+%2F%3D%252B; Path=/; Secure", &url)
        .unwrap();
    let token = cookie_csrf_header(&jar, &url, "csrf_fixture").unwrap();
    assert_eq!(token.to_str().unwrap(), "A+B+/=%2B");
    assert!(token.is_sensitive());
    assert!(!format!("{token:?}").contains("A+B"));
    jar.0
        .lock()
        .unwrap()
        .parse("csrf_fixture=other; Path=/messages; Secure", &url)
        .unwrap();
    assert!(cookie_csrf_header(&jar, &url, "csrf_fixture").is_err());
    jar.0
        .lock()
        .unwrap()
        .parse("csrf_fixture=gone; Path=/messages; Max-Age=0; Secure", &url)
        .unwrap();
    jar.0
        .lock()
        .unwrap()
        .parse("csrf_fixture=gone; Path=/; Max-Age=0; Secure", &url)
        .unwrap();
    assert!(cookie_csrf_header(&jar, &url, "csrf_fixture").is_err());
}

#[tokio::test]
async fn local_tls_injects_only_private_cookie_header_and_filters_echoed_secret_headers() {
    let (origin, network, requests, task) = fixture("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-CSRF-Fixture: DO-NOT-EXPORT\r\nSet-Cookie: secret=hidden; Secure\r\nConnection: close\r\n\r\n{}").await;
    let (principal, grant) = authority(&origin);
    let response = network
        .request_with_cookie_csrf(&principal, &grant, request(&origin), policy(&origin))
        .await
        .unwrap();
    assert!(
        !serde_json::to_string(&response)
            .unwrap()
            .contains("DO-NOT-EXPORT")
    );
    assert!(!response.headers.contains_key("set-cookie"));
    let seen = requests.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert!(seen[0].starts_with("POST /messages "));
    assert!(seen[0].contains("x-csrf-fixture: A+B+/=%2B\r\n"));
    assert!(seen[0].contains(&format!("origin: {origin}\r\n")));
    assert!(seen[0].contains("SID=account-a"));
    assert!(!seen[0].contains("BEARER-MUST-NOT-SEND"));
    drop(seen);
    task.abort();
}

#[tokio::test]
async fn preflight_rejects_account_origin_method_headers_missing_csrf_and_grants_before_io() {
    let (origin, network, requests, task) = fixture("").await;
    let (principal, grant) = authority(&origin);
    let mut cases = Vec::new();
    let mut input = request(&origin);
    input.account_id = Some("b".into());
    cases.push(input);
    let mut input = request(&origin);
    input.account_id = None;
    cases.push(input);
    let mut input = request(&origin);
    input.method = "GET".into();
    cases.push(input);
    let mut input = request(&origin);
    input.follow_redirects = true;
    cases.push(input);
    let mut input = request(&origin);
    input.url = "https://wrong.invalid/messages".into();
    cases.push(input);
    for header in [
        "Cookie",
        "Authorization",
        "Origin",
        "X-CSRF-Fixture",
        "Host",
    ] {
        let mut input = request(&origin);
        input.headers.insert(header.into(), "forged".into());
        cases.push(input);
    }
    for input in cases {
        assert!(
            network
                .request_with_cookie_csrf(&principal, &grant, input, policy(&origin))
                .await
                .is_err()
        );
    }
    for capability in ["http.write", "http.request"] {
        let mut grant = grant.clone();
        grant.capabilities.remove(capability);
        assert_eq!(
            network
                .request_with_cookie_csrf(&principal, &grant, request(&origin), policy(&origin))
                .await
                .err()
                .unwrap()
                .code,
            "PermissionDenied"
        );
    }
    let mut wrong_header = policy(&origin);
    wrong_header.header_name = "Authorization".into();
    assert!(
        network
            .request_with_cookie_csrf(&principal, &grant, request(&origin), wrong_header)
            .await
            .is_err()
    );
    // Another account has the valid CSRF token; this account must not borrow it.
    network
        .set_session(
            "b",
            &origin,
            None,
            vec!["csrf_fixture=account-b; Path=/; Secure".into()],
        )
        .unwrap();
    network
        .set_session("a", &origin, None, vec!["SID=only; Path=/; Secure".into()])
        .unwrap();
    assert_eq!(
        network
            .request_with_cookie_csrf(&principal, &grant, request(&origin), policy(&origin))
            .await
            .err()
            .unwrap()
            .code,
        "CsrfRequired"
    );
    assert!(requests.lock().unwrap().is_empty());
    task.abort();
}

#[tokio::test]
async fn redirects_server_errors_and_lost_responses_are_unknown_and_never_retried() {
    for reply in [
        "HTTP/1.1 302 Found\r\nLocation: /other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 999\r\nConnection: close\r\n\r\n{}",
        "",
    ] {
        let (origin, network, requests, task) = fixture(reply).await;
        let (principal, grant) = authority(&origin);
        let error = network
            .request_with_cookie_csrf(&principal, &grant, request(&origin), policy(&origin))
            .await
            .err()
            .unwrap();
        assert_eq!(error.code, "NeedsReconciliation");
        assert_eq!(requests.lock().unwrap().len(), 1);
        task.abort();
    }
}

#[tokio::test]
async fn gateway_rejected_and_auto_route_never_retries_a_failed_post() {
    let (gateway, network, requests, task) = fixture("").await;
    let dead_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("https://{}", dead_listener.local_addr().unwrap());
    drop(dead_listener);
    let (principal, grant) = authority(&origin);
    network
        .set_session(
            "a",
            &origin,
            None,
            vec![
                "SID=a; Path=/; Secure".into(),
                "csrf_fixture=ok; Path=/; Secure".into(),
            ],
        )
        .unwrap();
    for mode in [RouteMode::Gateway, RouteMode::Auto] {
        network
            .set_routes(
                "a",
                vec![GatewayRoute {
                    provider: "fixture".into(),
                    origin: origin.clone(),
                    gateway_prefix: format!("{gateway}/gateway"),
                    mode,
                }],
            )
            .unwrap();
        let error = network
            .request_with_cookie_csrf(&principal, &grant, request(&origin), policy(&origin))
            .await
            .err()
            .unwrap();
        assert_eq!(
            error.code,
            if mode == RouteMode::Gateway {
                "CapabilityUnavailable"
            } else {
                "NeedsReconciliation"
            }
        );
    }
    // Auto mode selecting the gateway for a missing native session also fails closed.
    network.set_session("a", &origin, None, vec![]).unwrap();
    assert_eq!(
        network
            .request_with_cookie_csrf(&principal, &grant, request(&origin), policy(&origin))
            .await
            .err()
            .unwrap()
            .code,
        "CapabilityUnavailable"
    );
    assert!(requests.lock().unwrap().is_empty());
    task.abort();
}
