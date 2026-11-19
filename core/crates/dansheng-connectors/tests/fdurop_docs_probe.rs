//! Opt-in authenticated read-only end-to-end check of the research page's
//! live sources through `CampusService`: the FDUROP open-topic platform and
//! the FDUROP forms published (sign-in only) on jwc.fudan.edu.cn.
//! Prints only status codes and counts; never credentials, cookies or tokens.
//! Run: cargo test --features webvpn --test fdurop_docs_probe -- --ignored --nocapture
#![cfg(all(feature = "login", feature = "services"))]

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

const FORMS_PAGE: &str = "https://jwc.fudan.edu.cn/0e/07/c27281a724487/page.psp";

fn credentials() -> (String, String) {
    let path = std::env::var_os("DANSHENG_TEST_CREDENTIALS")
        .unwrap_or_else(|| "D:\\Code\\dansheng\\credentials.txt".into());
    let text = std::fs::read_to_string(path).expect("credential file unavailable");
    let (mut user, mut password) = (None, None);
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
            _ => {}
        }
    }
    (
        user.expect("missing user"),
        password.expect("missing password"),
    )
}

struct Harness {
    _temp: tempfile::TempDir,
    store: Store,
    network: Network,
    platform: UnavailablePlatform,
    account: String,
}

impl Harness {
    async fn call(&self, method: &str, mut params: Value) -> Result<Value, String> {
        params["account_id"] = json!(self.account);
        let started = std::time::Instant::now();
        let result = CampusService
            .call(
                ServiceContext {
                    store: &self.store,
                    network: &self.network,
                    platform: &self.platform,
                },
                &Principal::owner(),
                &Grant::default(),
                method,
                params,
            )
            .await
            .map_err(|e| format!("{}: {}", e.code, e.message));
        let ms = started.elapsed().as_millis();
        match &result {
            Ok(_) => println!("{method}: ok ({ms} ms)"),
            Err(code) => println!("{method}: error {code} ({ms} ms)"),
        }
        result
    }
}

#[tokio::test]
#[ignore = "live check with credentials; signs in then reads only"]
async fn research_live_sources_end_to_end() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (user, password) = credentials();
    let temp = tempfile::tempdir().unwrap();
    let h = Harness {
        store: Store::open(temp.path()).unwrap(),
        _temp: temp,
        network: Network::default(),
        platform: UnavailablePlatform,
        account: user,
    };

    // --- FDUROP forms on jwc: sign-in only. ---
    let before = h
        .call("fudan.notice.attachments", json!({"url": FORMS_PAGE}))
        .await;
    assert_eq!(
        before
            .err()
            .as_deref()
            .map(|e| e.split(':').next().unwrap()),
        Some("AuthenticationRequired"),
        "the forms page must ask for sign-in, not look empty"
    );
    h.call("fudan.notices.login", json!({"password": password}))
        .await
        .expect("jwc sign-in");
    let files = h
        .call("fudan.notice.attachments", json!({"url": FORMS_PAGE}))
        .await
        .expect("forms listing");
    let files = files.as_array().expect("attachment list");
    let named = files
        .iter()
        .filter(|f| f["name"].as_str().is_some_and(|n| n.contains('【')))
        .count();
    println!(
        "  forms: {} attachments, {named} with a 【stage】 tag",
        files.len()
    );
    assert!(files.len() >= 10, "expected the FDUROP form set");
    // Smallest-looking file first: a .doc/.docx form.
    let first = files
        .iter()
        .find(|f| f["url"].as_str().is_some_and(|u| u.ends_with(".doc")))
        .unwrap_or(&files[0]);
    let downloaded = h
        .call(
            "fudan.notice.attachment.download",
            json!({"url": first["url"], "name": first["name"]}),
        )
        .await
        .expect("attachment download");
    println!(
        "  download: mime={} size={} asset_id_present={}",
        downloaded["mime_type"],
        downloaded["size"],
        downloaded["asset_id"].as_str().is_some()
    );
    assert!(
        !downloaded["mime_type"]
            .as_str()
            .unwrap_or("")
            .starts_with("text/html")
    );
    // A second download of the same file is served from the asset cache.
    let again = h
        .call(
            "fudan.notice.attachment.download",
            json!({"url": first["url"], "name": first["name"]}),
        )
        .await
        .expect("second download");
    println!(
        "  re-download: same_sha={}",
        again["sha256"] == downloaded["sha256"]
    );

    // --- FDUROP open topics. ---
    h.call("fudan.fdurop.login", json!({"password": password}))
        .await
        .expect("fdurop sign-in");
    let subjects = h.call("fudan.fdurop.subjects", json!({})).await.unwrap();
    let labels = h.call("fudan.fdurop.labels", json!({})).await.unwrap();
    println!(
        "  subjects={} labels={}",
        subjects.as_array().map_or(0, Vec::len),
        labels.as_array().map_or(0, Vec::len)
    );
    let p1 = h
        .call("fudan.fdurop.topics", json!({"page": 1, "page_size": 20}))
        .await
        .unwrap();
    let p2 = h
        .call("fudan.fdurop.topics", json!({"page": 2, "page_size": 20}))
        .await
        .unwrap();
    let ids = |p: &Value| -> Vec<String> {
        p["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["id"].as_str().unwrap().to_owned())
            .collect()
    };
    let (a, b) = (ids(&p1), ids(&p2));
    println!(
        "  page1={} page2={} overlap={} total={} has_more={}",
        a.len(),
        b.len(),
        a.iter().filter(|i| b.contains(i)).count(),
        p1["total"],
        p1["has_more"]
    );
    assert_eq!(a.len(), 20);
    assert!(p1["total"].as_u64().unwrap() > 20 && p1["has_more"] == json!(true));
    assert!(a.iter().all(|i| !b.contains(i)), "pages must not overlap");

    // Subject filter by live id.
    let subject = &subjects.as_array().unwrap()[0];
    let filtered = h
        .call(
            "fudan.fdurop.topics",
            json!({"page": 1, "page_size": 20, "subject_kind_id": subject["id"]}),
        )
        .await
        .unwrap();
    println!(
        "  subject-filtered total={} (unfiltered {})",
        filtered["total"], p1["total"]
    );
    assert!(filtered["total"].as_u64().unwrap() < p1["total"].as_u64().unwrap());
    let subject_name = subject["name_zh"].as_str().unwrap();
    assert!(
        filtered["items"]
            .as_array()
            .unwrap()
            .iter()
            .all(|i| i["subject_kinds"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s == subject_name)),
        "every filtered topic carries the subject"
    );

    let label = &labels.as_array().unwrap()[0];
    let by_label = h
        .call(
            "fudan.fdurop.topics",
            json!({"page": 1, "page_size": 20, "topic_label_id": label["id"]}),
        )
        .await
        .unwrap();
    println!("  label-filtered total={}", by_label["total"]);
    assert!(by_label["total"].as_u64().unwrap() < p1["total"].as_u64().unwrap());

    // Keyword search by the first topic's teacher name matches via code_or_name.
    let teacher = p1["items"][0]["teacher_name"]
        .as_str()
        .unwrap_or("")
        .to_owned();
    if !teacher.is_empty() {
        let by_teacher = h
            .call(
                "fudan.fdurop.topics",
                json!({"page": 1, "page_size": 20, "keyword": teacher}),
            )
            .await
            .unwrap();
        let hits = by_teacher["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|i| i["teacher_name"] == json!(teacher))
            .count();
        println!("  teacher keyword: {hits} topics by that teacher");
        assert!(hits >= 1, "teacher-name keyword must find their topics");
    }

    let detail = h
        .call("fudan.fdurop.topic.detail", json!({"id": a[0]}))
        .await
        .unwrap();
    println!(
        "  detail: title_present={} brief_len={}",
        detail["title"].as_str().is_some_and(|t| !t.is_empty()),
        detail["brief"].as_str().map_or(0, |s| s.chars().count())
    );
}
