//! Bounded cross-domain search. Content stays behind each domain's read policy.
use crate::{
    api::{CoreResult, Principal, PrincipalKind},
    organizer,
    policy::Grant,
    store::Store,
};
use serde_json::{Value, json};

pub(crate) fn query(
    store: &Store,
    principal: &Principal,
    grant: &Grant,
    params: Value,
    query: &str,
) -> CoreResult<Value> {
    let limit = params["limit"].as_u64().unwrap_or(50).clamp(1, 100) as usize;
    let mut filters = params.clone();
    filters["summary"] = json!(true);
    filters["limit"] = json!(limit);
    let mut results = store.records(principal, grant, &filters, Some(query))?;
    for hit in &mut results {
        hit["reference"] = json!({"method":"sources.query","params":{"record_owner":hit["owner"],"source_id":hit["source_id"],"external_id":hit["external_id"],"account_id":hit["account_id"],"limit":1}});
    }
    let needle = query.to_lowercase();
    for (kind, source, list_method, get_method, capability) in [
        ("todo", "local.todo", "todo.list", "todo.get", "todo.read"),
        (
            "event",
            "local.calendar",
            "calendar.list",
            "calendar.get",
            "calendar.read",
        ),
    ] {
        if !(principal.is_owner() || grant.allows(capability))
            || params["source_id"].as_str().is_some_and(|s| s != source)
            || params["kind"].as_str().is_some_and(|k| k != kind)
        {
            continue;
        }
        // Source-only account filters must not silently broaden into personal data.
        if params["account_id"].as_str().is_some_and(|a| !a.is_empty()) {
            continue;
        }
        let owner = if principal.kind == PrincipalKind::Plugin
            && grant.organizer_scope.as_deref() != Some("profile")
        {
            principal.id.as_str()
        } else {
            "owner"
        };
        if params["record_owner"].as_str().is_some_and(|p| p != owner) {
            continue;
        }
        let mut matches = 0;
        for offset in (0..2000).step_by(200) {
            let page = organizer::dispatch(
                store,
                principal,
                grant,
                list_method,
                json!({"limit":200,"offset":offset}),
            )?;
            let Some(items) = page["items"].as_array() else {
                break;
            };
            for item in items {
                if params["external_id"]
                    .as_str()
                    .is_some_and(|id| item["id"] != id)
                {
                    continue;
                }
                let text = format!(
                    "{} {}",
                    item["title"].as_str().unwrap_or(""),
                    item["notes"].as_str().unwrap_or("")
                );
                if !text.to_lowercase().contains(&needle) {
                    continue;
                }
                let title = item["title"]
                    .as_str()
                    .unwrap_or("")
                    .chars()
                    .take(256)
                    .collect::<String>();
                let snippet = text.chars().take(512).collect::<String>();
                results.push(json!({"owner":owner,"account_id":"","source_id":source,"external_id":item["id"],"kind":kind,"data":{"title":title,"snippet":snippet,"asset_id":null},"updated_at":item["updated_at"],"reference":{"method":get_method,"params":{"id":item["id"]}}}));
                matches += 1;
                if matches >= limit {
                    break;
                }
            }
            if matches >= limit || items.len() < 200 {
                break;
            }
        }
    }
    results.sort_by(|a, b| {
        let prefix = |item: &Value| {
            item["data"]["title"]
                .as_str()
                .unwrap_or("")
                .to_lowercase()
                .starts_with(&needle)
        };
        let timestamp = |item: &Value| {
            item["updated_at"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.timestamp_millis())
                .unwrap_or(0)
        };
        prefix(b)
            .cmp(&prefix(a))
            .then_with(|| timestamp(b).cmp(&timestamp(a)))
            .then_with(|| a["external_id"].as_str().cmp(&b["external_id"].as_str()))
    });
    results.truncate(limit);
    Ok(json!(results))
}
