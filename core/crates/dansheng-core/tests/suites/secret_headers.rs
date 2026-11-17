use async_trait::async_trait;
use dansheng_core::{
    CoreError, CoreResult, Engine, PlatformPort, Principal, PrincipalKind, Request, Response,
    network::{CredentialKind, HttpRequest},
    policy::Grant,
    services::{CoreService, ServiceContext},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

// These values only represent synthetic credentials on loopback fixtures.
const SECRET_A: &str = "SYNTHETIC-SECRET-HEADER-A";
const SECRET_B: &str = "SYNTHETIC-SECRET-HEADER-B";

#[derive(Default)]
struct TestVault(Mutex<BTreeMap<String, Value>>);

#[async_trait]
impl PlatformPort for TestVault {
    fn capabilities(&self) -> Vec<String> {
        vec![
            "vault.set".into(),
            "vault.get".into(),
            "vault.delete".into(),
        ]
    }
    async fn call(&self, method: &str, params: Value) -> CoreResult<Value> {
        let key = params["key"].as_str().unwrap();
        let mut values = self.0.lock().unwrap();
        match method {
            "vault.set" => {
                values.insert(key.into(), params["value"].clone());
                Ok(json!({"ok":true}))
            }
            "vault.get" => Ok(json!({"value":values.get(key).cloned().unwrap_or(Value::Null)})),
            "vault.delete" => {
                values.remove(key);
                Ok(json!({"ok":true}))
            }
            _ => Err(CoreError::new(
                "CapabilityUnavailable",
                "unknown fixture operation",
            )),
        }
    }
}

struct Probe;

#[async_trait]
impl CoreService for Probe {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        vec![
            ("fixture.secret", "http.request"),
            ("fixture.any", "http.request"),
        ]
    }
    async fn call(
        &self,
        context: ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> CoreResult<Value> {
        let request = serde_json::from_value::<HttpRequest>(params)?;
        let kind = if method == "fixture.secret" {
            CredentialKind::SecretHeaders
        } else {
            CredentialKind::Any
        };
        Ok(serde_json::to_value(
            context
                .network
                .request_with_credentials(principal, grant, request, kind)
                .await?,
        )?)
    }
}

struct Fixture {
    origin: String,
    requests: Arc<Mutex<Vec<String>>>,
    redirects: Arc<Mutex<BTreeMap<String, String>>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Fixture {
    async fn start() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let redirects = Arc::new(Mutex::new(BTreeMap::<String, String>::new()));
        let observed = requests.clone();
        let paths = redirects.clone();
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0u8; 1024];
                while !bytes.windows(4).any(|w| w == b"\r\n\r\n") && bytes.len() < 32768 {
                    let size = socket.read(&mut buffer).await.unwrap();
                    if size == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&buffer[..size]);
                }
                let request = String::from_utf8(bytes).unwrap();
                let path = request.split_whitespace().nth(1).unwrap_or("/");
                let target = paths.lock().unwrap().get(path).cloned();
                observed.lock().unwrap().push(request);
                let response = if let Some(target) = target {
                    format!(
                        "HTTP/1.1 302 Found\r\nLocation: {target}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    )
                } else {
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Fixture-Token: SYNTHETIC-SERVER-ECHO\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}".into()
                };
                socket.write_all(response.as_bytes()).await.unwrap();
            }
        });
        Self {
            origin,
            requests,
            redirects,
            task,
        }
    }
    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
    fn last(&self) -> String {
        self.requests.lock().unwrap().last().unwrap().clone()
    }
    fn redirect(&self, path: &str, target: String) {
        self.redirects.lock().unwrap().insert(path.into(), target);
    }
}

fn reader() -> Principal {
    Principal {
        id: "reader".into(),
        kind: PrincipalKind::Client,
    }
}

fn grant(origins: &[&str]) -> Grant {
    Grant {
        capabilities: ["http.request".into(), "auth.status".into()].into(),
        origins: origins.iter().map(|s| s.to_string()).collect(),
        account_ids: ["a".into(), "b".into()].into(),
        allow_private_network: true,
        ..Default::default()
    }
}

fn open(path: &std::path::Path, vault: Arc<TestVault>) -> Arc<Engine> {
    let engine = Engine::open(path, vault).unwrap();
    engine.register_service(Arc::new(Probe)).unwrap();
    engine
}

async fn call(engine: &Arc<Engine>, who: Principal, method: &str, params: Value) -> Response {
    engine
        .handle(
            who,
            Request {
                id: "secret-fixture".into(),
                method: method.into(),
                params,
            },
        )
        .await
}

async fn bind(engine: &Arc<Engine>, origin: &str, secret: &str) {
    let result = call(
        engine,
        Principal::owner(),
        "auth.session.set",
        json!({
            "account_id":"a", "origin":origin, "persist":true,
            "bearer":"synthetic-bearer", "cookies":["SID=synthetic; Path=/"],
            "secret_headers":{"X-Fixture-Token":secret}
        }),
    )
    .await;
    assert!(result.error.is_none());
    assert_eq!(result.result.unwrap()["authenticated"], true);
}

fn input(origin: &str) -> Value {
    json!({"url":format!("{origin}/data"),"account_id":"a"})
}

fn assert_redacted(response: &Response) {
    let wire = serde_json::to_string(response).unwrap();
    let debug = format!("{response:?}");
    for secret in [
        SECRET_A,
        SECRET_B,
        "SYNTHETIC-CALLER-COLLISION",
        "SYNTHETIC-SERVER-ECHO",
    ] {
        assert!(!wire.contains(secret));
        assert!(!debug.contains(secret));
    }
}

#[tokio::test]
async fn explicit_secret_headers_are_isolated_from_default_credentials_and_grants() {
    let fixture = Fixture::start().await;
    let temp = tempfile::tempdir().unwrap();
    let vault = Arc::new(TestVault::default());
    let engine = open(temp.path(), vault);
    let allowed = grant(&[&fixture.origin]);
    engine.store.set_grant("reader", &allowed).unwrap();
    bind(&engine, &fixture.origin, SECRET_A).await;

    let result = call(&engine, reader(), "fixture.secret", input(&fixture.origin)).await;
    assert!(result.error.is_none());
    assert_redacted(&result);
    let request = fixture.last();
    assert!(request.contains(SECRET_A));
    assert!(!request.to_lowercase().contains("authorization:"));
    assert!(!request.to_lowercase().contains("cookie:"));
    let result = call(&engine, reader(), "fixture.any", input(&fixture.origin)).await;
    assert!(result.error.is_none());
    let request = fixture.last();
    assert!(!request.contains(SECRET_A));
    assert!(
        request
            .to_lowercase()
            .contains("authorization: bearer synthetic-bearer")
    );
    assert!(request.to_lowercase().contains("cookie: sid=synthetic"));
    assert_redacted(&result);

    let before = fixture.count();
    for method in ["fixture.secret", "fixture.any"] {
        let mut query = input(&fixture.origin);
        query["headers"] = json!({"x-fixture-TOKEN":"SYNTHETIC-CALLER-COLLISION"});
        let result = call(&engine, reader(), method, query).await;
        assert_redacted(&result);
        assert_eq!(result.error.unwrap().code, "PermissionDenied");
    }
    let mut query = input(&fixture.origin);
    query["account_id"] = json!("b");
    let result = call(&engine, reader(), "fixture.secret", query).await;
    assert_eq!(result.error.unwrap().code, "AuthenticationRequired");
    let mut query = input(&fixture.origin);
    query.as_object_mut().unwrap().remove("account_id");
    let result = call(&engine, Principal::owner(), "fixture.secret", query).await;
    assert_eq!(result.error.unwrap().code, "AuthenticationRequired");
    engine.store.set_grant("reader", &Grant::default()).unwrap();
    let result = call(&engine, reader(), "fixture.secret", input(&fixture.origin)).await;
    assert_eq!(result.error.unwrap().code, "PermissionDenied");
    assert_eq!(fixture.count(), before);
    engine.store.set_grant("reader", &allowed).unwrap();
    assert!(
        call(&engine, reader(), "fixture.secret", input(&fixture.origin))
            .await
            .error
            .is_none()
    );
}

#[tokio::test]
async fn redirected_origins_require_their_own_secret_without_anonymous_fallback() {
    let source = Fixture::start().await;
    let target = Fixture::start().await;
    source.redirect("/cross", format!("{}/data", target.origin));
    source.redirect("/same", "/data".into());
    let temp = tempfile::tempdir().unwrap();
    let engine = open(temp.path(), Arc::new(TestVault::default()));
    engine
        .store
        .set_grant("reader", &grant(&[&source.origin, &target.origin]))
        .unwrap();
    bind(&engine, &source.origin, SECRET_A).await;
    let query = json!({"url":format!("{}/cross",source.origin),"account_id":"a"});
    let result = call(&engine, reader(), "fixture.secret", query.clone()).await;
    assert_eq!(result.error.unwrap().code, "AuthenticationRequired");
    assert_eq!(target.count(), 0);
    assert!(source.last().contains(SECRET_A));
    bind(&engine, &target.origin, SECRET_B).await;
    assert!(
        call(&engine, reader(), "fixture.secret", query)
            .await
            .error
            .is_none()
    );
    assert!(target.last().contains(SECRET_B));
    assert!(!target.last().contains(SECRET_A));
    let same = json!({"url":format!("{}/same",source.origin),"account_id":"a"});
    assert!(
        call(&engine, reader(), "fixture.secret", same)
            .await
            .error
            .is_none()
    );
    assert!(source.last().starts_with("GET /data "));
    assert!(source.last().contains(SECRET_A));

    let mut only_source = grant(&[&source.origin]);
    only_source.account_ids.remove("b");
    engine.store.set_grant("reader", &only_source).unwrap();
    let count = target.count();
    let result = call(
        &engine,
        reader(),
        "fixture.secret",
        json!({"url":format!("{}/cross",source.origin),"account_id":"a"}),
    )
    .await;
    assert_eq!(result.error.unwrap().code, "PermissionDenied");
    assert_eq!(target.count(), count);
}

#[tokio::test]
async fn persisted_secrets_restore_replace_logout_and_stay_out_of_audit() {
    let fixture = Fixture::start().await;
    let temp = tempfile::tempdir().unwrap();
    let vault = Arc::new(TestVault::default());
    let engine = open(temp.path(), vault.clone());
    engine
        .store
        .set_grant("reader", &grant(&[&fixture.origin]))
        .unwrap();
    bind(&engine, &fixture.origin, SECRET_A).await;
    let saved = vault.0.lock().unwrap()["http-sessions:a"].clone();
    assert_eq!(saved[0]["secret_headers"]["x-fixture-token"], SECRET_A);
    let audit = call(&engine, Principal::owner(), "events.poll", json!({})).await;
    assert_redacted(&audit);
    drop(engine);
    let engine = open(temp.path(), vault.clone());
    assert!(
        call(&engine, reader(), "fixture.secret", input(&fixture.origin))
            .await
            .error
            .is_none()
    );
    assert!(fixture.last().contains(SECRET_A));
    let replaced = call(
        &engine,
        Principal::owner(),
        "auth.session.set",
        json!({
            "account_id":"a", "origin":fixture.origin,"bearer":"synthetic-new-bearer"
        }),
    )
    .await;
    assert!(replaced.error.is_none());
    assert!(
        vault.0.lock().unwrap()["http-sessions:a"][0]
            .get("secret_headers")
            .is_none()
    );
    let count = fixture.count();
    let result = call(&engine, reader(), "fixture.secret", input(&fixture.origin)).await;
    assert_eq!(result.error.unwrap().code, "AuthenticationRequired");
    assert_eq!(fixture.count(), count);
    bind(&engine, &fixture.origin, SECRET_B).await;
    let result = call(
        &engine,
        Principal::owner(),
        "auth.logout",
        json!({"account_id":"a"}),
    )
    .await;
    assert!(result.error.is_none());
    assert!(!vault.0.lock().unwrap().contains_key("http-sessions:a"));
    drop(engine);
    let engine = open(temp.path(), vault);
    let result = call(&engine, reader(), "fixture.secret", input(&fixture.origin)).await;
    assert_eq!(result.error.unwrap().code, "AuthenticationRequired");
}

#[tokio::test]
async fn malformed_or_untrusted_session_inputs_cannot_replace_valid_secrets() {
    let fixture = Fixture::start().await;
    let temp = tempfile::tempdir().unwrap();
    let vault = Arc::new(TestVault::default());
    let engine = open(temp.path(), vault.clone());
    engine
        .store
        .set_grant("reader", &grant(&[&fixture.origin]))
        .unwrap();
    bind(&engine, &fixture.origin, SECRET_A).await;
    let saved = vault.0.lock().unwrap()["http-sessions:a"].clone();
    for invalid in [
        json!(null),
        json!([]),
        json!({"x-fixture-token":123}),
        json!({"Cookie":SECRET_B}),
        json!({"x-fixture-token":"synthetic\r\ninvalid"}),
    ] {
        let result = call(
            &engine,
            Principal::owner(),
            "auth.session.set",
            json!({"account_id":"a","origin":fixture.origin,"secret_headers":invalid}),
        )
        .await;
        assert_redacted(&result);
        assert_eq!(result.error.unwrap().code, "InvalidInput");
        assert_eq!(vault.0.lock().unwrap()["http-sessions:a"], saved);
    }
    let mut privileged = grant(&[&fixture.origin]);
    privileged.capabilities.insert("auth.session.set".into());
    engine.store.set_grant("reader", &privileged).unwrap();
    let result = call(&engine, reader(), "auth.session.set", json!({"account_id":"a","origin":fixture.origin,"secret_headers":{"x-fixture-token":SECRET_B}})).await;
    assert_redacted(&result);
    assert_eq!(result.error.unwrap().code, "PermissionDenied");
    assert!(
        call(&engine, reader(), "fixture.secret", input(&fixture.origin))
            .await
            .error
            .is_none()
    );
    assert!(fixture.last().contains(SECRET_A));
}
