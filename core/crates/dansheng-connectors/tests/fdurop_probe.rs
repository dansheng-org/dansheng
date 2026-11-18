//! Opt-in authenticated read-only probe for FDUROP (paper.fudan.edu.cn).
//! Never prints credentials, tokens, or private secrets.
//! Reads D:\Code\dansheng\credentials.txt in-process only.
#![cfg(all(feature = "login", feature = "services"))]

use reqwest::{Client, header::LOCATION};
use std::time::Duration;

fn credentials() -> (String, String) {
    let path = std::env::var_os("DANSHENG_TEST_CREDENTIALS")
        .unwrap_or_else(|| "D:\\Code\\dansheng\\credentials.txt".into());
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
            _ => {}
        }
    }
    (
        user.expect("missing user"),
        password.expect("missing password"),
    )
}

#[tokio::test]
#[ignore = "live probe with credentials"]
async fn test_fdurop_login_and_query() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (user, pass) = credentials();
    println!("Loaded credentials for user length {}", user.len());

    let client = Client::builder()
        .cookie_store(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(15))
        .user_agent("dansheng-core/0.2.25")
        .build()
        .unwrap();

    // 1. Start at entry point on paper.fudan.edu.cn
    let entry_url = "https://paper.fudan.edu.cn/fdurop-service/jwt/cas/login";
    let entry_res = client.get(entry_url).send().await.unwrap();
    println!("Step 1 entry status: {}", entry_res.status());
    let entry_loc = entry_res
        .headers()
        .get(LOCATION)
        .map(|v| v.to_str().unwrap().to_string())
        .expect("entry redirect missing");
    println!("Step 1 redirect to CAS: {}", entry_loc);

    // 2. Follow redirect on id.fudan.edu.cn
    let mut current_url = entry_loc;
    let mut fragment_url = None;
    for hop in 0..5 {
        let res = client.get(&current_url).send().await.unwrap();
        println!("Hop {} status: {}, url: {}", hop, res.status(), current_url);
        if res.status().is_redirection() {
            let next_loc = res
                .headers()
                .get(LOCATION)
                .map(|v| v.to_str().unwrap().to_string())
                .unwrap();
            let parsed = url::Url::parse(&current_url)
                .unwrap()
                .join(&next_loc)
                .unwrap();
            if parsed.fragment().is_some() && parsed.as_str().contains("lck=") {
                fragment_url = Some(parsed.clone());
            }
            current_url = parsed.to_string();
        } else {
            break;
        }
    }

    let frag_u = fragment_url.expect("expected fragment URL with lck");
    let frag = frag_u.fragment().unwrap();
    let query_str = frag.split_once('?').map(|(_, q)| q).unwrap_or(frag);
    let pairs: std::collections::HashMap<_, _> = url::form_urlencoded::parse(query_str.as_bytes())
        .into_owned()
        .collect();
    let lck = pairs.get("lck").cloned().expect("lck missing");
    let entity_id = pairs.get("entityId").cloned().expect("entityId missing");
    println!(
        "Step 2 found lck len: {}, entity len: {}",
        lck.len(),
        entity_id.len()
    );

    // 3. Query auth methods
    let methods_res = client
        .post("https://id.fudan.edu.cn/idp/authn/queryAuthMethods")
        .json(&serde_json::json!({"lck": lck, "entityId": entity_id}))
        .send()
        .await
        .unwrap();
    println!("Step 3 methods status: {}", methods_res.status());
    let methods_json: serde_json::Value = methods_res.json().await.unwrap();
    let chain = methods_json["data"]
        .as_array()
        .and_then(|arr| arr.iter().find(|m| m["moduleCode"] == "userAndPwd"))
        .and_then(|m| m["authChainCode"].as_str())
        .expect("authChainCode missing")
        .to_string();

    // 4. Get public key
    let key_res = client
        .post("https://id.fudan.edu.cn/idp/authn/getJsPublicKey")
        .json(&serde_json::json!({}))
        .send()
        .await
        .unwrap();
    let key_json: serde_json::Value = key_res.json().await.unwrap();
    let pub_key_der = key_json["data"].as_str().unwrap();

    // 5. Encrypt password
    let compact: String = pub_key_der
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    let der = <base64::engine::general_purpose::GeneralPurpose as base64::Engine>::decode(
        &base64::engine::general_purpose::STANDARD,
        compact,
    )
    .unwrap();
    let rsa_key =
        <rsa::RsaPublicKey as rsa::pkcs8::DecodePublicKey>::from_public_key_der(&der).unwrap();
    let mut rng = rsa::rand_core::OsRng;
    let enc_bytes = rsa_key
        .encrypt(&mut rng, rsa::Pkcs1v15Encrypt, pass.as_bytes())
        .unwrap();
    let enc_b64 = <base64::engine::general_purpose::GeneralPurpose as base64::Engine>::encode(
        &base64::engine::general_purpose::STANDARD,
        enc_bytes,
    );

    // 6. Submit authExecute
    let auth_res = client
        .post("https://id.fudan.edu.cn/idp/authn/authExecute")
        .json(&serde_json::json!({
            "authModuleCode": "userAndPwd",
            "authChainCode": chain,
            "entityId": entity_id,
            "requestType": "chain_type",
            "lck": lck,
            "authPara": {
                "loginName": user,
                "password": enc_b64,
                "verifyCode": ""
            }
        }))
        .send()
        .await
        .unwrap();
    println!("Step 6 auth status: {}", auth_res.status());
    let auth_json: serde_json::Value = auth_res.json().await.unwrap();
    println!("Step 6 code: {}", auth_json["code"]);
    let login_token = auth_json["loginToken"]
        .as_str()
        .expect("loginToken missing");

    // 7. AuthnEngine
    let engine_res = client
        .post("https://id.fudan.edu.cn/idp/authCenter/authnEngine")
        .form(&[("loginToken", login_token)])
        .send()
        .await
        .unwrap();
    println!("Step 7 engine status: {}", engine_res.status());
    let engine_body = engine_res.text().await.unwrap();
    println!(
        "Step 7 engine body preview: {}",
        &engine_body[..std::cmp::min(500, engine_body.len())]
    );

    // Extract ticket from form using scraper like login.rs
    let doc = scraper::Html::parse_document(&engine_body);
    let form_sel = scraper::Selector::parse("form#logon").unwrap();
    let form_el = doc.select(&form_sel).next().expect("form#logon missing");
    let action = form_el
        .value()
        .attr("action")
        .expect("action missing")
        .to_string();
    let ticket_sel = scraper::Selector::parse("input#ticket").unwrap();
    let ticket_el = form_el
        .select(&ticket_sel)
        .next()
        .expect("input#ticket missing");
    let ticket = ticket_el
        .value()
        .attr("value")
        .expect("ticket value missing")
        .to_string();
    println!(
        "Step 7 ticket found, len: {}, action: {}",
        ticket.len(),
        action
    );

    // 8. Submit ticket to target
    let sep = if action.contains('?') { "&" } else { "?" };
    let ticket_url = format!("{}{sep}ticket={}", action, ticket);
    println!("Step 8 ticket consume URL: {}", ticket_url);
    let target_res = client.get(&ticket_url).send().await.unwrap();
    println!("Step 8 ticket consume status: {}", target_res.status());
    let step8_loc = target_res
        .headers()
        .get(LOCATION)
        .map(|v| v.to_str().unwrap().to_string());
    println!(
        "Step 8 redirect: {:?}",
        step8_loc.as_ref().map(|s| {
            let u = url::Url::parse(s).unwrap();
            (
                u.origin().ascii_serialization(),
                u.path().to_string(),
                u.fragment().is_some(),
            )
        })
    );

    // Extract idToken from redirect location or query/fragment
    let mut id_token = None;
    if let Some(ref loc) = step8_loc {
        if let Some(pos) = loc.find("idToken=") {
            let part = &loc[pos + 8..];
            let end = part.find('&').unwrap_or(part.len());
            id_token = Some(part[..end].to_string());
        }
    }
    println!("Step 8 extracted idToken present: {}", id_token.is_some());

    let token = id_token.expect("expected idToken");

    // 9. Query open topic endpoint!
    let test_client = Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .unwrap();

    // Test search / list
    let search_url = "https://paper.fudan.edu.cn/fdurop-service/api/v1/for-std/urop-init-flow/open-topic/search?queryPage__=1,20";
    // Test if Bearer prefix works
    let bearer_res = test_client
        .get(search_url)
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .unwrap();
    println!(
        "GET open-topic/search with Bearer prefix status: {}",
        bearer_res.status()
    );
    let raw_res = test_client
        .get(search_url)
        .header("Authorization", &token)
        .send()
        .await
        .unwrap();
    println!(
        "GET open-topic/search with raw token status: {}",
        raw_res.status()
    );
    let search_res = raw_res;
    println!(
        "Step 9 GET open-topic/search status: {}",
        search_res.status()
    );
    let search_text = search_res.text().await.unwrap();
    println!(
        "Step 9 response preview (first 100 chars): {}",
        search_text.chars().take(100).collect::<String>()
    );

    // Parse json
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&search_text) {
        println!(
            "Step 9 parsed code: {}, has data: {}",
            v["code"],
            v.get("data").is_some()
        );
        let list_opt = v["data"]
            .as_array()
            .or_else(|| v["data"]["dataList"].as_array())
            .or_else(|| v["data"]["rows"].as_array());
        if let Some(arr) = list_opt {
            println!("Step 9 total items in data array: {}", arr.len());
            if let Some(first) = arr.first() {
                println!(
                    "First topic keys: {:?}",
                    first
                        .as_object()
                        .map(|o| o.keys().cloned().collect::<Vec<_>>())
                );
                println!(
                    "First topic: {}",
                    serde_json::to_string_pretty(first).unwrap()
                );
                let topic_id = first["id"].as_str().expect("topic id missing");
                // 10. Query detail
                let detail_url = format!(
                    "https://paper.fudan.edu.cn/fdurop-service/api/v1/for-std/urop-init-flow/topic-view/{}",
                    topic_id
                );
                let detail_res = test_client
                    .get(&detail_url)
                    .header("Authorization", &token)
                    .send()
                    .await
                    .unwrap();
                println!("Step 10 detail status: {}", detail_res.status());
                let detail_val: serde_json::Value = detail_res.json().await.unwrap();
                println!(
                    "Step 10 detail code: {}, has data: {}",
                    detail_val["code"],
                    detail_val.get("data").is_some()
                );
                if let Some(data) = detail_val.get("data") {
                    println!(
                        "Detail data keys: {:?}",
                        data.as_object()
                            .map(|o| o.keys().cloned().collect::<Vec<_>>())
                    );
                    println!(
                        "Detail data: {}",
                        serde_json::to_string_pretty(data).unwrap()
                    );
                }
            }
        }
    }
}

#[tokio::test]
#[ignore = "live probe with credentials"]
async fn test_fdurop_via_login_target() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (user, pass) = credentials();
    let session = dansheng_connectors::login::login(
        &user,
        &pass,
        dansheng_connectors::login::LoginTarget::Fdurop,
    )
    .await
    .unwrap();
    println!("Session origin: {}", session.origin);
    println!("Session cookies count: {}", session.cookies.len());
    println!("Session token present: {}", session.token.is_some());
    assert!(session.token.is_some(), "idToken must be extracted");
}
