//! Opt-in anonymous read-only check of the department columns the research
//! page aggregates (科研动态 / 学术讲座). Prints counts and the newest date.
//! Run: cargo test --features webvpn --test site_columns_probe -- --ignored --nocapture
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
use serde_json::json;

#[tokio::test]
#[ignore = "live check of public department sites"]
async fn department_columns_parse() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let platform = UnavailablePlatform;
    let list = std::env::var("SITE_COLUMNS")
        .unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/tests/site_columns.tsv").into());
    let mut empty = 0;
    for line in std::fs::read_to_string(list).unwrap().lines() {
        let cols: Vec<&str> = line.split('\t').collect();
        let [kind, name, url] = cols[..] else {
            continue;
        };
        let result = CampusService
            .call(
                ServiceContext {
                    store: &store,
                    network: &network,
                    platform: &platform,
                },
                &Principal::owner(),
                &Grant::default(),
                "fudan.site.articles",
                json!({"url": url, "account_id": "probe"}),
            )
            .await;
        match result {
            Ok(v) => {
                let rows = v.as_array().unwrap();
                let wx = rows
                    .iter()
                    .filter(|r| r["url"].as_str().unwrap().contains("weixin"))
                    .count();
                if rows.is_empty() {
                    empty += 1;
                }
                println!(
                    "{kind}\t{name}\t{}\twx={wx}\tnewest={}\t{}",
                    rows.len(),
                    rows.first()
                        .map_or("-".into(), |r| r["published_on"].to_string()),
                    rows.first().map_or(String::new(), |r| r["title"]
                        .as_str()
                        .unwrap()
                        .chars()
                        .take(30)
                        .collect())
                );
            }
            Err(e) => {
                empty += 1;
                println!("{kind}\t{name}\tERR {}: {}", e.code, e.message)
            }
        }
    }
    println!("empty or failed: {empty}");
}
