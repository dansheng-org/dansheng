use dansheng_core::{
    Principal, PrincipalKind,
    network::{CredentialKind, HttpRequest, Network},
    policy::Grant,
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const QUOTA: usize = 8 * 1024 * 1024;
const SECRET_A: &str = "SYNTHETIC-BINARY-SECRET-A";
const SECRET_B: &str = "SYNTHETIC-BINARY-SECRET-B";

#[derive(Clone)]
struct Reply {
    status: u16,
    body: Vec<u8>,
    headers: BTreeMap<String, String>,
    chunked: bool,
    advertised_length: Option<usize>,
    body_delay: Option<Duration>,
}
impl Reply {
    fn bytes(body: &[u8]) -> Self {
        Self {
            status: 200,
            body: body.into(),
            headers: [("Content-Type".into(), "application/octet-stream".into())].into(),
            chunked: false,
            advertised_length: None,
            body_delay: None,
        }
    }
}
#[derive(Clone)]
struct Captured {
    method: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}
struct Fixture {
    origin: String,
    replies: Arc<Mutex<BTreeMap<String, Reply>>>,
    requests: Arc<Mutex<Vec<Captured>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Fixture {
    async fn start(reply: Reply) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let replies = Arc::new(Mutex::new(BTreeMap::from([("/data".into(), reply)])));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let answers = replies.clone();
        let recorded = requests.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let answers = answers.clone();
                let recorded = recorded.clone();
                tokio::spawn(async move {
                    let mut received = Vec::new();
                    let mut buffer = [0u8; 4096];
                    let boundary = loop {
                        let Ok(size) = socket.read(&mut buffer).await else {
                            return;
                        };
                        if size == 0 {
                            return;
                        }
                        received.extend_from_slice(&buffer[..size]);
                        if let Some(position) = received.windows(4).position(|w| w == b"\r\n\r\n") {
                            break position + 4;
                        }
                        assert!(
                            received.len() < 65536,
                            "synthetic request headers unexpectedly large"
                        );
                    };
                    let header_text = std::str::from_utf8(&received[..boundary]).unwrap();
                    let mut lines = header_text.split("\r\n");
                    let mut request_line = lines.next().unwrap().split_whitespace();
                    let method = request_line.next().unwrap().to_owned();
                    let path = request_line.next().unwrap().to_owned();
                    let headers: BTreeMap<String, String> = lines
                        .filter_map(|line| line.split_once(':'))
                        .map(|(k, v)| (k.to_ascii_lowercase(), v.trim().into()))
                        .collect();
                    let length = headers
                        .get("content-length")
                        .map(|s| s.parse::<usize>().unwrap())
                        .unwrap_or(0);
                    assert!(
                        length <= QUOTA,
                        "fixture only accepts small synthetic request bodies"
                    );
                    while received.len() < boundary + length {
                        let Ok(size) = socket.read(&mut buffer).await else {
                            return;
                        };
                        if size == 0 {
                            return;
                        }
                        received.extend_from_slice(&buffer[..size]);
                    }
                    recorded.lock().unwrap().push(Captured {
                        method,
                        headers,
                        body: received[boundary..boundary + length].to_vec(),
                    });
                    let reply = answers
                        .lock()
                        .unwrap()
                        .get(&path)
                        .cloned()
                        .unwrap_or_else(|| Reply::bytes(b"fixture"));
                    let mut header =
                        format!("HTTP/1.1 {} Fixture\r\nConnection: close\r\n", reply.status);
                    for (k, v) in &reply.headers {
                        header.push_str(&format!("{k}: {v}\r\n"));
                    }
                    if reply.chunked {
                        header.push_str("Transfer-Encoding: chunked\r\n");
                    } else {
                        header.push_str(&format!(
                            "Content-Length: {}\r\n",
                            reply.advertised_length.unwrap_or(reply.body.len())
                        ));
                    }
                    header.push_str("\r\n");
                    if socket.write_all(header.as_bytes()).await.is_err() {
                        return;
                    }
                    if let Some(delay) = reply.body_delay {
                        tokio::time::sleep(delay).await;
                    }
                    if reply.chunked {
                        for bytes in reply.body.chunks(65536) {
                            if socket
                                .write_all(format!("{:x}\r\n", bytes.len()).as_bytes())
                                .await
                                .is_err()
                            {
                                return;
                            }
                            if socket.write_all(bytes).await.is_err() {
                                return;
                            }
                            if socket.write_all(b"\r\n").await.is_err() {
                                return;
                            }
                        }
                        let _ = socket.write_all(b"0\r\n\r\n").await;
                    } else {
                        let _ = socket.write_all(&reply.body).await;
                    }
                });
            }
        });
        Self {
            origin,
            replies,
            requests,
            task,
        }
    }
    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
    fn last(&self) -> Captured {
        self.requests.lock().unwrap().last().unwrap().clone()
    }
    fn route(&self, path: &str, reply: Reply) {
        self.replies.lock().unwrap().insert(path.into(), reply);
    }
}
fn reader() -> Principal {
    Principal {
        id: "binary-reader".into(),
        kind: PrincipalKind::Client,
    }
}
fn grant(origins: &[&str]) -> Grant {
    Grant {
        capabilities: ["http.request".into(), "http.write".into()].into(),
        origins: origins.iter().map(|s| s.to_string()).collect(),
        account_ids: ["a".into()].into(),
        allow_private_network: true,
        ..Default::default()
    }
}
fn input(origin: &str, method: &str) -> HttpRequest {
    HttpRequest {
        url: format!("{origin}/data"),
        method: method.into(),
        timeout_ms: Some(3000),
        ..Default::default()
    }
}
fn bind(network: &Network, origin: &str, secret: &str) {
    network
        .set_session_with_headers(
            "a",
            origin,
            Some("SYNTHETIC-BEARER".into()),
            vec!["SID=synthetic; Path=/".into()],
            [("X-Fixture-Token".into(), secret.into())].into(),
        )
        .unwrap();
}

#[tokio::test]
async fn raw_nul_and_non_utf8_request_and_response_are_unchanged() {
    let body = vec![0, 0xff, 0x80, 0xfe, 0, 0x0a, 0xc0, 0xaf];
    let fixture = Fixture::start(Reply::bytes(&body)).await;
    let network = Network::default();
    let mut request = input(&fixture.origin, "POST");
    request
        .headers
        .insert("Content-Type".into(), "application/x-protobuf".into());
    let result = network
        .request_bytes(
            &reader(),
            &grant(&[&fixture.origin]),
            request,
            Some(body.clone()),
            CredentialKind::Anonymous,
        )
        .await
        .unwrap();
    assert_eq!(result.status, 200);
    assert_eq!(result.url, format!("{}/data", fixture.origin));
    assert_eq!(result.body, body);
    assert_eq!(fixture.last().body, body);
    assert_eq!(fixture.last().method, "POST");
    assert_eq!(
        fixture.last().headers.get("content-type").unwrap(),
        "application/x-protobuf"
    );
}

#[tokio::test]
async fn text_interface_still_decodes_and_managed_download_remains_binary() {
    let bytes = [0, 0xff, 0x80, 0xfe];
    let fixture = Fixture::start(Reply::bytes(&bytes)).await;
    let network = Network::default();
    let allowed = grant(&[&fixture.origin]);
    let error = network
        .request_with_credentials(
            &reader(),
            &allowed,
            input(&fixture.origin, "GET"),
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "UnsupportedContent");
    let binary = network
        .request_bytes(
            &reader(),
            &allowed,
            input(&fixture.origin, "GET"),
            None,
            CredentialKind::Anonymous,
        )
        .await
        .unwrap();
    assert_eq!(binary.body, bytes);
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("synthetic.bin");
    let receipt = network
        .download(
            &reader(),
            &allowed,
            input(&fixture.origin, "GET"),
            path.clone(),
            100,
            false,
        )
        .await
        .unwrap();
    assert_eq!(receipt.size, 4);
    assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
    let mut text = Reply::bytes("中文兼容".as_bytes());
    text.headers
        .insert("Content-Type".into(), "text/plain; charset=utf-8".into());
    fixture.route("/text", text);
    let mut request = input(&fixture.origin, "GET");
    request.url = format!("{}/text", fixture.origin);
    let response = network.request(&reader(), &allowed, request).await.unwrap();
    assert_eq!(response.body, "中文兼容");
    assert!(response.download.is_none());
    assert!(serde_json::to_value(response).unwrap()["body"].is_string());
}

#[tokio::test]
async fn raw_body_quota_and_two_body_sources_fail_before_dispatch() {
    let fixture = Fixture::start(Reply::bytes(b"ok")).await;
    let network = Network::default();
    let allowed = grant(&[&fixture.origin]);
    let error = network
        .request_bytes(
            &reader(),
            &allowed,
            input(&fixture.origin, "POST"),
            Some(vec![0; QUOTA + 1]),
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "RequestTooLarge");
    let mut request = input(&fixture.origin, "POST");
    request.body = Some(json!({"ambiguous":true}));
    let error = network
        .request_bytes(
            &reader(),
            &allowed,
            request,
            Some(vec![0xff]),
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "InvalidInput");
    assert_eq!(fixture.count(), 0);
}

#[tokio::test]
async fn response_quota_is_checked_for_length_and_streamed_chunks() {
    let mut oversized = Reply::bytes(b"");
    oversized.advertised_length = Some(QUOTA + 1);
    let fixture = Fixture::start(oversized).await;
    let network = Network::default();
    let allowed = grant(&[&fixture.origin]);
    let error = network
        .request_bytes(
            &reader(),
            &allowed,
            input(&fixture.origin, "GET"),
            None,
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "ResponseTooLarge");
    let mut streamed = Reply::bytes(&vec![0xff; QUOTA + 1]);
    streamed.chunked = true;
    fixture.route("/stream", streamed);
    let mut request = input(&fixture.origin, "GET");
    request.url = format!("{}/stream", fixture.origin);
    let error = network
        .request_bytes(
            &reader(),
            &allowed,
            request,
            None,
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "ResponseTooLarge");
    let error = network
        .request_bytes(
            &reader(),
            &allowed,
            input(&fixture.origin, "POST"),
            Some(vec![0]),
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "NeedsReconciliation");
}

#[tokio::test]
async fn binary_requests_cannot_bypass_capability_origin_account_or_lan_grants() {
    let fixture = Fixture::start(Reply::bytes(b"ok")).await;
    let network = Network::default();
    let allowed = grant(&[&fixture.origin]);
    let mut tests = Vec::new();
    let mut denied = allowed.clone();
    denied.capabilities.remove("http.request");
    tests.push((denied, input(&fixture.origin, "GET")));
    let mut denied = allowed.clone();
    denied.capabilities.remove("http.write");
    tests.push((denied, input(&fixture.origin, "POST")));
    let mut denied = allowed.clone();
    denied.origins.clear();
    tests.push((denied, input(&fixture.origin, "GET")));
    let mut denied = allowed.clone();
    denied.allow_private_network = false;
    tests.push((denied, input(&fixture.origin, "GET")));
    let mut request = input(&fixture.origin, "GET");
    request.account_id = Some("other-account".into());
    tests.push((allowed.clone(), request));
    let mut request = input(&fixture.origin, "GET");
    request
        .headers
        .insert("Authorization".into(), "SYNTHETIC-CALLER-CREDENTIAL".into());
    tests.push((allowed, request));
    for (g, r) in tests {
        let error = network
            .request_bytes(&reader(), &g, r, None, CredentialKind::Anonymous)
            .await
            .err()
            .unwrap();
        assert_eq!(error.code, "PermissionDenied");
    }
    assert_eq!(fixture.count(), 0);
}

#[tokio::test]
async fn binary_secret_headers_use_exact_origin_and_response_secrets_are_filtered() {
    let mut reply = Reply::bytes(&[0, 0xff]);
    for (name, value) in [
        ("Set-Cookie", "SID=synthetic"),
        ("Authorization", "SYNTHETIC-SERVER-AUTH"),
        ("Proxy-Authenticate", "SYNTHETIC-PROXY-AUTH"),
        ("X-Fixture-Token", SECRET_A),
    ] {
        reply.headers.insert(name.into(), value.into());
    }
    let fixture = Fixture::start(reply).await;
    let network = Network::default();
    bind(&network, &fixture.origin, SECRET_A);
    let mut request = input(&fixture.origin, "GET");
    request.account_id = Some("a".into());
    let result = network
        .request_bytes(
            &reader(),
            &grant(&[&fixture.origin]),
            request.clone(),
            None,
            CredentialKind::SecretHeaders,
        )
        .await
        .unwrap();
    assert_eq!(
        fixture.last().headers.get("x-fixture-token").unwrap(),
        SECRET_A
    );
    assert!(!fixture.last().headers.contains_key("authorization"));
    assert!(!fixture.last().headers.contains_key("cookie"));
    for key in [
        "set-cookie",
        "authorization",
        "proxy-authenticate",
        "x-fixture-token",
    ] {
        assert!(!result.headers.contains_key(key));
    }
    let any = network
        .request_bytes(
            &reader(),
            &grant(&[&fixture.origin]),
            request.clone(),
            None,
            CredentialKind::Any,
        )
        .await
        .unwrap();
    assert!(!fixture.last().headers.contains_key("x-fixture-token"));
    assert_eq!(any.body, [0, 0xff]);
    request
        .headers
        .insert("x-fixture-token".into(), "SYNTHETIC-COLLISION".into());
    let error = network
        .request_bytes(
            &reader(),
            &grant(&[&fixture.origin]),
            request,
            None,
            CredentialKind::SecretHeaders,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "PermissionDenied");
    assert_eq!(fixture.count(), 2);
}

#[tokio::test]
async fn binary_redirects_reauthorize_and_do_not_forward_other_origin_secrets() {
    let first = Fixture::start(Reply::bytes(b"first")).await;
    let second = Fixture::start(Reply::bytes(&[0xff, 0])).await;
    let mut redirect = Reply::bytes(b"");
    redirect.status = 302;
    redirect
        .headers
        .insert("Location".into(), format!("{}/data", second.origin));
    first.route("/data", redirect);
    let network = Network::default();
    bind(&network, &first.origin, SECRET_A);
    let allowed = grant(&[&first.origin, &second.origin]);
    let mut request = input(&first.origin, "GET");
    request.account_id = Some("a".into());
    let error = network
        .request_bytes(
            &reader(),
            &allowed,
            request.clone(),
            None,
            CredentialKind::SecretHeaders,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "AuthenticationRequired");
    assert_eq!(second.count(), 0);
    bind(&network, &second.origin, SECRET_B);
    let result = network
        .request_bytes(
            &reader(),
            &allowed,
            request,
            None,
            CredentialKind::SecretHeaders,
        )
        .await
        .unwrap();
    assert_eq!(result.url, format!("{}/data", second.origin));
    assert_eq!(result.body, [0xff, 0]);
    assert_eq!(
        first.last().headers.get("x-fixture-token").unwrap(),
        SECRET_A
    );
    assert_eq!(
        second.last().headers.get("x-fixture-token").unwrap(),
        SECRET_B
    );
    let error = network
        .request_bytes(
            &reader(),
            &grant(&[&first.origin]),
            input(&first.origin, "GET"),
            None,
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "PermissionDenied");
    assert_eq!(second.count(), 1);
}

#[tokio::test]
async fn binary_write_redirect_is_uncertain_and_is_never_replayed() {
    let fixture = Fixture::start(Reply::bytes(b"")).await;
    let mut redirect = Reply::bytes(b"");
    redirect.status = 307;
    redirect.headers.insert("Location".into(), "/other".into());
    fixture.route("/data", redirect);
    let network = Network::default();
    let bytes = vec![0xff, 0];
    let error = network
        .request_bytes(
            &reader(),
            &grant(&[&fixture.origin]),
            input(&fixture.origin, "POST"),
            Some(bytes.clone()),
            CredentialKind::Anonymous,
        )
        .await
        .err()
        .unwrap();
    assert_eq!(error.code, "NeedsReconciliation");
    assert_eq!(fixture.count(), 1);
    assert_eq!(fixture.last().body, bytes);
}

#[tokio::test]
async fn binary_body_deadline_preserves_read_timeout_and_write_uncertainty() {
    let mut reply = Reply::bytes(&[0xff]);
    reply.body_delay = Some(Duration::from_millis(250));
    let fixture = Fixture::start(reply).await;
    let network = Network::default();
    let allowed = grant(&[&fixture.origin]);
    for (method, expected) in [("GET", "Timeout"), ("POST", "NeedsReconciliation")] {
        let mut request = input(&fixture.origin, method);
        request.timeout_ms = Some(100);
        let error = network
            .request_bytes(
                &reader(),
                &allowed,
                request,
                Some(vec![0]),
                CredentialKind::Anonymous,
            )
            .await
            .err()
            .unwrap();
        assert_eq!(error.code, expected);
    }
}

#[tokio::test]
async fn exact_buffer_limit_is_allowed_for_raw_request_and_response() {
    let bytes = vec![0xff; QUOTA];
    let fixture = Fixture::start(Reply::bytes(&bytes)).await;
    let network = Network::default();
    let mut request = input(&fixture.origin, "POST");
    request.timeout_ms = Some(10000);
    let response = network
        .request_bytes(
            &reader(),
            &grant(&[&fixture.origin]),
            request,
            Some(bytes.clone()),
            CredentialKind::Anonymous,
        )
        .await
        .unwrap();
    assert_eq!(response.body.len(), QUOTA);
    assert_eq!(response.body, bytes);
    assert_eq!(fixture.last().body, bytes);
}
