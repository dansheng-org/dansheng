//! Opt-in probe of the forum while WebVPN is switched on. Signs in, then reads
//! only. Credentials and response bodies are never printed.
//! Set DANSHENG_TEST_CREDENTIALS and run with --ignored --nocapture.
#![cfg(all(feature = "services", feature = "webvpn"))]

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
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; authenticates then reads only"]
async fn forum_with_webvpn_switched_on() {
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
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let platform = UnavailablePlatform;
    let owner = Principal::owner();
    let grant = Grant {
        private_network_origins: [
            dansheng_connectors::forum_actions::AUTH_ORIGIN.to_owned(),
            dansheng_connectors::community::TEA_ORIGIN.to_owned(),
        ]
        .into_iter()
        .collect(),
        ..Default::default()
    };
    let mut failures = 0;
    let forced = || json!({"account_id":account,"mode":"gateway","origins":dansheng_connectors::webvpn::FORUM_ORIGINS});
    let login = || json!({"account_id":account,"email":email,"password":password});
    let own = || json!({"account_id":account});
    let search = || json!({"account_id":account,"query":"复旦","size":5});
    // (stage, method, params, expected error code)
    let steps: Vec<(&str, &str, Value, Option<&str>)> = vec![
        // Routed through WebVPN without a WebVPN session: WebVPN is what needs
        // signing in, and the forum password is never reported as rejected.
        (
            "forced/no-vpn-session",
            "fudan.webvpn.configure",
            forced(),
            None,
        ),
        (
            "forced/no-vpn-session",
            "community.tea.login",
            login(),
            Some("WebVpnLoginRequired"),
        ),
        // WebVPN switched on, not signed in to it: the forum still works directly.
        (
            "on/no-vpn-session",
            "fudan.webvpn.configure",
            json!({"account_id":account,"mode":"gateway"}),
            None,
        ),
        (
            "on/no-vpn-session",
            "community.tea.divisions",
            own(),
            Some("AuthenticationRequired"),
        ),
        ("on/no-vpn-session", "community.tea.login", login(), None),
        ("on/no-vpn-session", "community.tea.divisions", own(), None),
        // Signed in to the forum but routed through WebVPN: again a WebVPN matter.
        (
            "forced/no-vpn-session",
            "fudan.webvpn.configure",
            forced(),
            None,
        ),
        (
            "forced/no-vpn-session",
            "community.tea.divisions",
            own(),
            Some("WebVpnLoginRequired"),
        ),
        (
            "forced/no-vpn-session",
            "community.tea.search",
            search(),
            Some("WebVpnLoginRequired"),
        ),
        // The forum forced through WebVPN: what a blocked direct path falls back to.
        (
            "forced",
            "fudan.webvpn.login",
            json!({"account_id":account,"password":uis}),
            None,
        ),
        ("forced", "community.tea.divisions", own(), None),
        (
            "forced",
            "community.tea.holes",
            json!({"account_id":account,"page_size":10}),
            None,
        ),
        ("forced", "community.tea.search", search(), None),
        ("forced", "community.tea.login", login(), None),
        ("forced", "community.tea.divisions", own(), None),
    ];
    for (stage, method, params, expected) in steps {
        let started = std::time::Instant::now();
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
        let ms = started.elapsed().as_millis() as u64;
        match result {
            Ok(value) => {
                println!(
                    "{}",
                    json!({"stage":stage,"method":method,"ok":true,"ms":ms,
                    "records":value.get("records").and_then(Value::as_array).map(Vec::len)})
                );
                if expected.is_some() {
                    failures += 1;
                }
            }
            Err(error) => {
                println!(
                    "{}",
                    json!({"stage":stage,"method":method,"ok":false,"ms":ms,"code":error.code,"message":error.message})
                );
                if expected != Some(error.code.as_str()) {
                    failures += 1;
                }
            }
        }
    }
    assert_eq!(
        failures, 0,
        "forum-with-WebVPN probe failed; see sanitized statuses above"
    );
}
