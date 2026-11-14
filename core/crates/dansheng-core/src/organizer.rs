//! Local organizer. All identities and grants come from the trusted adapter.
use crate::{
    api::{CoreError, CoreResult, Principal, PrincipalKind},
    policy::Grant,
    store::Store,
};
use chrono::{DateTime, Datelike, LocalResult, NaiveDateTime, TimeZone, Utc};
use chrono_tz::Tz;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub const DEFAULT_TIMEZONE: &str = "Asia/Shanghai";
const MAX_ITEMS: i64 = 2_000;
const MAX_BATCH: usize = 500;
const PROFILE_OWNER: &str = "[\"owner\",\"owner\"]";

fn organizer_owner(principal: &Principal, grant: &Grant) -> CoreResult<String> {
    if principal.is_owner()
        || matches!(principal.kind, PrincipalKind::Client | PrincipalKind::Mcp)
        || (principal.kind == PrincipalKind::Plugin
            && grant.organizer_scope.as_deref() == Some("profile"))
    {
        Ok(PROFILE_OWNER.into())
    } else {
        Ok(serde_json::to_string(&(&principal.kind, &principal.id))?)
    }
}

fn stored_principal(owner: &str) -> CoreResult<Principal> {
    let (kind, id): (PrincipalKind, String) = serde_json::from_str(owner)
        .map_err(|_| CoreError::new("StorageError", "invalid organizer owner identity"))?;
    bounded(&id, 256, false)?;
    Ok(Principal { kind, id })
}

/// The outer engine and plugin manifest gate must use this same map.
pub fn required_capability(method: &str) -> Option<&'static str> {
    Some(match method {
        "todo.list" | "todo.get" => "todo.read",
        "todo.create" | "todo.update" | "todo.complete" | "todo.delete" | "todo.link" => {
            "todo.write"
        }
        "calendar.list" | "calendar.get" | "calendar.conflicts" | "calendar.export_ics" => {
            "calendar.read"
        }
        "calendar.create" | "calendar.update" | "calendar.delete" | "calendar.link" => {
            "calendar.write"
        }
        "activity.list" => "activity.read",
        "activity.sync" | "activity.read" | "activity.archive" | "activity.notifications" => {
            "activity.write"
        }
        "reminders.list" => "reminders.read",
        "reminders.schedule" | "reminders.cancel" | "reminders.due" => "reminders.write",
        _ => return None,
    })
}

/// No filesystem, network, notification delivery, or arbitrary SQL surface.
pub fn dispatch(
    store: &Store,
    principal: &Principal,
    grant: &Grant,
    method: &str,
    params: Value,
) -> CoreResult<Value> {
    Organizer { store }.dispatch(principal, grant, method, params)
}

pub struct Organizer<'a> {
    store: &'a Store,
}

impl<'a> Organizer<'a> {
    /// Transactional, independently versioned schema; never changes user_version.
    pub fn new(store: &'a Store) -> CoreResult<Self> {
        initialize(store)?;
        Ok(Self { store })
    }

    pub fn dispatch(
        &self,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        input: Value,
    ) -> CoreResult<Value> {
        let cap = required_capability(method)
            .ok_or_else(|| CoreError::new("MethodNotFound", "unknown organizer method"))?;
        grant.check(principal, cap)?;
        bounded(&principal.id, 256, false)?;
        if !input.is_object() || input.to_string().len() > 256 * 1024 {
            return Err(CoreError::invalid(
                "organizer params must be a bounded object",
            ));
        }
        initialize(self.store)?;
        // A data directory is a user profile; adapter identity is authorization, not tenancy.
        let owner = organizer_owner(principal, grant)?;
        self.store.with(|db| {
            let tx = db.transaction()?;
            let ctx = Context {
                db: &tx,
                owner: &owner,
                principal,
                grant,
            };
            let value = ctx.execute(method, input)?;
            tx.commit()?;
            Ok(value)
        })
    }
}

fn initialize(store: &Store) -> CoreResult<()> {
    store.with(|db| {
        let tx = db.transaction()?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS organizer_schema(singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL);
             INSERT OR IGNORE INTO organizer_schema VALUES(1,0);",
        )?;
        let version: i64 = tx.query_row("SELECT version FROM organizer_schema WHERE singleton=1", [], |r| r.get(0))?;
        match version {
            0 => {
                tx.execute_batch(
                    "CREATE TABLE organizer_items(
                        owner TEXT NOT NULL,id TEXT NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('todo','event')),
                        body TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,
                        record_owner TEXT,account_id TEXT,source_id TEXT,external_id TEXT,
                        PRIMARY KEY(owner,id),UNIQUE(owner,kind,record_owner,account_id,source_id,external_id));
                     CREATE TABLE organizer_reminders(
                        owner TEXT NOT NULL,id TEXT NOT NULL,item_id TEXT NOT NULL,at INTEGER NOT NULL,timezone TEXT NOT NULL,
                        state TEXT NOT NULL CHECK(state IN ('pending','fired','cancelled')),created_at INTEGER NOT NULL,fired_at INTEGER,
                        PRIMARY KEY(owner,id),UNIQUE(owner,item_id,at),
                        FOREIGN KEY(owner,item_id) REFERENCES organizer_items(owner,id) ON DELETE CASCADE);
                     CREATE INDEX organizer_reminders_due ON organizer_reminders(owner,state,at);
                     CREATE TABLE organizer_sync(
                        owner TEXT NOT NULL,account_id TEXT NOT NULL,source_id TEXT NOT NULL,initialized INTEGER NOT NULL,
                        PRIMARY KEY(owner,account_id,source_id));
                     CREATE TABLE organizer_activity(
                        owner TEXT NOT NULL,id TEXT NOT NULL,account_id TEXT NOT NULL,source_id TEXT NOT NULL,external_id TEXT NOT NULL,
                        title TEXT NOT NULL,kind TEXT NOT NULL,occurred_at INTEGER NOT NULL,
                        notification TEXT NOT NULL CHECK(notification IN ('suppressed','pending','claimed')),
                        read_at INTEGER,archived_at INTEGER,item_id TEXT,
                        PRIMARY KEY(owner,id),UNIQUE(owner,account_id,source_id,external_id));
                     CREATE INDEX organizer_activity_inbox ON organizer_activity(owner,archived_at,occurred_at);
                     UPDATE organizer_schema SET version=1 WHERE singleton=1;",
                )?;
            }
            1 | 2 => {}
            _ => return Err(CoreError::new("UnsupportedDatabaseVersion", "unsupported organizer schema version")),
        }
        if version < 2 {
            migrate_profile_owners(&tx)?;
            tx.execute_batch(
                "CREATE TABLE organizer_deliveries(
                    owner TEXT NOT NULL,activity_id TEXT NOT NULL,channel TEXT NOT NULL CHECK(channel IN ('event','platform')),
                    delivery_key TEXT NOT NULL UNIQUE,state TEXT NOT NULL CHECK(state IN ('ready','leased','delivered','uncertain','cancelled')),
                    attempt INTEGER NOT NULL DEFAULT 0,lease_id TEXT,lease_expires_at INTEGER,next_at INTEGER NOT NULL,
                    delivered_at INTEGER,event_sequence INTEGER,
                    PRIMARY KEY(owner,activity_id,channel),
                    FOREIGN KEY(owner,activity_id) REFERENCES organizer_activity(owner,id) ON DELETE CASCADE);
                 CREATE TABLE organizer_scheduler(singleton INTEGER PRIMARY KEY CHECK(singleton=1),last_owner TEXT NOT NULL);
                 INSERT INTO organizer_scheduler VALUES(1,'');
                 CREATE INDEX organizer_deliveries_due ON organizer_deliveries(state,next_at,owner);
                 CREATE INDEX organizer_reminders_scheduler ON organizer_reminders(state,at,owner);
                 CREATE INDEX organizer_activity_scheduler ON organizer_activity(notification,owner);
                 UPDATE organizer_schema SET version=2 WHERE singleton=1;",
            )?;
        }
        tx.commit()?;
        Ok(())
    })
}

/// Upgrade the earlier adapter-private Client/MCP namespaces into the profile.
/// Duplicate canonical links/reminder instants/activity identities merge conservatively.
fn migrate_profile_owners(db: &Connection) -> CoreResult<()> {
    db.execute_batch("PRAGMA defer_foreign_keys=ON;")?;
    let mut stmt=db.prepare("SELECT owner FROM organizer_items UNION SELECT owner FROM organizer_reminders UNION SELECT owner FROM organizer_activity UNION SELECT owner FROM organizer_sync ORDER BY owner")?;
    let owners = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    for owner in owners {
        let p = stored_principal(&owner)?;
        if !matches!(p.kind, PrincipalKind::Client | PrincipalKind::Mcp) {
            continue;
        }
        let mut item_map = BTreeMap::new();
        let mut stmt=db.prepare("SELECT id,kind,record_owner,account_id,source_id,external_id,body,updated_at FROM organizer_items WHERE owner=? ORDER BY created_at,id")?;
        let rows = stmt
            .query_map([&owner], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, Option<String>>(5)?,
                    r.get::<_, String>(6)?,
                    r.get::<_, i64>(7)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        for (id, kind, record_owner, account, source, external, body, updated) in rows {
            let existing: Option<(String, String)> = if record_owner.is_some() {
                db.query_row("SELECT id,body FROM organizer_items WHERE owner=? AND kind=? AND record_owner=? AND account_id=? AND source_id=? AND external_id=?",params![PROFILE_OWNER,kind,record_owner,account,source,external],|r|Ok((r.get(0)?,r.get(1)?))).optional()?
            } else {
                None
            };
            if let Some((target, target_body)) = existing {
                let old: Content = serde_json::from_str(&body)?;
                let mut new: Content = serde_json::from_str(&target_body)?;
                if let (
                    Content::Link {
                        completed_at: a, ..
                    },
                    Content::Link {
                        completed_at: b, ..
                    },
                ) = (&mut new, old)
                {
                    *a = (*a).max(b);
                }
                db.execute("UPDATE organizer_items SET body=?,updated_at=max(updated_at,?) WHERE owner=? AND id=?",params![serde_json::to_string(&new)?,updated,PROFILE_OWNER,target])?;
                item_map.insert(id, target);
            } else {
                db.execute(
                    "UPDATE organizer_items SET owner=? WHERE owner=? AND id=?",
                    params![PROFILE_OWNER, owner, id],
                )?;
                item_map.insert(id.clone(), id);
            }
        }
        let mut reminder_map = BTreeMap::new();
        let mut stmt=db.prepare("SELECT id,item_id,at,state,fired_at FROM organizer_reminders WHERE owner=? ORDER BY at,id")?;
        let rows = stmt
            .query_map([&owner], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, Option<i64>>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        for (id, item, at, state, fired) in rows {
            let item = item_map
                .get(&item)
                .ok_or_else(|| CoreError::new("StorageError", "orphaned organizer reminder"))?;
            let existing: Option<String> = db
                .query_row(
                    "SELECT id FROM organizer_reminders WHERE owner=? AND item_id=? AND at=?",
                    params![PROFILE_OWNER, item, at],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(target) = existing {
                db.execute("UPDATE organizer_reminders SET state=CASE WHEN state='fired' OR ?='fired' THEN 'fired' WHEN state='cancelled' OR ?='cancelled' THEN 'cancelled' ELSE 'pending' END,fired_at=coalesce(fired_at,?) WHERE owner=? AND id=?",params![state,state,fired,PROFILE_OWNER,target])?;
                db.execute(
                    "DELETE FROM organizer_reminders WHERE owner=? AND id=?",
                    params![owner, id],
                )?;
                reminder_map.insert(id, target);
            } else {
                db.execute(
                    "UPDATE organizer_reminders SET owner=?,item_id=? WHERE owner=? AND id=?",
                    params![PROFILE_OWNER, item, owner, id],
                )?;
                reminder_map.insert(id.clone(), id);
            }
        }
        let mut stmt=db.prepare("SELECT id,account_id,source_id,external_id,item_id,notification,read_at,archived_at FROM organizer_activity WHERE owner=? ORDER BY occurred_at,id")?;
        let rows = stmt
            .query_map([&owner], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, Option<i64>>(6)?,
                    r.get::<_, Option<i64>>(7)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        for (id, account, source, external, item, notification, read, archived) in rows {
            let external = if source == "organizer.reminders" {
                reminder_map.get(&external).cloned().unwrap_or(external)
            } else {
                external
            };
            let item = item.as_ref().and_then(|id| item_map.get(id)).cloned();
            let existing: Option<String>=db.query_row("SELECT id FROM organizer_activity WHERE owner=? AND account_id=? AND source_id=? AND external_id=?",params![PROFILE_OWNER,account,source,external],|r|r.get(0)).optional()?;
            if let Some(target) = existing {
                db.execute("UPDATE organizer_activity SET notification=CASE WHEN notification='claimed' OR ?='claimed' THEN 'claimed' WHEN notification='suppressed' OR ?='suppressed' THEN 'suppressed' ELSE 'pending' END,read_at=coalesce(max(read_at,?),read_at,?),archived_at=coalesce(max(archived_at,?),archived_at,?),item_id=coalesce(item_id,?) WHERE owner=? AND id=?",params![notification,notification,read,read,archived,archived,item,PROFILE_OWNER,target])?;
                db.execute(
                    "DELETE FROM organizer_activity WHERE owner=? AND id=?",
                    params![owner, id],
                )?;
            } else {
                db.execute("UPDATE organizer_activity SET owner=?,external_id=?,item_id=? WHERE owner=? AND id=?",params![PROFILE_OWNER,external,item,owner,id])?;
            }
        }
        db.execute("INSERT INTO organizer_sync(owner,account_id,source_id,initialized) SELECT ?,account_id,source_id,initialized FROM organizer_sync WHERE owner=? ON CONFLICT(owner,account_id,source_id) DO UPDATE SET initialized=max(organizer_sync.initialized,excluded.initialized)",params![PROFILE_OWNER,owner])?;
        db.execute("DELETE FROM organizer_sync WHERE owner=?", [&owner])?;
        // Only duplicate link wrappers remain; their dependent rows have been rehomed.
        db.execute("DELETE FROM organizer_items WHERE owner=?", [&owner])?;
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceRef {
    #[serde(default)]
    account_id: String,
    source_id: String,
    external_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    record_owner: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Content {
    Todo {
        title: String,
        notes: String,
        timezone: String,
        due_at: Option<DateTime<Utc>>,
        completed_at: Option<DateTime<Utc>>,
    },
    Event {
        title: String,
        notes: String,
        location: String,
        timezone: String,
        start_at: DateTime<Utc>,
        end_at: DateTime<Utc>,
    },
    Link {
        source: SourceRef,
        completed_at: Option<DateTime<Utc>>,
    },
}

struct Stored {
    id: String,
    kind: String,
    body: Content,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Clone, Serialize)]
struct Item {
    id: String,
    kind: String,
    origin: &'static str,
    title: String,
    notes: String,
    location: String,
    timezone: String,
    due_at: Option<DateTime<Utc>>,
    start_at: Option<DateTime<Utc>>,
    end_at: Option<DateTime<Utc>>,
    completed_at: Option<DateTime<Utc>>,
    source: Option<SourceRef>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TodoInput {
    title: String,
    #[serde(default)]
    notes: String,
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    due_at: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EventInput {
    title: String,
    #[serde(default)]
    notes: String,
    #[serde(default)]
    location: String,
    #[serde(default)]
    timezone: Option<String>,
    start_at: String,
    end_at: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UpdateInput {
    id: String,
    changes: Value,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IdInput {
    id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CompleteInput {
    id: String,
    #[serde(default = "yes")]
    completed: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LinkInput {
    source: SourceRef,
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ListInput {
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    offset: usize,
    #[serde(default)]
    completed: Option<bool>,
    #[serde(default)]
    from: Option<String>,
    #[serde(default)]
    to: Option<String>,
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    include_todos: Option<bool>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConflictInput {
    #[serde(default)]
    from: Option<String>,
    #[serde(default)]
    to: Option<String>,
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    candidate: Option<Candidate>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Candidate {
    start_at: String,
    end_at: String,
    #[serde(default)]
    exclude_id: Option<String>,
}

struct Context<'a> {
    db: &'a Connection,
    owner: &'a str,
    principal: &'a Principal,
    grant: &'a Grant,
}

impl Context<'_> {
    fn execute(&self, method: &str, input: Value) -> CoreResult<Value> {
        match method {
            "todo.create" => {
                let p: TodoInput = decode(input)?;
                let tz = timezone(p.timezone.as_deref())?;
                bounded(&p.title, 512, false)?;
                bounded(&p.notes, 16_384, true)?;
                let due_at = p.due_at.as_deref().map(|s| at(s, tz)).transpose()?;
                self.insert(
                    "todo",
                    Content::Todo {
                        title: p.title,
                        notes: p.notes,
                        timezone: tz.to_string(),
                        due_at,
                        completed_at: None,
                    },
                )
            }
            "calendar.create" => {
                let p: EventInput = decode(input)?;
                let tz = timezone(p.timezone.as_deref())?;
                bounded(&p.title, 512, false)?;
                bounded(&p.notes, 16_384, true)?;
                bounded(&p.location, 1_024, true)?;
                let (start_at, end_at) = interval(&p.start_at, &p.end_at, tz)?;
                self.insert(
                    "event",
                    Content::Event {
                        title: p.title,
                        notes: p.notes,
                        location: p.location,
                        timezone: tz.to_string(),
                        start_at,
                        end_at,
                    },
                )
            }
            "todo.link" | "calendar.link" => {
                let p: LinkInput = decode(input)?;
                self.grant.check(self.principal, "sources.read")?;
                let source = self.source(&p.source)?.ok_or_else(not_found)?.0;
                let kind = if method == "todo.link" {
                    "todo"
                } else {
                    "event"
                };
                let existing: Option<String> = self.db.query_row(
                    "SELECT id FROM organizer_items WHERE owner=? AND kind=? AND record_owner=? AND account_id=? AND source_id=? AND external_id=?",
                    params![self.owner,kind,source.record_owner,source.account_id,source.source_id,source.external_id], |r| r.get(0),
                ).optional()?;
                if let Some(id) = existing {
                    return self.get(&id, Some(kind));
                }
                self.insert(
                    kind,
                    Content::Link {
                        source,
                        completed_at: None,
                    },
                )
            }
            "todo.update" | "calendar.update" => self.update(method, decode(input)?),
            "todo.complete" => {
                let p: CompleteInput = decode(input)?;
                let mut stored = self.load(&p.id, Some("todo"))?;
                let item = self.project(&stored)?.ok_or_else(not_found)?;
                let now = clock_now();
                let completed = if p.completed {
                    item.completed_at.or(Some(now))
                } else {
                    None
                };
                match &mut stored.body {
                    Content::Todo { completed_at, .. } | Content::Link { completed_at, .. } => {
                        *completed_at = completed
                    }
                    _ => unreachable!(),
                }
                if p.completed {
                    self.cancel_item_reminders(&stored.id)?;
                }
                self.save(&mut stored)?;
                self.get(&stored.id, Some("todo"))
            }
            "todo.delete" | "calendar.delete" => {
                let p: IdInput = decode(input)?;
                let kind = if method == "todo.delete" {
                    "todo"
                } else {
                    "event"
                };
                // Unlinking remains possible after a source is deleted or access revoked.
                self.load(&p.id, Some(kind))?;
                self.db.execute(
                    "DELETE FROM organizer_activity WHERE owner=? AND item_id=?",
                    params![self.owner, p.id],
                )?;
                self.db.execute(
                    "DELETE FROM organizer_items WHERE owner=? AND id=? AND kind=?",
                    params![self.owner, p.id, kind],
                )?;
                Ok(json!({"id":p.id,"deleted":true}))
            }
            "todo.get" | "calendar.get" => {
                let p: IdInput = decode(input)?;
                self.get(
                    &p.id,
                    Some(if method == "todo.get" {
                        "todo"
                    } else {
                        "event"
                    }),
                )
            }
            "todo.list" | "calendar.list" => {
                let p: ListInput = decode(input)?;
                let kind = if method == "todo.list" {
                    "todo"
                } else {
                    "event"
                };
                let items = self.filtered(kind, &p)?;
                let total = items.len();
                let limit = page_limit(p.limit)?;
                if p.offset > 100_000 {
                    return Err(CoreError::invalid("offset exceeds limit"));
                }
                Ok(
                    json!({"items":items.into_iter().skip(p.offset).take(limit).collect::<Vec<_>>(),"total":total}),
                )
            }
            "calendar.conflicts" => self.conflicts(decode(input)?),
            "calendar.export_ics" => {
                let p: ListInput = decode(input)?;
                if p.limit.is_some() || p.offset != 0 {
                    return Err(CoreError::invalid("ICS exports cannot be paginated"));
                }
                let mut items = self.filtered("event", &p)?;
                if p.include_todos.unwrap_or(true) {
                    self.grant.check(self.principal, "todo.read")?;
                    items.extend(self.filtered("todo", &p)?);
                }
                Ok(json!({"content_type":"text/calendar; charset=utf-8","ics":export_ics(&items)}))
            }
            "activity.sync" => self.activity_sync(decode(input)?),
            "activity.list" => self.activity_list(decode(input)?),
            "activity.read" | "activity.archive" => self.activity_state(method, decode(input)?),
            "activity.notifications" => self.activity_notifications(decode(input)?),
            "reminders.schedule" => self.reminder_schedule(decode(input)?),
            "reminders.list" => self.reminder_list(decode(input)?),
            "reminders.cancel" => {
                let p: IdInput = decode(input)?;
                bounded(&p.id, 128, false)?;
                if self.db.execute("UPDATE organizer_reminders SET state='cancelled' WHERE owner=? AND id=? AND state='pending'",params![self.owner,p.id])? == 0 {
                    let present: bool = self.db.query_row("SELECT EXISTS(SELECT 1 FROM organizer_reminders WHERE owner=? AND id=?)",params![self.owner,p.id],|r|r.get(0))?;
                    if !present { return Err(not_found()); }
                }
                Ok(json!({"id":p.id}))
            }
            "reminders.due" => self.reminders_due(decode(input)?),
            _ => Err(CoreError::new("MethodNotFound", "unknown organizer method")),
        }
    }

    fn insert(&self, kind: &str, body: Content) -> CoreResult<Value> {
        let count: i64 = self.db.query_row(
            "SELECT count(*) FROM organizer_items WHERE owner=?",
            [self.owner],
            |r| r.get(0),
        )?;
        if count >= MAX_ITEMS {
            return Err(quota());
        }
        let now = clock_now();
        let stored = Stored {
            id: new_id(),
            kind: kind.into(),
            body,
            created_at: now,
            updated_at: now,
        };
        let item = self.project(&stored)?.ok_or_else(not_found)?;
        let source = item.source.as_ref();
        self.db.execute(
            "INSERT INTO organizer_items(owner,id,kind,body,created_at,updated_at,record_owner,account_id,source_id,external_id) VALUES(?,?,?,?,?,?,?,?,?,?)",
            params![self.owner,stored.id,kind,serde_json::to_string(&stored.body)?,now.timestamp_millis(),now.timestamp_millis(),
                source.and_then(|s|s.record_owner.as_deref()),source.map(|s|&s.account_id),source.map(|s|&s.source_id),source.map(|s|&s.external_id)],
        )?;
        Ok(serde_json::to_value(item)?)
    }

    fn load(&self, id: &str, kind: Option<&str>) -> CoreResult<Stored> {
        bounded(id, 128, false)?;
        let value: Option<(String,String,i64,i64)> = self.db.query_row(
            "SELECT kind,body,created_at,updated_at FROM organizer_items WHERE owner=? AND id=? AND (? IS NULL OR kind=?)",
            params![self.owner,id,kind,kind], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)),
        ).optional()?;
        let (kind, body, created_at, updated_at) = value.ok_or_else(not_found)?;
        Ok(Stored {
            id: id.into(),
            kind,
            body: serde_json::from_str(&body)?,
            created_at: from_millis(created_at)?,
            updated_at: from_millis(updated_at)?,
        })
    }

    fn get(&self, id: &str, kind: Option<&str>) -> CoreResult<Value> {
        Ok(serde_json::to_value(
            self.project(&self.load(id, kind)?)?.ok_or_else(not_found)?,
        )?)
    }

    fn save(&self, stored: &mut Stored) -> CoreResult<()> {
        stored.updated_at = clock_now();
        self.db.execute(
            "UPDATE organizer_items SET body=?,updated_at=? WHERE owner=? AND id=?",
            params![
                serde_json::to_string(&stored.body)?,
                stored.updated_at.timestamp_millis(),
                self.owner,
                stored.id
            ],
        )?;
        Ok(())
    }

    fn update(&self, method: &str, p: UpdateInput) -> CoreResult<Value> {
        let kind = if method == "todo.update" {
            "todo"
        } else {
            "event"
        };
        let mut stored = self.load(&p.id, Some(kind))?;
        let changes = p
            .changes
            .as_object()
            .ok_or_else(|| CoreError::invalid("changes must be an object"))?;
        if changes.is_empty() {
            return Err(CoreError::invalid("changes must not be empty"));
        }
        if matches!(stored.body, Content::Link { .. }) {
            return Err(CoreError::new(
                "ReadOnlySource",
                "update the authoritative source through its connector",
            ));
        }
        let item = self.project(&stored)?.ok_or_else(not_found)?;
        let mut fields = if kind == "todo" {
            json!({"title":item.title,"notes":item.notes,"timezone":item.timezone,"due_at":item.due_at})
        } else {
            json!({"title":item.title,"notes":item.notes,"location":item.location,"timezone":item.timezone,"start_at":item.start_at,"end_at":item.end_at})
        };
        for (key, value) in changes {
            if fields.get(key).is_none() {
                return Err(CoreError::invalid("unsupported update field"));
            }
            if value.is_null() && key != "due_at" {
                return Err(CoreError::invalid("only due_at may be cleared"));
            }
            fields[key] = value.clone();
        }
        stored.body = if kind == "todo" {
            let v: TodoInput = decode(fields)?;
            let tz = timezone(v.timezone.as_deref())?;
            bounded(&v.title, 512, false)?;
            bounded(&v.notes, 16_384, true)?;
            Content::Todo {
                title: v.title,
                notes: v.notes,
                timezone: tz.to_string(),
                due_at: v.due_at.as_deref().map(|s| at(s, tz)).transpose()?,
                completed_at: item.completed_at,
            }
        } else {
            let v: EventInput = decode(fields)?;
            let tz = timezone(v.timezone.as_deref())?;
            bounded(&v.title, 512, false)?;
            bounded(&v.notes, 16_384, true)?;
            bounded(&v.location, 1_024, true)?;
            let (start_at, end_at) = interval(&v.start_at, &v.end_at, tz)?;
            Content::Event {
                title: v.title,
                notes: v.notes,
                location: v.location,
                timezone: tz.to_string(),
                start_at,
                end_at,
            }
        };
        self.save(&mut stored)?;
        self.get(&p.id, Some(kind))
    }

    /// Source access is decided inside the SELECT, using the core records ACL.
    fn source(&self, reference: &SourceRef) -> CoreResult<Option<(SourceRef, Value)>> {
        bounded(&reference.account_id, 256, true)?;
        bounded(&reference.source_id, 256, false)?;
        bounded(&reference.external_id, 512, false)?;
        if let Some(owner) = &reference.record_owner {
            bounded(owner, 256, false)?;
        }
        if !self.principal.is_owner() && !self.grant.allows("sources.read") {
            return Ok(None);
        }
        let (acl, mut values) = record_acl(self.principal, self.grant);
        let sql = format!(
            "SELECT owner,data,kind,updated_at FROM records WHERE {acl} AND account_id=? AND source_id=? AND external_id=? AND (? IS NULL OR owner=?) LIMIT 2"
        );
        values.extend([
            reference.account_id.clone().into(),
            reference.source_id.clone().into(),
            reference.external_id.clone().into(),
            reference
                .record_owner
                .clone()
                .map(Into::into)
                .unwrap_or(rusqlite::types::Value::Null),
            reference
                .record_owner
                .clone()
                .map(Into::into)
                .unwrap_or(rusqlite::types::Value::Null),
        ]);
        let mut stmt = self.db.prepare(&sql)?;
        let mut rows = stmt.query(params_from_iter(values))?;
        let Some(row) = rows.next()? else {
            return Ok(None);
        };
        let owner: String = row.get(0)?;
        let text: String = row.get(1)?;
        let kind: String = row.get(2)?;
        let updated_at: String = row.get(3)?;
        if rows.next()?.is_some() {
            return Err(CoreError::new(
                "AmbiguousSource",
                "supply record_owner to disambiguate the source",
            ));
        }
        let mut reference = reference.clone();
        reference.record_owner = Some(owner);
        Ok(Some((
            reference,
            json!({"kind":kind,"updated_at":updated_at,"data":serde_json::from_str::<Value>(&text)?}),
        )))
    }

    fn project(&self, stored: &Stored) -> CoreResult<Option<Item>> {
        let mut item = Item {
            id: stored.id.clone(),
            kind: stored.kind.clone(),
            origin: "personal",
            title: String::new(),
            notes: String::new(),
            location: String::new(),
            timezone: DEFAULT_TIMEZONE.into(),
            due_at: None,
            start_at: None,
            end_at: None,
            completed_at: None,
            source: None,
            created_at: stored.created_at,
            updated_at: stored.updated_at,
        };
        match &stored.body {
            Content::Todo {
                title,
                notes,
                timezone,
                due_at,
                completed_at,
            } => {
                item.title = title.clone();
                item.notes = notes.clone();
                item.timezone = timezone.clone();
                item.due_at = *due_at;
                item.completed_at = *completed_at;
            }
            Content::Event {
                title,
                notes,
                location,
                timezone,
                start_at,
                end_at,
            } => {
                item.title = title.clone();
                item.notes = notes.clone();
                item.location = location.clone();
                item.timezone = timezone.clone();
                item.start_at = Some(*start_at);
                item.end_at = Some(*end_at);
            }
            Content::Link {
                source,
                completed_at,
            } => {
                let Some((reference, record)) = self.source(source)? else {
                    return Ok(None);
                };
                let data = &record["data"];
                let expected = if stored.kind == "todo" {
                    "assignment"
                } else {
                    "timetable"
                };
                if record["kind"] != expected {
                    return Err(CoreError::invalid(
                        "source kind must be assignment or timetable respectively",
                    ));
                }
                item.origin = "source";
                item.source = Some(reference);
                item.completed_at = *completed_at;
                let source_updated = at(
                    record["updated_at"].as_str().ok_or_else(|| {
                        CoreError::new("StorageError", "missing source timestamp")
                    })?,
                    chrono_tz::UTC,
                )?;
                item.updated_at = item.updated_at.max(source_updated);
                item.title = data["title"]
                    .as_str()
                    .or_else(|| data["name"].as_str())
                    .ok_or_else(|| CoreError::invalid("source requires a title or name"))?
                    .into();
                bounded(&item.title, 512, false)?;
                let tz = timezone(
                    data.get("timezone")
                        .map(|v| {
                            v.as_str()
                                .ok_or_else(|| CoreError::invalid("invalid source timezone"))
                        })
                        .transpose()?,
                )?;
                item.timezone = tz.to_string();
                if stored.kind == "todo" {
                    item.due_at = data
                        .get("due_at")
                        .filter(|v| !v.is_null())
                        .map(|v| {
                            at(
                                v.as_str().ok_or_else(|| {
                                    CoreError::invalid("invalid assignment due_at")
                                })?,
                                tz,
                            )
                        })
                        .transpose()?;
                } else {
                    let start = data["start_at"].as_str().ok_or_else(|| {
                        CoreError::invalid("timetable source needs normalized start_at")
                    })?;
                    let end = data["end_at"].as_str().ok_or_else(|| {
                        CoreError::invalid("timetable source needs normalized end_at")
                    })?;
                    let (start, end) = interval(start, end, tz)?;
                    item.start_at = Some(start);
                    item.end_at = Some(end);
                    item.location = data["location"].as_str().unwrap_or("").into();
                    bounded(&item.location, 1_024, true)?;
                }
                // Only allowlisted presentation fields are projected, never raw payloads/URLs.
            }
        }
        Ok(Some(item))
    }

    fn all(&self, kind: &str) -> CoreResult<Vec<Item>> {
        let mut stmt = self.db.prepare("SELECT id FROM organizer_items WHERE owner=? AND kind=? ORDER BY created_at,id LIMIT 2001")?;
        let ids = stmt
            .query_map(params![self.owner, kind], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        if ids.len() > MAX_ITEMS as usize {
            return Err(quota());
        }
        let mut result = Vec::new();
        for id in ids {
            if let Some(item) = self.project(&self.load(&id, Some(kind))?)? {
                result.push(item);
            }
        }
        Ok(result)
    }

    fn filtered(&self, kind: &str, p: &ListInput) -> CoreResult<Vec<Item>> {
        let range = window(
            p.from.as_deref(),
            p.to.as_deref(),
            timezone(p.timezone.as_deref())?,
        )?;
        let mut items = self.all(kind)?;
        items.retain(|i| {
            if kind == "todo" && p.completed.is_some_and(|c| c != i.completed_at.is_some()) {
                return false;
            }
            match range {
                None => true,
                Some((from, to)) => {
                    if kind == "event" {
                        i.start_at.unwrap() < to && i.end_at.unwrap() > from
                    } else {
                        i.due_at.is_some_and(|t| t >= from && t < to)
                    }
                }
            }
        });
        items.sort_by_key(|i| (i.start_at.or(i.due_at), i.id.clone()));
        Ok(items)
    }

    fn conflicts(&self, p: ConflictInput) -> CoreResult<Value> {
        let tz = timezone(p.timezone.as_deref())?;
        let list = ListInput {
            from: p.from,
            to: p.to,
            timezone: Some(tz.to_string()),
            ..Default::default()
        };
        let mut items = self.filtered("event", &list)?;
        let mut result = Vec::new();
        if let Some(candidate) = p.candidate {
            let (start, end) = interval(&candidate.start_at, &candidate.end_at, tz)?;
            if let Some(id) = &candidate.exclude_id {
                bounded(id, 128, false)?;
            }
            for item in items {
                if candidate.exclude_id.as_deref() == Some(item.id.as_str()) {
                    continue;
                }
                if item.start_at.unwrap() < end && item.end_at.unwrap() > start {
                    result.push(json!({"id":item.id,"start_at":start.max(item.start_at.unwrap()),"end_at":end.min(item.end_at.unwrap())}));
                }
            }
        } else {
            items.sort_by_key(|i| (i.start_at, i.id.clone()));
            for (n, left) in items.iter().enumerate() {
                for right in items
                    .iter()
                    .skip(n + 1)
                    .take_while(|r| r.start_at.unwrap() < left.end_at.unwrap())
                {
                    if result.len() >= 5_000 {
                        return Err(quota());
                    }
                    result.push(json!({"left_id":left.id,"right_id":right.id,"start_at":left.start_at.max(right.start_at),"end_at":left.end_at.min(right.end_at)}));
                }
            }
        }
        Ok(json!({"conflicts":result}))
    }

    fn cancel_item_reminders(&self, id: &str) -> CoreResult<()> {
        self.db.execute("UPDATE organizer_reminders SET state='cancelled' WHERE owner=? AND item_id=? AND state='pending'",params![self.owner,id])?;
        Ok(())
    }
}

fn record_acl(principal: &Principal, grant: &Grant) -> (String, Vec<rusqlite::types::Value>) {
    if principal.is_owner() {
        return ("1=1".into(), Vec::new());
    }
    let mut values = Vec::new();
    values.extend(grant.account_ids.iter().cloned().map(Into::into));
    values.push(principal.id.clone().into());
    values.extend(grant.source_ids.iter().cloned().map(Into::into));
    let mut sql = format!(
        "((records.account_id<>'' AND records.account_id IN ({})) OR (records.account_id='' AND (records.owner=? OR records.source_id IN ({}))))",
        placeholders(grant.account_ids.len()),
        placeholders(grant.source_ids.len())
    );
    // Match Store::records, including legacy mail sources that predate read labels.
    // This predicate is shared by source projection and the correlated reminder/
    // activity EXISTS queries: canonical bodies never cross an ACL boundary first.
    if !grant.allows("mail.read") {
        sql.push_str(" AND records.kind NOT LIKE 'mail.%' AND records.source_id NOT LIKE 'mail.%'");
    }
    let allowed: Vec<_> = grant
        .capabilities
        .iter()
        .filter(|cap| grant.allows(cap))
        .collect();
    sql.push_str(&format!(
        " AND NOT EXISTS(SELECT 1 FROM source_access acl,json_each(acl.capabilities) needed WHERE acl.owner=records.owner AND acl.source_id=records.source_id AND needed.value NOT IN ({}))",
        placeholders(allowed.len())
    ));
    values.extend(allowed.into_iter().cloned().map(Into::into));
    (format!("({sql})"), values)
}

fn placeholders(count: usize) -> String {
    vec!["?"; count].join(",")
}
fn decode<T: DeserializeOwned>(input: Value) -> CoreResult<T> {
    serde_json::from_value(input)
        .map_err(|_| CoreError::invalid("invalid organizer parameters or unknown fields"))
}
fn bounded(value: &str, max: usize, empty: bool) -> CoreResult<()> {
    if value.len() > max
        || (!empty && value.trim().is_empty())
        || value
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\r' | '\n' | '\t'))
    {
        return Err(CoreError::invalid(
            "organizer text exceeds limits or contains invalid characters",
        ));
    }
    Ok(())
}
fn timezone(value: Option<&str>) -> CoreResult<Tz> {
    value
        .unwrap_or(DEFAULT_TIMEZONE)
        .parse()
        .map_err(|_| CoreError::invalid("invalid IANA timezone"))
}
fn at(value: &str, tz: Tz) -> CoreResult<DateTime<Utc>> {
    if value.len() > 64 {
        return Err(CoreError::invalid("invalid date-time"));
    }
    let instant = if let Ok(d) = DateTime::parse_from_rfc3339(value) {
        d.with_timezone(&Utc)
    } else {
        let naive = NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f")
            .or_else(|_| NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M"))
            .map_err(|_| CoreError::invalid("date-time requires RFC3339 or local ISO date-time"))?;
        match tz.from_local_datetime(&naive) {
            LocalResult::Single(d) => d.with_timezone(&Utc),
            _ => {
                return Err(CoreError::invalid(
                    "ambiguous or nonexistent local time; supply an explicit RFC3339 offset",
                ));
            }
        }
    };
    if !(1900..=9999).contains(&instant.year()) {
        return Err(CoreError::invalid(
            "date-time year must be 1900 through 9999",
        ));
    }
    // Persist exactly the millisecond precision used by SQL ordering and deduplication.
    from_millis(instant.timestamp_millis())
}
fn interval(start: &str, end: &str, tz: Tz) -> CoreResult<(DateTime<Utc>, DateTime<Utc>)> {
    let (start, end) = (at(start, tz)?, at(end, tz)?);
    if start.timestamp_subsec_millis() != 0 || end.timestamp_subsec_millis() != 0 {
        return Err(CoreError::invalid(
            "calendar interval boundaries require whole seconds",
        ));
    }
    if end <= start || (end - start).num_seconds() > 366 * 86_400 {
        return Err(CoreError::invalid(
            "interval must be positive and at most 366 days",
        ));
    }
    Ok((start, end))
}
fn window(
    from: Option<&str>,
    to: Option<&str>,
    tz: Tz,
) -> CoreResult<Option<(DateTime<Utc>, DateTime<Utc>)>> {
    match (from, to) {
        (None, None) => Ok(None),
        (Some(from), Some(to)) => Ok(Some(interval(from, to, tz)?)),
        _ => Err(CoreError::invalid("from and to must be supplied together")),
    }
}
fn clock_now() -> DateTime<Utc> {
    DateTime::from_timestamp_millis(Utc::now().timestamp_millis())
        .expect("current UTC time is representable")
}
fn from_millis(value: i64) -> CoreResult<DateTime<Utc>> {
    DateTime::from_timestamp_millis(value)
        .ok_or_else(|| CoreError::new("StorageError", "invalid stored date-time"))
}
fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
fn not_found() -> CoreError {
    CoreError::new("NotFound", "organizer item not found")
}
fn quota() -> CoreError {
    CoreError::new("LimitExceeded", "organizer quota exceeded")
}
fn yes() -> bool {
    true
}
fn page_limit(limit: Option<usize>) -> CoreResult<usize> {
    let limit = limit.unwrap_or(50);
    if !(1..=MAX_BATCH).contains(&limit) {
        return Err(CoreError::invalid("limit must be 1 through 500"));
    }
    Ok(limit)
}

fn ics_text(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .replace('\n', "\\n")
        .replace(';', "\\;")
        .replace(',', "\\,")
}
fn ics_line(out: &mut String, line: &str) {
    let mut octets = 0;
    for c in line.chars() {
        if octets + c.len_utf8() > 75 {
            out.push_str("\r\n ");
            octets = 1;
        }
        out.push(c);
        octets += c.len_utf8();
    }
    out.push_str("\r\n");
}
fn export_ics(items: &[Item]) -> String {
    let mut out = String::new();
    for line in [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//dansheng-core//Local Organizer//EN",
        "CALSCALE:GREGORIAN",
    ] {
        ics_line(&mut out, line);
    }
    for item in items {
        let component = if item.kind == "todo" {
            "VTODO"
        } else {
            "VEVENT"
        };
        ics_line(&mut out, &format!("BEGIN:{component}"));
        ics_line(&mut out, &format!("UID:{}@dansheng.local", item.id));
        ics_line(
            &mut out,
            &format!("DTSTAMP:{}", item.updated_at.format("%Y%m%dT%H%M%SZ")),
        );
        ics_line(
            &mut out,
            &format!("CREATED:{}", item.created_at.format("%Y%m%dT%H%M%SZ")),
        );
        ics_line(
            &mut out,
            &format!("LAST-MODIFIED:{}", item.updated_at.format("%Y%m%dT%H%M%SZ")),
        );
        ics_line(&mut out, &format!("SUMMARY:{}", ics_text(&item.title)));
        ics_line(&mut out, &format!("DESCRIPTION:{}", ics_text(&item.notes)));
        // UTC needs no VTIMEZONE definition. Retain the IANA display zone as TEXT metadata.
        ics_line(
            &mut out,
            &format!("X-DANSHENG-TIMEZONE:{}", ics_text(&item.timezone)),
        );
        if item.kind == "event" {
            ics_line(
                &mut out,
                &format!(
                    "DTSTART:{}",
                    item.start_at.unwrap().format("%Y%m%dT%H%M%SZ")
                ),
            );
            ics_line(
                &mut out,
                &format!("DTEND:{}", item.end_at.unwrap().format("%Y%m%dT%H%M%SZ")),
            );
            ics_line(&mut out, &format!("LOCATION:{}", ics_text(&item.location)));
        } else {
            if let Some(due) = item.due_at {
                ics_line(&mut out, &format!("DUE:{}", due.format("%Y%m%dT%H%M%SZ")));
            }
            ics_line(
                &mut out,
                if item.completed_at.is_some() {
                    "STATUS:COMPLETED"
                } else {
                    "STATUS:NEEDS-ACTION"
                },
            );
            if let Some(completed) = item.completed_at {
                ics_line(
                    &mut out,
                    &format!("COMPLETED:{}", completed.format("%Y%m%dT%H%M%SZ")),
                );
            }
        }
        ics_line(&mut out, &format!("END:{component}"));
    }
    ics_line(&mut out, "END:VCALENDAR");
    out
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ScheduleInput {
    item_id: String,
    at: String,
    #[serde(default)]
    timezone: Option<String>,
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReminderListInput {
    #[serde(default)]
    item_id: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    offset: usize,
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct DueInput {
    #[serde(default)]
    now: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
}
#[derive(Serialize)]
struct Reminder {
    id: String,
    item_id: String,
    at: DateTime<Utc>,
    timezone: String,
    state: String,
    created_at: DateTime<Utc>,
    fired_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SyncInput {
    #[serde(default)]
    account_id: String,
    source_id: String,
    items: Vec<ActivityInput>,
    /// The initial import can span pages/restarts. Only its final page sets this.
    #[serde(default = "yes")]
    complete: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ActivityInput {
    external_id: String,
    title: String,
    kind: String,
    occurred_at: String,
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActivityListInput {
    #[serde(default)]
    account_id: Option<String>,
    #[serde(default)]
    source_id: Option<String>,
    #[serde(default)]
    unread: Option<bool>,
    #[serde(default)]
    archived: bool,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    offset: usize,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ActivityStateInput {
    id: String,
    #[serde(default = "yes")]
    value: bool,
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct LimitInput {
    #[serde(default)]
    limit: Option<usize>,
}
#[derive(Serialize)]
struct Activity {
    id: String,
    account_id: String,
    source_id: String,
    external_id: String,
    title: String,
    kind: String,
    occurred_at: DateTime<Utc>,
    notification: String,
    read_at: Option<DateTime<Utc>>,
    archived_at: Option<DateTime<Utc>>,
    item_id: Option<String>,
}

impl Context<'_> {
    /// Applied in SQL to reminders and reminder-generated activities as well.
    fn item_visibility(&self) -> (String, Vec<rusqlite::types::Value>) {
        let kinds = format!(
            "((oi.kind='todo' AND {}) OR (oi.kind='event' AND {}))",
            i32::from(self.principal.is_owner() || self.grant.allows("todo.read")),
            i32::from(self.principal.is_owner() || self.grant.allows("calendar.read"))
        );
        if !self.principal.is_owner() && !self.grant.allows("sources.read") {
            return (format!("({kinds} AND oi.record_owner IS NULL)"), Vec::new());
        }
        let (acl, values) = record_acl(self.principal, self.grant);
        (
            format!(
                "({kinds} AND (oi.record_owner IS NULL OR EXISTS(SELECT 1 FROM records WHERE records.owner=oi.record_owner AND records.account_id=oi.account_id AND records.source_id=oi.source_id AND records.external_id=oi.external_id AND {acl})))"
            ),
            values,
        )
    }

    fn reminder_schedule(&self, p: ScheduleInput) -> CoreResult<Value> {
        let stored = self.load(&p.item_id, None)?;
        self.grant.check(
            self.principal,
            if stored.kind == "todo" {
                "todo.read"
            } else {
                "calendar.read"
            },
        )?;
        let item = self.project(&stored)?.ok_or_else(not_found)?;
        if item.completed_at.is_some() {
            return Err(CoreError::invalid("cannot remind a completed TODO"));
        }
        let tz = timezone(p.timezone.as_deref().or(Some(&item.timezone)))?;
        let at = at(&p.at, tz)?;
        let existing: Option<String> = self
            .db
            .query_row(
                "SELECT id FROM organizer_reminders WHERE owner=? AND item_id=? AND at=?",
                params![self.owner, p.item_id, at.timestamp_millis()],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(id) = existing {
            return Ok(serde_json::to_value(self.reminder(&id)?)?);
        }
        let count: i64 = self.db.query_row(
            "SELECT count(*) FROM organizer_reminders WHERE owner=?",
            [self.owner],
            |r| r.get(0),
        )?;
        if count >= 10_000 {
            return Err(quota());
        }
        let id = new_id();
        self.db.execute("INSERT INTO organizer_reminders(owner,id,item_id,at,timezone,state,created_at) VALUES(?,?,?,?,?,'pending',?)",
            params![self.owner,id,p.item_id,at.timestamp_millis(),tz.to_string(),clock_now().timestamp_millis()])?;
        Ok(serde_json::to_value(self.reminder(&id)?)?)
    }

    fn reminder(&self, id: &str) -> CoreResult<Reminder> {
        let row: (String,i64,String,String,i64,Option<i64>)=self.db.query_row(
            "SELECT item_id,at,timezone,state,created_at,fired_at FROM organizer_reminders WHERE owner=? AND id=?",params![self.owner,id],
            |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)))?;
        Ok(Reminder {
            id: id.into(),
            item_id: row.0,
            at: from_millis(row.1)?,
            timezone: row.2,
            state: row.3,
            created_at: from_millis(row.4)?,
            fired_at: row.5.map(from_millis).transpose()?,
        })
    }

    fn reminder_list(&self, p: ReminderListInput) -> CoreResult<Value> {
        let limit = page_limit(p.limit)?;
        if p.offset > 100_000 {
            return Err(CoreError::invalid("offset exceeds limit"));
        }
        if let Some(id) = &p.item_id {
            bounded(id, 128, false)?;
        }
        let (visible, mut acl) = self.item_visibility();
        let sql = format!(
            "SELECT r.id FROM organizer_reminders r JOIN organizer_items oi ON oi.owner=r.owner AND oi.id=r.item_id WHERE r.owner=? AND (? IS NULL OR r.item_id=?) AND {visible} ORDER BY r.at,r.id LIMIT ? OFFSET ?"
        );
        let item_id = p
            .item_id
            .map(Into::into)
            .unwrap_or(rusqlite::types::Value::Null);
        let mut values = vec![self.owner.to_string().into(), item_id.clone(), item_id];
        values.append(&mut acl);
        values.push((limit as i64).into());
        values.push((p.offset as i64).into());
        let mut stmt = self.db.prepare(&sql)?;
        let ids = stmt
            .query_map(params_from_iter(values), |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(json!({"items":ids.iter().map(|id|self.reminder(id)).collect::<CoreResult<Vec<_>>>()?}))
    }

    fn reminders_due(&self, p: DueInput) -> CoreResult<Value> {
        let limit = page_limit(p.limit)?;
        let now = p
            .now
            .as_deref()
            .map(|s| at(s, chrono_tz::UTC))
            .transpose()?
            .unwrap_or_else(clock_now);
        let (visible, mut acl) = self.item_visibility();
        let sql = format!(
            "SELECT r.id,r.item_id FROM organizer_reminders r JOIN organizer_items oi ON oi.owner=r.owner AND oi.id=r.item_id WHERE r.owner=? AND r.state='pending' AND r.at<=? AND {visible} ORDER BY r.at,r.id LIMIT ?"
        );
        let mut values = vec![self.owner.to_string().into(), now.timestamp_millis().into()];
        values.append(&mut acl);
        values.push((limit as i64).into());
        let mut stmt = self.db.prepare(&sql)?;
        let rows = stmt
            .query_map(params_from_iter(values), |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut result = Vec::new();
        for (id, item_id) in rows {
            let item = self
                .project(&self.load(&item_id, None)?)?
                .ok_or_else(not_found)?;
            if item.completed_at.is_some() {
                self.cancel_item_reminders(&item_id)?;
                continue;
            }
            self.activity_quota(1)?;
            let activity_id = new_id();
            let source_account = item
                .source
                .as_ref()
                .map(|s| s.account_id.as_str())
                .unwrap_or("");
            self.db.execute("INSERT INTO organizer_activity(owner,id,account_id,source_id,external_id,title,kind,occurred_at,notification,item_id) VALUES(?,?,?,'organizer.reminders',?,?,'reminder',?,'pending',?)",
                params![self.owner,activity_id,source_account,id,item.title,now.timestamp_millis(),item_id])?;
            self.db.execute("UPDATE organizer_reminders SET state='fired',fired_at=? WHERE owner=? AND id=? AND state='pending'",params![now.timestamp_millis(),self.owner,id])?;
            result.push(json!({"reminder":self.reminder(&id)?,"activity_id":activity_id}));
        }
        Ok(json!({"items":result}))
    }

    fn activity_quota(&self, incoming: i64) -> CoreResult<()> {
        let count: i64 = self.db.query_row(
            "SELECT count(*) FROM organizer_activity WHERE owner=? AND archived_at IS NULL",
            [self.owner],
            |r| r.get(0),
        )?;
        if count + incoming > 10_000 {
            return Err(quota());
        }
        Ok(())
    }

    fn activity_sync(&self, p: SyncInput) -> CoreResult<Value> {
        bounded(&p.account_id, 256, true)?;
        bounded(&p.source_id, 256, false)?;
        if p.source_id == "organizer.reminders" {
            return Err(CoreError::invalid("reserved activity source"));
        }
        self.grant.check_account(
            self.principal,
            if p.account_id.is_empty() {
                None
            } else {
                Some(&p.account_id)
            },
        )?;
        if p.items.len() > MAX_BATCH {
            return Err(quota());
        }
        let mut seen = BTreeSet::new();
        let mut prepared = Vec::new();
        for row in p.items {
            bounded(&row.external_id, 512, false)?;
            bounded(&row.title, 512, false)?;
            bounded(&row.kind, 64, false)?;
            if !seen.insert(row.external_id.clone()) {
                return Err(CoreError::invalid(
                    "duplicate activity external_id in batch",
                ));
            }
            let occurred_at = at(&row.occurred_at, chrono_tz::UTC)?;
            prepared.push((row, occurred_at));
        }
        let initialized: bool=self.db.query_row("SELECT initialized FROM organizer_sync WHERE owner=? AND account_id=? AND source_id=?",params![self.owner,p.account_id,p.source_id],|r|r.get(0)).optional()?.unwrap_or(false);
        let mut inserted = 0;
        let mut notifications = 0;
        for (row, occurred_at) in prepared {
            let existing: Option<String>=self.db.query_row("SELECT id FROM organizer_activity WHERE owner=? AND account_id=? AND source_id=? AND external_id=?",params![self.owner,p.account_id,p.source_id,row.external_id],|r|r.get(0)).optional()?;
            if let Some(id) = existing {
                self.db.execute("UPDATE organizer_activity SET title=?,kind=?,occurred_at=? WHERE owner=? AND id=?",params![row.title,row.kind,occurred_at.timestamp_millis(),self.owner,id])?;
            } else {
                self.activity_quota(1)?;
                self.db.execute("INSERT INTO organizer_activity(owner,id,account_id,source_id,external_id,title,kind,occurred_at,notification) VALUES(?,?,?,?,?,?,?,?,?)",
                    params![self.owner,new_id(),p.account_id,p.source_id,row.external_id,row.title,row.kind,occurred_at.timestamp_millis(),if initialized { "pending" } else { "suppressed" }])?;
                inserted += 1;
                if initialized {
                    notifications += 1;
                }
            }
        }
        self.db.execute("INSERT INTO organizer_sync(owner,account_id,source_id,initialized) VALUES(?,?,?,?) ON CONFLICT(owner,account_id,source_id) DO UPDATE SET initialized=max(organizer_sync.initialized,excluded.initialized)",params![self.owner,p.account_id,p.source_id,p.complete])?;
        Ok(
            json!({"inserted":inserted,"notifications":notifications,"initial_sync":!initialized,"initialized":initialized || p.complete}),
        )
    }

    /// An inbox row is personal AND must remain inside the live account grant.
    fn activity_acl(&self) -> (String, Vec<rusqlite::types::Value>) {
        let mut values = vec![self.owner.to_string().into()];
        let mut sql = "a.owner=?".to_string();
        if !self.principal.is_owner() {
            sql.push_str(&format!(
                " AND (a.account_id='' OR a.account_id IN ({}))",
                placeholders(self.grant.account_ids.len())
            ));
            values.extend(self.grant.account_ids.iter().cloned().map(Into::into));
        }
        let (visible, mut acl) = self.item_visibility();
        sql.push_str(&format!(" AND (a.item_id IS NULL OR EXISTS(SELECT 1 FROM organizer_items oi WHERE oi.owner=a.owner AND oi.id=a.item_id AND {visible}))"));
        values.append(&mut acl);
        (sql, values)
    }

    fn activity(&self, id: &str) -> CoreResult<Activity> {
        type ActivityRow = (
            String,
            String,
            String,
            String,
            String,
            i64,
            String,
            Option<i64>,
            Option<i64>,
            Option<String>,
        );
        // This internal serializer is called only after an ACL-filtered SQL lookup.
        let row: ActivityRow=self.db.query_row(
            "SELECT account_id,source_id,external_id,title,kind,occurred_at,notification,read_at,archived_at,item_id FROM organizer_activity WHERE owner=? AND id=?",params![self.owner,id],
            |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?,r.get(9)?)))?;
        Ok(Activity {
            id: id.into(),
            account_id: row.0,
            source_id: row.1,
            external_id: row.2,
            title: row.3,
            kind: row.4,
            occurred_at: from_millis(row.5)?,
            notification: row.6,
            read_at: row.7.map(from_millis).transpose()?,
            archived_at: row.8.map(from_millis).transpose()?,
            item_id: row.9,
        })
    }

    fn activity_list(&self, p: ActivityListInput) -> CoreResult<Value> {
        let limit = page_limit(p.limit)?;
        if p.offset > 100_000 {
            return Err(CoreError::invalid("offset exceeds limit"));
        }
        if let Some(account) = &p.account_id {
            bounded(account, 256, true)?;
        }
        if let Some(source) = &p.source_id {
            bounded(source, 256, false)?;
        }
        let (mut sql, mut values) = self.activity_acl();
        sql.push_str(" AND (a.archived_at IS NOT NULL)=?");
        values.push(p.archived.into());
        if let Some(unread) = p.unread {
            sql.push_str(" AND (a.read_at IS NULL)=?");
            values.push(unread.into());
        }
        if let Some(account) = p.account_id {
            sql.push_str(" AND a.account_id=?");
            values.push(account.into());
        }
        if let Some(source) = p.source_id {
            sql.push_str(" AND a.source_id=?");
            values.push(source.into());
        }
        let total: i64 = self.db.query_row(
            &format!("SELECT count(*) FROM organizer_activity a WHERE {sql}"),
            params_from_iter(values.iter()),
            |r| r.get(0),
        )?;
        sql.push_str(" ORDER BY a.occurred_at DESC,a.id LIMIT ? OFFSET ?");
        values.push((limit as i64).into());
        values.push((p.offset as i64).into());
        let mut stmt = self.db.prepare(&format!(
            "SELECT a.id FROM organizer_activity a WHERE {sql}"
        ))?;
        let ids = stmt
            .query_map(params_from_iter(values), |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(
            json!({"items":ids.iter().map(|id|self.activity(id)).collect::<CoreResult<Vec<_>>>()?,"total":total}),
        )
    }

    fn activity_state(&self, method: &str, p: ActivityStateInput) -> CoreResult<Value> {
        bounded(&p.id, 128, false)?;
        let (sql, mut values) = self.activity_acl();
        values.push(p.id.clone().into());
        let present: bool = self.db.query_row(
            &format!("SELECT EXISTS(SELECT 1 FROM organizer_activity a WHERE {sql} AND a.id=?)"),
            params_from_iter(values),
            |r| r.get(0),
        )?;
        if !present {
            return Err(not_found());
        }
        if method == "activity.archive" && !p.value && self.activity(&p.id)?.archived_at.is_some() {
            self.activity_quota(1)?;
        }
        let field = if method == "activity.read" {
            "read_at"
        } else {
            "archived_at"
        };
        let at = if p.value {
            Some(clock_now().timestamp_millis())
        } else {
            None
        };
        // Reading/archiving consumes a pending alert; undoing local state never re-arms it.
        self.db.execute(&format!("UPDATE organizer_activity SET {field}=CASE WHEN ? THEN coalesce({field},?) ELSE NULL END,notification=CASE WHEN ? AND notification='pending' THEN 'claimed' ELSE notification END WHERE owner=? AND id=?"),params![p.value,at,p.value,self.owner,p.id])?;
        if p.value {
            self.db.execute("UPDATE organizer_deliveries SET state='cancelled',lease_id=NULL,lease_expires_at=NULL WHERE owner=? AND activity_id=? AND state IN ('ready','leased','uncertain')",params![self.owner,p.id])?;
        }
        Ok(serde_json::to_value(self.activity(&p.id)?)?)
    }

    fn activity_notifications(&self, p: LimitInput) -> CoreResult<Value> {
        let limit = page_limit(p.limit)?;
        let (sql, mut values) = self.activity_acl();
        values.push((limit as i64).into());
        let mut stmt=self.db.prepare(&format!("SELECT a.id FROM organizer_activity a WHERE {sql} AND a.notification='pending' AND a.read_at IS NULL AND a.archived_at IS NULL ORDER BY a.occurred_at,a.id LIMIT ?"))?;
        let ids = stmt
            .query_map(params_from_iter(values), |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let mut items = Vec::new();
        for id in ids {
            self.db.execute("UPDATE organizer_activity SET notification='claimed' WHERE owner=? AND id=? AND notification='pending'",params![self.owner,id])?;
            items.push(self.activity(&id)?);
        }
        Ok(json!({"items":items}))
    }
}

/// Native-host API only: never add these helpers to wire dispatch or plugin APIs.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryChannel {
    Event,
    Platform,
}
impl DeliveryChannel {
    fn as_str(self) -> &'static str {
        match self {
            Self::Event => "event",
            Self::Platform => "platform",
        }
    }
    fn parse(value: &str) -> CoreResult<Self> {
        match value {
            "event" => Ok(Self::Event),
            "platform" => Ok(Self::Platform),
            _ => Err(CoreError::new("StorageError", "invalid delivery channel")),
        }
    }
}

#[derive(Clone, Copy)]
pub struct NotificationOptions {
    pub limit: usize,
    /// Five through 300 seconds; expired attempts require explicit reconciliation.
    pub lease_seconds: u32,
    /// Set only if the host actually supplies notifications.show. Never opens a GUI.
    pub include_platform: bool,
}
impl Default for NotificationOptions {
    fn default() -> Self {
        Self {
            limit: 50,
            lease_seconds: 60,
            include_platform: false,
        }
    }
}

#[derive(Clone, Serialize)]
pub struct NotificationClaim {
    /// Profile data is represented by the intrinsic owner, never its creating agent.
    pub principal: Principal,
    pub activity_id: String,
    pub channel: DeliveryChannel,
    /// Stable across confirmed-nondelivery retries. Pass to the sink for deduplication.
    pub delivery_key: String,
    /// Internal receipt authority. Do not put this token in events/logs/platform payloads.
    #[serde(skip_serializing)]
    pub lease_id: String,
    pub lease_expires_at: DateTime<Utc>,
    pub attempt: i64,
    pub activity: Value,
}

#[derive(Clone, Debug, Serialize)]
pub struct DeliveryReceipt {
    pub principal: Principal,
    pub activity_id: String,
    pub channel: DeliveryChannel,
    pub delivery_key: String,
    pub state: String,
    pub attempt: i64,
    pub lease_expires_at: Option<DateTime<Utc>>,
    pub next_at: DateTime<Utc>,
    pub delivered_at: Option<DateTime<Utc>>,
    pub event_sequence: Option<i64>,
}

#[derive(Serialize)]
pub struct SchedulerIssue {
    pub principal: Principal,
    pub code: String,
}
#[derive(Serialize)]
pub struct NotificationBatch {
    pub claims: Vec<NotificationClaim>,
    /// One bad/revoked private source cannot roll back another owner's work.
    pub issues: Vec<SchedulerIssue>,
    pub scanned_owners: usize,
}

#[derive(Clone, Copy)]
pub enum DeliveryOutcome {
    /// Event receipts include the Store::event sequence; platform receipts use None.
    Delivered { event_sequence: Option<i64> },
    /// Only use after confirmed nondelivery; bounds are one through 3600 seconds.
    Retry { after_seconds: u32 },
    /// Timeout or uncertain external outcome: never automatically resend.
    Uncertain,
}

fn current_grant(db: &Connection, principal: &Principal) -> CoreResult<Grant> {
    if principal.is_owner() {
        return Ok(Grant::default());
    }
    let value: Option<String> = db
        .query_row(
            "SELECT data FROM grants WHERE subject=?",
            [&principal.id],
            |r| r.get(0),
        )
        .optional()?;
    value
        .map(|s| {
            serde_json::from_str(&s)
                .map_err(|_| CoreError::new("StorageError", "invalid stored organizer grant"))
        })
        .transpose()
        .map(|g| g.unwrap_or_default())
}
fn permitted(p: &Principal, g: &Grant, cap: &str) -> bool {
    p.is_owner() || g.allows(cap)
}
fn scheduler_now(now: DateTime<Utc>) -> CoreResult<DateTime<Utc>> {
    at(&now.to_rfc3339(), chrono_tz::UTC)
}

/// Collect due reminder inbox entries and claim notification work across profile/private owners.
/// Reloads grants inside the same transaction; performs no publication or platform calls.
pub fn claim_due_notifications(
    store: &Store,
    now: DateTime<Utc>,
    options: NotificationOptions,
) -> CoreResult<NotificationBatch> {
    page_limit(Some(options.limit))?;
    if !(5..=300).contains(&options.lease_seconds) {
        return Err(CoreError::invalid(
            "notification lease must be 5 through 300 seconds",
        ));
    }
    let now = scheduler_now(now)?;
    let until = now
        .checked_add_signed(chrono::Duration::seconds(options.lease_seconds.into()))
        .filter(|d| d.year() <= 9999)
        .ok_or_else(|| CoreError::invalid("notification lease exceeds date-time range"))?;
    initialize(store)?;
    store.with(|db| {
        let tx=db.transaction()?;
        // A crash may have followed a successful sink call. Expiry is uncertainty, not retry authority.
        tx.execute("UPDATE organizer_deliveries SET state='uncertain' WHERE state='leased' AND lease_expires_at<=?",[now.timestamp_millis()])?;
        let cursor: String=tx.query_row("SELECT last_owner FROM organizer_scheduler WHERE singleton=1",[],|r|r.get(0))?;
        let owners_sql="SELECT owner FROM (SELECT owner FROM organizer_reminders WHERE state='pending' AND at<=? UNION SELECT owner FROM organizer_activity WHERE notification='pending' AND read_at IS NULL AND archived_at IS NULL UNION SELECT owner FROM organizer_deliveries WHERE state='ready' AND next_at<=?) WHERE owner>? ORDER BY owner LIMIT 100";
        let read_owners=|cursor:&str|->CoreResult<Vec<String>> {
            Ok(tx.prepare(owners_sql)?.query_map(params![now.timestamp_millis(),now.timestamp_millis(),cursor],|r|r.get(0))?.collect::<Result<Vec<_>,_>>()?)
        };
        let mut owners=read_owners(&cursor)?;
        if owners.is_empty() && !cursor.is_empty() { owners=read_owners("")?; }
        let mut batch=NotificationBatch { claims:Vec::new(),issues:Vec::new(),scanned_owners:0 };
        for owner in owners {
            if batch.claims.len()>=options.limit { break; }
            let principal=stored_principal(&owner)?;
            tx.execute("UPDATE organizer_scheduler SET last_owner=? WHERE singleton=1",[&owner])?;
            batch.scanned_owners+=1;
            tx.execute_batch("SAVEPOINT organizer_owner_tick;")?;
            let result=(||->CoreResult<Vec<NotificationClaim>> {
                let grant=current_grant(&tx,&principal)?;
                let ctx=Context { db:&tx,owner:&owner,principal:&principal,grant:&grant };
                let remaining=(options.limit-batch.claims.len()).min(50);
                if permitted(&principal,&grant,"reminders.write") {
                    ctx.reminders_due(DueInput { now:Some(now.to_rfc3339()),limit:Some(remaining) })?;
                }
                if !permitted(&principal,&grant,"activity.write") || !permitted(&principal,&grant,"activity.read") { return Ok(Vec::new()); }
                ctx.claim_notifications(now,until,remaining,options.include_platform && permitted(&principal,&grant,"notifications.show"))
            })();
            match result {
                Ok(claims)=> { tx.execute_batch("RELEASE organizer_owner_tick;")?; batch.claims.extend(claims); }
                Err(e)=> { tx.execute_batch("ROLLBACK TO organizer_owner_tick; RELEASE organizer_owner_tick;")?; batch.issues.push(SchedulerIssue { principal,code:e.code }); }
            }
        }
        if batch.scanned_owners==0 { tx.execute("UPDATE organizer_scheduler SET last_owner='' WHERE singleton=1",[])?; }
        tx.commit()?;
        Ok(batch)
    })
}

impl Context<'_> {
    fn scheduler_activity_acl(&self) -> (String, Vec<rusqlite::types::Value>) {
        let (mut acl, mut values) = self.activity_acl();
        acl.push_str(" AND a.read_at IS NULL AND a.archived_at IS NULL AND (a.source_id<>'organizer.reminders' OR ?)");
        values.push(permitted(self.principal, self.grant, "reminders.write").into());
        (acl, values)
    }
    fn claim_notifications(
        &self,
        now: DateTime<Utc>,
        until: DateTime<Utc>,
        limit: usize,
        platform: bool,
    ) -> CoreResult<Vec<NotificationClaim>> {
        let (acl, mut values) = self.scheduler_activity_acl();
        values.push((limit as i64).into());
        let sql = format!(
            "SELECT a.id FROM organizer_activity a WHERE {acl} AND a.notification='pending' AND NOT EXISTS(SELECT 1 FROM organizer_deliveries d WHERE d.owner=a.owner AND d.activity_id=a.id) ORDER BY a.occurred_at,a.id LIMIT ?"
        );
        let ids = self
            .db
            .prepare(&sql)?
            .query_map(params_from_iter(values), |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        for id in ids {
            for channel in [DeliveryChannel::Event, DeliveryChannel::Platform] {
                if channel == DeliveryChannel::Platform && !platform {
                    continue;
                }
                self.db.execute("INSERT INTO organizer_deliveries(owner,activity_id,channel,delivery_key,state,next_at) VALUES(?,?,?,?,'ready',?)",params![self.owner,id,channel.as_str(),new_id(),now.timestamp_millis()])?;
            }
            self.db.execute("UPDATE organizer_activity SET notification='claimed' WHERE owner=? AND id=? AND notification='pending'",params![self.owner,id])?;
        }
        let (acl, mut values) = self.scheduler_activity_acl();
        values.extend([
            now.timestamp_millis().into(),
            platform.into(),
            (limit as i64).into(),
        ]);
        let sql = format!(
            "SELECT d.delivery_key FROM organizer_deliveries d JOIN organizer_activity a ON a.owner=d.owner AND a.id=d.activity_id WHERE {acl} AND d.state='ready' AND d.next_at<=? AND (d.channel='event' OR ?) ORDER BY d.next_at,a.occurred_at,a.id,d.channel LIMIT ?"
        );
        let keys = self
            .db
            .prepare(&sql)?
            .query_map(params_from_iter(values), |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let mut claims = Vec::new();
        for key in keys {
            let lease_id = new_id();
            self.db.execute("UPDATE organizer_deliveries SET state='leased',attempt=attempt+1,lease_id=?,lease_expires_at=? WHERE owner=? AND delivery_key=? AND state='ready'",params![lease_id,until.timestamp_millis(),self.owner,key])?;
            let receipt = delivery_receipt(self.db, &key)?;
            claims.push(NotificationClaim {
                principal: self.principal.clone(),
                activity_id: receipt.activity_id.clone(),
                channel: receipt.channel,
                delivery_key: key,
                lease_id,
                lease_expires_at: until,
                attempt: receipt.attempt,
                activity: serde_json::to_value(self.activity(&receipt.activity_id)?)?,
            });
        }
        Ok(claims)
    }
}

fn delivery_receipt(db: &Connection, key: &str) -> CoreResult<DeliveryReceipt> {
    type ReceiptRow = (
        String,
        String,
        String,
        String,
        i64,
        Option<i64>,
        i64,
        Option<i64>,
        Option<i64>,
    );
    let row:Option<ReceiptRow>=db.query_row("SELECT owner,activity_id,channel,state,attempt,lease_expires_at,next_at,delivered_at,event_sequence FROM organizer_deliveries WHERE delivery_key=?",[key],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?))).optional()?;
    let (owner, activity_id, channel, state, attempt, expires, next, delivered, sequence) =
        row.ok_or_else(not_found)?;
    Ok(DeliveryReceipt {
        principal: stored_principal(&owner)?,
        activity_id,
        channel: DeliveryChannel::parse(&channel)?,
        delivery_key: key.into(),
        state,
        attempt,
        lease_expires_at: expires.map(from_millis).transpose()?,
        next_at: from_millis(next)?,
        delivered_at: delivered.map(from_millis).transpose()?,
        event_sequence: sequence,
    })
}

/// Trusted inspection of durable delivery metadata, including ambiguous expired attempts.
pub fn inspect_notification(store: &Store, delivery_key: &str) -> CoreResult<DeliveryReceipt> {
    bounded(delivery_key, 128, false)?;
    initialize(store)?;
    store.with(|db| delivery_receipt(db, delivery_key))
}

/// Recheck current grants, source visibility, local read/archive state, and live lease
/// immediately before a host sink call. No lease payload is trusted as current authority.
pub fn notification_claim_is_current(
    store: &Store,
    claim: &NotificationClaim,
    now: DateTime<Utc>,
) -> CoreResult<bool> {
    let now = scheduler_now(now)?;
    initialize(store)?;
    store.with(|db| {
        let receipt=delivery_receipt(db,&claim.delivery_key)?;
        if receipt.state!="leased" || receipt.lease_expires_at.is_none_or(|at|at<=now) { return Ok(false); }
        let owner=serde_json::to_string(&(&receipt.principal.kind,&receipt.principal.id))?;
        let valid:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM organizer_deliveries WHERE owner=? AND delivery_key=? AND lease_id=?)",params![owner,claim.delivery_key,claim.lease_id],|r|r.get(0))?;
        if !valid { return Ok(false); }
        let grant=current_grant(db,&receipt.principal)?;
        if !permitted(&receipt.principal,&grant,"activity.read") || !permitted(&receipt.principal,&grant,"activity.write") || (receipt.channel==DeliveryChannel::Platform && !permitted(&receipt.principal,&grant,"notifications.show")) { return Ok(false); }
        let ctx=Context { db,owner:&owner,principal:&receipt.principal,grant:&grant };
        let (acl,mut values)=ctx.scheduler_activity_acl(); values.push(receipt.activity_id.into());
        Ok(db.query_row(&format!("SELECT EXISTS(SELECT 1 FROM organizer_activity a WHERE {acl} AND a.id=?)"),params_from_iter(values),|r|r.get(0))?)
    })
}

fn apply_outcome(
    db: &Connection,
    key: &str,
    channel: DeliveryChannel,
    outcome: DeliveryOutcome,
    now: DateTime<Utc>,
) -> CoreResult<()> {
    match outcome {
        DeliveryOutcome::Delivered { event_sequence } => {
            if (channel == DeliveryChannel::Event && event_sequence.is_none_or(|n| n < 1))
                || (channel == DeliveryChannel::Platform && event_sequence.is_some())
            {
                return Err(CoreError::invalid(
                    "event delivery requires a positive event sequence; platform delivery has no event sequence",
                ));
            }
            db.execute("UPDATE organizer_deliveries SET state='delivered',delivered_at=?,event_sequence=? WHERE delivery_key=?",params![now.timestamp_millis(),event_sequence,key])?;
        }
        DeliveryOutcome::Retry { after_seconds } => {
            if !(1..=3600).contains(&after_seconds) {
                return Err(CoreError::invalid(
                    "retry delay must be 1 through 3600 seconds",
                ));
            }
            let next = now
                .checked_add_signed(chrono::Duration::seconds(after_seconds.into()))
                .filter(|d| d.year() <= 9999)
                .ok_or_else(|| CoreError::invalid("retry exceeds date-time range"))?;
            db.execute(
                "UPDATE organizer_deliveries SET state='ready',next_at=? WHERE delivery_key=?",
                params![next.timestamp_millis(), key],
            )?;
        }
        DeliveryOutcome::Uncertain => {
            db.execute(
                "UPDATE organizer_deliveries SET state='uncertain' WHERE delivery_key=?",
                [key],
            )?;
        }
    }
    Ok(())
}

/// Acknowledge one channel of one live attempt. This records facts, not grant authority:
/// a completed sink call can be receipted even if the grant was revoked during that call.
pub fn finish_notification(
    store: &Store,
    claim: &NotificationClaim,
    outcome: DeliveryOutcome,
    now: DateTime<Utc>,
) -> CoreResult<DeliveryReceipt> {
    let now = scheduler_now(now)?;
    initialize(store)?;
    store.with(|db| {
        let tx = db.transaction()?;
        let receipt = delivery_receipt(&tx, &claim.delivery_key)?;
        let token: Option<String> = tx.query_row(
            "SELECT lease_id FROM organizer_deliveries WHERE delivery_key=?",
            [&claim.delivery_key],
            |r| r.get(0),
        )?;
        if token.as_deref() != Some(claim.lease_id.as_str()) {
            return Err(CoreError::new(
                "LeaseLost",
                "notification attempt no longer owns the lease",
            ));
        }
        // Repeated acknowledgements never rearm delivered work or move a scheduled retry.
        if receipt.state == "delivered"
            || receipt.state == "ready"
            || (receipt.state == "uncertain" && matches!(outcome, DeliveryOutcome::Uncertain))
        {
            return Ok(receipt);
        }
        if receipt.state != "leased" || receipt.lease_expires_at.is_none_or(|at| at <= now) {
            return Err(CoreError::new(
                "LeaseLost",
                "notification lease is inactive or expired; reconcile the outcome",
            ));
        }
        apply_outcome(&tx, &claim.delivery_key, receipt.channel, outcome, now)?;
        let receipt = delivery_receipt(&tx, &claim.delivery_key)?;
        tx.commit()?;
        Ok(receipt)
    })
}

/// Only after the host has reconciled an uncertain/expired sink outcome. An expired
/// lease never authorizes automatic resubmission. Retry retains the stable delivery key.
pub fn reconcile_notification(
    store: &Store,
    delivery_key: &str,
    outcome: DeliveryOutcome,
    now: DateTime<Utc>,
) -> CoreResult<DeliveryReceipt> {
    bounded(delivery_key, 128, false)?;
    let now = scheduler_now(now)?;
    initialize(store)?;
    store.with(|db| {
        let tx = db.transaction()?;
        let receipt = delivery_receipt(&tx, delivery_key)?;
        if receipt.state == "delivered" {
            return Ok(receipt);
        }
        let expired =
            receipt.state == "leased" && receipt.lease_expires_at.is_some_and(|at| at <= now);
        if receipt.state != "uncertain" && !expired {
            return Err(CoreError::new(
                "ReconciliationRequired",
                "only uncertain or expired deliveries can be reconciled",
            ));
        }
        if matches!(outcome, DeliveryOutcome::Uncertain) {
            return Err(CoreError::invalid(
                "reconciliation requires a known delivered or not-delivered outcome",
            ));
        }
        apply_outcome(&tx, delivery_key, receipt.channel, outcome, now)?;
        let receipt = delivery_receipt(&tx, delivery_key)?;
        tx.commit()?;
        Ok(receipt)
    })
}
