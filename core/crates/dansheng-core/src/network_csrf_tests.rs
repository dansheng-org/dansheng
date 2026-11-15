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
    fixture_with_reply_pause(reply, None).await
}

async fn fixture_with_reply_pause(
    reply: &'static str,
    reply_pause: Option<Arc<TestDispatchPause>>,
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
            if let Some(pause) = &reply_pause {
                pause.pause().await;
            }
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

// Exercise the real Engine -> trusted service -> Network -> local TLS path.
// The service only delegates a fixed fixture operation, just as a typed adapter
// does; it does not fake a transport result or contact a public origin.
struct WriteFixtureService {
    origin: String,
}

#[async_trait::async_trait]
impl crate::services::CoreService for WriteFixtureService {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        vec![
            ("fixture.send", "fixture.write"),
            ("fixture.read", "fixture.read"),
        ]
    }

    async fn call(
        &self,
        context: crate::services::ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> CoreResult<Value> {
        let mut io_grant = grant.clone();
        io_grant
            .capabilities
            .extend(["http.request".into(), "http.write".into()]);
        let response = if method == "fixture.send" {
            context
                .network
                .request_with_cookie_csrf(
                    principal,
                    &io_grant,
                    request(&self.origin),
                    policy(&self.origin),
                )
                .await?
        } else {
            let mut input = request(&self.origin);
            input.method = "GET".into();
            input.body = None;
            context
                .network
                .request_with_credentials(principal, &io_grant, input, CredentialKind::Cookie)
                .await?
        };
        if params["postcheck"].as_bool() == Some(true) {
            context
                .store
                .grant(&principal.id)?
                .check(principal, "fixture.write")
                .map_err(|_| {
                    CoreError::new(
                        "NeedsReconciliation",
                        "fixture authority changed after send",
                    )
                })?;
        }
        Ok(serde_json::json!({"status": response.status}))
    }
}

struct SaveFixturePlatform {
    pause: Option<Arc<TestDispatchPause>>,
}

#[async_trait::async_trait]
impl crate::platform::PlatformPort for SaveFixturePlatform {
    fn capabilities(&self) -> Vec<String> {
        vec!["vault.set".into()]
    }
    async fn call(&self, method: &str, _: Value) -> CoreResult<Value> {
        assert_eq!(method, "vault.set");
        if let Some(pause) = &self.pause {
            pause.pause().await;
        }
        Ok(Value::Null)
    }
}

async fn engine_call(
    engine: &Arc<crate::Engine>,
    principal: Principal,
    method: &str,
    params: Value,
) -> crate::Response {
    tokio::time::timeout(
        Duration::from_secs(10),
        engine.handle(
            principal,
            crate::Request {
                id: "fixture".into(),
                method: method.into(),
                params,
            },
        ),
    )
    .await
    .expect("fixture Engine call timed out")
}

async fn notification(notify: &tokio::sync::Notify) {
    tokio::time::timeout(Duration::from_secs(10), notify.notified())
        .await
        .expect("fixture phase was not reached");
}

fn writer() -> Principal {
    Principal {
        id: "fixture-writer".into(),
        kind: crate::PrincipalKind::Mcp,
    }
}

async fn engine_fixture(
    directory: &std::path::Path,
    network: Network,
    origin: &str,
    save_pause: Option<Arc<TestDispatchPause>>,
) -> Arc<crate::Engine> {
    let mut engine = crate::Engine::open(
        directory,
        Arc::new(SaveFixturePlatform { pause: save_pause }),
    )
    .unwrap();
    Arc::get_mut(&mut engine).unwrap().set_test_network(network);
    engine
        .register_service(Arc::new(WriteFixtureService {
            origin: origin.into(),
        }))
        .unwrap();
    let grant = Grant {
        capabilities: ["fixture.write".into(), "fixture.read".into()].into(),
        account_ids: ["a".into()].into(),
        origins: [origin.into()].into(),
        allow_private_network: true,
        ..Default::default()
    };
    let response = engine_call(
        &engine,
        Principal::owner(),
        "permissions.set",
        serde_json::json!({"subject": writer().id, "grant": grant}),
    )
    .await;
    assert!(response.error.is_none(), "{:?}", response.error);
    engine
}

async fn change_authority(engine: &Arc<crate::Engine>, origin: &str, change: &str) {
    let (method, params) = match change {
        "replace" => (
            "auth.session.set",
            serde_json::json!({
                "account_id":"a", "origin":origin, "persist":false,
                "cookies":["SID=new-identity; Path=/; Secure", "csrf_fixture=new-csrf; Path=/; Secure"]
            }),
        ),
        "logout" => ("auth.logout", serde_json::json!({"account_id":"a"})),
        "capability" | "account" | "network" => {
            let mut grant = engine.store.grant(&writer().id).unwrap();
            if change == "capability" {
                grant.capabilities.clear();
            } else if change == "account" {
                grant.account_ids.clear();
            } else {
                grant.allow_private_network = false;
            }
            (
                "permissions.set",
                serde_json::json!({"subject":writer().id, "grant":grant}),
            )
        }
        _ => panic!("unknown fixture mutation"),
    };
    let response = engine_call(engine, Principal::owner(), method, params).await;
    assert!(response.error.is_none(), "{:?}", response.error);
}

const OK_REPLY: &str = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";

#[tokio::test]
async fn engine_write_queue_and_dns_reject_changed_authority_without_dispatch() {
    for phase in ["queue", "dns"] {
        for change in ["capability", "account", "network", "replace", "logout"] {
            let temp = tempfile::tempdir().unwrap();
            let (origin, mut network, requests, server) = fixture(OK_REPLY).await;
            let queued = Arc::new(tokio::sync::Notify::new());
            let dns = Arc::new(TestDispatchPause::default());
            let permit = if phase == "queue" {
                network.test_before_queue = Some(queued.clone());
                Some(
                    network
                        .concurrency
                        .clone()
                        .acquire_many_owned(8)
                        .await
                        .unwrap(),
                )
            } else {
                network.test_dns_pause = Some(dns.clone());
                None
            };
            let engine = engine_fixture(temp.path(), network, &origin, None).await;
            let task_engine = engine.clone();
            let send = tokio::spawn(async move {
                engine_call(
                    &task_engine,
                    writer(),
                    "fixture.send",
                    serde_json::json!({"account_id":"a"}),
                )
                .await
            });
            notification(if phase == "queue" {
                &queued
            } else {
                &dns.reached
            })
            .await;
            change_authority(&engine, &origin, change).await;
            drop(permit);
            dns.resume.notify_one();
            let response = send.await.unwrap();
            let code = response.error.expect("pending write must fail closed").code;
            let expected = if matches!(change, "replace" | "logout") {
                "AuthenticationRequired"
            } else {
                "PermissionDenied"
            };
            assert_eq!(code, expected, "{phase}: {change}");
            assert!(
                requests.lock().unwrap().is_empty(),
                "{phase}: {change} dispatched a stale write"
            );
            server.abort();
        }
    }
}

#[tokio::test]
async fn engine_write_after_dispatch_never_masks_uncertainty_with_permission_denied() {
    for (reply, postcheck, change) in [
        (OK_REPLY, false, "capability"),
        (OK_REPLY, true, "capability"),
        ("", false, "capability"),
        (OK_REPLY, false, "account"),
        (OK_REPLY, false, "network"),
        (OK_REPLY, false, "replace"),
        (OK_REPLY, false, "logout"),
    ] {
        let temp = tempfile::tempdir().unwrap();
        let pause = Arc::new(TestDispatchPause::default());
        let (origin, network, requests, server) =
            fixture_with_reply_pause(reply, Some(pause.clone())).await;
        let engine = engine_fixture(temp.path(), network, &origin, None).await;
        let task_engine = engine.clone();
        let send = tokio::spawn(async move {
            engine_call(
                &task_engine,
                writer(),
                "fixture.send",
                serde_json::json!({"account_id":"a", "postcheck":postcheck}),
            )
            .await
        });
        notification(&pause.reached).await;
        change_authority(&engine, &origin, change).await;
        pause.resume.notify_one();
        let response = send.await.unwrap();
        assert_eq!(
            response.error.unwrap().code,
            "NeedsReconciliation",
            "{change}: postcheck={postcheck}"
        );
        let seen = requests.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert!(seen[0].contains("SID=account-a"));
        assert!(!seen[0].contains("new-identity"));
        server.abort();
    }
}

#[tokio::test]
async fn engine_write_revocation_during_session_persistence_is_uncertain() {
    let temp = tempfile::tempdir().unwrap();
    let (origin, network, requests, server) = fixture(OK_REPLY).await;
    let pause = Arc::new(TestDispatchPause::default());
    let engine = engine_fixture(temp.path(), network, &origin, Some(pause.clone())).await;
    engine
        .store
        .kv_set("core:session-policy", "a", &serde_json::json!(true))
        .unwrap();
    let task_engine = engine.clone();
    let send = tokio::spawn(async move {
        engine_call(
            &task_engine,
            writer(),
            "fixture.send",
            serde_json::json!({"account_id":"a"}),
        )
        .await
    });
    notification(&pause.reached).await;
    change_authority(&engine, &origin, "capability").await;
    pause.resume.notify_one();
    assert_eq!(
        send.await.unwrap().error.unwrap().code,
        "NeedsReconciliation"
    );
    assert_eq!(requests.lock().unwrap().len(), 1);
    server.abort();
}

#[tokio::test]
async fn engine_write_success_and_preflight_failure_keep_their_original_outcomes() {
    let temp = tempfile::tempdir().unwrap();
    let (origin, network, requests, server) = fixture(OK_REPLY).await;
    let engine = engine_fixture(temp.path(), network, &origin, None).await;
    let response = engine_call(
        &engine,
        writer(),
        "fixture.send",
        serde_json::json!({"account_id":"a"}),
    )
    .await;
    assert!(response.error.is_none(), "{:?}", response.error);
    assert_eq!(response.result.unwrap()["status"], 200);
    // Dispatch state belongs to a single invocation, not to an account/network.
    change_authority(&engine, &origin, "replace").await;
    let response = engine_call(&engine, Principal::owner(), "auth.session.set", serde_json::json!({
        "account_id":"a", "origin":origin, "persist":false, "cookies":["SID=only; Path=/; Secure"]
    })).await;
    assert!(response.error.is_none());
    let response = engine_call(
        &engine,
        writer(),
        "fixture.send",
        serde_json::json!({"account_id":"a"}),
    )
    .await;
    assert_eq!(response.error.unwrap().code, "CsrfRequired");
    assert_eq!(requests.lock().unwrap().len(), 1);
    server.abort();
}

#[tokio::test]
async fn engine_read_revocation_still_rejects_sensitive_results() {
    let temp = tempfile::tempdir().unwrap();
    let pause = Arc::new(TestDispatchPause::default());
    let (origin, network, requests, server) =
        fixture_with_reply_pause(OK_REPLY, Some(pause.clone())).await;
    let engine = engine_fixture(temp.path(), network, &origin, None).await;
    let task_engine = engine.clone();
    let read = tokio::spawn(async move {
        engine_call(
            &task_engine,
            writer(),
            "fixture.read",
            serde_json::json!({"account_id":"a"}),
        )
        .await
    });
    notification(&pause.reached).await;
    change_authority(&engine, &origin, "capability").await;
    pause.resume.notify_one();
    let response = read.await.unwrap();
    assert_eq!(response.error.unwrap().code, "PermissionDenied");
    assert!(response.result.is_none());
    let seen = requests.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert!(seen[0].starts_with("GET "));
    server.abort();
}
