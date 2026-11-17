//! Opt-in read-only WebVPN probe: signs in to WebVPN once, then follows each
//! service entry through the gateway and prints only status, host and path of
//! every hop. No cookie, query, body or credential is printed.
//! Set DANSHENG_TEST_CREDENTIALS and run with --ignored --nocapture.
#![cfg(all(feature = "login", feature = "webvpn"))]

use dansheng_connectors::login::{LoginTarget, login};
use dansheng_connectors::webvpn::gateway_route;
use dansheng_core::network_routes::RouteMode;
use std::sync::Arc;

thread_local! { static CLOUD: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) }; }

fn credentials() -> (String, String) {
    let path = std::env::var_os("DANSHENG_TEST_CREDENTIALS")
        .expect("set DANSHENG_TEST_CREDENTIALS to the authorized credential file");
    let text = std::fs::read_to_string(path).expect("credential file unavailable");
    let mut user = None;
    let mut password = None;
    for line in text.trim_start_matches('\u{feff}').lines() {
        let Some((key, value)) = line.split_once([':', '=']) else {
            continue;
        };
        let raw = value.trim().trim_end_matches(',').trim();
        let value = raw
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| raw.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .unwrap_or(raw)
            .to_owned();
        match key.trim().to_ascii_lowercase().as_str() {
            "user" | "username" | "account" | "student_id" | "id" => user = Some(value),
            "password" | "pass" | "pwd" => password = Some(value),
            "yunpanpassword" | "cloud_password" | "cloudpassword" => CLOUD.with(|c| *c.borrow_mut() = Some(value)),
            _ => {}
        }
    }
    (
        user.expect("missing user"),
        password.expect("missing password"),
    )
}

const HOSTS: &[&str] = &[
    "id.fudan.edu.cn",
    "uis.fudan.edu.cn",
    "elearning.fudan.edu.cn",
    "fdjwgl.fudan.edu.cn",
    "ecard.fudan.edu.cn",
    "zlapp.fudan.edu.cn",
    "my.fudan.edu.cn",
    "ehall.fudan.edu.cn",
    "cloud.fudan.edu.cn",
];

/// `webvpn/<scheme>/<encoded host>` → logical host, for printing only.
fn describe(url: &url::Url) -> String {
    if url.host_str() != Some("webvpn.fudan.edu.cn") {
        return format!("direct {}{}", url.host_str().unwrap_or("?"), url.path());
    }
    for host in HOSTS {
        for scheme in ["https", "http"] {
            let origin = format!("{scheme}://{host}");
            // Auth hosts are refused as routes and print as `<host:…>`.
            let Ok(route) = gateway_route(&origin, RouteMode::Gateway) else {
                continue;
            };
            let prefix = url::Url::parse(&route.gateway_prefix).unwrap();
            if let Some(rest) = url.path().strip_prefix(prefix.path()) {
                return format!("via-vpn {host}{rest}");
            }
        }
    }
    let mut parts = url.path().splitn(4, '/');
    let _ = parts.next();
    let a = parts.next().unwrap_or("");
    let b = parts.next().unwrap_or("");
    if a == "http" || a == "https" || a.starts_with("http") {
        format!(
            "via-vpn <host:{}> /{}",
            &b[..b.len().min(12)],
            parts.next().unwrap_or("")
        )
    } else {
        format!("vpn-own {}", url.path())
    }
}

#[tokio::test]
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; signs in then reads only"]
async fn webvpn_proxied_service_entries() {
    let (user, password) = credentials();
    let session = match login(&user, &password, LoginTarget::WebVpn).await {
        Ok(session) => session,
        Err(error) => panic!("webvpn login failed: {error:?}"),
    };
    println!("webvpn login ok, cookies={}", session.cookies.len());
    let jar = Arc::new(reqwest::cookie::Jar::default());
    let gateway = url::Url::parse("https://webvpn.fudan.edu.cn/").unwrap();
    for cookie in &session.cookies {
        jar.add_cookie_str(cookie, &gateway);
    }
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(roots)
    .with_no_client_auth();
    let client = reqwest::Client::builder()
        .tls_backend_preconfigured(tls)
        .cookie_provider(jar)
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .unwrap();
    for entry in [
        "https://elearning.fudan.edu.cn/login/cas",
        "https://fdjwgl.fudan.edu.cn/student/for-std/course-table",
        "https://ecard.fudan.edu.cn/epay",
        "https://zlapp.fudan.edu.cn/fudanelec/wap/default/info",
        "https://my.fudan.edu.cn/simple_list/stqk",
        "https://ehall.fudan.edu.cn/",
        "https://cloud.fudan.edu.cn/user",
    ] {
        let logical = url::Url::parse(entry).unwrap();
        let route =
            gateway_route(&logical.origin().ascii_serialization(), RouteMode::Gateway).unwrap();
        let mut url =
            url::Url::parse(&format!("{}{}", route.gateway_prefix, logical.path())).unwrap();
        println!("== {}{}", logical.host_str().unwrap(), logical.path());
        for _ in 0..12 {
            let response = match client.get(url.clone()).send().await {
                Ok(r) => r,
                Err(error) => {
                    println!(
                        "   error timeout={} connect={}",
                        error.is_timeout(),
                        error.is_connect()
                    );
                    break;
                }
            };
            let status = response.status().as_u16();
            let location = response
                .headers()
                .get("location")
                .and_then(|v| v.to_str().ok())
                .and_then(|l| url.join(l).ok());
            let body = response.text().await.unwrap_or_default();
            let lower = body.to_ascii_lowercase();
            let login_form = lower.contains("password") || lower.contains("authserver");
            println!(
                "   {status} {} len={} login_form={login_form}",
                describe(&url),
                body.len()
            );
            for (name, value) in url.query_pairs() {
                if (name.eq_ignore_ascii_case("service") || name.eq_ignore_ascii_case("redirect"))
                    && let Ok(inner) = url::Url::parse(&value)
                {
                    println!("      {name}= {}", describe(&inner));
                }
            }
            if let (Some(start), Some(end)) = (lower.find("<title>"), lower.find("</title>"))
                && start < end
            {
                println!("      title={:?}", &body[start + 7..end.min(start + 87)]);
            }
            match location {
                Some(next) if (300..400).contains(&status) => url = next,
                _ => break,
            }
        }
    }
}

#[tokio::test]
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; signs in then reads only"]
async fn service_sign_in_through_webvpn_reaches_private_reads() {
    use dansheng_connectors::login::login_via_gateway;
    let (user, password) = credentials();
    let vpn = login(&user, &password, LoginTarget::WebVpn)
        .await
        .unwrap_or_else(|e| panic!("webvpn login failed: {e:?}"));
    println!("webvpn login ok");
    let mut cookies = vpn.cookies;
    for (target, probe) in [
        (
            LoginTarget::Canvas,
            "https://elearning.fudan.edu.cn/api/v1/users/self/profile",
        ),
        (
            LoginTarget::Academic,
            "https://fdjwgl.fudan.edu.cn/student/for-std/course-table",
        ),
        (
            LoginTarget::Ecard,
            "https://ecard.fudan.edu.cn/epay/myepay/index",
        ),
    ] {
        match login_via_gateway(&user, &password, target, &cookies).await {
            Ok(session) => {
                println!(
                    "{target:?}: gateway sign-in ok, gateway cookies={}",
                    session.cookies.len()
                );
                cookies = session.cookies;
            }
            Err(error) => {
                println!("{target:?}: gateway sign-in failed: {}", error.code());
                continue;
            }
        }
        let jar = Arc::new(reqwest::cookie::Jar::default());
        let gateway = url::Url::parse("https://webvpn.fudan.edu.cn/").unwrap();
        for cookie in &cookies {
            jar.add_cookie_str(cookie, &gateway);
        }
        let roots =
            rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(roots)
        .with_no_client_auth();
        let client = reqwest::Client::builder()
            .tls_backend_preconfigured(tls)
            .cookie_provider(jar)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .unwrap();
        let url =
            dansheng_connectors::webvpn::encode_url(&url::Url::parse(probe).unwrap()).unwrap();
        match client.get(url).send().await {
            Ok(response) => {
                let status = response.status().as_u16();
                let location = response
                    .headers()
                    .get("location")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|l| url::Url::parse(l).ok())
                    .map(|l| describe(&l));
                let body = response.text().await.unwrap_or_default();
                let has_id = serde_json::from_str::<serde_json::Value>(&body)
                    .ok()
                    .is_some_and(|v| v.get("id").is_some());
                println!(
                    "   private read: {status} len={} json_id={has_id} location={location:?}",
                    body.len()
                );
            }
            Err(error) => println!("   private read error timeout={}", error.is_timeout()),
        }
    }
}

/// The app's real path: switch WebVPN on, sign in, read. Every Fudan request
/// must then leave through the gateway; the probe network has no direct
/// session for any service, so a read can only succeed through WebVPN.
#[tokio::test]
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; signs in then reads only"]
async fn switched_on_campus_services_sign_in_and_read_through_webvpn() {
    use dansheng_connectors::core_adapter::CampusService;
    use dansheng_core::{
        Principal,
        network::Network,
        platform::UnavailablePlatform,
        policy::Grant,
        services::{CoreService, ServiceContext},
        store::Store,
    };
    use serde_json::{Value, json};
    let (user, password) = credentials();
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let platform = UnavailablePlatform;
    let owner = Principal::owner();
    let grant = Grant::default();
    let steps = [
        (
            "fudan.webvpn.configure",
            json!({"mode": std::env::var("DANSHENG_WEBVPN_MODE").unwrap_or_else(|_| "gateway".into())}),
        ),
        (
            "fudan.webvpn.login",
            json!({"password":password}),
        ),
        ("fudan.webvpn.status", json!({})),
        ("canvas.uis.login", json!({"password":password})),
        ("canvas.courses.sync", json!({})),
        ("fudan.ecard.login", json!({"password":password})),
        ("fudan.ecard.balance", json!({})),
        ("fudan.academic.login", json!({"password":password})),
        ("fudan.semesters", json!({})),
        ("fudan.rooms", json!({"building":"HGX","date":"2026-11-17"})),
    ];
    for (method, mut params) in steps {
        params["account_id"] = json!(user);
        let result = CampusService
            .call(
                ServiceContext {
                    store: &store,
                    network: &network,
                    platform: &platform,
                },
                &owner,
                &grant,
                method,
                params,
            )
            .await;
        match result {
            Ok(value) => {
                let summary = if method == "fudan.webvpn.status" {
                    json!({"enabled":value["enabled"],"mode":value["mode"],"has_session":value["has_session"],"routes":value["routes_count"]})
                } else {
                    let rows = value
                        .as_array()
                        .or_else(|| value.get("records").and_then(Value::as_array));
                    json!({"rows":rows.map(Vec::len),"keys":value.as_object().map(|o| o.keys().take(4).cloned().collect::<Vec<_>>())})
                };
                println!("{method}: ok {summary}");
            }
            Err(error) => println!("{method}: error {}", error.code),
        }
    }
    // No Fudan service ever got a direct session: everything sits in WebVPN.
    for origin in [
        "https://elearning.fudan.edu.cn",
        "https://ecard.fudan.edu.cn",
        "https://fdjwgl.fudan.edu.cn",
    ] {
        println!(
            "direct cookies for {origin}: {}",
            network.session_cookies(&user, origin).unwrap().len()
        );
    }
}

/// The cloud drive only has a campus address (10.x). A: without the owner's
/// named LAN approval it fails with PermissionDenied (the reported error);
/// B: with it (the Android policy) it lists; C: through WebVPN.
#[tokio::test]
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; signs in then reads only"]
async fn cloud_drive_lists_with_lan_approval_and_through_webvpn() {
    use dansheng_connectors::core_adapter::CampusService;
    use dansheng_core::{
        Principal,
        network::Network,
        platform::UnavailablePlatform,
        policy::Grant,
        services::{CoreService, ServiceContext},
        store::Store,
    };
    use serde_json::{Value, json};
    let (user, password) = credentials();
    let cloud = CLOUD
        .with(|c| c.borrow().clone())
        .expect("missing yunpanpassword");
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let platform = UnavailablePlatform;
    let owner = Principal::owner();
    let plain = Grant::default();
    let approved = Grant {
        private_network_origins: ["https://cloud.fudan.edu.cn".to_owned()]
            .into_iter()
            .collect(),
        ..Default::default()
    };
    let call = |grant: Grant, method: &'static str, params: Value| {
        let (store, network, platform, owner, user) =
            (&store, &network, &platform, &owner, user.clone());
        async move {
            let mut params = params;
            params["account_id"] = json!(user);
            let result = CampusService
                .call(
                    ServiceContext {
                        store,
                        network,
                        platform,
                    },
                    owner,
                    &grant,
                    method,
                    params,
                )
                .await;
            match &result {
                Ok(v) => {
                    let n = v
                        .as_array()
                        .map(Vec::len)
                        .or_else(|| v.get("items").and_then(Value::as_array).map(Vec::len));
                    println!("{method}: ok items={n:?}");
                }
                Err(e) => println!("{method}: error {} ({})", e.code, e.message),
            }
            result.ok()
        }
    };
    println!("-- direct sign-in");
    call(
        plain.clone(),
        "fudan.cloud.login",
        json!({"password":cloud}),
    )
    .await;
    println!("-- A: no LAN approval for the drive");
    call(plain.clone(), "fudan.cloud.roots", json!({})).await;
    println!("-- B: drive approved as a campus LAN origin (the fix)");
    if let Some(roots) = call(approved.clone(), "fudan.cloud.roots", json!({})).await
        && let Some(path) = roots
            .as_array()
            .and_then(|r| r.first())
            .and_then(|r| r["path"].as_str())
    {
        call(approved.clone(), "fudan.cloud.list", json!({"path":path})).await;
    }
    println!("-- C: WebVPN switched on");
    call(
        plain.clone(),
        "fudan.webvpn.configure",
        json!({"mode":"gateway"}),
    )
    .await;
    call(
        plain.clone(),
        "fudan.life.login",
        json!({"service":"webvpn","password":password}),
    )
    .await;
    call(
        plain.clone(),
        "fudan.cloud.login",
        json!({"password":cloud}),
    )
    .await;
    if let Some(roots) = call(plain.clone(), "fudan.cloud.roots", json!({})).await
        && let Some(path) = roots
            .as_array()
            .and_then(|r| r.first())
            .and_then(|r| r["path"].as_str())
    {
        call(plain.clone(), "fudan.cloud.list", json!({"path":path})).await;
    }
}

/// Where WebVPN's own sign-in spends its time (stage names only).
#[tokio::test]
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; signs in only"]
async fn webvpn_sign_in_timing() {
    use dansheng_connectors::login::{LoginProgress, login_with_progress};
    let (user, password) = credentials();
    for round in 0..8 {
        let progress = LoginProgress::default();
        let watch = progress.clone();
        let started = std::time::Instant::now();
        let ticker = tokio::spawn(async move {
            let mut last = String::new();
            loop {
                let now = watch.snapshot().to_string();
                if now != last {
                    println!("   {:>5.1}s {now}", started.elapsed().as_secs_f32());
                    last = now;
                }
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        });
        let result = login_with_progress(&user, &password, LoginTarget::WebVpn, progress).await;
        ticker.abort();
        println!(
            "round {round}: {} after {:.1}s",
            result.map(|_| "ok").unwrap_or_else(|e| e.code()),
            started.elapsed().as_secs_f32()
        );
    }
}
