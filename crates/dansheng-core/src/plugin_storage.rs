//! Transactional, offline migrations of permission-partitioned plugin KV data.
//! Recovery copies retain the complete namespace suffix; no scope is merged.
use crate::{
    CoreError, CoreResult,
    plugins::{PluginManifest, PluginStorageOperation},
    store::Store,
};
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const STATE: &str = "core:plugin-storage-schema";
const SNAPSHOTS: &str = "core:plugin-storage-snapshots";
const MAX_BYTES: i64 = 64 * 1024 * 1024;
const MAX_ENTRIES: i64 = 65_536;
const MAX_SNAPSHOTS: usize = 8;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    snapshot_id: String,
    plugin_id: String,
    version: u32,
    created_at: String,
    scopes: i64,
    entries: i64,
    bytes: i64,
    sha256: String,
}

fn failure(code: &str) -> CoreError {
    CoreError::new(
        code,
        "private plugin storage transition refused; data remains recoverable",
    )
}
fn state_version(db: &Connection, id: &str) -> CoreResult<Option<u32>> {
    let data: Option<String> = db
        .query_row(
            "SELECT data FROM kv WHERE namespace=? AND key=?",
            params![STATE, id],
            |r| r.get(0),
        )
        .optional()?;
    data.map(|data| {
        serde_json::from_str::<u32>(&data)
            .ok()
            .filter(|v| *v <= 1_000_000)
            .ok_or_else(|| failure("PluginStorageStateInvalid"))
    })
    .transpose()
}
fn set_version(db: &Connection, id: &str, version: u32) -> CoreResult<()> {
    db.execute(
        "INSERT INTO kv VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET data=excluded.data",
        params![STATE, id, version.to_string()],
    )?;
    Ok(())
}
fn prefix(id: &str) -> String {
    format!("plugin-state:{id}:")
}
fn recovery_prefix(id: &str, snapshot: &str) -> String {
    format!("plugin-storage-snapshot:{id}:{snapshot}:")
}
fn target(manifest: &PluginManifest) -> u32 {
    manifest
        .storage_schema
        .as_ref()
        .map_or(0, |schema| schema.version)
}
fn manifest(db: &Connection, id: &str) -> CoreResult<(PluginManifest, bool)> {
    let row: Option<(String, bool)> = db
        .query_row(
            "SELECT manifest,enabled FROM plugins WHERE id=?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let (data, enabled) = row.ok_or_else(|| failure("PluginUnavailable"))?;
    let manifest = PluginManifest::from_slice(data.as_bytes())
        .map_err(|_| failure("PluginStorageStateInvalid"))?;
    if manifest.id != id {
        return Err(failure("PluginStorageStateInvalid"));
    }
    Ok((manifest, enabled))
}
fn scopes(db: &Connection, prefix: &str) -> CoreResult<Vec<String>> {
    let rows = db.prepare("SELECT DISTINCT namespace FROM kv WHERE substr(namespace,1,?)=? ORDER BY namespace LIMIT 1025")?
        .query_map(params![prefix.len() as i64,prefix], |r|r.get::<_,String>(0))?.collect::<Result<Vec<_>,_>>()?;
    if rows.len() > 1024
        || rows.iter().any(|namespace| {
            let suffix = &namespace[prefix.len()..];
            suffix.len() != 64
                || !suffix
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
    {
        return Err(failure("PluginStorageScopeInvalid"));
    }
    Ok(rows)
}
fn stats(db: &Connection, prefix: &str) -> CoreResult<(i64, i64)> {
    let (count, bytes) = db.query_row("SELECT COUNT(*),COALESCE(SUM(length(CAST(data AS BLOB))),0) FROM kv WHERE substr(namespace,1,?)=?", params![prefix.len() as i64,prefix], |r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?)))?;
    if count > MAX_ENTRIES || bytes > MAX_BYTES {
        return Err(failure("PluginStorageQuotaExceeded"));
    }
    Ok((count, bytes))
}
fn digest(db: &Connection, prefix: &str) -> CoreResult<String> {
    let mut hash = Sha256::new();
    let mut statement = db.prepare(
        "SELECT namespace,key,data FROM kv WHERE substr(namespace,1,?)=? ORDER BY namespace,key",
    )?;
    let mut rows = statement.query(params![prefix.len() as i64, prefix])?;
    while let Some(row) = rows.next()? {
        let namespace: String = row.get(0)?;
        let key: String = row.get(1)?;
        let data: String = row.get(2)?;
        if data.len() > 1024 * 1024 || key.len() > 256 {
            return Err(failure("PluginStorageQuotaExceeded"));
        }
        for part in [&namespace[prefix.len()..], key.as_str(), data.as_str()] {
            hash.update((part.len() as u64).to_be_bytes());
            hash.update(part.as_bytes());
        }
    }
    Ok(hex::encode(hash.finalize()))
}
fn snapshots(db: &Connection, id: &str) -> CoreResult<Vec<Snapshot>> {
    let values = db.prepare("SELECT key,data FROM kv WHERE namespace=? AND json_extract(data,'$.plugin_id')=? ORDER BY key LIMIT 9")?
        .query_map(params![SNAPSHOTS,id], |r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?
        .collect::<Result<Vec<_>,_>>()?;
    if values.len() > MAX_SNAPSHOTS {
        return Err(failure("PluginStorageStateInvalid"));
    }
    values
        .into_iter()
        .map(|(key, data)| {
            let value: Snapshot =
                serde_json::from_str(&data).map_err(|_| failure("PluginStorageStateInvalid"))?;
            if value.plugin_id != id
                || value.snapshot_id != key
                || !valid_snapshot_id(&key)
                || value.version > 1_000_000
            {
                return Err(failure("PluginStorageStateInvalid"));
            }
            Ok(value)
        })
        .collect()
}
fn valid_snapshot_id(id: &str) -> bool {
    uuid::Uuid::parse_str(id)
        .is_ok_and(|uuid| uuid.to_string() == id && uuid.get_version_num() == 4)
}
fn snapshot(db: &Connection, id: &str, version: u32) -> CoreResult<Snapshot> {
    if snapshots(db, id)?.len() >= MAX_SNAPSHOTS {
        return Err(failure("PluginStorageSnapshotLimit"));
    }
    let source = prefix(id);
    let names = scopes(db, &source)?;
    let (entries, bytes) = stats(db, &source)?;
    let snapshot_id = uuid::Uuid::new_v4().to_string();
    let destination = recovery_prefix(id, &snapshot_id);
    let sha256 = digest(db, &source)?;
    db.execute("INSERT INTO kv SELECT ?||substr(namespace,?),key,data FROM kv WHERE substr(namespace,1,?)=?",
        params![destination,source.len() as i64+1,source.len() as i64,source])?;
    let value = Snapshot {
        snapshot_id,
        plugin_id: id.into(),
        version,
        created_at: Utc::now().to_rfc3339(),
        scopes: names.len() as i64,
        entries,
        bytes,
        sha256,
    };
    db.execute(
        "INSERT INTO kv VALUES(?,?,?)",
        params![SNAPSHOTS, value.snapshot_id, serde_json::to_string(&value)?],
    )?;
    Ok(value)
}
fn get(db: &Connection, namespace: &str, key: &str) -> CoreResult<Option<String>> {
    Ok(db
        .query_row(
            "SELECT data FROM kv WHERE namespace=? AND key=?",
            params![namespace, key],
            |r| r.get(0),
        )
        .optional()?)
}
fn apply(db: &Connection, namespace: &str, operation: &PluginStorageOperation) -> CoreResult<()> {
    match operation {
        PluginStorageOperation::RenameKey { from, to } => {
            if get(db, namespace, from)?.is_some() {
                if get(db, namespace, to)?.is_some() {
                    return Err(failure("PluginStorageConflict"));
                }
                db.execute(
                    "UPDATE kv SET key=? WHERE namespace=? AND key=?",
                    params![to, namespace, from],
                )?;
            }
        }
        PluginStorageOperation::DeleteKey { key } => {
            db.execute(
                "DELETE FROM kv WHERE namespace=? AND key=?",
                params![namespace, key],
            )?;
        }
        PluginStorageOperation::SetDefault { key, value } => {
            db.execute(
                "INSERT INTO kv VALUES(?,?,?) ON CONFLICT(namespace,key) DO NOTHING",
                params![namespace, key, value.to_string()],
            )?;
        }
        PluginStorageOperation::PatchObject {
            key,
            rename_fields,
            defaults,
            remove_fields,
        } => {
            if let Some(data) = get(db, namespace, key)? {
                let mut value: Value = serde_json::from_str(&data)
                    .map_err(|_| failure("PluginStorageStateInvalid"))?;
                let object = value
                    .as_object_mut()
                    .ok_or_else(|| failure("PluginStorageTypeMismatch"))?;
                for (from, to) in rename_fields {
                    if let Some(value) = object.remove(from) {
                        if object.contains_key(to) {
                            return Err(failure("PluginStorageConflict"));
                        }
                        object.insert(to.clone(), value);
                    }
                }
                for key in remove_fields {
                    object.remove(key);
                }
                for (key, value) in defaults {
                    object.entry(key.clone()).or_insert_with(|| value.clone());
                }
                let data = value.to_string();
                if data.len() > 1024 * 1024 {
                    return Err(failure("PluginStorageQuotaExceeded"));
                }
                db.execute(
                    "UPDATE kv SET data=? WHERE namespace=? AND key=?",
                    params![data, namespace, key],
                )?;
            }
        }
    }
    Ok(())
}

impl Store {
    pub(crate) fn plugin_storage_ready(&self, manifest: &PluginManifest) -> CoreResult<()> {
        self.with(|db| {
            if state_version(db, &manifest.id)?.unwrap_or(0) != target(manifest) {
                return Err(failure("PluginStorageVersionMismatch"));
            }
            Ok(())
        })
    }
    /// The caller holds the Engine lifecycle write gate. SQLite commits data,
    /// recovery copy, version and enablement together, or commits none of them.
    pub(crate) fn plugin_storage_enable(&self, expected: &PluginManifest) -> CoreResult<Value> {
        self.with(|db| {
            let tx=db.transaction()?;
            let (current,_)=manifest(&tx,&expected.id)?;
            if &current!=expected {return Err(failure("PluginChanged"));}
            let id=&expected.id;
            let source=prefix(id);
            let names=scopes(&tx,&source)?;
            let version=state_version(&tx,id)?;
            let from=version.unwrap_or(0);
            let to=target(expected);
            let mut receipt=None;
            // A never-initialized empty installation starts at its declared version.
            if (version.is_some() || !names.is_empty()) && from!=to {
                if from>to {return Err(failure("PluginStorageVersionMismatch"));}
                let schema=expected.storage_schema.as_ref().ok_or_else(||failure("PluginStorageMigrationMissing"))?;
                let steps=(from..to).map(|version|schema.migrations.iter().find(|step|step.from==version)
                    .ok_or_else(||failure("PluginStorageMigrationMissing"))).collect::<CoreResult<Vec<_>>>()?;
                let before=snapshot(&tx,id,from)?;
                for namespace in &names {
                    for step in &steps {for operation in &step.operations {apply(&tx,namespace,operation)?;}}
                    let bytes:i64=tx.query_row("SELECT COALESCE(SUM(length(CAST(data AS BLOB))),0) FROM kv WHERE namespace=?",[namespace],|r|r.get(0))?;
                    if bytes>16*1024*1024 {return Err(failure("PluginStorageQuotaExceeded"));}
                }
                stats(&tx,&source)?;
                receipt=Some(before.snapshot_id);
            }
            set_version(&tx,id,to)?;
            tx.execute("UPDATE plugins SET enabled=1 WHERE id=?",[id])?;
            tx.commit()?;
            Ok(json!({"from":from,"version":to,"snapshot_id":receipt}))
        })
    }
    pub(crate) fn plugin_storage_snapshots(&self, id: &str) -> CoreResult<Value> {
        self.with(|db| {
            manifest(db, id)?;
            Ok(json!({"version":state_version(db,id)?.unwrap_or(0),"snapshots":snapshots(db,id)?}))
        })
    }
    pub(crate) fn plugin_storage_restore(&self, id: &str, snapshot_id: &str) -> CoreResult<Value> {
        if !valid_snapshot_id(snapshot_id) {
            return Err(CoreError::invalid("invalid storage snapshot id"));
        }
        self.with(|db| {
            let tx=db.transaction()?;
            let (manifest,enabled)=manifest(&tx,id)?;
            if enabled {return Err(failure("PluginMustBeDisabled"));}
            let saved=snapshots(&tx,id)?.into_iter().find(|s|s.snapshot_id==snapshot_id).ok_or_else(||failure("NotFound"))?;
            if saved.version!=target(&manifest) {return Err(failure("PluginStorageVersionMismatch"));}
            let source=recovery_prefix(id,snapshot_id);
            let names=scopes(&tx,&source)?;
            let (entries,bytes)=stats(&tx,&source)?;
            if entries!=saved.entries || bytes!=saved.bytes || names.len() as i64!=saved.scopes || digest(&tx,&source)?!=saved.sha256 {
                return Err(failure("PluginStorageSnapshotCorrupt"));
            }
            let reverse=snapshot(&tx,id,state_version(&tx,id)?.unwrap_or(0))?;
            let destination=prefix(id);
            tx.execute("DELETE FROM kv WHERE substr(namespace,1,?)=?",params![destination.len() as i64,destination])?;
            tx.execute("INSERT INTO kv SELECT ?||substr(namespace,?),key,data FROM kv WHERE substr(namespace,1,?)=?",
                params![destination,source.len() as i64+1,source.len() as i64,source])?;
            set_version(&tx,id,saved.version)?;
            tx.commit()?;
            Ok(json!({"plugin_id":id,"version":saved.version,"restored":true,"enabled":false,"recovery_snapshot_id":reverse.snapshot_id}))
        })
    }
    pub(crate) fn plugin_storage_discard(&self, id: &str, snapshot_id: &str) -> CoreResult<Value> {
        if !valid_snapshot_id(snapshot_id) {
            return Err(CoreError::invalid("invalid storage snapshot id"));
        }
        self.with(|db| {
            let tx = db.transaction()?;
            manifest(&tx, id)?;
            if !snapshots(&tx, id)?
                .iter()
                .any(|s| s.snapshot_id == snapshot_id)
            {
                return Err(failure("NotFound"));
            }
            let source = recovery_prefix(id, snapshot_id);
            tx.execute(
                "DELETE FROM kv WHERE substr(namespace,1,?)=?",
                params![source.len() as i64, source],
            )?;
            tx.execute(
                "DELETE FROM kv WHERE namespace=? AND key=?",
                params![SNAPSHOTS, snapshot_id],
            )?;
            tx.commit()?;
            Ok(json!({"discarded":true,"snapshot_id":snapshot_id}))
        })
    }
}
