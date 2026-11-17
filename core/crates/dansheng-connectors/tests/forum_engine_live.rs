//! Opt-in probe of forum sign-in through the real Engine, as the app calls it:
//! a UIS sign-in first (so the account already has sessions), then the forum
//! sign-in and a read, with WebVPN off, on, and forced for the forum.
//! Signs in and reads only; credentials and bodies are never printed.
//! Set DANSHENG_TEST_CREDENTIALS and run with --ignored --nocapture.
#![cfg(all(feature = "services", feature = "webvpn", feature = "login"))]

use std::sync::Arc;

use dansheng_connectors::core_adapter::CampusService;
use dansheng_core::{Engine, Principal, Request, UnavailablePlatform};
use serde_json::{Value, json};

fn credentials() -> std::collections::BTreeMap<String, String> {
    let path = std::env::var_os("DANSHENG_TEST_CREDENTIALS")
        .expect("set DANSHENG_TEST_CREDENTIALS to the authorized credential file");
    let text = std::fs::read_to_string(path).expect("credential file unavailable");
    let field = regex::Regex::new(r"^\s*([A-Za-z_]+)\s*[:=：]\s*(.*?)\s*$").unwrap();
    let mut values = std::collections::BTreeMap::new();
    for line in text.trim_start_matches('\u{feff}').lines() {
        let Some(capture) = field.captures(line) else {
            continue;
        };
        let raw = capture[2].trim_end_matches(',').trim();
        let value = raw
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| raw.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .unwrap_or(raw)
            .to_owned();
        values.insert(capture[1].to_ascii_lowercase(), value);
    }
    values
}

#[tokio::test]
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; signs in then reads only"]
async fn forum_sign_in_through_the_engine_with_and_without_webvpn() {
    let values = credentials();
    let pick = |keys: &[&str]| {
        keys.iter()
            .find_map(|key| values.get(*key).cloned())
            .unwrap_or_else(|| panic!("missing credential field {}", keys[0]))
    };
    let account = pick(&["user", "username", "account", "student_id", "id"]);
    let uis = pick(&["password", "pass", "pwd"]);
    let email = pick(&["danxiuser"]);
    let password = pick(&["danxipassword"]);

    let temp = tempfile::tempdir().unwrap();
    let engine = Engine::open(temp.path(), Arc::new(UnavailablePlatform)).unwrap();
    engine.register_service(Arc::new(CampusService)).unwrap();
    // The same campus network policy the Android host sets at start-up.
    let origins: Vec<String> = [
        "auth.fduhole.com",
        "forum.fduhole.com",
        "danke.fduhole.com",
        "elearning.fudan.edu.cn",
        "fdjwgl.fudan.edu.cn",
        "ecard.fudan.edu.cn",
        "zlapp.fudan.edu.cn",
        "webvpn.fudan.edu.cn",
        "my.fudan.edu.cn",
        "mlibrary.fudan.edu.cn",
        "cloud.fudan.edu.cn",
    ]
    .map(|host| format!("https://{host}"))
    .into();
    let policy = engine
        .handle(
            Principal::owner(),
            Request {
                id: "policy".into(),
                method: "http.policy.set".into(),
                params: json!({"private_network_origins": origins}),
            },
        )
        .await;
    assert!(policy.error.is_none(), "{:?}", policy.error);

    let forum_login = || json!({"account_id":account,"email":email,"password":password});
    let own = || json!({"account_id":account});
    let steps: Vec<(&str, &str, Value)> = vec![
        // The app signs in to UIS services first, so the forum sign-in starts
        // with sessions already present.
        (
            "direct",
            "fudan.life.login",
            json!({"account_id":account,"service":"power","password":uis}),
        ),
        ("direct", "community.tea.login", forum_login()),
        ("direct", "community.tea.divisions", own()),
        // WebVPN switched on (gateway for Fudan services), then signed in to it.
        (
            "webvpn-on",
            "fudan.webvpn.configure",
            json!({"account_id":account,"mode":"gateway"}),
        ),
        (
            "webvpn-on",
            "fudan.webvpn.login",
            json!({"account_id":account,"password":uis}),
        ),
        ("webvpn-on", "community.tea.login", forum_login()),
        ("webvpn-on", "community.tea.divisions", own()),
        // The forum itself routed through WebVPN.
        (
            "forum-via-webvpn",
            "fudan.webvpn.configure",
            json!({"account_id":account,"mode":"gateway",
                "origins":dansheng_connectors::webvpn::FORUM_ORIGINS}),
        ),
        ("forum-via-webvpn", "community.tea.login", forum_login()),
        ("forum-via-webvpn", "community.tea.divisions", own()),
    ];
    let mut failures = 0;
    for (stage, method, params) in steps {
        let mut attempt = 0;
        loop {
            attempt += 1;
            let started = std::time::Instant::now();
            let response = engine
                .handle(
                    Principal::owner(),
                    Request {
                        id: method.into(),
                        method: method.into(),
                        params: params.clone(),
                    },
                )
                .await;
            let ms = started.elapsed().as_millis() as u64;
            let code = response.error.as_ref().map(|e| e.code.clone());
            println!(
                "{}",
                json!({"stage":stage,"method":method,"attempt":attempt,"ok":code.is_none(),
                    "ms":ms,"code":code,
                    "message":response.error.as_ref().map(|e| e.message.clone())})
            );
            // The school's sign-in sometimes times out from this machine; only a
            // network failure is tried again, never a refusal.
            if attempt < 3 && matches!(code.as_deref(), Some("Timeout" | "NetworkError")) {
                continue;
            }
            if code.is_some() {
                failures += 1;
            }
            break;
        }
    }
    // DanXi's course reviews (旦课), read with the same forum sign-in.
    let read = |method: &'static str, params: Value| {
        let engine = engine.clone();
        async move {
            let response = engine
                .handle(
                    Principal::owner(),
                    Request {
                        id: method.into(),
                        method: method.into(),
                        params,
                    },
                )
                .await;
            let code = response.error.as_ref().map(|e| e.code.clone());
            println!(
                "{}",
                json!({"stage":"danke","method":method,"ok":code.is_none(),"code":code,
                    "message":response.error.as_ref().map(|e| e.message.clone())})
            );
            response.result
        }
    };
    let random = read("community.danke.random", own()).await;
    let group_id = random
        .as_ref()
        .and_then(|r| r["payload"]["group_id"].as_u64());
    println!(
        "{}",
        json!({"stage":"danke","random_has_course":random.as_ref()
            .is_some_and(|r| r["payload"]["course"].is_object()),"group_id_present":group_id.is_some()})
    );
    let search = read(
        "community.danke.search",
        json!({"account_id":account,"query":"数学","page":1,"page_size":10}),
    )
    .await;
    println!(
        "{}",
        json!({"stage":"danke","search_records":search.as_ref()
            .and_then(|r| r["records"].as_array()).map(Vec::len)})
    );
    let group = match group_id {
        Some(id) => {
            read(
                "community.danke.group",
                json!({"account_id":account,"group_id":id}),
            )
            .await
        }
        None => None,
    };
    let courses = group
        .as_ref()
        .and_then(|g| g["payload"]["course_list"].as_array())
        .map(|list| {
            (
                list.len(),
                list.iter()
                    .filter_map(|c| c["review_list"].as_array())
                    .map(Vec::len)
                    .sum::<usize>(),
            )
        });
    println!(
        "{}",
        json!({"stage":"danke","group_courses_and_reviews":courses})
    );
    for ok in [random.is_some(), search.is_some(), group.is_some()] {
        if !ok {
            failures += 1;
        }
    }
    assert_eq!(failures, 0, "see sanitized statuses above");
}
