//! Opt-in authenticated read-only probe. Credentials and response bodies are never printed.
//! Set DANSHENG_TEST_CREDENTIALS to a local credential file and run with --ignored --nocapture.
#![cfg(feature = "services")]

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

#[tokio::test]
#[ignore = "requires explicit authorization and DANSHENG_TEST_CREDENTIALS; authenticates then reads only"]
async fn forum_authenticated_readonly() {
    let path = std::env::var_os("DANSHENG_TEST_CREDENTIALS")
        .expect("set DANSHENG_TEST_CREDENTIALS to the authorized credential file");
    let text = std::fs::read_to_string(path).expect("credential file unavailable");
    let field = regex::Regex::new(r"^\s*([A-Za-z]+)\s*[:=：]\s*(.*?)\s*$").unwrap();
    let mut email = None;
    let mut password = None;
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
        match capture[1].to_ascii_lowercase().as_str() {
            "danxiuser" => email = Some(value),
            "danxipassword" => password = Some(value),
            _ => {}
        }
    }
    let email = email.expect("missing forum email");
    let password = password.expect("missing forum password");
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let platform = UnavailablePlatform;
    let owner = Principal::owner();
    // Match the Android host's exact-origin policy for campus DNS / VPN routing.
    let grant = Grant {
        private_network_origins: [
            dansheng_connectors::forum_actions::AUTH_ORIGIN.to_owned(),
            dansheng_connectors::community::TEA_ORIGIN.to_owned(),
        ]
        .into_iter()
        .collect(),
        ..Default::default()
    };
    let account = "forum-readonly-probe";
    let mut failures = 0;
    let mut hole_id = None;
    let mut next_before = None;
    let mut division_id = None;
    for (method, params) in [
        (
            "community.tea.login",
            json!({"account_id":account,"email":email,"password":password}),
        ),
        ("community.tea.divisions", json!({"account_id":account})),
        (
            "community.tea.holes",
            json!({"account_id":account,"page_size":20,"order":"time_updated"}),
        ),
        ("community.tea.favorites", json!({"account_id":account})),
    ] {
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
                let records = value
                    .get("records")
                    .and_then(Value::as_array)
                    .or_else(|| value.as_array());
                if method == "community.tea.holes" {
                    hole_id = records
                        .and_then(|r| r.first())
                        .and_then(|r| r["payload"]["hole_id"].as_u64());
                    division_id = records
                        .and_then(|r| r.first())
                        .and_then(|r| r["payload"]["division_id"].as_u64());
                    next_before = records
                        .and_then(|r| r.last())
                        .and_then(|r| r["payload"]["time_updated"].as_str())
                        .map(str::to_owned);
                }
                println!(
                    "{}",
                    json!({"method":method,"ok":true,"records":records.map(Vec::len)})
                );
            }
            Err(error) => {
                println!(
                    "{}",
                    json!({"method":method,"ok":false,"code":error.code,"message":error.message})
                );
                failures += 1;
                if method == "community.tea.login" {
                    break;
                }
            }
        }
    }
    if let Some(before) = next_before {
        for (stage, params) in [
            (
                "next_page",
                json!({"account_id":account,"page_size":10,"before":before}),
            ),
            (
                "division",
                json!({"account_id":account,"page_size":10,"division_id":division_id}),
            ),
        ] {
            let result = CampusService
                .call(
                    ServiceContext {
                        store: &store,
                        network: &network,
                        platform: &platform,
                    },
                    &owner,
                    &grant,
                    "community.tea.holes",
                    params,
                )
                .await;
            match result {
                Ok(value) => println!(
                    "{}",
                    json!({"stage":stage,"ok":true,"records":value["records"].as_array().map(Vec::len)})
                ),
                Err(error) => {
                    println!("{}", json!({"stage":stage,"ok":false,"code":error.code}));
                    failures += 1;
                }
            }
        }
    }
    if let Some(hole_id) = hole_id {
        for method in ["community.tea.hole", "community.tea.floors"] {
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
                    json!({"account_id":account,"hole_id":hole_id,"page_size":20}),
                )
                .await;
            match result {
                Ok(value) => println!(
                    "{}",
                    json!({"method":method,"ok":true,"records":value["records"].as_array().map(Vec::len)})
                ),
                Err(error) => {
                    println!(
                        "{}",
                        json!({"method":method,"ok":false,"code":error.code,"message":error.message})
                    );
                    failures += 1;
                }
            }
        }
    }
    assert_eq!(
        failures, 0,
        "read-only forum probe failed; see sanitized statuses above"
    );
}
