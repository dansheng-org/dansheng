// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 dansheng-core contributors.
//! Thin offline public service boundary tests for official forum actions.
//! Exercises public API parameter bounds, owner permissions, account scoping, and method routing.

#![cfg(feature = "services")]

use dansheng_connectors::forum_actions::call;
use dansheng_core::{
    Principal, PrincipalKind, network::Network, platform::UnavailablePlatform, policy::Grant,
    services::ServiceContext, store::Store,
};
use serde_json::json;

fn make_context<'a>(
    store: &'a Store,
    network: &'a Network,
    platform: &'a UnavailablePlatform,
) -> ServiceContext<'a> {
    ServiceContext {
        store,
        network,
        platform,
    }
}

fn owner_grant_for(account: &str) -> Grant {
    let mut grant = Grant::default();
    grant.account_ids.insert(account.to_string());
    grant.capabilities.insert("community.login".to_string());
    grant.capabilities.insert("community.read".to_string());
    grant.capabilities.insert("community.write".to_string());
    grant
}

#[tokio::test]
async fn test_public_boundary_login_owner_and_account_enforcement() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);

    // 1. Non-owner principal is rejected with PermissionDenied
    let plugin = Principal {
        id: "plugin:forum_crawler".into(),
        kind: PrincipalKind::Plugin,
    };
    let mut grant = Grant::default();
    grant.account_ids.insert("user1".into());
    grant.capabilities.insert("community.login".into());

    let params = json!({
        "account_id": "user1",
        "email": "user@fudan.edu.cn",
        "password": "valid_password_123"
    });

    let err = call(&context, &plugin, &grant, "community.tea.login", &params)
        .await
        .unwrap_err();
    assert_eq!(err.code, "PermissionDenied");

    // 2. Client principal with account outside grant is rejected
    let client = Principal {
        id: "client:unauthorized".into(),
        kind: PrincipalKind::Client,
    };
    let mut restricted_grant = Grant::default();
    restricted_grant.account_ids.insert("other_user".into());
    restricted_grant
        .capabilities
        .insert("community.login".into());

    let err2 = call(
        &context,
        &client,
        &restricted_grant,
        "community.tea.login",
        &params,
    )
    .await
    .unwrap_err();
    assert_eq!(err2.code, "PermissionDenied");
}

#[tokio::test]
async fn test_public_boundary_login_parameter_validation() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("acc1");

    // Invalid email formats
    for bad_email in [
        "notanemail",
        "@fudan.edu.cn",
        "user@",
        "bad\nemail@fudan.edu.cn",
    ] {
        let params = json!({
            "account_id": "acc1",
            "email": bad_email,
            "password": "valid_password_1"
        });
        let err = call(&context, &owner, &grant, "community.tea.login", &params)
            .await
            .unwrap_err();
        assert_eq!(err.code, "InvalidInput");
    }

    // Invalid password (empty or control characters)
    for bad_pwd in ["", "pwd\0null"] {
        let params = json!({
            "account_id": "acc1",
            "email": "student@fudan.edu.cn",
            "password": bad_pwd
        });
        let err = call(&context, &owner, &grant, "community.tea.login", &params)
            .await
            .unwrap_err();
        assert_eq!(err.code, "InvalidInput");
    }
}

#[tokio::test]
async fn test_public_boundary_search_requires_auth_and_validates_bounds() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("acc_search");

    // 1. Without session, search fails with AuthenticationRequired
    let valid_params = json!({
        "account_id": "acc_search",
        "query": "study group",
        "offset": 0,
        "size": 10
    });
    let err_unauth = call(
        &context,
        &owner,
        &grant,
        "community.tea.search",
        &valid_params,
    )
    .await
    .unwrap_err();
    assert_eq!(err_unauth.code, "AuthenticationRequired");

    // 2. Empty query -> InvalidInput
    let empty_q = json!({
        "account_id": "acc_search",
        "query": "   ",
        "offset": 0
    });
    let err_q = call(&context, &owner, &grant, "community.tea.search", &empty_q)
        .await
        .unwrap_err();
    assert_eq!(err_q.code, "InvalidInput");

    // 3. Offset exceeding upper bound -> InvalidInput
    let bad_offset = json!({
        "account_id": "acc_search",
        "query": "valid query",
        "offset": 2_000_000
    });
    let err_off = call(
        &context,
        &owner,
        &grant,
        "community.tea.search",
        &bad_offset,
    )
    .await
    .unwrap_err();
    assert_eq!(err_off.code, "InvalidInput");
}

#[tokio::test]
async fn test_public_boundary_publish_requires_owner_and_validates_bounds() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);

    let plugin = Principal {
        id: "plugin:writer".into(),
        kind: PrincipalKind::Plugin,
    };
    let grant = owner_grant_for("user_pub");
    let owner = Principal::owner();

    // 1. Non-owner write -> PermissionDenied
    let valid_params = json!({
        "account_id": "user_pub",
        "division_id": 1,
        "content": "Valid publication text"
    });
    let err_non_owner = call(
        &context,
        &plugin,
        &grant,
        "community.tea.publish",
        &valid_params,
    )
    .await
    .unwrap_err();
    assert_eq!(err_non_owner.code, "PermissionDenied");

    // 2. Division id zero -> InvalidInput
    let zero_div = json!({
        "account_id": "user_pub",
        "division_id": 0,
        "content": "Valid content"
    });
    let err_zero = call(&context, &owner, &grant, "community.tea.publish", &zero_div)
        .await
        .unwrap_err();
    assert_eq!(err_zero.code, "InvalidInput");

    // 3. Empty or whitespace content -> InvalidInput
    let empty_content = json!({
        "account_id": "user_pub",
        "division_id": 1,
        "content": "   "
    });
    let err_empty = call(
        &context,
        &owner,
        &grant,
        "community.tea.publish",
        &empty_content,
    )
    .await
    .unwrap_err();
    assert_eq!(err_empty.code, "InvalidInput");

    // 4. Content exceeding 20,000 characters -> InvalidInput
    let huge_content = "a".repeat(20_001);
    let huge_params = json!({
        "account_id": "user_pub",
        "division_id": 1,
        "content": huge_content
    });
    let err_huge = call(
        &context,
        &owner,
        &grant,
        "community.tea.publish",
        &huge_params,
    )
    .await
    .unwrap_err();
    assert_eq!(err_huge.code, "InvalidInput");

    // 5. Excessive tags (> 10 items) -> InvalidInput
    let tags: Vec<String> = (0..11).map(|i| format!("tag_{i}")).collect();
    let too_many_tags = json!({
        "account_id": "user_pub",
        "division_id": 1,
        "content": "Valid content",
        "tags": tags
    });
    let err_tags = call(
        &context,
        &owner,
        &grant,
        "community.tea.publish",
        &too_many_tags,
    )
    .await
    .unwrap_err();
    assert_eq!(err_tags.code, "InvalidInput");
}

#[tokio::test]
async fn test_public_boundary_reply_requires_owner_and_validates_bounds() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("reply_user");

    // 1. Non-owner -> PermissionDenied
    let plugin = Principal {
        id: "plugin:auto_replier".into(),
        kind: PrincipalKind::Plugin,
    };
    let params = json!({
        "account_id": "reply_user",
        "hole_id": 100,
        "content": "Reply body"
    });
    let err_non_owner = call(&context, &plugin, &grant, "community.tea.reply", &params)
        .await
        .unwrap_err();
    assert_eq!(err_non_owner.code, "PermissionDenied");

    // 2. Zero hole_id -> InvalidInput
    let zero_hole = json!({
        "account_id": "reply_user",
        "hole_id": 0,
        "content": "Reply body"
    });
    let err_zero = call(&context, &owner, &grant, "community.tea.reply", &zero_hole)
        .await
        .unwrap_err();
    assert_eq!(err_zero.code, "InvalidInput");

    // 3. Empty content -> InvalidInput
    let empty_c = json!({
        "account_id": "reply_user",
        "hole_id": 100,
        "content": ""
    });
    let err_empty = call(&context, &owner, &grant, "community.tea.reply", &empty_c)
        .await
        .unwrap_err();
    assert_eq!(err_empty.code, "InvalidInput");
}

#[tokio::test]
async fn test_public_boundary_reconcile_wire_contract_and_bounds() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("reconcile_user");

    // 1. Unknown action -> InvalidInput
    let bad_action = json!({
        "account_id": "reconcile_user",
        "action": "unknown_action",
        "content": "text",
        "hole_id": 10
    });
    let err_action = call(
        &context,
        &owner,
        &grant,
        "community.tea.reconcile",
        &bad_action,
    )
    .await
    .unwrap_err();
    assert_eq!(err_action.code, "InvalidInput");

    // 2. Missing target_id/hole_id for reply -> InvalidInput
    let missing_id = json!({
        "account_id": "reconcile_user",
        "action": "reply",
        "content": "text"
    });
    let err_id = call(
        &context,
        &owner,
        &grant,
        "community.tea.reconcile",
        &missing_id,
    )
    .await
    .unwrap_err();
    assert_eq!(err_id.code, "InvalidInput");
}

#[tokio::test]
async fn test_public_boundary_unknown_method() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("acc");

    let err = call(
        &context,
        &owner,
        &grant,
        "community.tea.unknown",
        &json!({}),
    )
    .await
    .unwrap_err();
    assert_eq!(err.code, "MethodNotFound");
}

#[tokio::test]
async fn test_public_boundary_divisions_and_pinned_validation() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("acc_div");

    // 1. Without session, divisions fails with AuthenticationRequired
    let err_unauth = call(
        &context,
        &owner,
        &grant,
        "community.tea.divisions",
        &json!({"account_id": "acc_div"}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_unauth.code, "AuthenticationRequired");

    // 2. Without session, pinned fails with AuthenticationRequired
    let err_pinned_unauth = call(
        &context,
        &owner,
        &grant,
        "community.tea.pinned",
        &json!({"account_id": "acc_div", "division_id": 1}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_pinned_unauth.code, "AuthenticationRequired");

    // 3. Pinned with missing division_id fails with InvalidInput
    let err_missing_div = call(
        &context,
        &owner,
        &grant,
        "community.tea.pinned",
        &json!({"account_id": "acc_div"}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_missing_div.code, "InvalidInput");

    // 4. Pinned with zero division_id fails with InvalidInput
    let err_zero_div = call(
        &context,
        &owner,
        &grant,
        "community.tea.pinned",
        &json!({"account_id": "acc_div", "division_id": 0}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_zero_div.code, "InvalidInput");
}

#[tokio::test]
async fn test_public_boundary_hole_and_floors_validation() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("acc_read");

    // 1. Single hole missing or zero hole_id -> InvalidInput
    let err_missing_hole = call(
        &context,
        &owner,
        &grant,
        "community.tea.hole",
        &json!({"account_id": "acc_read"}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_missing_hole.code, "InvalidInput");

    let err_zero_hole = call(
        &context,
        &owner,
        &grant,
        "community.tea.hole",
        &json!({"account_id": "acc_read", "hole_id": 0}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_zero_hole.code, "InvalidInput");

    // 2. Floors missing or zero hole_id -> InvalidInput
    let err_zero_floors = call(
        &context,
        &owner,
        &grant,
        "community.tea.floors",
        &json!({"account_id": "acc_read", "hole_id": 0}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_zero_floors.code, "InvalidInput");

    // 3. Holes with invalid start_time -> InvalidInput
    let err_bad_time = call(
        &context,
        &owner,
        &grant,
        "community.tea.holes",
        &json!({"account_id": "acc_read", "start_time": "invalid_date"}),
    )
    .await
    .unwrap_err();
    assert_eq!(err_bad_time.code, "InvalidInput");
}

#[tokio::test]
async fn test_public_boundary_search_accurate_and_date_bounds() {
    let temp = tempfile::tempdir().unwrap();
    let platform = UnavailablePlatform;
    let store = Store::open(temp.path()).unwrap();
    let network = Network::default();
    let context = make_context(&store, &network, &platform);
    let owner = Principal::owner();
    let grant = owner_grant_for("acc_s");

    // Bad timestamp format for start_time -> InvalidInput
    let bad_st = json!({
        "account_id": "acc_s",
        "query": "query text",
        "start_time": "not-a-timestamp"
    });
    let err = call(&context, &owner, &grant, "community.tea.search", &bad_st)
        .await
        .unwrap_err();
    assert_eq!(err.code, "InvalidInput");
}
