use crate::api::{CoreError, CoreResult, Event, Principal, PrincipalKind};
use crate::policy::Grant;
use chrono::Utc;
use fs2::FileExt;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
};

pub struct Store {
    db: Mutex<Connection>,
    pub directory: PathBuf,
    _owner_lock: std::fs::File,
    _profile_lock: ProfileLock,
}

#[derive(Debug)]
pub struct ProfileLock {
    _file: std::fs::File,
    directory: PathBuf,
}

impl Store {
    /// A stable sibling lock remains valid while an offline restore swaps the
    /// profile directory. Its identity follows the canonical final profile path.
    pub fn profile_path(directory: &Path) -> CoreResult<PathBuf> {
        if directory.as_os_str().is_empty() {
            return Err(CoreError::invalid("profile path is empty"));
        }
        let mut probe = if directory.is_absolute() {
            directory.to_path_buf()
        } else {
            std::env::current_dir()?.join(directory)
        };
        let mut missing = Vec::new();
        while !probe.try_exists()? {
            let leaf = probe
                .file_name()
                .ok_or_else(|| {
                    CoreError::invalid("profile path must have a normal final component")
                })?
                .to_owned();
            missing.push(leaf);
            probe = probe
                .parent()
                .ok_or_else(|| CoreError::invalid("profile parent is missing"))?
                .to_path_buf();
        }
        let mut resolved = std::fs::canonicalize(probe)?;
        for leaf in missing.into_iter().rev() {
            resolved.push(leaf);
        }
        if resolved.parent().is_none() || resolved.file_name().is_none() {
            return Err(CoreError::invalid(
                "a filesystem root cannot be an application profile",
            ));
        }
        Ok(resolved)
    }
    pub fn acquire_profile_lock(directory: &Path) -> CoreResult<ProfileLock> {
        let canonical = Self::profile_path(directory)?;
        let parent = canonical.parent().ok_or_else(|| {
            CoreError::invalid("a filesystem root cannot be an application profile")
        })?;
        // Create only ancestors. The profile leaf may be absent during restore's
        // directory swap and must not be recreated by a refused startup.
        std::fs::create_dir_all(parent)?;
        let identity = canonical.to_string_lossy().into_owned();
        #[cfg(windows)]
        let identity = identity.to_lowercase();
        let path = parent.join(format!(".dansheng-profile-{}.lock", hash(&identity)));
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        lock.try_lock_exclusive().map_err(|_| {
            CoreError::new(
                "DataDirectoryInUse",
                "another core or restore owns this profile",
            )
        })?;
        Ok(ProfileLock {
            _file: lock,
            directory: canonical,
        })
    }
    pub fn open(directory: &Path) -> CoreResult<Self> {
        let profile_lock = Self::acquire_profile_lock(directory)?;
        Self::open_locked(profile_lock)
    }
    pub fn open_locked(profile_lock: ProfileLock) -> CoreResult<Self> {
        let directory = profile_lock.directory.clone();
        std::fs::create_dir_all(&directory)?;
        let owner_lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(directory.join("core.lock"))?;
        owner_lock.try_lock_exclusive().map_err(|_| {
            CoreError::new(
                "DataDirectoryInUse",
                "another core owns this data directory; connect through IPC",
            )
        })?;
        let mut db = Connection::open(directory.join("dansheng.db"))?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > 3 {
            return Err(CoreError::new(
                "UnsupportedDatabaseVersion",
                "database was created by a newer core",
            ));
        }
        if version == 0 {
            let tx = db.transaction()?;
            tx.execute_batch(r#"
CREATE TABLE accounts(id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE grants(subject TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE clients(id TEXT PRIMARY KEY, kind TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE);
CREATE TABLE kv(namespace TEXT NOT NULL, key TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(namespace,key));
CREATE TABLE records(id INTEGER PRIMARY KEY, owner TEXT NOT NULL, account_id TEXT NOT NULL, source_id TEXT NOT NULL, external_id TEXT NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL, search_text TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(owner,account_id,source_id,external_id));
CREATE INDEX records_source ON records(account_id,source_id,kind);
CREATE TABLE source_access(owner TEXT NOT NULL,source_id TEXT NOT NULL,capabilities TEXT NOT NULL,PRIMARY KEY(owner,source_id));
CREATE VIRTUAL TABLE records_fts USING fts5(search_text,content='records',content_rowid='id',tokenize='trigram');
CREATE TRIGGER records_ai AFTER INSERT ON records BEGIN INSERT INTO records_fts(rowid,search_text) VALUES(new.id,new.search_text); END;
CREATE TRIGGER records_ad AFTER DELETE ON records BEGIN INSERT INTO records_fts(records_fts,rowid,search_text) VALUES('delete',old.id,old.search_text); END;
CREATE TRIGGER records_au AFTER UPDATE ON records BEGIN INSERT INTO records_fts(records_fts,rowid,search_text) VALUES('delete',old.id,old.search_text); INSERT INTO records_fts(rowid,search_text) VALUES(new.id,new.search_text); END;
CREATE TABLE jobs(id TEXT PRIMARY KEY, owner TEXT NOT NULL, data TEXT NOT NULL, state TEXT NOT NULL, run_at TEXT NOT NULL, lease TEXT, result TEXT, updated_at TEXT NOT NULL,dedup_key TEXT NOT NULL);
CREATE INDEX jobs_due ON jobs(state,run_at);
CREATE UNIQUE INDEX jobs_active_dedup ON jobs(owner,dedup_key) WHERE state IN ('scheduled','running','waiting_for_auth','waiting_for_approval','needs_reconciliation');
CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, data TEXT NOT NULL, at TEXT NOT NULL);
CREATE TABLE plugins(id TEXT PRIMARY KEY, path TEXT NOT NULL, manifest TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, verification TEXT);
PRAGMA user_version=3;
"#)?;
            tx.commit()?;
        }
        if version == 1 {
            let tx = db.transaction()?;
            tx.execute_batch("ALTER TABLE jobs ADD COLUMN dedup_key TEXT NOT NULL DEFAULT ''; UPDATE jobs SET dedup_key=id; CREATE UNIQUE INDEX jobs_active_dedup ON jobs(owner,dedup_key) WHERE state IN ('scheduled','running','waiting_for_auth','waiting_for_approval','needs_reconciliation'); PRAGMA user_version=2;")?;
            tx.commit()?;
        }
        if version > 0 && version < 3 {
            let tx = db.transaction()?;
            tx.execute_batch("ALTER TABLE plugins ADD COLUMN verification TEXT; CREATE TABLE IF NOT EXISTS source_access(owner TEXT NOT NULL,source_id TEXT NOT NULL,capabilities TEXT NOT NULL,PRIMARY KEY(owner,source_id)); PRAGMA user_version=3;")?;
            tx.commit()?;
        }
        // A process crash can follow a successful external write. Recovery never replays it.
        db.execute("UPDATE jobs SET state='needs_reconciliation',lease=NULL,updated_at=? WHERE state='running'", [Utc::now().to_rfc3339()])?;
        Ok(Self {
            db: Mutex::new(db),
            directory,
            _owner_lock: owner_lock,
            _profile_lock: profile_lock,
        })
    }

    pub(crate) fn with<T>(
        &self,
        f: impl FnOnce(&mut Connection) -> CoreResult<T>,
    ) -> CoreResult<T> {
        let mut db = self
            .db
            .lock()
            .map_err(|_| CoreError::new("StorageError", "database lock poisoned"))?;
        f(&mut db)
    }
    /// Read the profile's local credential-binding epoch without establishing trust.
    /// Opening a Store never creates an epoch; snapshots and restores discard it.
    pub fn credential_binding_epoch(&self) -> CoreResult<Option<String>> {
        self.with(|db| read_credential_binding_epoch(db))
    }

    /// Establish an epoch only from a trusted, explicit credential configuration flow.
    /// The caller must supply fresh credentials before binding service configuration.
    /// Never call this while loading imported configuration or adopt its saved epoch.
    /// Concurrent initializers share one randomly generated, persisted epoch.
    pub fn ensure_credential_binding_epoch(&self) -> CoreResult<String> {
        self.with(|db| {
            if let Some(epoch) = read_credential_binding_epoch(db)? {
                return Ok(epoch);
            }
            let epoch = uuid::Uuid::new_v4().to_string();
            db.execute(
                "INSERT INTO kv(namespace,key,data) VALUES('core:credential-bindings','epoch',?) ON CONFLICT(namespace,key) DO UPDATE SET data=excluded.data",
                [serde_json::to_string(&epoch)?],
            )?;
            Ok(epoch)
        })
    }

    pub fn grant(&self, subject: &str) -> CoreResult<Grant> {
        self.with(|db| {
            let value: Option<String> = db
                .query_row("SELECT data FROM grants WHERE subject=?", [subject], |r| {
                    r.get(0)
                })
                .optional()?;
            Ok(value
                .map(|s| serde_json::from_str(&s))
                .transpose()?
                .unwrap_or_default())
        })
    }
    pub fn set_grant(&self, subject: &str, grant: &Grant) -> CoreResult<()> {
        self.with(|db| { db.execute("INSERT INTO grants VALUES(?,?) ON CONFLICT(subject) DO UPDATE SET data=excluded.data", params![subject,serde_json::to_string(grant)?])?; Ok(()) })
    }
    pub fn register_client(&self, id: &str, kind: PrincipalKind, token: &str) -> CoreResult<()> {
        if token.len() < 32 {
            return Err(CoreError::invalid(
                "client tokens must contain at least 32 characters",
            ));
        }
        self.with(|db| { db.execute("INSERT INTO clients VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,token_hash=excluded.token_hash", params![id,serde_json::to_string(&kind)?,hash(token)])?; Ok(()) })
    }
    pub fn authenticate(&self, token: &str) -> CoreResult<Principal> {
        self.with(|db| {
            let row: Option<(String, String)> = db
                .query_row(
                    "SELECT id,kind FROM clients WHERE token_hash=?",
                    [hash(token)],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let (id, kind) =
                row.ok_or_else(|| CoreError::new("Unauthenticated", "invalid client token"))?;
            Ok(Principal {
                id,
                kind: serde_json::from_str(&kind)?,
            })
        })
    }
    pub fn account_upsert(&self, id: &str, data: &Value) -> CoreResult<()> {
        self.with(|db| {
            db.execute(
                "INSERT INTO accounts VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                params![id, data.to_string()],
            )?;
            Ok(())
        })
    }
    pub fn accounts(&self) -> CoreResult<Vec<Value>> {
        self.with(|db| {
            collect_values(
                db.prepare("SELECT data FROM accounts ORDER BY id")?
                    .query_map([], |r| r.get::<_, String>(0))?,
            )
        })
    }
    pub fn kv_get(&self, namespace: &str, key: &str) -> CoreResult<Value> {
        self.with(|db| {
            let s: Option<String> = db
                .query_row(
                    "SELECT data FROM kv WHERE namespace=? AND key=?",
                    params![namespace, key],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(s.map(|s| serde_json::from_str(&s))
                .transpose()?
                .unwrap_or(Value::Null))
        })
    }
    pub fn kv_set(&self, namespace: &str, key: &str, data: &Value) -> CoreResult<()> {
        if key.len() > 256 || data.to_string().len() > 1024 * 1024 {
            return Err(CoreError::invalid("storage item exceeds quota"));
        }
        self.with(|db| {let tx=db.transaction()?;
            let current:i64=tx.query_row("SELECT COALESCE(SUM(length(CAST(data AS BLOB))),0) FROM kv WHERE namespace=? AND key<>?",params![namespace,key],|r|r.get(0))?;
            if current.saturating_add(data.to_string().len()as i64)>16*1024*1024{return Err(CoreError::new("StorageQuotaExceeded","namespace storage exceeds 16 MiB"));}
            tx.execute("INSERT INTO kv VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET data=excluded.data",params![namespace,key,data.to_string()])?;tx.commit()?; Ok(()) })
    }
    pub fn kv_delete(&self, namespace: &str, key: &str) -> CoreResult<()> {
        self.with(|db| {
            db.execute(
                "DELETE FROM kv WHERE namespace=? AND key=?",
                params![namespace, key],
            )?;
            Ok(())
        })
    }
    pub fn record_upsert(
        &self,
        owner: &str,
        account: &str,
        source: &str,
        external: &str,
        kind: &str,
        data: &Value,
    ) -> CoreResult<Value> {
        if data.to_string().len() > 2 * 1024 * 1024 {
            return Err(CoreError::invalid("record exceeds quota"));
        }
        validate_record_identity(owner, account, source, external, kind)?;
        let now = Utc::now().to_rfc3339();
        self.with(|db| { db.execute("INSERT INTO records(owner,account_id,source_id,external_id,kind,data,search_text,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(owner,account_id,source_id,external_id) DO UPDATE SET kind=excluded.kind,data=excluded.data,search_text=excluded.search_text,updated_at=excluded.updated_at",params![owner,account,source,external,kind,data.to_string(),search_text(data),now])?; Ok(()) })?;
        Ok(json!({"source_id":source,"external_id":external,"updated_at":now}))
    }
    /// Commit a complete source result and its checkpoint together. Absence in a
    /// result never implies deletion, so partial source availability is non-destructive.
    pub fn commit_source(
        &self,
        owner: &str,
        account: &str,
        source: &str,
        kind: &str,
        rows: &[(String, Value)],
        checkpoint: &Value,
    ) -> CoreResult<()> {
        if rows.len() > 10000
            || rows.iter().map(|(_, v)| v.to_string().len()).sum::<usize>() > 16 * 1024 * 1024
        {
            return Err(CoreError::invalid("source batch exceeds quota"));
        }
        for (external, data) in rows {
            validate_record_identity(owner, account, source, external, kind)?;
            if data.to_string().len() > 2 * 1024 * 1024 {
                return Err(CoreError::invalid("source record exceeds quota"));
            }
        }
        self.with(|db|{let tx=db.transaction()?;let now=Utc::now().to_rfc3339();
            for(external,data)in rows {tx.execute("INSERT INTO records(owner,account_id,source_id,external_id,kind,data,search_text,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(owner,account_id,source_id,external_id) DO UPDATE SET kind=excluded.kind,data=excluded.data,search_text=excluded.search_text,updated_at=excluded.updated_at",params![owner,account,source,external,kind,data.to_string(),search_text(data),now])?;}
            tx.execute("INSERT INTO kv VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET data=excluded.data",params![format!("checkpoint:{owner}:{source}"),account,checkpoint.to_string()])?;tx.commit()?;Ok(())
        })
    }
    pub fn require_source_capabilities(
        &self,
        owner: &str,
        source: &str,
        capabilities: &std::collections::BTreeSet<String>,
    ) -> CoreResult<()> {
        if capabilities.is_empty() {
            return Ok(());
        }
        self.with(|db|{let tx=db.transaction()?;let previous:Option<String>=tx.query_row("SELECT capabilities FROM source_access WHERE owner=? AND source_id=?",params![owner,source],|r|r.get(0)).optional()?;
            let mut combined:std::collections::BTreeSet<String>=previous.map(|s|serde_json::from_str(&s)).transpose()?.unwrap_or_default();combined.extend(capabilities.iter().cloned());
            tx.execute("INSERT INTO source_access VALUES(?,?,?) ON CONFLICT(owner,source_id) DO UPDATE SET capabilities=excluded.capabilities",params![owner,source,serde_json::to_string(&combined)?])?;tx.commit()?;Ok(())
        })
    }
    pub fn records(
        &self,
        principal: &Principal,
        grant: &Grant,
        filter: &Value,
        search: Option<&str>,
    ) -> CoreResult<Vec<Value>> {
        let limit = filter["limit"].as_u64().unwrap_or(50).clamp(1, 500) as usize;
        let source = filter["source_id"].as_str().unwrap_or("");
        let kind = filter["kind"].as_str().unwrap_or("");
        let account = filter["account_id"].as_str().unwrap_or("");
        let external = filter["external_id"].as_str().unwrap_or("");
        let record_owner = filter["record_owner"].as_str().unwrap_or("");
        let summary = filter["summary"].as_bool().unwrap_or(false);
        self.with(|db| {
            let mut values:Vec<rusqlite::types::Value>=Vec::new();
            let projection=if summary{values.push(search.unwrap_or("").to_owned().into());"json_object('title',substr(COALESCE(json_extract(data,'$.title'),json_extract(data,'$.name'),json_extract(data,'$.subject'),kind),1,256),'snippet',substr(search_text,MAX(1,instr(lower(search_text),lower(?))-96),512),'asset_id',CASE WHEN json_type(data,'$.asset_id')='text' THEN substr(json_extract(data,'$.asset_id'),1,128) ELSE NULL END)"}else{"data"};
            let mut sql=format!("SELECT owner,account_id,source_id,external_id,kind,{projection},updated_at FROM records WHERE (?='' OR source_id=?) AND (?='' OR kind=?) AND (?='' OR account_id=?) AND (?='' OR external_id=?) AND (?='' OR owner=?)");
            values.extend([source,source,kind,kind,account,account,external,external,record_owner,record_owner].into_iter().map(|s|rusqlite::types::Value::from(s.to_owned())));
            if !principal.is_owner(){
                if !grant.allows("mail.read"){sql.push_str(" AND kind NOT LIKE 'mail.%' AND source_id NOT LIKE 'mail.%'");}
                sql.push_str(" AND NOT EXISTS(SELECT 1 FROM source_access acl,json_each(acl.capabilities) needed WHERE acl.owner=records.owner AND acl.source_id=records.source_id AND needed.value NOT IN (");
                let allowed:Vec<_>=grant.capabilities.iter().filter(|cap|grant.allows(cap)).collect();sql.push_str(&vec!["?";allowed.len()].join(","));sql.push_str("))");values.extend(allowed.into_iter().cloned().map(Into::into));
                sql.push_str(" AND ((account_id<>'' AND account_id IN (");
                sql.push_str(&vec!["?";grant.account_ids.len()].join(","));sql.push_str(")) OR (account_id='' AND (owner=? OR source_id IN (");
                values.extend(grant.account_ids.iter().cloned().map(Into::into));values.push(principal.id.clone().into());
                sql.push_str(&vec!["?";grant.source_ids.len()].join(","));sql.push_str("))))");
                values.extend(grant.source_ids.iter().cloned().map(Into::into));
            }
            let q=search.unwrap_or("");
            if q.chars().count()>=3 {sql.push_str(" AND id IN (SELECT rowid FROM records_fts WHERE records_fts MATCH ?)");values.push(format!("\"{}\"",q.replace('"',"\"\"")).into());}
            else if !q.is_empty(){sql.push_str(" AND search_text LIKE ? ESCAPE '!'");values.push(format!("%{}%",q.replace('!',"!!").replace('%',"!%").replace('_',"!_")).into());}
            sql.push_str(" ORDER BY updated_at DESC LIMIT ?");values.push((limit as i64).into());
            let mut stmt=db.prepare(&sql)?;
            let rows=stmt.query_map(rusqlite::params_from_iter(values),|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?,r.get::<_,String>(5)?,r.get::<_,String>(6)?)))?;
            let mut result=Vec::new();
            let mut bytes=0usize;
            for row in rows {
                let (owner,account,source,external,kind,data,updated)=row?;
                bytes=bytes.saturating_add(owner.len()+account.len()+source.len()+external.len()+kind.len()+data.len()+updated.len()+256);
                if bytes>4*1024*1024{return Err(CoreError::new("ResultTooLarge","reduce limit or request source summaries"));}
                result.push(json!({"owner":owner,"account_id":account,"source_id":source,"external_id":external,"kind":kind,"data":serde_json::from_str::<Value>(&data)?,"updated_at":updated}));
                if result.len()>=limit { break; }
            }
            Ok(result)
        })
    }
    pub fn event(&self, kind: &str, data: &Value) -> CoreResult<i64> {
        self.with(|db| {
            let tx = db.transaction()?;
            tx.execute(
                "INSERT INTO events(kind,data,at) VALUES(?,?,?)",
                params![kind, data.to_string(), Utc::now().to_rfc3339()],
            )?;
            let id = tx.last_insert_rowid();
            tx.execute("DELETE FROM events WHERE sequence<=?", [id - 10000])?;
            tx.commit()?;
            Ok(id)
        })
    }
    pub fn first_event_sequence(&self) -> CoreResult<i64> {
        self.with(|db| {
            Ok(
                db.query_row("SELECT COALESCE(MIN(sequence),0) FROM events", [], |r| {
                    r.get(0)
                })?,
            )
        })
    }
    pub fn events(&self, after: i64) -> CoreResult<Vec<Event>> {
        self.with(|db| {
            let mut stmt=db.prepare("SELECT sequence,kind,data,at FROM events WHERE sequence>? ORDER BY sequence LIMIT 200")?;
            let rows=stmt.query_map([after],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?)))?;
            rows.map(|r| { let (sequence,kind,data,at)=r?; Ok(Event {sequence,kind,data:serde_json::from_str(&data)?,at}) }).collect()
        })
    }
    pub fn plugin_save(&self, id: &str, path: &Path, manifest: &Value) -> CoreResult<()> {
        self.plugin_save_verified(id, path, manifest, None)
    }
    pub fn plugin_save_verified(
        &self,
        id: &str,
        path: &Path,
        manifest: &Value,
        verification: Option<&Value>,
    ) -> CoreResult<()> {
        self.with(|db| { db.execute("INSERT INTO plugins(id,path,manifest,enabled,verification) VALUES(?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,manifest=excluded.manifest,enabled=0,verification=excluded.verification",params![id,path.to_string_lossy(),manifest.to_string(),verification.map(Value::to_string)])?; Ok(()) })
    }
    pub fn plugin_enable(&self, id: &str, enabled: bool) -> CoreResult<()> {
        self.with(|db| {
            if db.execute(
                "UPDATE plugins SET enabled=? WHERE id=?",
                params![enabled, id],
            )? == 0
            {
                return Err(CoreError::new("NotFound", "plugin not installed"));
            }
            Ok(())
        })
    }
    pub fn plugin_remove(&self, id: &str) -> CoreResult<()> {
        self.with(|db| {
            let tx = db.transaction()?;
            tx.execute("DELETE FROM plugins WHERE id=?", [id])?;
            tx.execute(
                "DELETE FROM grants WHERE subject=?",
                [format!("plugin:{id}")],
            )?;
            tx.commit()?;
            Ok(())
        })
    }
    pub fn plugins(&self) -> CoreResult<Vec<Value>> {
        self.with(|db| {
            let mut stmt=db.prepare("SELECT id,path,manifest,enabled,verification FROM plugins ORDER BY id")?;
            let rows=stmt.query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,bool>(3)?,r.get::<_,Option<String>>(4)?)))?;
            rows.map(|r|{let(id,path,manifest,enabled,verification)=r?;Ok(json!({"id":id,"path":path,"manifest":serde_json::from_str::<Value>(&manifest)?,"enabled":enabled,"verification":verification.map(|s|serde_json::from_str::<Value>(&s)).transpose()?}))}).collect()
        })
    }
    pub fn create_job(&self, owner: &Principal, data: &Value, run_at: &str) -> CoreResult<String> {
        let id = uuid::Uuid::new_v4().to_string();
        let dedup=data["dedup_key"].as_str().map(str::to_owned).unwrap_or_else(||hash(&json!({"plugin_id":data["plugin_id"],"action":data["action"],"input":data["input"],"interval_seconds":data["interval_seconds"]}).to_string()));
        self.with(|db| { let owner_json=serde_json::to_string(owner)?;
            db.execute("INSERT OR IGNORE INTO jobs(id,owner,data,state,run_at,updated_at,dedup_key) VALUES(?,?,?,'scheduled',?,?,?)",params![id,owner_json,data.to_string(),run_at,Utc::now().to_rfc3339(),dedup])?;
            Ok(db.query_row("SELECT id FROM jobs WHERE owner=? AND dedup_key=? AND state IN ('scheduled','running','waiting_for_auth','waiting_for_approval','needs_reconciliation')",params![owner_json,dedup],|r|r.get(0))?)
        })
    }
    /// Publish an immediate plugin invocation and its lease in one transaction.
    /// It is never visible to the scheduler as an unclaimed due job. Active
    /// duplicate invocations keep their original id and are not executed twice.
    pub(crate) fn create_claimed_plugin_job(
        &self,
        owner: &Principal,
        data: &Value,
        run_at: &str,
    ) -> CoreResult<(String, Option<String>)> {
        let id = uuid::Uuid::new_v4().to_string();
        let lease = uuid::Uuid::new_v4().to_string();
        let dedup=hash(&json!({"plugin_id":data["plugin_id"],"action":data["action"],"input":data["input"],"interval_seconds":data["interval_seconds"]}).to_string());
        self.with(|db| {
            let tx=db.transaction()?;
            let owner_json=serde_json::to_string(owner)?;
            let now=Utc::now().to_rfc3339();
            if tx.execute("INSERT OR IGNORE INTO jobs(id,owner,data,state,run_at,lease,updated_at,dedup_key) VALUES(?,?,?,'running',?,?,?,?)",
                params![id,owner_json,data.to_string(),run_at,lease,now,dedup])?==1 {
                tx.commit()?;
                return Ok((id,Some(lease)));
            }
            let (existing,stored):(String,String)=tx.query_row("SELECT id,data FROM jobs WHERE owner=? AND dedup_key=? AND state IN ('scheduled','running','waiting_for_auth','waiting_for_approval','needs_reconciliation')",
                params![owner_json,dedup],|row|Ok((row.get(0)?,row.get(1)?)))?;
            let stored:Value=serde_json::from_str(&stored)?;
            if ["plugin_id","action","input","interval_seconds"].iter().any(|key|stored[key]!=data[key]) {
                return Err(CoreError::new("JobDefinitionConflict","active dedup key belongs to a different invocation"));
            }
            let claimed=tx.execute("UPDATE jobs SET state='running',lease=?,updated_at=? WHERE id=? AND state='scheduled' AND run_at<=?",
                params![lease,now,existing,now])?==1;
            tx.commit()?;
            Ok((existing,claimed.then_some(lease)))
        })
    }
    pub(crate) fn owns_job_lease(&self, id: &str, lease: &str) -> CoreResult<bool> {
        self.with(|db| {
            Ok(db.query_row(
                "SELECT EXISTS(SELECT 1 FROM jobs WHERE id=? AND state='running' AND lease=?)",
                params![id, lease],
                |row| row.get(0),
            )?)
        })
    }
    pub fn jobs(&self) -> CoreResult<Vec<Value>> {
        self.with(|db| query_jobs(db, "ORDER BY run_at DESC LIMIT 1000", vec![]))
    }
    pub fn job(&self, id: &str) -> CoreResult<Option<Value>> {
        self.with(|db| {
            Ok(query_jobs(db, "WHERE id=?", vec![id.to_owned().into()])?
                .into_iter()
                .next())
        })
    }
    pub fn due_jobs(&self) -> CoreResult<Vec<Value>> {
        self.with(|db| {
            query_jobs(
                db,
                "WHERE state='scheduled' AND run_at<=? ORDER BY run_at,id LIMIT 8",
                vec![Utc::now().to_rfc3339().into()],
            )
        })
    }
    pub fn claim_job(&self, id: &str) -> CoreResult<Option<String>> {
        let lease = uuid::Uuid::new_v4().to_string();
        self.with(|db| Ok((db.execute("UPDATE jobs SET state='running',lease=?,updated_at=? WHERE id=? AND state='scheduled' AND run_at<=?",params![lease,Utc::now().to_rfc3339(),id,Utc::now().to_rfc3339()])?==1).then_some(lease)))
    }
    pub fn finish_job(
        &self,
        id: &str,
        lease: &str,
        state: &str,
        result: &Value,
        next: Option<&str>,
    ) -> CoreResult<()> {
        self.with(|db| {let tx=db.transaction()?;
            let mut updated:Option<String>=None;
            if let Some(next)=next{let data:Option<String>=tx.query_row("SELECT data FROM jobs WHERE id=? AND lease=? AND state='running'",params![id,lease],|r|r.get(0)).optional()?;
                if let Some(data)=data{let mut value:Value=serde_json::from_str(&data)?;if let Some(window)=value["_deadline_window_seconds"].as_i64(){let run=chrono::DateTime::parse_from_rfc3339(next).map_err(|_|CoreError::invalid("invalid recurring run time"))?;let deadline=run.checked_add_signed(chrono::Duration::seconds(window)).ok_or_else(||CoreError::invalid("recurring deadline overflow"))?;value["deadline_at"]=json!(deadline.to_rfc3339());}updated=Some(value.to_string());}
            }
            tx.execute("UPDATE jobs SET state=?,result=?,run_at=COALESCE(?,run_at),data=COALESCE(?,data),lease=NULL,updated_at=? WHERE id=? AND lease=? AND state='running'",params![state,result.to_string(),next,updated,Utc::now().to_rfc3339(),id,lease])?;tx.commit()?;Ok(()) })
    }
    pub fn cancel_job(&self, id: &str) -> CoreResult<()> {
        self.with(|db| { db.execute("UPDATE jobs SET state=CASE WHEN state='running' THEN 'needs_reconciliation' ELSE 'cancelled' END,lease=NULL,updated_at=? WHERE id=? AND state IN ('scheduled','running','waiting_for_auth','waiting_for_approval')",params![Utc::now().to_rfc3339(),id])?; Ok(()) })
    }
    pub fn has_uncertain_job(&self, plugin: &str, account: Option<&str>) -> CoreResult<bool> {
        self.with(|db|Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM jobs WHERE state='needs_reconciliation' AND json_extract(data,'$.plugin_id')=? AND (?='' OR COALESCE(json_extract(data,'$.input.account_id'),'')='' OR json_extract(data,'$.input.account_id')=?))",params![plugin,account.unwrap_or(""),account.unwrap_or("")],|r|r.get(0))?))
    }
    pub fn reconcile_job(&self, id: &str, outcome: &str, result: &Value) -> CoreResult<()> {
        if !matches!(outcome, "succeeded" | "failed" | "cancelled") {
            return Err(CoreError::invalid(
                "reconciliation must record a confirmed terminal outcome",
            ));
        }
        self.with(|db| {if db.execute("UPDATE jobs SET state=?,result=?,lease=NULL,updated_at=? WHERE id=? AND state='needs_reconciliation'",params![outcome,result.to_string(),Utc::now().to_rfc3339(),id])?!=1{return Err(CoreError::new("JobNotReconcilable","job is not awaiting reconciliation"));}Ok(())})
    }
    pub fn resume_job(&self, id: &str) -> CoreResult<()> {
        self.with(|db| {if db.execute("UPDATE jobs SET state='scheduled',lease=NULL,updated_at=? WHERE id=? AND state IN ('waiting_for_auth','waiting_for_approval')",params![Utc::now().to_rfc3339(),id])?!=1{return Err(CoreError::new("JobNotResumable","job is not waiting for authentication or approval"));}Ok(())})
    }
    pub fn job_active(&self, id: &str) -> CoreResult<bool> {
        self.with(|db| {
            Ok(db
                .query_row("SELECT state='running' FROM jobs WHERE id=?", [id], |r| {
                    r.get(0)
                })
                .optional()?
                .unwrap_or(false))
        })
    }
    pub fn backup(&self) -> CoreResult<PathBuf> {
        let directory = self.directory.join("backups");
        std::fs::create_dir_all(&directory)?;
        let path = directory.join(format!("{}.db", uuid::Uuid::new_v4()));
        self.with(|db| {
            db.backup(
                rusqlite::MAIN_DB,
                &path,
                None::<fn(rusqlite::backup::Progress)>,
            )?;
            Ok(())
        })?;
        Ok(path)
    }
}

fn hash(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}
fn validate_record_identity(
    owner: &str,
    account: &str,
    source: &str,
    external: &str,
    kind: &str,
) -> CoreResult<()> {
    for (value, max) in [
        (owner, 256),
        (account, 256),
        (source, 256),
        (external, 512),
        (kind, 128),
    ] {
        if value.len() > max || value.chars().any(char::is_control) {
            return Err(CoreError::invalid("invalid source record identity"));
        }
    }
    if owner.is_empty() || source.is_empty() || external.is_empty() || kind.is_empty() {
        return Err(CoreError::invalid("source identity cannot be empty"));
    }
    Ok(())
}
fn query_jobs(
    db: &Connection,
    clause: &str,
    values: Vec<rusqlite::types::Value>,
) -> CoreResult<Vec<Value>> {
    let mut stmt = db.prepare(&format!(
        "SELECT id,owner,data,state,run_at,result,updated_at FROM jobs {clause}"
    ))?;
    let rows = stmt.query_map(rusqlite::params_from_iter(values), |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
            r.get::<_, Option<String>>(5)?,
            r.get::<_, String>(6)?,
        ))
    })?;
    rows.map(|r|{let(id,owner,data,state,run_at,result,updated_at)=r?;Ok(json!({"id":id,"owner":serde_json::from_str::<Value>(&owner)?,"data":serde_json::from_str::<Value>(&data)?,"state":state,"run_at":run_at,"result":result.map(|s|serde_json::from_str::<Value>(&s)).transpose()?,"updated_at":updated_at}))}).collect()
}
fn read_credential_binding_epoch(db: &Connection) -> CoreResult<Option<String>> {
    let value: Option<String> = db
        .query_row(
            "SELECT data FROM kv WHERE namespace='core:credential-bindings' AND key='epoch'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let epoch = value
        .map(|value| serde_json::from_str::<Option<String>>(&value))
        .transpose()?
        .flatten();
    Ok(epoch.filter(|epoch| !epoch.is_empty()))
}

fn collect_values(rows: impl Iterator<Item = rusqlite::Result<String>>) -> CoreResult<Vec<Value>> {
    rows.map(|s| Ok(serde_json::from_str(&s?)?)).collect()
}
fn search_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Array(a) => a.iter().map(search_text).collect::<Vec<_>>().join(" "),
        Value::Object(o) => o.values().map(search_text).collect::<Vec<_>>().join(" "),
        _ => value.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn isolation_and_restart_recovery() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::open(dir.path()).unwrap();
        s.kv_set("a", "x", &json!(42)).unwrap();
        assert_eq!(s.kv_get("b", "x").unwrap(), Value::Null);
        let id = s
            .create_job(&Principal::owner(), &json!({}), "2000-01-01T00:00:00+00:00")
            .unwrap();
        assert!(s.claim_job(&id).unwrap().is_some());
        assert!(s.claim_job(&id).unwrap().is_none());
        drop(s);
        let s = Store::open(dir.path()).unwrap();
        assert_eq!(s.jobs().unwrap()[0]["state"], "needs_reconciliation");
    }
    #[test]
    fn account_filter_and_literal_search() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::open(dir.path()).unwrap();
        s.record_upsert(
            "plugin:p",
            "a",
            "p.courses",
            "1",
            "course",
            &json!({"name":"数学 100%"}),
        )
        .unwrap();
        s.record_upsert(
            "plugin:p",
            "b",
            "p.courses",
            "2",
            "course",
            &json!({"name":"数学"}),
        )
        .unwrap();
        let p = Principal {
            id: "reader".into(),
            kind: PrincipalKind::Client,
        };
        let mut g = Grant::default();
        g.account_ids.insert("a".into());
        g.capabilities.insert("sources.read".into());
        assert_eq!(
            s.records(&p, &g, &json!({}), Some("数学")).unwrap().len(),
            1
        );
        assert_eq!(
            s.records(&Principal::owner(), &g, &json!({}), Some("%"))
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn general_search_cannot_read_mail_without_mail_capability() {
        let d = tempfile::tempdir().unwrap();
        let s = Store::open(d.path()).unwrap();
        s.record_upsert(
            "service:mail",
            "a",
            "mail.inbox",
            "1",
            "mail.message",
            &json!({"text":"private synthetic message"}),
        )
        .unwrap();
        let p = Principal {
            id: "reader".into(),
            kind: PrincipalKind::Mcp,
        };
        let mut g = Grant::default();
        g.account_ids.insert("a".into());
        g.capabilities.insert("sources.read".into());
        assert!(
            s.records(&p, &g, &json!({}), Some("synthetic"))
                .unwrap()
                .is_empty()
        );
        g.capabilities.insert("mail.read".into());
        assert_eq!(
            s.records(&p, &g, &json!({}), Some("synthetic"))
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn retry_time_does_not_change_default_job_identity() {
        let d = tempfile::tempdir().unwrap();
        let s = Store::open(d.path()).unwrap();
        let a=s.create_job(&Principal::owner(),&json!({"plugin_id":"p","action":"a","input":{"target":"same"},"run_at":"2026-01-01T00:00:00Z"}),"2026-01-01T00:00:00+00:00").unwrap();
        let b=s.create_job(&Principal::owner(),&json!({"plugin_id":"p","action":"a","input":{"target":"same"},"run_at":"2026-01-02T00:00:00Z"}),"2026-01-02T00:00:00+00:00").unwrap();
        assert_eq!(a, b);
    }
}
