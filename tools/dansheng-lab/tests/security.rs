use dansheng_core::{Engine, PlatformPort};
use dansheng_host::platform::DesktopPlatform;
use reqwest::{Client, StatusCode};
use serde_json::{Value, json};
use std::{path::Path, sync::Arc};

struct Harness {
    server: tokio::task::JoinHandle<()>,
    client: Client,
    origin: String,
    control: String,
    bootstrap: String,
}
impl Harness {
    async fn start(profile: &Path) -> Self {
        let platform: Arc<dyn PlatformPort> = Arc::new(DesktopPlatform::new(profile));
        let engine = Engine::open(profile, platform.clone()).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let state = dansheng_lab::Lab::new(engine, platform, port);
        let control = state.control_file().await;
        let app = dansheng_lab::router(state);
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();
        Self {
            server,
            client: Client::builder()
                .tls_backend_preconfigured(tls)
                .no_proxy()
                .build()
                .unwrap(),
            origin: format!("http://127.0.0.1:{port}"),
            control: control["control_token"].as_str().unwrap().into(),
            bootstrap: control["browser_url"]
                .as_str()
                .unwrap()
                .split("#token=")
                .nth(1)
                .unwrap()
                .into(),
        }
    }
    async fn stop(self) {
        self.server.abort();
        let _ = self.server.await;
    }
    #[cfg(windows)]
    async fn status(&self) -> Value {
        self.client
            .get(format!("{}/api/status", self.origin))
            .bearer_auth(&self.control)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap()
    }
}

#[tokio::test]
async fn rejects_unauthenticated_cross_origin_and_rebound_hosts() {
    let root = tempfile::tempdir().unwrap();
    let lab = Harness::start(root.path()).await;
    let page = lab.client.get(&lab.origin).send().await.unwrap();
    assert_eq!(page.status(), StatusCode::OK);
    assert_eq!(page.headers()["cache-control"], "no-store");
    assert!(
        page.headers()["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("frame-ancestors 'none'")
    );
    let html = page.text().await.unwrap();
    assert!(!html.contains(&lab.control));
    assert!(!html.contains(&lab.bootstrap));
    let missing = lab
        .client
        .get(format!("{}/api/status", lab.origin))
        .send()
        .await
        .unwrap();
    assert_eq!(missing.status(), StatusCode::UNAUTHORIZED);
    let rebound = lab
        .client
        .get(format!("{}/api/status", lab.origin))
        .header("host", "evil.example")
        .bearer_auth(&lab.control)
        .send()
        .await
        .unwrap();
    assert_eq!(rebound.status(), StatusCode::FORBIDDEN);
    let foreign = lab
        .client
        .post(format!("{}/api/probe", lab.origin))
        .header("origin", "https://evil.example")
        .bearer_auth(&lab.control)
        .json(&json!({"probe":"core"}))
        .send()
        .await
        .unwrap();
    assert_eq!(foreign.status(), StatusCode::FORBIDDEN);
    let fetch_site = lab
        .client
        .get(format!("{}/api/status", lab.origin))
        .header("sec-fetch-site", "cross-site")
        .bearer_auth(&lab.control)
        .send()
        .await
        .unwrap();
    assert_eq!(fetch_site.status(), StatusCode::FORBIDDEN);
    lab.stop().await;
}

#[tokio::test]
async fn bootstrap_is_single_use_and_browser_mutations_require_csrf() {
    let root = tempfile::tempdir().unwrap();
    let lab = Harness::start(root.path()).await;
    let missing_origin = lab
        .client
        .post(format!("{}/api/session", lab.origin))
        .json(&json!({"token":lab.bootstrap}))
        .send()
        .await
        .unwrap();
    assert_eq!(missing_origin.status(), StatusCode::FORBIDDEN);
    let created = lab
        .client
        .post(format!("{}/api/session", lab.origin))
        .header("origin", &lab.origin)
        .json(&json!({"token":lab.bootstrap}))
        .send()
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let set_cookie = created.headers()["set-cookie"].to_str().unwrap().to_owned();
    assert!(set_cookie.contains("HttpOnly"));
    assert!(set_cookie.contains("SameSite=Strict"));
    let cookie = set_cookie.split(';').next().unwrap();
    let csrf = created.json::<Value>().await.unwrap()["csrf_token"]
        .as_str()
        .unwrap()
        .to_owned();
    let reused = lab
        .client
        .post(format!("{}/api/session", lab.origin))
        .header("origin", &lab.origin)
        .json(&json!({"token":lab.bootstrap}))
        .send()
        .await
        .unwrap();
    assert_eq!(reused.status(), StatusCode::UNAUTHORIZED);
    let missing_csrf = lab
        .client
        .post(format!("{}/api/probe", lab.origin))
        .header("origin", &lab.origin)
        .header("cookie", cookie)
        .json(&json!({"probe":"core"}))
        .send()
        .await
        .unwrap();
    assert_eq!(missing_csrf.status(), StatusCode::FORBIDDEN);
    let allowed = lab
        .client
        .post(format!("{}/api/probe", lab.origin))
        .header("origin", &lab.origin)
        .header("cookie", cookie)
        .header("x-csrf-token", &csrf)
        .json(&json!({"probe":"core"}))
        .send()
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::OK);
    assert_eq!(allowed.json::<Value>().await.unwrap()["ok"], true);
    let cannot_open = lab
        .client
        .post(format!("{}/api/open", lab.origin))
        .header("origin", &lab.origin)
        .header("cookie", cookie)
        .header("x-csrf-token", "invalid")
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(cannot_open.status(), StatusCode::FORBIDDEN);
    let cannot_diagnose = lab
        .client
        .post(format!("{}/api/diagnostic/academic", lab.origin))
        .header("origin", &lab.origin)
        .header("cookie", cookie)
        .header("x-csrf-token", &csrf)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(cannot_diagnose.status(), StatusCode::FORBIDDEN);
    let cannot_diagnose_rooms = lab
        .client
        .post(format!("{}/api/diagnostic/rooms", lab.origin))
        .header("origin", &lab.origin)
        .header("cookie", cookie)
        .header("x-csrf-token", &csrf)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(cannot_diagnose_rooms.status(), StatusCode::FORBIDDEN);
    let cannot_diagnose_canvas = lab
        .client
        .post(format!("{}/api/diagnostic/canvas", lab.origin))
        .header("origin", &lab.origin)
        .header("cookie", cookie)
        .header("x-csrf-token", &csrf)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(cannot_diagnose_canvas.status(), StatusCode::FORBIDDEN);
    let cannot_bind_token = lab
        .client
        .post(format!("{}/api/canvas/token", lab.origin))
        .header("origin", &lab.origin)
        .header("cookie", cookie)
        .header("x-csrf-token", &csrf)
        .json(&json!({"token":"synthetic-token-for-test"}))
        .send()
        .await
        .unwrap();
    assert_eq!(cannot_bind_token.status(), StatusCode::FORBIDDEN);
    lab.stop().await;
}

#[tokio::test]
async fn rejects_unlisted_remote_writes_and_malformed_inputs() {
    let root = tempfile::tempdir().unwrap();
    let lab = Harness::start(root.path()).await;
    let invalid_token = "synthetic token with whitespace";
    let invalid = lab
        .client
        .post(format!("{}/api/canvas/token", lab.origin))
        .bearer_auth(&lab.control)
        .json(&json!({"token":invalid_token}))
        .send()
        .await
        .unwrap();
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
    assert!(!invalid.text().await.unwrap().contains(invalid_token));
    for probe in [
        "mail.send",
        "http.request",
        "plugins.run",
        "permissions.set",
    ] {
        let response = lab
            .client
            .post(format!("{}/api/probe", lab.origin))
            .bearer_auth(&lab.control)
            .json(&json!({"probe":probe}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            response.json::<Value>().await.unwrap()["error"]["code"],
            "UnknownProbe"
        );
    }
    let unknown = lab
        .client
        .post(format!("{}/api/probe", lab.origin))
        .bearer_auth(&lab.control)
        .json(&json!({"probe":"core","method":"mail.send"}))
        .send()
        .await
        .unwrap();
    assert_eq!(unknown.status(), StatusCode::BAD_REQUEST);
    let too_large = lab
        .client
        .post(format!("{}/api/credentials", lab.origin))
        .bearer_auth(&lab.control)
        .json(&json!({"student_id":"20770000123","password":"x".repeat(20000)}))
        .send()
        .await
        .unwrap();
    assert!(too_large.status().is_client_error());
    let wrong_type = lab
        .client
        .post(format!("{}/api/credentials", lab.origin))
        .bearer_auth(&lab.control)
        .form(&[("student_id", "20770000123"), ("password", "fake")])
        .send()
        .await
        .unwrap();
    assert_eq!(wrong_type.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
    lab.stop().await;
}

#[cfg(windows)]
#[tokio::test]
async fn synthetic_credentials_are_encrypted_non_echoed_and_survive_restart() {
    let root = tempfile::tempdir().unwrap();
    let lab = Harness::start(root.path()).await;
    let student_id = "20770000123";
    let password = "synthetic-lab-only-password-72f61f44";
    let saved = lab
        .client
        .post(format!("{}/api/credentials", lab.origin))
        .bearer_auth(&lab.control)
        .json(&json!({"student_id":student_id,"password":password}))
        .send()
        .await
        .unwrap();
    assert_eq!(saved.status(), StatusCode::OK);
    let receipt = saved.text().await.unwrap();
    assert!(!receipt.contains(student_id));
    assert!(!receipt.contains(password));
    let status = lab.status().await;
    assert_eq!(status["credentials"]["stored"], true);
    assert_eq!(status["session"]["authenticated"], false);
    assert!(!status.to_string().contains(password));
    let first_account = status["account_id"].clone();
    lab.stop().await;
    for entry in std::fs::read_dir(root.path().join("vault")).unwrap() {
        let encrypted = std::fs::read(entry.unwrap().path()).unwrap();
        assert!(
            !encrypted
                .windows(password.len())
                .any(|v| v == password.as_bytes())
        );
        assert!(
            !encrypted
                .windows(student_id.len())
                .any(|v| v == student_id.as_bytes())
        );
    }
    let database = std::fs::read(root.path().join("dansheng.db")).unwrap();
    assert!(
        !database
            .windows(password.len())
            .any(|v| v == password.as_bytes())
    );
    assert!(
        !database
            .windows(student_id.len())
            .any(|v| v == student_id.as_bytes())
    );
    let resumed = Harness::start(root.path()).await;
    assert_eq!(resumed.status().await["account_id"], first_account);
    let changed = resumed
        .client
        .post(format!("{}/api/credentials", resumed.origin))
        .bearer_auth(&resumed.control)
        .json(&json!({"student_id":"20770000999","password":password}))
        .send()
        .await
        .unwrap();
    assert_eq!(changed.status(), StatusCode::OK);
    assert_ne!(resumed.status().await["account_id"], first_account);
    let deleted = resumed
        .client
        .delete(format!("{}/api/credentials", resumed.origin))
        .bearer_auth(&resumed.control)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::OK);
    assert_eq!(resumed.status().await["credentials"]["stored"], false);
    resumed.stop().await;
}
