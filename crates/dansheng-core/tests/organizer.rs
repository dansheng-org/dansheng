use dansheng_core::{
    Principal, PrincipalKind,
    organizer::{
        DeliveryChannel, DeliveryOutcome, NotificationOptions, Organizer, claim_due_notifications,
        dispatch, finish_notification, inspect_notification, notification_claim_is_current,
        reconcile_notification, required_capability,
    },
    policy::Grant,
    store::Store,
};
use serde_json::{Value, json};
use std::sync::{Arc, Barrier};

fn client(id: &str) -> Principal {
    Principal {
        id: id.into(),
        kind: PrincipalKind::Client,
    }
}

fn full_grant() -> Grant {
    Grant {
        capabilities: [
            "todo.read",
            "todo.write",
            "calendar.read",
            "calendar.write",
            "activity.read",
            "activity.write",
            "reminders.read",
            "reminders.write",
            "sources.read",
        ]
        .into_iter()
        .map(str::to_string)
        .collect(),
        ..Grant::default()
    }
}

fn call(store: &Store, p: &Principal, g: &Grant, method: &str, input: Value) -> Value {
    dispatch(store, p, g, method, input).unwrap_or_else(|e| panic!("{method}: {}", e.code))
}

fn items(value: &Value) -> &Vec<Value> {
    value["items"].as_array().unwrap()
}

fn event(store: &Store, p: &Principal, g: &Grant, title: &str, start: &str, end: &str) -> Value {
    call(
        store,
        p,
        g,
        "calendar.create",
        json!({"title":title,"start_at":start,"end_at":end}),
    )
}

#[test]
fn personal_todo_updates_completion_and_persistence() {
    let directory = tempfile::tempdir().unwrap();
    let p = client("alice");
    let g = full_grant();
    let id;
    let completed_at;
    {
        let store = Store::open(directory.path()).unwrap();
        Organizer::new(&store).unwrap();
        Organizer::new(&store).unwrap();
        let created = call(
            &store,
            &p,
            &g,
            "todo.create",
            json!({"title":"复习","due_at":"2026-11-06T09:00"}),
        );
        assert_eq!(created["timezone"], "Asia/Shanghai");
        assert_eq!(created["due_at"], "2026-11-06T01:00:00Z");
        id = created["id"].as_str().unwrap().to_string();
        uuid::Uuid::parse_str(&id).unwrap();
        let updated = call(
            &store,
            &p,
            &g,
            "todo.update",
            json!({"id":id,"changes":{"notes":"第二章","title":"复习数学"}}),
        );
        assert_eq!(updated["due_at"], created["due_at"]);
        assert_eq!(updated["id"], id);
        let completed = call(&store, &p, &g, "todo.complete", json!({"id":id}));
        completed_at = completed["completed_at"].clone();
        assert!(completed_at.is_string());
        assert_eq!(
            call(&store, &p, &g, "todo.complete", json!({"id":id}))["completed_at"],
            completed_at
        );
        assert!(
            items(&call(
                &store,
                &p,
                &g,
                "todo.list",
                json!({"completed":false})
            ))
            .is_empty()
        );
    }
    let store = Store::open(directory.path()).unwrap();
    let persisted = call(&store, &p, &g, "todo.get", json!({"id":id}));
    assert_eq!(persisted["title"], "复习数学");
    assert_eq!(persisted["completed_at"], completed_at);
    let reopened = call(
        &store,
        &p,
        &g,
        "todo.complete",
        json!({"id":id,"completed":false}),
    );
    assert!(reopened["completed_at"].is_null());
    let cleared = call(
        &store,
        &p,
        &g,
        "todo.update",
        json!({"id":id,"changes":{"due_at":null}}),
    );
    assert!(cleared["due_at"].is_null());
    assert_eq!(
        call(&store, &p, &g, "todo.list", json!({"limit":1}))["total"],
        1
    );
}

#[test]
fn overlap_detection_uses_half_open_instants_and_current_event_updates() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let g = full_grant();
    let a = event(
        &store,
        &p,
        &g,
        "课程",
        "2026-11-06T09:00",
        "2026-11-06T10:00",
    );
    let b = event(
        &store,
        &p,
        &g,
        "讨论",
        "2026-11-06T01:30:00Z",
        "2026-11-06T02:30:00Z",
    );
    event(
        &store,
        &p,
        &g,
        "相邻",
        "2026-11-06T02:30:00+00:00",
        "2026-11-06T03:00:00+00:00",
    );
    let conflicts = call(&store, &p, &g, "calendar.conflicts", json!({}));
    let pairs = conflicts["conflicts"].as_array().unwrap();
    assert_eq!(pairs.len(), 1);
    assert_eq!(pairs[0]["start_at"], "2026-11-06T01:30:00Z");
    assert_eq!(pairs[0]["end_at"], "2026-11-06T02:00:00Z");
    let candidate = call(
        &store,
        &p,
        &g,
        "calendar.conflicts",
        json!({"candidate":{"start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00","exclude_id":a["id"]}}),
    );
    assert_eq!(candidate["conflicts"][0]["id"], b["id"]);
    call(
        &store,
        &p,
        &g,
        "calendar.update",
        json!({"id":b["id"],"changes":{"start_at":"2026-11-06T12:00","end_at":"2026-11-06T13:00"}}),
    );
    assert!(
        call(&store, &p, &g, "calendar.conflicts", json!({}))["conflicts"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let in_window = call(
        &store,
        &p,
        &g,
        "calendar.list",
        json!({"from":"2026-11-06T09:30","to":"2026-11-06T10:00"}),
    );
    assert_eq!(items(&in_window).len(), 1);
    assert_eq!(items(&in_window)[0]["id"], a["id"]);
    call(&store, &p, &g, "calendar.delete", json!({"id":a["id"]}));
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.get", json!({"id":a["id"]}))
            .unwrap_err()
            .code,
        "NotFound"
    );
}

#[test]
fn timezone_conversion_dst_rejection_and_offset_disambiguation() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let g = full_grant();
    let winter = call(
        &store,
        &p,
        &g,
        "todo.create",
        json!({"title":"NY","timezone":"America/New_York","due_at":"2026-01-06T09:00"}),
    );
    let summer = call(
        &store,
        &p,
        &g,
        "todo.create",
        json!({"title":"NY","timezone":"America/New_York","due_at":"2026-07-06T09:00"}),
    );
    assert_eq!(winter["due_at"], "2026-01-06T14:00:00Z");
    assert_eq!(summer["due_at"], "2026-07-06T13:00:00Z");
    for time in ["2026-03-08T02:30", "2026-11-01T01:30"] {
        assert_eq!(
            dispatch(
                &store,
                &p,
                &g,
                "todo.create",
                json!({"title":"DST","timezone":"America/New_York","due_at":time})
            )
            .unwrap_err()
            .code,
            "InvalidInput"
        );
    }
    let fold = call(
        &store,
        &p,
        &g,
        "todo.create",
        json!({"title":"fold","timezone":"America/New_York","due_at":"2026-11-01T01:30:00-05:00"}),
    );
    assert_eq!(fold["due_at"], "2026-11-01T06:30:00Z");
    assert_eq!(fold["timezone"], "America/New_York");
    let offset = call(
        &store,
        &p,
        &g,
        "todo.create",
        json!({"title":"offset","timezone":"UTC","due_at":"2026-11-06T09:00:00+08:00"}),
    );
    assert_eq!(offset["due_at"], "2026-11-06T01:00:00Z");
}

#[test]
fn ics_is_crlf_utf8_octet_folded_escaped_and_utc_with_stable_uids() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let g = full_grant();
    let title = "中文课程🦀".repeat(20);
    let created = call(
        &store,
        &p,
        &g,
        "calendar.create",
        json!({"title":title,"notes":"反斜线\\,逗号;分号\r\n下一行\nEND:VEVENT","location":"A,楼;一层","timezone":"Asia/Shanghai","start_at":"2026-11-06T09:00:00+08:00","end_at":"2026-11-06T10:00:00+08:00"}),
    );
    let todo = call(
        &store,
        &p,
        &g,
        "todo.create",
        json!({"title":"作业","due_at":"2026-11-07T09:00"}),
    );
    call(&store, &p, &g, "todo.complete", json!({"id":todo["id"]}));
    let result = call(&store, &p, &g, "calendar.export_ics", json!({}));
    assert_eq!(result["content_type"], "text/calendar; charset=utf-8");
    let ics = result["ics"].as_str().unwrap();
    assert!(ics.ends_with("END:VCALENDAR\r\n"));
    assert!(!ics.replace("\r\n", "").contains(['\r', '\n']));
    assert!(ics.contains("\r\n "));
    for line in ics.split("\r\n") {
        assert!(line.len() <= 75, "{} bytes", line.len());
    }
    let unfolded = ics.replace("\r\n ", "");
    assert!(unfolded.contains(&format!("SUMMARY:{title}\r\n")));
    assert!(unfolded.contains("DESCRIPTION:反斜线\\\\\\,逗号\\;分号\\n下一行\\nEND:VEVENT\r\n"));
    assert!(unfolded.contains("LOCATION:A\\,楼\\;一层\r\n"));
    assert!(unfolded.contains("DTSTART:20261106T010000Z\r\nDTEND:20261106T020000Z\r\n"));
    assert!(unfolded.contains("X-DANSHENG-TIMEZONE:Asia/Shanghai"));
    assert!(unfolded.contains("BEGIN:VTODO\r\n"));
    assert!(unfolded.contains("STATUS:COMPLETED\r\nCOMPLETED:"));
    assert_eq!(
        unfolded
            .split("\r\n")
            .filter(|line| *line == "BEGIN:VEVENT")
            .count(),
        1
    );
    assert_eq!(
        unfolded
            .split("\r\n")
            .filter(|line| *line == "END:VEVENT")
            .count(),
        1
    );
    let repeated = call(&store, &p, &g, "calendar.export_ics", json!({}));
    assert_eq!(repeated, result);
    assert!(unfolded.contains(&format!(
        "UID:{}@dansheng.local",
        created["id"].as_str().unwrap()
    )));
}

#[test]
fn canonical_source_links_are_idempotent_live_and_not_copies() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let g = full_grant();
    store.record_upsert(&p.id,"","campus.schedule","occurrence-1","timetable",&json!({"name":"源课程","timezone":"Asia/Shanghai","start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00","cookie":"must-never-be-projected"})).unwrap();
    let source = json!({"source_id":"campus.schedule","external_id":"occurrence-1"});
    let linked = call(&store, &p, &g, "calendar.link", json!({"source":source}));
    assert_eq!(linked["origin"], "source");
    assert_eq!(linked["title"], "源课程");
    assert!(!linked.to_string().contains("must-never-be-projected"));
    assert_eq!(
        call(&store, &p, &g, "calendar.link", json!({"source":source}))["id"],
        linked["id"]
    );
    let db = rusqlite::Connection::open(d.path().join("dansheng.db")).unwrap();
    let body: String = db
        .query_row(
            "SELECT body FROM organizer_items WHERE id=?",
            [linked["id"].as_str().unwrap()],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!body.contains("源课程"));
    assert!(!body.contains("start_at"));
    assert!(!body.contains("cookie"));
    store
        .record_upsert(
            &p.id,
            "",
            "campus.schedule",
            "occurrence-1",
            "timetable",
            &json!({"title":"新课程","start_at":"2026-11-06T10:00","end_at":"2026-11-06T11:00"}),
        )
        .unwrap();
    let current = call(&store, &p, &g, "calendar.get", json!({"id":linked["id"]}));
    assert_eq!(current["title"], "新课程");
    assert_eq!(current["start_at"], "2026-11-06T02:00:00Z");
    assert_eq!(
        dispatch(
            &store,
            &p,
            &g,
            "calendar.update",
            json!({"id":linked["id"],"changes":{"title":"override"}})
        )
        .unwrap_err()
        .code,
        "ReadOnlySource"
    );
    store
        .record_upsert(
            &p.id,
            "",
            "canvas.assignments",
            "a1",
            "assignment",
            &json!({"name":"论文","due_at":"2026-11-08T12:00:00Z"}),
        )
        .unwrap();
    let assignment = call(
        &store,
        &p,
        &g,
        "todo.link",
        json!({"source":{"source_id":"canvas.assignments","external_id":"a1"}}),
    );
    call(
        &store,
        &p,
        &g,
        "todo.complete",
        json!({"id":assignment["id"]}),
    );
    assert_eq!(
        store
            .records(&p, &g, &json!({"kind":"assignment"}), None)
            .unwrap()[0]["data"]["name"],
        "论文"
    );
    assert!(
        store
            .records(&p, &g, &json!({"kind":"assignment"}), None)
            .unwrap()[0]["data"]["completed_at"]
            .is_null()
    );
}

#[test]
fn source_acl_and_revoked_account_grants_apply_to_lists_reminders_and_notifications() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let mut g = full_grant();
    store
        .record_upsert(
            "plugin:campus",
            "school-a",
            "campus.schedule",
            "one",
            "timetable",
            &json!({"title":"授权课程","start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00"}),
        )
        .unwrap();
    let reference =
        json!({"account_id":"school-a","source_id":"campus.schedule","external_id":"one"});
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.link", json!({"source":reference}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    g.account_ids.insert("school-a".into());
    let linked = call(&store, &p, &g, "calendar.link", json!({"source":reference}));
    let scheduled = call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    let denied = full_grant();
    assert!(items(&call(&store, &p, &denied, "calendar.list", json!({}))).is_empty());
    assert!(items(&call(&store, &p, &denied, "reminders.list", json!({}))).is_empty());
    assert!(
        items(&call(
            &store,
            &p,
            &denied,
            "reminders.due",
            json!({"now":"2026-11-06T01:00:00Z"})
        ))
        .is_empty()
    );
    let fired = call(
        &store,
        &p,
        &g,
        "reminders.due",
        json!({"now":"2026-11-06T01:00:00Z"}),
    );
    assert_eq!(items(&fired)[0]["reminder"]["id"], scheduled["id"]);
    assert!(items(&call(&store, &p, &denied, "activity.list", json!({}))).is_empty());
    assert!(
        items(&call(
            &store,
            &p,
            &denied,
            "activity.notifications",
            json!({})
        ))
        .is_empty()
    );
    let mut no_sources = g.clone();
    no_sources.capabilities.remove("sources.read");
    assert!(
        items(&call(
            &store,
            &p,
            &no_sources,
            "activity.notifications",
            json!({})
        ))
        .is_empty()
    );
    assert!(items(&call(&store, &p, &no_sources, "calendar.list", json!({}))).is_empty());
    assert_eq!(
        items(&call(&store, &p, &g, "activity.notifications", json!({}))).len(),
        1
    );
    // The local link can still be removed without regaining source access.
    call(
        &store,
        &p,
        &denied,
        "calendar.delete",
        json!({"id":linked["id"]}),
    );
    assert!(items(&call(&store, &p, &g, "reminders.list", json!({}))).is_empty());
}

#[test]
fn duplicate_source_identity_requires_disambiguation_and_does_not_bypass_grants() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let mut g = full_grant();
    g.source_ids.insert("shared.assignment".into());
    for owner in ["writer-a", "writer-b"] {
        store
            .record_upsert(
                owner,
                "",
                "shared.assignment",
                "one",
                "assignment",
                &json!({"title":owner}),
            )
            .unwrap();
    }
    let source = json!({"source_id":"shared.assignment","external_id":"one"});
    assert_eq!(
        dispatch(&store, &p, &g, "todo.link", json!({"source":source}))
            .unwrap_err()
            .code,
        "AmbiguousSource"
    );
    let chosen = call(
        &store,
        &p,
        &g,
        "todo.link",
        json!({"source":{"source_id":"shared.assignment","external_id":"one","record_owner":"writer-b"}}),
    );
    assert_eq!(chosen["title"], "writer-b");
    g.source_ids.clear();
    assert_eq!(
        dispatch(&store, &p, &g, "todo.get", json!({"id":chosen["id"]}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    assert!(items(&call(&store, &p, &g, "todo.list", json!({}))).is_empty());
}

#[test]
fn reminders_are_durable_deduplicated_atomic_and_do_not_deliver_notifications() {
    let d = tempfile::tempdir().unwrap();
    let p = client("alice");
    let g = full_grant();
    let id;
    {
        let store = Store::open(d.path()).unwrap();
        let todo = call(&store, &p, &g, "todo.create", json!({"title":"交作业"}));
        let a = call(
            &store,
            &p,
            &g,
            "reminders.schedule",
            json!({"item_id":todo["id"],"at":"2026-11-06T09:00:00+08:00"}),
        );
        let b = call(
            &store,
            &p,
            &g,
            "reminders.schedule",
            json!({"item_id":todo["id"],"at":"2026-11-06T01:00:00Z"}),
        );
        assert_eq!(a["id"], b["id"]);
        id = a["id"].clone();
        assert!(
            items(&call(
                &store,
                &p,
                &g,
                "reminders.due",
                json!({"now":"2026-11-06T00:59:59Z"})
            ))
            .is_empty()
        );
        let due = call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-06T01:00:00Z"}),
        );
        assert_eq!(items(&due).len(), 1);
        assert_eq!(items(&due)[0]["reminder"]["id"], id);
        assert!(
            items(&call(
                &store,
                &p,
                &g,
                "reminders.due",
                json!({"now":"2026-11-07T01:00:00Z"})
            ))
            .is_empty()
        );
        let rearm = call(
            &store,
            &p,
            &g,
            "reminders.schedule",
            json!({"item_id":todo["id"],"at":"2026-11-06T01:00:00Z"}),
        );
        assert_eq!(rearm["id"], id);
        assert_eq!(rearm["state"], "fired");
    }
    let store = Store::open(d.path()).unwrap();
    assert_eq!(
        items(&call(&store, &p, &g, "activity.list", json!({}))).len(),
        1
    );
    assert_eq!(
        items(&call(&store, &p, &g, "activity.notifications", json!({})))[0]["kind"],
        "reminder"
    );
    assert!(items(&call(&store, &p, &g, "activity.notifications", json!({}))).is_empty());
    assert!(
        items(&call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-07T01:00:00Z"})
        ))
        .is_empty()
    );
}

#[test]
fn competing_reminder_claims_return_one_result_and_completed_todos_cancel_pending() {
    let d = tempfile::tempdir().unwrap();
    let store = Arc::new(Store::open(d.path()).unwrap());
    let p = client("alice");
    let g = full_grant();
    let todo = call(&store, &p, &g, "todo.create", json!({"title":"并发提醒"}));
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    let barrier = Arc::new(Barrier::new(2));
    let workers: Vec<_> = (0..2)
        .map(|_| {
            let (store, p, g, barrier) = (store.clone(), p.clone(), g.clone(), barrier.clone());
            std::thread::spawn(move || {
                barrier.wait();
                items(&call(
                    &store,
                    &p,
                    &g,
                    "reminders.due",
                    json!({"now":"2026-11-06T01:00:00Z"}),
                ))
                .len()
            })
        })
        .collect();
    assert_eq!(
        workers
            .into_iter()
            .map(|w| w.join().unwrap())
            .sum::<usize>(),
        1
    );
    let next = call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2026-11-07T00:00:00Z"}),
    );
    call(&store, &p, &g, "todo.complete", json!({"id":todo["id"]}));
    call(
        &store,
        &p,
        &g,
        "todo.complete",
        json!({"id":todo["id"],"completed":false}),
    );
    assert!(
        items(&call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-08T00:00:00Z"})
        ))
        .is_empty()
    );
    assert!(
        items(&call(&store, &p, &g, "reminders.list", json!({})))
            .iter()
            .any(|r| r["id"] == next["id"] && r["state"] == "cancelled")
    );
}

fn activity_row(id: &str) -> Value {
    json!({"external_id":id,"title":format!("活动 {id}"),"kind":"notice","occurred_at":"2026-11-06T00:00:00Z"})
}

#[test]
fn a_failed_due_batch_rolls_back_claims_and_inbox_entries() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let g = full_grant();
    let todo = call(&store, &p, &g, "todo.create", json!({"title":"first"}));
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    let valid = json!({"title":"course","start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00"});
    store
        .record_upsert(&p.id, "", "schedule", "one", "timetable", &valid)
        .unwrap();
    let linked = call(
        &store,
        &p,
        &g,
        "calendar.link",
        json!({"source":{"source_id":"schedule","external_id":"one"}}),
    );
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T00:01:00Z"}),
    );
    store
        .record_upsert(
            &p.id,
            "",
            "schedule",
            "one",
            "timetable",
            &json!({"title":"missing normalized dates"}),
        )
        .unwrap();
    assert_eq!(
        dispatch(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-06T01:00:00Z"})
        )
        .unwrap_err()
        .code,
        "InvalidInput"
    );
    assert!(items(&call(&store, &p, &g, "activity.list", json!({}))).is_empty());
    assert!(
        items(&call(&store, &p, &g, "reminders.list", json!({})))
            .iter()
            .all(|r| r["state"] == "pending")
    );
    store
        .record_upsert(&p.id, "", "schedule", "one", "timetable", &valid)
        .unwrap();
    assert_eq!(
        items(&call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-06T01:00:00Z"})
        ))
        .len(),
        2
    );
}

#[test]
fn first_sync_suppression_survives_pages_restart_replay_and_preserves_inbox_states() {
    let d = tempfile::tempdir().unwrap();
    let p = client("alice");
    let g = full_grant();
    {
        let store = Store::open(d.path()).unwrap();
        let first = call(
            &store,
            &p,
            &g,
            "activity.sync",
            json!({"source_id":"notices","items":[activity_row("old-a")],"complete":false}),
        );
        assert_eq!(first["notifications"], 0);
        assert_eq!(first["initialized"], false);
    }
    let store = Store::open(d.path()).unwrap();
    let second = call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"notices","items":[activity_row("old-b")],"complete":true}),
    );
    assert_eq!(second["notifications"], 0);
    assert_eq!(second["initialized"], true);
    assert!(items(&call(&store, &p, &g, "activity.notifications", json!({}))).is_empty());
    let later = call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"notices","items":[activity_row("old-a"),activity_row("new")]}),
    );
    assert_eq!(later["inserted"], 1);
    assert_eq!(later["notifications"], 1);
    let inbox = call(&store, &p, &g, "activity.list", json!({"unread":true}));
    assert_eq!(items(&inbox).len(), 3);
    let new = items(&inbox)
        .iter()
        .find(|i| i["external_id"] == "new")
        .unwrap();
    let old = items(&inbox)
        .iter()
        .find(|i| i["external_id"] == "old-a")
        .unwrap();
    let old_id = old["id"].clone();
    call(&store, &p, &g, "activity.read", json!({"id":old_id}));
    call(&store, &p, &g, "activity.archive", json!({"id":old_id}));
    let claimed = call(&store, &p, &g, "activity.notifications", json!({}));
    assert_eq!(items(&claimed).len(), 1);
    assert_eq!(items(&claimed)[0]["id"], new["id"]);
    let replay = call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"notices","items":[activity_row("old-a"),activity_row("new")]}),
    );
    assert_eq!(replay["inserted"], 0);
    assert_eq!(replay["notifications"], 0);
    assert!(items(&call(&store, &p, &g, "activity.notifications", json!({}))).is_empty());
    let archive = call(&store, &p, &g, "activity.list", json!({"archived":true}));
    assert_eq!(items(&archive)[0]["id"], old_id);
    assert!(items(&archive)[0]["read_at"].is_string());
    call(
        &store,
        &p,
        &g,
        "activity.archive",
        json!({"id":old_id,"value":false}),
    );
    call(
        &store,
        &p,
        &g,
        "activity.read",
        json!({"id":old_id,"value":false}),
    );
    assert!(items(&call(&store, &p, &g, "activity.notifications", json!({}))).is_empty());
    // A different source gets its own initial baseline, even after notices initialized.
    assert_eq!(
        call(
            &store,
            &p,
            &g,
            "activity.sync",
            json!({"source_id":"other","items":[activity_row("history")]})
        )["notifications"],
        0
    );
}

#[test]
fn activity_accounts_have_separate_baselines_and_live_account_acl() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let mut g = full_grant();
    g.account_ids.extend(["a".into(), "b".into()]);
    for account in ["a", "b"] {
        assert_eq!(
            call(
                &store,
                &p,
                &g,
                "activity.sync",
                json!({"account_id":account,"source_id":"mail","items":[activity_row("same-uid")]})
            )["notifications"],
            0
        );
    }
    let inbox = call(&store, &p, &g, "activity.list", json!({}));
    assert_eq!(items(&inbox).len(), 2);
    let a_id = items(&inbox)
        .iter()
        .find(|i| i["account_id"] == "a")
        .unwrap()["id"]
        .clone();
    g.account_ids.remove("a");
    let visible = call(&store, &p, &g, "activity.list", json!({}));
    assert_eq!(items(&visible).len(), 1);
    assert_eq!(items(&visible)[0]["account_id"], "b");
    assert_eq!(
        dispatch(&store, &p, &g, "activity.read", json!({"id":a_id}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    assert_eq!(
        dispatch(
            &store,
            &p,
            &g,
            "activity.sync",
            json!({"account_id":"a","source_id":"mail","items":[]})
        )
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
}

#[test]
fn private_plugin_isolation_covers_read_update_delete_claim_and_different_adapter_kinds() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = Principal {
        id: "plugin:alice".into(),
        kind: PrincipalKind::Plugin,
    };
    let q = client("bob");
    let g = full_grant();
    let todo = call(&store, &p, &g, "todo.create", json!({"title":"private"}));
    let event = event(
        &store,
        &p,
        &g,
        "private",
        "2026-11-06T09:00",
        "2026-11-06T10:00",
    );
    let reminder = call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"own","items":[activity_row("1")]}),
    );
    let activity = call(&store, &p, &g, "activity.list", json!({}))["items"][0].clone();
    let mut same_id = client("alice");
    same_id.kind = PrincipalKind::Mcp;
    for other in [&q, &same_id, &Principal::owner()] {
        for method in [
            "todo.list",
            "calendar.list",
            "reminders.list",
            "reminders.due",
            "activity.list",
            "activity.notifications",
        ] {
            assert!(
                items(&call(&store, other, &g, method, json!({}))).is_empty(),
                "{method}"
            );
        }
        for (method, input) in [
            ("todo.get", json!({"id":todo["id"]})),
            ("todo.complete", json!({"id":todo["id"]})),
            (
                "todo.update",
                json!({"id":todo["id"],"changes":{"title":"stolen"}}),
            ),
            ("todo.delete", json!({"id":todo["id"]})),
            ("calendar.get", json!({"id":event["id"]})),
            ("calendar.delete", json!({"id":event["id"]})),
            (
                "reminders.schedule",
                json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
            ),
            ("reminders.cancel", json!({"id":reminder["id"]})),
            ("activity.read", json!({"id":activity["id"]})),
            ("activity.archive", json!({"id":activity["id"]})),
        ] {
            assert_eq!(
                dispatch(&store, other, &g, method, input).unwrap_err().code,
                "NotFound",
                "{method}"
            );
        }
        assert!(
            call(&store, other, &g, "calendar.conflicts", json!({}))["conflicts"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(
            !call(&store, other, &g, "calendar.export_ics", json!({}))["ics"]
                .as_str()
                .unwrap()
                .contains("private")
        );
    }
}

#[test]
fn validation_permissions_and_transactions_do_not_accept_identity_or_raw_payloads() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("alice");
    let g = full_grant();
    for (method, input) in [
        ("todo.create", json!({"title":"x","principal":"owner"})),
        ("todo.create", json!({"title":"x","password":"never-store"})),
        ("todo.create", json!({"title":"x".repeat(513)})),
        (
            "todo.create",
            json!({"title":"x","timezone":"Mars/Olympus"}),
        ),
        (
            "calendar.create",
            json!({"title":"bad","start_at":"2026-11-06T10:00","end_at":"2026-11-06T09:00"}),
        ),
        ("todo.list", json!({"limit":0})),
        ("calendar.list", json!({"from":"2026-11-06T00:00"})),
        (
            "activity.sync",
            json!({"source_id":"s","items":[activity_row("one"),{"external_id":"bad","title":"bad","kind":"notice","occurred_at":"not-a-date"}]}),
        ),
        (
            "activity.sync",
            json!({"source_id":"s","items":[activity_row("same"),activity_row("same")]}),
        ),
        (
            "activity.sync",
            json!({"source_id":"organizer.reminders","items":[]}),
        ),
    ] {
        assert!(dispatch(&store, &p, &g, method, input).is_err(), "{method}");
    }
    assert!(items(&call(&store, &p, &g, "todo.list", json!({}))).is_empty());
    assert!(items(&call(&store, &p, &g, "activity.list", json!({}))).is_empty());
    assert_eq!(
        call(
            &store,
            &p,
            &g,
            "activity.sync",
            json!({"source_id":"s","items":[activity_row("one")]})
        )["notifications"],
        0
    );
    assert_eq!(
        dispatch(&store, &p, &Grant::default(), "todo.list", json!({}))
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    let mut expired = g.clone();
    expired.expires_at = Some("2000-01-01T00:00:00Z".into());
    assert_eq!(
        dispatch(&store, &p, &expired, "todo.list", json!({}))
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.raw_sql", json!({}))
            .unwrap_err()
            .code,
        "MethodNotFound"
    );
    assert_eq!(required_capability("todo.complete"), Some("todo.write"));
    assert_eq!(
        required_capability("activity.notifications"),
        Some("activity.write")
    );
    assert_eq!(
        required_capability("reminders.due"),
        Some("reminders.write")
    );
    assert_eq!(
        required_capability("calendar.export_ics"),
        Some("calendar.read")
    );
    let mut read_calendar = Grant::default();
    read_calendar.capabilities.insert("calendar.read".into());
    assert_eq!(
        dispatch(&store, &p, &read_calendar, "calendar.export_ics", json!({}))
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    call(
        &store,
        &p,
        &read_calendar,
        "calendar.export_ics",
        json!({"include_todos":false}),
    );
}

#[test]
fn migrations_are_namespaced_idempotent_and_reject_newer_versions() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let db = rusqlite::Connection::open(d.path().join("dansheng.db")).unwrap();
    let root_version: i64 = db
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    Organizer::new(&store).unwrap();
    Organizer::new(&store).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        root_version
    );
    assert_eq!(
        db.query_row("SELECT version FROM organizer_schema", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        2
    );
    db.execute("UPDATE organizer_schema SET version=99", [])
        .unwrap();
    assert_eq!(
        Organizer::new(&store).err().unwrap().code,
        "UnsupportedDatabaseVersion"
    );
    assert_eq!(
        db.query_row("SELECT version FROM organizer_schema", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        99
    );
}

fn when(value: &str) -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&chrono::Utc)
}
fn plugin(id: &str) -> Principal {
    Principal {
        id: format!("plugin:{id}"),
        kind: PrincipalKind::Plugin,
    }
}

#[test]
fn ui_and_mcp_share_the_profile_with_scoped_permissions_and_opted_in_plugins() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let mut mcp = client("local-mcp");
    mcp.kind = PrincipalKind::Mcp;
    let ui = client("ui");
    let g = full_grant();
    let todo = call(
        &store,
        &mcp,
        &g,
        "todo.create",
        json!({"title":"MCP 写入用户的待办"}),
    );
    assert_eq!(
        call(
            &store,
            &Principal::owner(),
            &Grant::default(),
            "todo.get",
            json!({"id":todo["id"]})
        )["title"],
        todo["title"]
    );
    let mut read = Grant::default();
    read.capabilities.insert("todo.read".into());
    assert_eq!(
        call(&store, &ui, &read, "todo.get", json!({"id":todo["id"]}))["id"],
        todo["id"]
    );
    assert_eq!(
        dispatch(
            &store,
            &ui,
            &read,
            "todo.update",
            json!({"id":todo["id"],"changes":{"title":"denied"}})
        )
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    call(
        &store,
        &ui,
        &g,
        "todo.update",
        json!({"id":todo["id"],"changes":{"title":"UI 编辑"}}),
    );
    assert_eq!(
        call(&store, &mcp, &g, "todo.get", json!({"id":todo["id"]}))["title"],
        "UI 编辑"
    );
    assert_eq!(
        dispatch(
            &store,
            &client("ungranted"),
            &Grant::default(),
            "todo.get",
            json!({"id":todo["id"]})
        )
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    let private = plugin("notes");
    assert_eq!(
        dispatch(&store, &private, &g, "todo.get", json!({"id":todo["id"]}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    let private_todo = call(
        &store,
        &private,
        &g,
        "todo.create",
        json!({"title":"插件私有"}),
    );
    let mut shared = g.clone();
    shared.organizer_scope = Some("profile".into());
    assert_eq!(
        call(
            &store,
            &private,
            &shared,
            "todo.get",
            json!({"id":todo["id"]})
        )["title"],
        "UI 编辑"
    );
    let contribution = call(
        &store,
        &private,
        &shared,
        "todo.create",
        json!({"title":"已批准的插件贡献"}),
    );
    assert_eq!(
        call(
            &store,
            &ui,
            &read,
            "todo.get",
            json!({"id":contribution["id"]})
        )["id"],
        contribution["id"]
    );
    assert_eq!(
        dispatch(
            &store,
            &ui,
            &g,
            "todo.get",
            json!({"id":private_todo["id"]})
        )
        .unwrap_err()
        .code,
        "NotFound"
    );
    assert!(
        dispatch(
            &store,
            &private,
            &g,
            "todo.list",
            json!({"organizer_scope":"profile"})
        )
        .is_err()
    );
    let other_directory = tempfile::tempdir().unwrap();
    let other = Store::open(other_directory.path()).unwrap();
    assert_eq!(
        dispatch(&other, &ui, &g, "todo.get", json!({"id":todo["id"]}))
            .unwrap_err()
            .code,
        "NotFound"
    );
}

#[test]
fn background_profile_reminders_survive_creating_agent_revocation_and_are_receipted() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("agent");
    let g = full_grant();
    store.set_grant(&p.id, &g).unwrap();
    let todo = call(
        &store,
        &p,
        &g,
        "todo.create",
        json!({"title":"属于用户的提醒"}),
    );
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    store.set_grant(&p.id, &Grant::default()).unwrap();
    let now = when("2026-11-06T01:00:00Z");
    let batch = claim_due_notifications(&store, now, NotificationOptions::default()).unwrap();
    assert!(batch.issues.is_empty());
    assert_eq!(batch.claims.len(), 1);
    let claim = &batch.claims[0];
    assert!(claim.principal.is_owner());
    assert_eq!(claim.channel, DeliveryChannel::Event);
    assert!(notification_claim_is_current(&store, claim, now).unwrap());
    assert_eq!(claim.activity["title"], "属于用户的提醒");
    assert!(
        serde_json::to_value(claim)
            .unwrap()
            .get("lease_id")
            .is_none()
    );
    let seq = store
        .event(
            "organizer.notification",
            &json!({"principal":claim.principal.id,"delivery_key":claim.delivery_key}),
        )
        .unwrap();
    let outcome = DeliveryOutcome::Delivered {
        event_sequence: Some(seq),
    };
    let receipt = finish_notification(&store, claim, outcome, now).unwrap();
    assert_eq!(receipt.state, "delivered");
    assert_eq!(receipt.event_sequence, Some(seq));
    assert_eq!(
        finish_notification(&store, claim, outcome, now)
            .unwrap()
            .state,
        "delivered"
    );
    assert!(
        claim_due_notifications(&store, now, NotificationOptions::default())
            .unwrap()
            .claims
            .is_empty()
    );
    assert_eq!(
        dispatch(
            &store,
            &p,
            &store.grant(&p.id).unwrap(),
            "todo.create",
            json!({"title":"future write denied"})
        )
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
}

#[test]
fn private_scheduler_uses_live_grants_and_source_revocation_before_and_after_claim() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = plugin("private");
    let mut g = full_grant();
    g.account_ids.insert("a".into());
    store
        .record_upsert(
            "writer",
            "a",
            "assignment",
            "one",
            "assignment",
            &json!({"title":"private source"}),
        )
        .unwrap();
    let todo = call(
        &store,
        &p,
        &g,
        "todo.link",
        json!({"source":{"account_id":"a","source_id":"assignment","external_id":"one"}}),
    );
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    let now = when("2026-11-06T01:00:00Z");
    // A previously supplied grant is not background authority.
    assert!(
        claim_due_notifications(&store, now, NotificationOptions::default())
            .unwrap()
            .claims
            .is_empty()
    );
    let mut no_account = g.clone();
    no_account.account_ids.clear();
    store.set_grant(&p.id, &no_account).unwrap();
    assert!(
        claim_due_notifications(&store, now, NotificationOptions::default())
            .unwrap()
            .claims
            .is_empty()
    );
    store.set_grant(&p.id, &g).unwrap();
    let batch = claim_due_notifications(&store, now, NotificationOptions::default()).unwrap();
    assert_eq!(batch.claims.len(), 1);
    let first = &batch.claims[0];
    assert_eq!(first.principal.id, p.id);
    store.set_grant(&p.id, &no_account).unwrap();
    assert!(!notification_claim_is_current(&store, first, now).unwrap());
    finish_notification(
        &store,
        first,
        DeliveryOutcome::Retry { after_seconds: 5 },
        now,
    )
    .unwrap();
    let later = now + chrono::Duration::seconds(6);
    assert!(
        claim_due_notifications(&store, later, NotificationOptions::default())
            .unwrap()
            .claims
            .is_empty()
    );
    store.set_grant(&p.id, &g).unwrap();
    let next = claim_due_notifications(&store, later, NotificationOptions::default()).unwrap();
    assert_eq!(next.claims.len(), 1);
    assert_eq!(next.claims[0].delivery_key, first.delivery_key);
    assert_ne!(next.claims[0].lease_id, first.lease_id);
    assert!(notification_claim_is_current(&store, &next.claims[0], later).unwrap());
    let mut expired = g.clone();
    expired.expires_at = Some("2000-01-01T00:00:00Z".into());
    store.set_grant(&p.id, &expired).unwrap();
    assert!(!notification_claim_is_current(&store, &next.claims[0], later).unwrap());
}

#[test]
fn scheduler_preserves_first_sync_suppression_and_separates_event_platform_receipts() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = Principal::owner();
    let g = Grant::default();
    call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"notices","items":[activity_row("history")],"complete":false}),
    );
    let now = when("2026-11-06T01:00:00Z");
    let options = NotificationOptions {
        include_platform: true,
        ..Default::default()
    };
    assert!(
        claim_due_notifications(&store, now, options)
            .unwrap()
            .claims
            .is_empty()
    );
    call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"notices","items":[],"complete":true}),
    );
    call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"notices","items":[activity_row("history"),activity_row("new")]}),
    );
    let batch = claim_due_notifications(&store, now, options).unwrap();
    assert_eq!(batch.claims.len(), 2);
    assert!(
        batch
            .claims
            .iter()
            .all(|c| c.activity["external_id"] == "new")
    );
    let event = batch
        .claims
        .iter()
        .find(|c| c.channel == DeliveryChannel::Event)
        .unwrap();
    let platform = batch
        .claims
        .iter()
        .find(|c| c.channel == DeliveryChannel::Platform)
        .unwrap();
    assert_ne!(event.delivery_key, platform.delivery_key);
    let sequence = store
        .event(
            "organizer.notification",
            &json!({"principal":p.id,"delivery_key":event.delivery_key}),
        )
        .unwrap();
    finish_notification(
        &store,
        event,
        DeliveryOutcome::Delivered {
            event_sequence: Some(sequence),
        },
        now,
    )
    .unwrap();
    finish_notification(
        &store,
        platform,
        DeliveryOutcome::Retry { after_seconds: 10 },
        now,
    )
    .unwrap();
    // A duplicate retry response does not move its next attempt time.
    assert_eq!(
        finish_notification(
            &store,
            platform,
            DeliveryOutcome::Retry { after_seconds: 20 },
            now
        )
        .unwrap()
        .next_at,
        now + chrono::Duration::seconds(10)
    );
    assert!(
        claim_due_notifications(&store, now + chrono::Duration::seconds(9), options)
            .unwrap()
            .claims
            .is_empty()
    );
    let retry =
        claim_due_notifications(&store, now + chrono::Duration::seconds(10), options).unwrap();
    assert_eq!(retry.claims.len(), 1);
    let retried = &retry.claims[0];
    assert_eq!(retried.channel, DeliveryChannel::Platform);
    assert_eq!(retried.delivery_key, platform.delivery_key);
    assert_eq!(retried.attempt, 2);
    assert_eq!(
        finish_notification(
            &store,
            platform,
            DeliveryOutcome::Delivered {
                event_sequence: None
            },
            now + chrono::Duration::seconds(10)
        )
        .unwrap_err()
        .code,
        "LeaseLost"
    );
    finish_notification(
        &store,
        retried,
        DeliveryOutcome::Delivered {
            event_sequence: None,
        },
        now + chrono::Duration::seconds(10),
    )
    .unwrap();
    assert_eq!(
        inspect_notification(&store, &event.delivery_key)
            .unwrap()
            .state,
        "delivered"
    );
    assert!(
        claim_due_notifications(&store, now + chrono::Duration::seconds(11), options)
            .unwrap()
            .claims
            .is_empty()
    );
}

#[test]
fn expired_or_uncertain_attempts_require_reconciliation_and_reuse_stable_dedup_keys() {
    let d = tempfile::tempdir().unwrap();
    let key;
    let claim;
    let now = when("2026-11-06T01:00:00Z");
    let options = NotificationOptions {
        lease_seconds: 5,
        ..Default::default()
    };
    {
        let store = Store::open(d.path()).unwrap();
        let p = Principal::owner();
        let todo = call(
            &store,
            &p,
            &Grant::default(),
            "todo.create",
            json!({"title":"crash recovery"}),
        );
        call(
            &store,
            &p,
            &Grant::default(),
            "reminders.schedule",
            json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
        );
        claim = claim_due_notifications(&store, now, options)
            .unwrap()
            .claims
            .remove(0);
        key = claim.delivery_key.clone();
    }
    let store = Store::open(d.path()).unwrap();
    let expired = now + chrono::Duration::seconds(5);
    assert!(
        claim_due_notifications(&store, expired, options)
            .unwrap()
            .claims
            .is_empty()
    );
    assert_eq!(
        inspect_notification(&store, &key).unwrap().state,
        "uncertain"
    );
    assert!(!notification_claim_is_current(&store, &claim, expired).unwrap());
    assert_eq!(
        finish_notification(
            &store,
            &claim,
            DeliveryOutcome::Delivered {
                event_sequence: Some(1)
            },
            expired
        )
        .unwrap_err()
        .code,
        "LeaseLost"
    );
    reconcile_notification(
        &store,
        &key,
        DeliveryOutcome::Retry { after_seconds: 1 },
        expired,
    )
    .unwrap();
    let retried = claim_due_notifications(&store, expired + chrono::Duration::seconds(1), options)
        .unwrap()
        .claims
        .remove(0);
    assert_eq!(retried.delivery_key, key);
    assert_ne!(retried.lease_id, claim.lease_id);
    finish_notification(
        &store,
        &retried,
        DeliveryOutcome::Uncertain,
        expired + chrono::Duration::seconds(1),
    )
    .unwrap();
    assert_eq!(
        finish_notification(
            &store,
            &retried,
            DeliveryOutcome::Uncertain,
            expired + chrono::Duration::seconds(1)
        )
        .unwrap()
        .state,
        "uncertain"
    );
    assert!(
        claim_due_notifications(&store, expired + chrono::Duration::seconds(2), options)
            .unwrap()
            .claims
            .is_empty()
    );
    let sequence = store
        .event(
            "organizer.notification",
            &json!({"principal":"owner","delivery_key":key}),
        )
        .unwrap();
    reconcile_notification(
        &store,
        &key,
        DeliveryOutcome::Delivered {
            event_sequence: Some(sequence),
        },
        expired + chrono::Duration::seconds(2),
    )
    .unwrap();
    assert_eq!(
        inspect_notification(&store, &key).unwrap().event_sequence,
        Some(sequence)
    );
    assert!(
        claim_due_notifications(&store, expired + chrono::Duration::seconds(3), options)
            .unwrap()
            .claims
            .is_empty()
    );
}

#[test]
fn scheduler_claims_are_atomic_under_concurrency_and_local_reads_cancel_delivery() {
    let d = tempfile::tempdir().unwrap();
    let store = Arc::new(Store::open(d.path()).unwrap());
    let p = Principal::owner();
    let g = Grant::default();
    let todo = call(&store, &p, &g, "todo.create", json!({"title":"once"}));
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":todo["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    let now = when("2026-11-06T01:00:00Z");
    let barrier = Arc::new(Barrier::new(2));
    let workers: Vec<_> = (0..2)
        .map(|_| {
            let store = store.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                claim_due_notifications(&store, now, NotificationOptions::default())
                    .unwrap()
                    .claims
            })
        })
        .collect();
    let mut claims: Vec<_> = workers
        .into_iter()
        .flat_map(|w| w.join().unwrap())
        .collect();
    assert_eq!(claims.len(), 1);
    let claim = claims.remove(0);
    call(
        &store,
        &p,
        &g,
        "activity.read",
        json!({"id":claim.activity_id}),
    );
    assert!(!notification_claim_is_current(&store, &claim, now).unwrap());
    assert_eq!(
        inspect_notification(&store, &claim.delivery_key)
            .unwrap()
            .state,
        "cancelled"
    );
    call(
        &store,
        &p,
        &g,
        "activity.read",
        json!({"id":claim.activity_id,"value":false}),
    );
    assert!(
        claim_due_notifications(
            &store,
            now + chrono::Duration::seconds(301),
            NotificationOptions::default()
        )
        .unwrap()
        .claims
        .is_empty()
    );
}

#[test]
fn scheduler_bounds_native_only_access_and_bad_owner_failure_isolation() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = plugin("broken");
    let g = full_grant();
    store.set_grant(&p.id, &g).unwrap();
    store
        .record_upsert(
            &p.id,
            "",
            "schedule",
            "one",
            "timetable",
            &json!({"title":"valid","start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00"}),
        )
        .unwrap();
    let linked = call(
        &store,
        &p,
        &g,
        "calendar.link",
        json!({"source":{"source_id":"schedule","external_id":"one"}}),
    );
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    store
        .record_upsert(
            &p.id,
            "",
            "schedule",
            "one",
            "timetable",
            &json!({"title":"malformed"}),
        )
        .unwrap();
    let profile = call(
        &store,
        &Principal::owner(),
        &Grant::default(),
        "todo.create",
        json!({"title":"unaffected"}),
    );
    call(
        &store,
        &Principal::owner(),
        &Grant::default(),
        "reminders.schedule",
        json!({"item_id":profile["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    let now = when("2026-11-06T01:00:00Z");
    for seconds in [0, 301] {
        assert!(
            claim_due_notifications(
                &store,
                now,
                NotificationOptions {
                    lease_seconds: seconds,
                    ..Default::default()
                }
            )
            .is_err()
        );
    }
    let batch = claim_due_notifications(&store, now, NotificationOptions::default()).unwrap();
    assert_eq!(batch.claims.len(), 1);
    assert_eq!(batch.issues.len(), 1);
    assert_eq!(batch.issues[0].principal.id, p.id);
    let claim = &batch.claims[0];
    assert!(
        finish_notification(
            &store,
            claim,
            DeliveryOutcome::Retry { after_seconds: 0 },
            now
        )
        .is_err()
    );
    assert!(
        finish_notification(
            &store,
            claim,
            DeliveryOutcome::Delivered {
                event_sequence: None
            },
            now
        )
        .is_err()
    );
    assert_eq!(
        inspect_notification(&store, &claim.delivery_key)
            .unwrap()
            .state,
        "leased"
    );
    assert_eq!(required_capability("reminders.claim_all"), None);
    assert_eq!(
        dispatch(
            &store,
            &Principal::owner(),
            &Grant::default(),
            "reminders.claim_all",
            json!({})
        )
        .unwrap_err()
        .code,
        "MethodNotFound"
    );
}

#[test]
fn version_one_client_namespaces_migrate_into_profile_without_losing_ids_or_dedup() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = Principal::owner();
    let g = Grant::default();
    let todo = call(
        &store,
        &p,
        &g,
        "todo.create",
        json!({"title":"legacy personal"}),
    );
    store
        .record_upsert(
            "writer",
            "",
            "legacy.assignments",
            "one",
            "assignment",
            &json!({"title":"legacy canonical"}),
        )
        .unwrap();
    let linked = call(
        &store,
        &p,
        &g,
        "todo.link",
        json!({"source":{"source_id":"legacy.assignments","external_id":"one"}}),
    );
    let reminder = call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    call(
        &store,
        &p,
        &g,
        "activity.sync",
        json!({"source_id":"notices","items":[activity_row("old")]}),
    );
    let db = rusqlite::Connection::open(d.path().join("dansheng.db")).unwrap();
    db.execute_batch("BEGIN; PRAGMA defer_foreign_keys=ON; DROP TABLE organizer_deliveries; DROP TABLE organizer_scheduler; DROP INDEX organizer_reminders_scheduler; DROP INDEX organizer_activity_scheduler; UPDATE organizer_schema SET version=1;").unwrap();
    let old = "[\"client\",\"legacy-ui\"]";
    let other = "[\"mcp\",\"legacy-agent\"]";
    for table in [
        "organizer_items",
        "organizer_reminders",
        "organizer_activity",
        "organizer_sync",
    ] {
        db.execute(&format!("UPDATE {table} SET owner=?"), [old])
            .unwrap();
    }
    // Same canonical link and instant were independently imported by the old adapters.
    let duplicate_id = uuid::Uuid::new_v4().to_string();
    db.execute("INSERT INTO organizer_items SELECT ?,?,kind,body,created_at,updated_at,record_owner,account_id,source_id,external_id FROM organizer_items WHERE owner=? AND id=?",rusqlite::params![other,duplicate_id,old,linked["id"].as_str().unwrap()]).unwrap();
    db.execute("INSERT INTO organizer_reminders SELECT ?,?,?,at,timezone,state,created_at,fired_at FROM organizer_reminders WHERE owner=? AND id=?",rusqlite::params![other,uuid::Uuid::new_v4().to_string(),duplicate_id,old,reminder["id"].as_str().unwrap()]).unwrap();
    db.execute("INSERT INTO organizer_activity SELECT ?,?,account_id,source_id,external_id,title,kind,occurred_at,notification,read_at,archived_at,item_id FROM organizer_activity WHERE owner=?",rusqlite::params![other,uuid::Uuid::new_v4().to_string(),old]).unwrap();
    db.execute("INSERT INTO organizer_sync SELECT ?,account_id,source_id,initialized FROM organizer_sync WHERE owner=?",rusqlite::params![other,old]).unwrap();
    db.execute_batch("COMMIT;").unwrap();
    Organizer::new(&store).unwrap();
    let migrated = call(&store, &p, &g, "todo.list", json!({}));
    assert_eq!(items(&migrated).len(), 2);
    assert_eq!(
        call(&store, &p, &g, "todo.get", json!({"id":todo["id"]}))["title"],
        "legacy personal"
    );
    assert_eq!(
        items(&call(&store, &p, &g, "reminders.list", json!({}))).len(),
        1
    );
    assert_eq!(
        items(&call(&store, &p, &g, "activity.list", json!({}))).len(),
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM organizer_items WHERE owner<>?",
            ["[\"owner\",\"owner\"]"],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert!(
        !db.prepare("PRAGMA foreign_key_check")
            .unwrap()
            .exists([])
            .unwrap()
    );
    assert_eq!(
        call(
            &store,
            &p,
            &g,
            "activity.sync",
            json!({"source_id":"notices","items":[activity_row("old"),activity_row("new")]})
        )["notifications"],
        1
    );
    let due = claim_due_notifications(
        &store,
        when("2026-11-06T01:00:00Z"),
        NotificationOptions::default(),
    )
    .unwrap();
    assert_eq!(due.claims.len(), 2); // New activity plus the single deduplicated reminder.
}

fn source_labels(store: &Store, owner: &str, source: &str, caps: &[&str]) {
    store
        .require_source_capabilities(owner, source, &caps.iter().map(|s| s.to_string()).collect())
        .unwrap();
}

#[test]
fn canonical_read_labels_protect_links_conflicts_ics_reminders_and_inbox_on_revocation() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("calendar-reader");
    let mut g = full_grant();
    g.account_ids.insert("school".into());
    let writer = "service:academic";
    let source = "official.schedule";
    source_labels(&store, writer, source, &["fudan.academic.read"]);
    // A label on another canonical writer is not a restriction on this row.
    source_labels(&store, "service:other", source, &["fudan.card.read"]);
    store.record_upsert(writer,"school",source,"one","timetable",&json!({"title":"label-only course","start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00"})).unwrap();
    let reference = json!({"account_id":"school","source_id":source,"external_id":"one"});
    event(
        &store,
        &p,
        &g,
        "personal",
        "2026-11-06T09:30",
        "2026-11-06T10:30",
    );
    assert!(store.records(&p, &g, &json!({}), None).unwrap().is_empty());
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.link", json!({"source":reference}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    g.capabilities.insert("fudan.academic.read".into());
    assert_eq!(store.records(&p, &g, &json!({}), None).unwrap().len(), 1);
    let linked = call(&store, &p, &g, "calendar.link", json!({"source":reference}));
    assert_eq!(linked["title"], "label-only course");
    assert_eq!(
        call(&store, &p, &g, "calendar.conflicts", json!({}))["conflicts"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(
        call(
            &store,
            &p,
            &g,
            "calendar.export_ics",
            json!({"include_todos":false})
        )["ics"]
            .as_str()
            .unwrap()
            .contains("label-only course")
    );
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    assert_eq!(
        items(&call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-06T01:00:00Z"})
        ))
        .len(),
        1
    );
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T02:00:00Z"}),
    );
    g.capabilities.remove("fudan.academic.read");
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.get", json!({"id":linked["id"]}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.link", json!({"source":reference}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    let visible = call(&store, &p, &g, "calendar.list", json!({}));
    assert_eq!(items(&visible).len(), 1);
    assert_eq!(items(&visible)[0]["title"], "personal");
    assert!(
        call(&store, &p, &g, "calendar.conflicts", json!({}))["conflicts"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        !call(
            &store,
            &p,
            &g,
            "calendar.export_ics",
            json!({"include_todos":false})
        )["ics"]
            .as_str()
            .unwrap()
            .contains("label-only course")
    );
    assert_eq!(
        dispatch(
            &store,
            &p,
            &g,
            "reminders.schedule",
            json!({"item_id":linked["id"],"at":"2026-11-06T03:00:00Z"})
        )
        .unwrap_err()
        .code,
        "NotFound"
    );
    assert!(items(&call(&store, &p, &g, "reminders.list", json!({}))).is_empty());
    assert!(
        items(&call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-06T03:00:00Z"})
        ))
        .is_empty()
    );
    assert!(items(&call(&store, &p, &g, "activity.list", json!({}))).is_empty());
    assert!(items(&call(&store, &p, &g, "activity.notifications", json!({}))).is_empty());
    // Revoking this reader cannot erase the profile owner's intrinsic access.
    assert_eq!(
        call(
            &store,
            &Principal::owner(),
            &Grant::default(),
            "calendar.get",
            json!({"id":linked["id"]})
        )["title"],
        "label-only course"
    );
    g.capabilities.insert("fudan.academic.read".into());
    assert_eq!(
        items(&call(&store, &p, &g, "reminders.list", json!({}))).len(),
        2
    );
    assert_eq!(
        items(&call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-06T03:00:00Z"})
        ))
        .len(),
        1
    );
    assert_eq!(
        items(&call(&store, &p, &g, "activity.notifications", json!({}))).len(),
        2
    );
}

#[test]
fn private_scheduler_rechecks_all_unioned_source_labels_in_sql_and_live_leases() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = plugin("read-labels");
    let source = "own.schedule";
    let mut g = full_grant();
    g.capabilities.insert("fudan.academic.read".into());
    source_labels(&store, &p.id, source, &["fudan.academic.read"]);
    store.record_upsert(&p.id,"",source,"one","timetable",&json!({"title":"private labeled course","start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00"})).unwrap();
    let linked = call(
        &store,
        &p,
        &g,
        "calendar.link",
        json!({"source":{"source_id":source,"external_id":"one"}}),
    );
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    let mut denied = g.clone();
    denied.capabilities.remove("fudan.academic.read");
    store.set_grant(&p.id, &denied).unwrap();
    let now = when("2026-11-06T01:00:00Z");
    let blocked = claim_due_notifications(&store, now, NotificationOptions::default()).unwrap();
    assert!(blocked.claims.is_empty());
    assert!(blocked.issues.is_empty());
    assert!(items(&call(&store, &p, &denied, "reminders.list", json!({}))).is_empty());
    store.set_grant(&p.id, &g).unwrap();
    let ready = claim_due_notifications(&store, now, NotificationOptions::default()).unwrap();
    assert_eq!(ready.claims.len(), 1);
    let claim = &ready.claims[0];
    assert!(notification_claim_is_current(&store, claim, now).unwrap());
    // Adding another read requirement unions it with the earlier requirement.
    source_labels(&store, &p.id, source, &["fudan.card.read"]);
    assert!(!notification_claim_is_current(&store, claim, now).unwrap());
    assert!(items(&call(&store, &p, &g, "activity.list", json!({}))).is_empty());
    g.capabilities.insert("fudan.card.read".into());
    store.set_grant(&p.id, &g).unwrap();
    assert!(notification_claim_is_current(&store, claim, now).unwrap());
    g.capabilities.remove("fudan.academic.read");
    store.set_grant(&p.id, &g).unwrap();
    assert!(!notification_claim_is_current(&store, claim, now).unwrap());
    assert!(items(&call(&store, &p, &g, "activity.notifications", json!({}))).is_empty());
}

#[test]
fn source_label_filter_precedes_disambiguation_and_tracks_the_canonical_writer() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("reader");
    let mut g = full_grant();
    g.account_ids.insert("school".into());
    g.capabilities.insert("fudan.academic.read".into());
    for (writer, cap, title) in [
        ("writer-a", "fudan.academic.read", "allowed A"),
        ("writer-b", "fudan.card.read", "restricted B"),
    ] {
        source_labels(&store, writer, "same.source", &[cap]);
        store
            .record_upsert(
                writer,
                "school",
                "same.source",
                "one",
                "timetable",
                &json!({"title":title,"start_at":"2026-11-06T09:00","end_at":"2026-11-06T10:00"}),
            )
            .unwrap();
    }
    let reference = json!({"account_id":"school","source_id":"same.source","external_id":"one"});
    let a = call(&store, &p, &g, "calendar.link", json!({"source":reference}));
    assert_eq!(a["title"], "allowed A");
    g.capabilities.insert("fudan.card.read".into());
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.link", json!({"source":reference}))
            .unwrap_err()
            .code,
        "AmbiguousSource"
    );
    assert_eq!(
        call(&store, &p, &g, "calendar.get", json!({"id":a["id"]}))["title"],
        "allowed A"
    );
    g.capabilities.remove("fudan.academic.read");
    assert_eq!(
        dispatch(&store, &p, &g, "calendar.get", json!({"id":a["id"]}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    let b = call(&store, &p, &g, "calendar.link", json!({"source":reference}));
    assert_eq!(b["title"], "restricted B");
    assert_ne!(a["id"], b["id"]);
    let visible = call(&store, &p, &g, "calendar.list", json!({}));
    assert_eq!(items(&visible).len(), 1);
    assert_eq!(items(&visible)[0]["id"], b["id"]);
}

#[test]
fn unlabeled_legacy_mail_sources_require_mail_read_before_projection_and_reminders() {
    let d = tempfile::tempdir().unwrap();
    let store = Store::open(d.path()).unwrap();
    let p = client("mail-derived");
    let mut g = full_grant();
    g.account_ids.insert("mail-account".into());
    store
        .record_upsert(
            "service:mail",
            "mail-account",
            "mail.assignments",
            "one",
            "assignment",
            &json!({"title":"mail-derived task","due_at":"2026-11-07T00:00:00Z"}),
        )
        .unwrap();
    let reference =
        json!({"account_id":"mail-account","source_id":"mail.assignments","external_id":"one"});
    assert!(store.records(&p, &g, &json!({}), None).unwrap().is_empty());
    assert_eq!(
        dispatch(&store, &p, &g, "todo.link", json!({"source":reference}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    g.capabilities.insert("mail.read".into());
    let linked = call(&store, &p, &g, "todo.link", json!({"source":reference}));
    call(
        &store,
        &p,
        &g,
        "reminders.schedule",
        json!({"item_id":linked["id"],"at":"2026-11-06T00:00:00Z"}),
    );
    g.capabilities.remove("mail.read");
    assert_eq!(
        dispatch(&store, &p, &g, "todo.get", json!({"id":linked["id"]}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    assert!(items(&call(&store, &p, &g, "todo.list", json!({}))).is_empty());
    assert!(
        !call(&store, &p, &g, "calendar.export_ics", json!({}))["ics"]
            .as_str()
            .unwrap()
            .contains("mail-derived task")
    );
    assert!(items(&call(&store, &p, &g, "reminders.list", json!({}))).is_empty());
    assert!(
        items(&call(
            &store,
            &p,
            &g,
            "reminders.due",
            json!({"now":"2026-11-06T01:00:00Z"})
        ))
        .is_empty()
    );
    // A legacy mail kind is protected even if its source ID has no mail prefix.
    store
        .record_upsert(
            "service:mail",
            "mail-account",
            "legacy.messages",
            "two",
            "mail.message",
            &json!({"title":"native mail"}),
        )
        .unwrap();
    let native =
        json!({"account_id":"mail-account","source_id":"legacy.messages","external_id":"two"});
    assert_eq!(
        dispatch(&store, &p, &g, "todo.link", json!({"source":native}))
            .unwrap_err()
            .code,
        "NotFound"
    );
    g.capabilities.insert("mail.read".into());
    assert_eq!(
        dispatch(&store, &p, &g, "todo.link", json!({"source":native}))
            .unwrap_err()
            .code,
        "InvalidInput"
    );
    assert_eq!(
        call(&store, &p, &g, "todo.get", json!({"id":linked["id"]}))["title"],
        "mail-derived task"
    );
}
