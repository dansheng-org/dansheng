//! Managed downloads. Paths, ownership and quota reservations never come from plugins.
use crate::{
    api::{CoreError, CoreResult, Principal, PrincipalKind},
    network::{HttpRequest, Network},
    policy::Grant,
    store::Store,
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::Utc;
use fs2::FileExt;
use rusqlite::{OptionalExtension, params, params_from_iter, types::Value as SqlValue};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::{Arc, LazyLock},
};
use uuid::Uuid;

pub const MAX_FILE_BYTES: u64 = 100 * 1024 * 1024;
pub const MAX_TOTAL_BYTES: u64 = 512 * 1024 * 1024;
pub const MAX_READ_BYTES: u64 = 1024 * 1024;
pub const MAX_INDEX_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_TEXT_READ_BYTES: usize = 24 * 1024;
pub const MAX_PDF_PAGES: usize = 128;
pub const MAX_PDF_OBJECTS: usize = 4096;
// Retain the permit inside the blocking task: dropping its caller cannot admit
// more work while a third-party parser is still running.
static INDEX_WORKERS: LazyLock<Arc<tokio::sync::Semaphore>> =
    LazyLock::new(|| Arc::new(tokio::sync::Semaphore::new(2)));

const COLUMNS: &str = "id,owner,account_id,source_id,name,mime_type,state,size,max_bytes,url_hash,request_hash,session_hash,expected_sha256,sha256,etag,created_at,updated_at,indexed_at,error_code";

#[derive(Clone)]
struct Asset {
    id: String,
    owner: String,
    account: String,
    source: String,
    name: String,
    mime: String,
    state: String,
    size: u64,
    max_bytes: u64,
    url_hash: String,
    request_hash: String,
    session_hash: String,
    expected: Option<String>,
    sha256: Option<String>,
    etag: Option<String>,
    created_at: String,
    updated_at: String,
    indexed_at: Option<String>,
    error_code: Option<String>,
}

impl Asset {
    fn from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: r.get(0)?,
            owner: r.get(1)?,
            account: r.get(2)?,
            source: r.get(3)?,
            name: r.get(4)?,
            mime: r.get(5)?,
            state: r.get(6)?,
            size: row_bytes(r, 7)?,
            max_bytes: row_bytes(r, 8)?,
            url_hash: r.get(9)?,
            request_hash: r.get(10)?,
            session_hash: r.get(11)?,
            expected: r.get(12)?,
            sha256: r.get(13)?,
            etag: r.get(14)?,
            created_at: r.get(15)?,
            updated_at: r.get(16)?,
            indexed_at: r.get(17)?,
            error_code: r.get(18)?,
        })
    }
    fn metadata(&self) -> Value {
        json!({"asset_id":self.id,"owner":self.owner,"account_id":self.account,
            "source_id":self.source,"name":self.name,"mime_type":self.mime,
            "state":self.state,"size":self.size,"max_bytes":self.max_bytes,
            "sha256":self.sha256,"created_at":self.created_at,"updated_at":self.updated_at,
            "indexed_at":self.indexed_at,"error_code":self.error_code,
            "progress":{"bytes":self.size,"limit":self.max_bytes},
            "resumable":self.state=="partial" && self.size>0 && self.etag.is_some()})
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DownloadInput {
    url: String,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    headers: BTreeMap<String, String>,
    account_id: Option<String>,
    source_id: Option<String>,
    name: Option<String>,
    mime_type: Option<String>,
    sha256: Option<String>,
    max_bytes: Option<u64>,
    timeout_ms: Option<u64>,
    asset_id: Option<String>,
    #[serde(default)]
    resume: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AssetInput {
    asset_id: String,
    account_id: Option<String>,
    offset: Option<u64>,
    length: Option<u64>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ListInput {
    account_id: Option<String>,
    source_id: Option<String>,
    state: Option<String>,
    limit: Option<u64>,
    offset: Option<u64>,
}

/// Dispatches the file capability boundary, including when called without Engine.
pub async fn dispatch(
    store: &Store,
    network: &Network,
    principal: &Principal,
    grant: &Grant,
    method: &str,
    params: Value,
) -> CoreResult<Value> {
    if !matches!(
        method,
        "files.download"
            | "files.list"
            | "files.read"
            | "files.text"
            | "files.delete"
            | "files.index"
            | "files.export"
    ) {
        return Err(CoreError::new("MethodNotFound", "unknown files method"));
    }
    grant.check(principal, method)?;
    let root = initialize(store)?;
    if method == "files.download" {
        return download(store, network, principal, grant, &root, params).await;
    }
    if method == "files.list" {
        let input: ListInput = serde_json::from_value(params)?;
        check_account(principal, grant, input.account_id.as_deref())?;
        return list(store, principal, grant, &root, input);
    }
    let input: AssetInput = serde_json::from_value(params)?;
    validate_id(&input.asset_id)?;
    check_account(principal, grant, input.account_id.as_deref())?;
    let asset = visible(
        store,
        principal,
        grant,
        &input.asset_id,
        input.account_id.as_deref(),
    )?;
    let _lock = lock_asset(&root, &asset.id)?;
    // Re-read after taking the lock: delete/replace may have raced with the first lookup.
    let asset = visible(
        store,
        principal,
        grant,
        &asset.id,
        input.account_id.as_deref(),
    )?;
    if method != "files.read" && (input.offset.is_some() || input.length.is_some()) {
        return Err(CoreError::invalid(
            "offset and length are only valid for files.read",
        ));
    }
    match method {
        "files.read" => read(
            &root,
            &asset,
            input.offset.unwrap_or(0),
            input.length.unwrap_or(64 * 1024),
        ),
        "files.text" => {
            let mut text = extract_managed_text(&root, &asset).await?;
            let truncated = text.len() > MAX_TEXT_READ_BYTES;
            if truncated {
                text.truncate(text.floor_char_boundary(MAX_TEXT_READ_BYTES));
            }
            Ok(json!({"asset_id":asset.id,"text":text,"truncated":truncated}))
        }
        "files.delete" => delete(store, &root, &asset),
        "files.index" => {
            grant.check(principal, "sources.write")?;
            index(store, &root, &asset).await
        }
        "files.export" => Err(CoreError::new(
            "CapabilityUnavailable",
            "managed file export requires a trusted platform file picker",
        )),
        _ => unreachable!(),
    }
}

/// Returns a filesystem descriptor only to a trusted Rust host, never to dispatch.
/// The host must pass it to its file-picker port and return only a safe receipt.
pub fn export_descriptor(
    store: &Store,
    principal: &Principal,
    grant: &Grant,
    params: Value,
) -> CoreResult<Value> {
    grant.check(principal, "files.export")?;
    let input: AssetInput = serde_json::from_value(params)?;
    validate_id(&input.asset_id)?;
    check_account(principal, grant, input.account_id.as_deref())?;
    if input.offset.is_some() || input.length.is_some() {
        return Err(CoreError::invalid(
            "export requires a complete managed file",
        ));
    }
    let root = initialize(store)?;
    visible(
        store,
        principal,
        grant,
        &input.asset_id,
        input.account_id.as_deref(),
    )?;
    let _lock = lock_asset(&root, &input.asset_id)?;
    let asset = visible(
        store,
        principal,
        grant,
        &input.asset_id,
        input.account_id.as_deref(),
    )?;
    ready(&asset)?;
    let path = root.join(&asset.id);
    let size = regular_size(&path)?
        .ok_or_else(|| CoreError::new("AssetMissing", "managed file is missing"))?;
    if size != asset.size || size > MAX_FILE_BYTES {
        return Err(CoreError::new(
            "IntegrityMismatch",
            "managed export file size changed",
        ));
    }
    if asset.sha256.as_deref() != Some(file_hash(&path)?.as_str()) {
        return Err(CoreError::new(
            "IntegrityMismatch",
            "managed export file SHA-256 changed",
        ));
    }
    let path = std::fs::canonicalize(path)?;
    if path.parent() != Some(std::fs::canonicalize(&root)?.as_path()) {
        return Err(CoreError::new(
            "UnsafeAssetPath",
            "managed export file must be inside assets",
        ));
    }
    Ok(
        json!({"asset_id":asset.id,"path":path,"name":asset.name,"mime_type":asset.mime,
        "size":size,"sha256":asset.sha256}),
    )
}

fn initialize(store: &Store) -> CoreResult<PathBuf> {
    let root = store.directory.join("assets");
    std::fs::create_dir_all(&root)?;
    regular_directory(&root)?;
    if std::fs::canonicalize(&root)?.parent()
        != Some(std::fs::canonicalize(&store.directory)?.as_path())
    {
        return Err(CoreError::new(
            "UnsafeAssetPath",
            "assets directory must be inside the data directory",
        ));
    }
    store.with(|db| {
        db.execute_batch("CREATE TABLE IF NOT EXISTS managed_assets_v1(
            id TEXT PRIMARY KEY,owner TEXT NOT NULL,account_id TEXT NOT NULL,source_id TEXT NOT NULL,
            name TEXT NOT NULL,mime_type TEXT NOT NULL,state TEXT NOT NULL,size INTEGER NOT NULL,
            max_bytes INTEGER NOT NULL,reserved_bytes INTEGER NOT NULL,url_hash TEXT NOT NULL,
            request_hash TEXT NOT NULL,session_hash TEXT NOT NULL,expected_sha256 TEXT,sha256 TEXT,
            etag TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,indexed_at TEXT,error_code TEXT);
            CREATE INDEX IF NOT EXISTS managed_assets_owner_v1 ON managed_assets_v1(owner,account_id,updated_at);")?;
        Ok(())
    })?;
    // Persistent state plus OS locks distinguish a live future from process/future cancellation.
    let stale = store.with(|db| {
        let mut stmt = db.prepare("SELECT id FROM managed_assets_v1 WHERE state IN ('downloading','promoting','deleting')")?;
        Ok(stmt.query_map([], |r| r.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?)
    })?;
    for id in stale {
        validate_id(&id)?;
        let lock = match lock_asset(&root, &id) {
            Ok(lock) => lock,
            Err(e) if e.code == "AssetBusy" => continue,
            Err(e) => return Err(e),
        };
        recover(store, &root, &id)?;
        drop(lock);
    }
    Ok(root)
}

fn recover(store: &Store, root: &Path, id: &str) -> CoreResult<()> {
    let state: Option<String> = store.with(|db| {
        Ok(db
            .query_row(
                "SELECT state FROM managed_assets_v1 WHERE id=?",
                [id],
                |r| r.get(0),
            )
            .optional()?)
    })?;
    if state.as_deref() == Some("deleting") {
        return finish_delete(store, root, id);
    }
    if state.as_deref() == Some("promoting") && regular_size(&root.join(id))?.is_some() {
        let (size, digest): (u64, String) = store.with(|db| {
            Ok(db.query_row(
                "SELECT size,sha256 FROM managed_assets_v1 WHERE id=?",
                [id],
                |r| Ok((row_bytes(r, 0)?, r.get(1)?)),
            )?)
        })?;
        if regular_size(&root.join(id))? != Some(size) || size > MAX_FILE_BYTES {
            return Err(CoreError::new(
                "IntegrityMismatch",
                "promoted managed file has an invalid size",
            ));
        }
        if file_hash(&root.join(id))? != digest {
            return Err(CoreError::new(
                "IntegrityMismatch",
                "promoted managed file SHA-256 changed",
            ));
        }
        store.with(|db| { db.execute("UPDATE managed_assets_v1 SET state='ready',reserved_bytes=size WHERE id=? AND state='promoting'", [id])?; Ok(()) })?;
    } else if matches!(state.as_deref(), Some("downloading" | "promoting")) {
        let size = regular_size(&part_path(root, id))?.unwrap_or(0);
        let size = sql_bytes(size)?;
        store.with(|db| { db.execute("UPDATE managed_assets_v1 SET state='partial',size=?,reserved_bytes=?,updated_at=?,error_code='Interrupted' WHERE id=?", params![size,size,now(),id])?; Ok(()) })?;
    }
    Ok(())
}

fn scope(principal: &Principal, grant: &Grant, sql: &mut String, values: &mut Vec<SqlValue>) {
    if !principal.is_owner() {
        sql.push_str(" AND (owner=? OR source_id IN (");
        values.push(principal.id.clone().into());
        sql.push_str(&vec!["?"; grant.source_ids.len()].join(","));
        sql.push_str(")) AND (account_id='' OR account_id IN (");
        values.extend(grant.source_ids.iter().cloned().map(Into::into));
        sql.push_str(&vec!["?"; grant.account_ids.len()].join(","));
        sql.push_str("))");
        values.extend(grant.account_ids.iter().cloned().map(Into::into));
        if !grant.allows("mail.read") {
            sql.push_str(" AND source_id NOT LIKE 'mail.%'");
        }
        // Cache bytes carry the same source labels as Store records. Sharing a
        // source/account cannot erase the sensitive capabilities that produced it.
        sql.push_str(" AND NOT EXISTS(SELECT 1 FROM source_access acl,json_each(acl.capabilities) needed WHERE acl.owner=managed_assets_v1.owner AND acl.source_id=managed_assets_v1.source_id AND needed.value NOT IN (");
        let allowed: Vec<_> = grant
            .capabilities
            .iter()
            .filter(|cap| grant.allows(cap))
            .collect();
        sql.push_str(&vec!["?"; allowed.len()].join(","));
        sql.push_str("))");
        values.extend(allowed.into_iter().cloned().map(Into::into));
    }
}

fn visible(
    store: &Store,
    principal: &Principal,
    grant: &Grant,
    id: &str,
    account: Option<&str>,
) -> CoreResult<Asset> {
    let mut sql = format!("SELECT {COLUMNS} FROM managed_assets_v1 WHERE id=?");
    let mut values: Vec<SqlValue> = vec![id.to_owned().into()];
    scope(principal, grant, &mut sql, &mut values);
    if let Some(account) = account {
        sql.push_str(" AND account_id=?");
        values.push(account.to_owned().into());
    }
    store.with(|db| {
        db.query_row(&sql, params_from_iter(values), Asset::from_row)
            .optional()?
            .ok_or_else(not_found)
    })
}

fn list(
    store: &Store,
    principal: &Principal,
    grant: &Grant,
    root: &Path,
    input: ListInput,
) -> CoreResult<Value> {
    let mut sql = format!("SELECT {COLUMNS} FROM managed_assets_v1 WHERE 1=1");
    let mut values = Vec::<SqlValue>::new();
    scope(principal, grant, &mut sql, &mut values);
    for (column, filter) in [
        ("account_id", input.account_id),
        ("source_id", input.source_id),
        ("state", input.state),
    ] {
        if let Some(filter) = filter {
            sql.push_str(&format!(" AND {column}=?"));
            values.push(filter.into());
        }
    }
    let limit = input.limit.unwrap_or(50).clamp(1, 500);
    let offset = input.offset.unwrap_or(0).min(i64::MAX as u64);
    sql.push_str(" ORDER BY created_at,id LIMIT ? OFFSET ?");
    values.push((limit as i64).into());
    values.push((offset as i64).into());
    let rows = store.with(|db| {
        let mut stmt = db.prepare(&sql)?;
        Ok(stmt
            .query_map(params_from_iter(values), Asset::from_row)?
            .collect::<Result<Vec<_>, _>>()?)
    })?;
    let mut items = Vec::new();
    for mut asset in rows {
        validate_id(&asset.id)?;
        if asset.state == "downloading" || asset.state == "partial" {
            asset.size = regular_size(&part_path(root, &asset.id))?.unwrap_or(0);
        }
        items.push(asset.metadata());
    }
    Ok(json!({"items":items,"offset":offset,"limit":limit}))
}

async fn download(
    store: &Store,
    network: &Network,
    principal: &Principal,
    grant: &Grant,
    root: &Path,
    params: Value,
) -> CoreResult<Value> {
    let input: DownloadInput = serde_json::from_value(params)?;
    grant.check(principal, "http.request")?;
    check_account(principal, grant, input.account_id.as_deref())?;
    if input.url.is_empty()
        || input.url.len() > 16 * 1024
        || input.method.as_deref().is_some_and(|m| m != "GET")
    {
        return Err(CoreError::invalid(
            "managed downloads require a bounded URL and GET method",
        ));
    }
    if input.resume && input.asset_id.is_none() {
        return Err(CoreError::invalid("resume requires asset_id"));
    }
    if input.headers.keys().any(|h| {
        matches!(
            h.to_ascii_lowercase().as_str(),
            "range"
                | "if-range"
                | "if-match"
                | "if-none-match"
                | "if-modified-since"
                | "if-unmodified-since"
                | "accept-encoding"
        )
    }) {
        return Err(CoreError::invalid(
            "range, validators and encoding are controlled by the asset manager",
        ));
    }
    let expected = input.sha256.as_deref().map(validate_sha).transpose()?;
    let session_hash = network.session_fingerprint(input.account_id.as_deref())?;
    let url_hash = hash(input.url.as_bytes());
    let request_hash = hash(
        serde_json::to_vec(&json!([
            input.url,
            input.headers,
            input.account_id,
            expected,
            session_hash
        ]))?
        .as_slice(),
    );
    let id = input
        .asset_id
        .clone()
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    validate_id(&id)?;
    let existing = if input.asset_id.is_some() {
        Some(visible(
            store,
            principal,
            grant,
            &id,
            input.account_id.as_deref(),
        )?)
    } else {
        None
    };
    let _lock = lock_asset(root, &id)?;
    let existing = if existing.is_some() {
        Some(visible(
            store,
            principal,
            grant,
            &id,
            input.account_id.as_deref(),
        )?)
    } else {
        None
    };
    if let Some(asset) = &existing {
        if asset.url_hash != url_hash
            || asset.request_hash != request_hash
            || asset.session_hash != session_hash
            || asset.expected != expected
            || asset.account != input.account_id.as_deref().unwrap_or("")
        {
            return Err(CoreError::new(
                "ResumeMismatch",
                "asset resume binding does not match the original request/session/account/hash",
            ));
        }
        if asset.state == "ready" {
            return Ok(asset.metadata());
        }
        if asset.state != "partial" {
            return Err(CoreError::new(
                "AssetBusy",
                "asset is not available for download",
            ));
        }
    }
    let max_bytes = input
        .max_bytes
        .or_else(|| existing.as_ref().map(|a| a.max_bytes))
        .unwrap_or(MAX_FILE_BYTES);
    if max_bytes == 0 || max_bytes > MAX_FILE_BYTES {
        return Err(CoreError::new("QuotaExceeded", "per-file quota is 100 MiB"));
    }
    let source = input
        .source_id
        .clone()
        .or_else(|| existing.as_ref().map(|a| a.source.clone()))
        .unwrap_or_else(|| {
            if principal.kind == PrincipalKind::Plugin {
                format!("{}.documents", principal.id.trim_start_matches("plugin:"))
            } else {
                "files.documents".into()
            }
        });
    validate_label(&source, "source_id", 256)?;
    if principal.kind == PrincipalKind::Plugin
        && !source.starts_with(&format!("{}.", principal.id.trim_start_matches("plugin:")))
    {
        return Err(CoreError::new(
            "PermissionDenied",
            "plugin document sources must use their own id prefix",
        ));
    }
    let name = input
        .name
        .clone()
        .or_else(|| existing.as_ref().map(|a| a.name.clone()))
        .unwrap_or_else(|| "document".into());
    validate_label(&name, "name", 255)?;
    let mime = input
        .mime_type
        .as_deref()
        .map(validate_mime)
        .transpose()?
        .or_else(|| existing.as_ref().map(|a| a.mime.clone()))
        .unwrap_or_else(|| "application/octet-stream".into());
    if existing.as_ref().is_some_and(|a| {
        a.source != source || a.name != name || (input.mime_type.is_some() && a.mime != mime)
    }) {
        return Err(CoreError::new(
            "ResumeMismatch",
            "asset metadata cannot change during resume",
        ));
    }
    let part = part_path(root, &id);
    let size = regular_size(&part)?.unwrap_or(0);
    if size > max_bytes {
        return Err(CoreError::new(
            "QuotaExceeded",
            "partial exceeds requested byte quota",
        ));
    }
    // Reserve the entire permitted sink size in the same SQLite transaction as the state change.
    let sql_limit = sql_bytes(max_bytes)?;
    store.with(|db| {
        let tx = db.transaction()?;
        let used: i64 = tx.query_row("SELECT coalesce(sum(reserved_bytes),0) FROM managed_assets_v1 WHERE id<>?", [&id], |r| r.get(0))?;
        let used = u64::try_from(used).map_err(|_|CoreError::new("StorageError", "invalid managed byte reservation"))?;
        if used.saturating_add(max_bytes) > MAX_TOTAL_BYTES { return Err(CoreError::new("QuotaExceeded", "managed files total quota is 512 MiB, including active reservations")); }
        if existing.is_some() {
            tx.execute("UPDATE managed_assets_v1 SET state='downloading',reserved_bytes=?,max_bytes=?,error_code=NULL,updated_at=? WHERE id=?", params![sql_limit,sql_limit,now(),id])?;
        } else {
            tx.execute("INSERT INTO managed_assets_v1(id,owner,account_id,source_id,name,mime_type,state,size,max_bytes,reserved_bytes,url_hash,request_hash,session_hash,expected_sha256,created_at,updated_at) VALUES(?,?,?,?,?,?,'downloading',0,?,?,?,?,?,?,?,?)", params![id,principal.id,input.account_id.as_deref().unwrap_or(""),source,name,mime,sql_limit,sql_limit,url_hash,request_hash,session_hash,expected,now(),now()])?;
        }
        tx.commit()?; Ok(())
    })?;
    let bound_account = input.account_id.clone();
    let mut guard = TransferGuard {
        store,
        root,
        id: &id,
        complete: false,
        error: "Interrupted".into(),
    };
    let result: CoreResult<Value> = async {
        let mut request = HttpRequest { url: input.url, method: "GET".into(), headers: input.headers, body: None, account_id: input.account_id, timeout_ms: input.timeout_ms,follow_redirects:true };
        request.headers.insert("accept-encoding".into(), "identity".into());
        let mut etag = existing.as_ref().and_then(|a|a.etag.clone());
        let resume = input.resume && size > 0 && etag.is_some();
        if !resume {
            let mut head = request.clone(); head.method = "HEAD".into();
            let response = network.request(principal, grant, head).await?;
            etag = if response.status == 200 { strong_etag(header(&response.headers, "etag")) } else { None };
            if let Some(length) = header(&response.headers, "content-length").and_then(|s|s.parse::<u64>().ok())
                && response.status == 200 && length > max_bytes {
                return Err(CoreError::new("ResponseTooLarge", "document exceeds requested byte quota"));
            }
            let detected = header(&response.headers, "content-type").and_then(|m| validate_mime(m).ok());
            store.with(|db| { db.execute("UPDATE managed_assets_v1 SET etag=?,mime_type=CASE WHEN mime_type='application/octet-stream' THEN coalesce(?,mime_type) ELSE mime_type END WHERE id=?", params![etag,detected,id])?; Ok(()) })?;
            // A newly discovered validator cannot authenticate bytes from an earlier unvalidated transfer.
            let file = OpenOptions::new().create(true).write(true).truncate(true).open(&part)?;
            file.sync_all()?;
            if let Some(etag) = &etag { request.headers.insert("if-match".into(), etag.clone()); }
        } else {
            request.headers.insert("range".into(), format!("bytes={size}-"));
            request.headers.insert("if-range".into(), etag.clone().unwrap());
        }
        if network.session_fingerprint(bound_account.as_deref())? != session_hash {
            return Err(CoreError::new("ResumeMismatch", "HTTP session changed before the download"));
        }
        let receipt = network.download(principal, grant, request, part.clone(), max_bytes, resume).await?;
        if network.session_fingerprint(bound_account.as_deref())? != session_hash {
            return Err(CoreError::new("ResumeMismatch", "HTTP session changed during the download"));
        }
        if !matches!(receipt.status, 200|206) || (receipt.status == 206 && !resume) {
            return Err(CoreError::new("InvalidResponse", "download returned an unexpected success status"));
        }
        if receipt.status == 206 && strong_etag(header(&receipt.headers, "etag")) != etag {
            // Do not append to these bytes again if a server violates validator semantics.
            store.with(|db| { db.execute("UPDATE managed_assets_v1 SET etag=NULL WHERE id=?", [&id])?; Ok(()) })?;
            return Err(CoreError::new("InvalidResponse", "resumed response did not confirm the strong validator"));
        }
        if receipt.status == 206
            && let Err(error) = validate_complete_range(header(&receipt.headers, "content-range"), size, receipt.size) {
            store.with(|db| { db.execute("UPDATE managed_assets_v1 SET etag=NULL WHERE id=?", [&id])?; Ok(()) })?;
            return Err(error);
        }
        let actual = regular_size(&part)?.ok_or_else(||CoreError::new("AssetMissing", "download sink is missing"))?;
        let digest = validate_sha(&receipt.sha256)?;
        if actual != receipt.size || actual > max_bytes { return Err(CoreError::new("InvalidResponse", "download receipt size does not match the managed file")); }
        if expected.as_ref().is_some_and(|s| s != &digest) {
            store.with(|db| { db.execute("UPDATE managed_assets_v1 SET etag=NULL WHERE id=?", [&id])?; Ok(()) })?;
            std::fs::remove_file(&part)?;
            return Err(CoreError::new("IntegrityMismatch", "download SHA-256 did not match the expected value"));
        }
        let etag = strong_etag(header(&receipt.headers, "etag"));
        let actual = sql_bytes(actual)?;
        // Persist a promotion intent before atomic rename. Crash recovery can complete either side.
        store.with(|db| { db.execute("UPDATE managed_assets_v1 SET state='promoting',size=?,reserved_bytes=?,sha256=?,etag=?,updated_at=? WHERE id=?", params![actual,actual,digest,etag,now(),id])?; Ok(()) })?;
        if regular_size(&root.join(&id))?.is_some() { return Err(CoreError::new("UnsafeAssetPath", "managed final file already exists")); }
        std::fs::rename(&part, root.join(&id))?;
        store.with(|db| { db.execute("UPDATE managed_assets_v1 SET state='ready',error_code=NULL,updated_at=? WHERE id=?", params![now(),id])?; Ok(()) })?;
        guard.complete = true;
        Ok(visible(store, principal, grant, &id, None)?.metadata())
    }.await;
    if let Err(e) = &result {
        guard.error = safe_error_code(&e.code);
    }
    result
}

struct TransferGuard<'a> {
    store: &'a Store,
    root: &'a Path,
    id: &'a str,
    complete: bool,
    error: String,
}
impl Drop for TransferGuard<'_> {
    fn drop(&mut self) {
        if self.complete {
            return;
        }
        let size = regular_size(&part_path(self.root, self.id))
            .ok()
            .flatten()
            .unwrap_or(0);
        let _ = self.store.with(|db| {
            let size = sql_bytes(size)?;
            db.execute("UPDATE managed_assets_v1 SET state='partial',size=?,reserved_bytes=?,error_code=?,updated_at=? WHERE id=? AND state='downloading'", params![size,size,self.error,now(),self.id])?;
            Ok(())
        });
    }
}

fn read(root: &Path, asset: &Asset, offset: u64, length: u64) -> CoreResult<Value> {
    ready(asset)?;
    if length == 0 || length > MAX_READ_BYTES {
        return Err(CoreError::invalid("read length must be 1 byte to 1 MiB"));
    }
    let path = root.join(&asset.id);
    let size = regular_size(&path)?
        .ok_or_else(|| CoreError::new("AssetMissing", "managed file is missing"))?;
    if size != asset.size {
        return Err(CoreError::new(
            "IntegrityMismatch",
            "managed file size changed",
        ));
    }
    if offset > size {
        return Err(CoreError::invalid("offset is past end of file"));
    }
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::with_capacity(length.min(size - offset) as usize);
    file.take(length).read_to_end(&mut bytes)?;
    let next = offset + bytes.len() as u64;
    Ok(
        json!({"asset_id":asset.id,"encoding":"base64","data":STANDARD.encode(&bytes),"offset":offset,"length":bytes.len(),"next_offset":next,"eof":next==size}),
    )
}

fn delete(store: &Store, root: &Path, asset: &Asset) -> CoreResult<Value> {
    store.with(|db| {
        db.execute(
            "UPDATE managed_assets_v1 SET state='deleting',updated_at=? WHERE id=?",
            params![now(), asset.id],
        )?;
        Ok(())
    })?;
    finish_delete(store, root, &asset.id)?;
    Ok(json!({"asset_id":asset.id,"deleted":true}))
}

fn finish_delete(store: &Store, root: &Path, id: &str) -> CoreResult<()> {
    for path in [root.join(id), part_path(root, id)] {
        if regular_size(&path)?.is_some() {
            std::fs::remove_file(path)?;
        }
    }
    store.with(|db| {
        let tx = db.transaction()?;
        tx.execute("DELETE FROM records WHERE external_id=? AND EXISTS(SELECT 1 FROM managed_assets_v1 a WHERE a.id=? AND a.owner=records.owner AND a.account_id=records.account_id AND a.source_id=records.source_id)", params![format!("asset:{id}"),id])?;
        tx.execute("DELETE FROM managed_assets_v1 WHERE id=? AND state='deleting'", [id])?;
        tx.commit()?; Ok(())
    })
}

async fn extract_managed_text(root: &Path, asset: &Asset) -> CoreResult<String> {
    ready(asset)?;
    if asset.size > MAX_INDEX_BYTES {
        return Err(CoreError::new(
            "DocumentTooLarge",
            "document extraction input exceeds 8 MiB",
        ));
    }
    let path = root.join(&asset.id);
    let size = regular_size(&path)?
        .ok_or_else(|| CoreError::new("AssetMissing", "managed file is missing"))?;
    if size != asset.size {
        return Err(CoreError::new(
            "IntegrityMismatch",
            "managed file size changed",
        ));
    }
    let mime = asset.mime.clone();
    let expected = asset.sha256.clone();
    let permit =
        INDEX_WORKERS.clone().acquire_owned().await.map_err(|_| {
            CoreError::new("Shutdown", "document extraction workers are unavailable")
        })?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let mut bytes = Vec::new();
        File::open(path)?
            .take(MAX_INDEX_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_INDEX_BYTES {
            return Err(CoreError::new(
                "DocumentTooLarge",
                "document extraction input exceeds 8 MiB",
            ));
        }
        if expected.as_deref() != Some(hash(&bytes).as_str()) {
            return Err(CoreError::new(
                "IntegrityMismatch",
                "managed document SHA-256 changed",
            ));
        }
        extract(&bytes, &mime)
    })
    .await
    .map_err(|_| CoreError::new("DocumentParseError", "document extraction stopped"))?
}

async fn index(store: &Store, root: &Path, asset: &Asset) -> CoreResult<Value> {
    let text = extract_managed_text(root, asset).await?;
    // The Store creates the search record with its standard FTS triggers and size checks.
    let external = format!("asset:{}", asset.id);
    let data = json!({"asset_id":asset.id,"name":asset.name,"mime_type":asset.mime,"sha256":asset.sha256,"text":text});
    store.record_upsert(
        &asset.owner,
        &asset.account,
        &asset.source,
        &external,
        "document",
        &data,
    )?;
    let indexed_at = now();
    store.with(|db| {
        db.execute(
            "UPDATE managed_assets_v1 SET indexed_at=?,updated_at=? WHERE id=? AND state='ready'",
            params![indexed_at, indexed_at, asset.id],
        )?;
        Ok(())
    })?;
    Ok(
        json!({"asset_id":asset.id,"owner":asset.owner,"account_id":asset.account,"source_id":asset.source,"external_id":external,"kind":"document","text_bytes":text.len(),"indexed_at":indexed_at}),
    )
}

#[cfg(feature = "pdf")]
mod pdf {
    use super::*;
    use pdf_extract::{Dictionary, Document, Object, ObjectId, PlainTextOutput, content::Content};
    use std::{
        collections::BTreeSet,
        io::Write,
        time::{Duration, Instant},
    };

    const MAX_STREAM: usize = 4 * 1024 * 1024;
    const MAX_STREAMS: usize = 16 * 1024 * 1024;
    const MAX_NODES: usize = 65_536;
    const MAX_OPERATIONS: usize = 65_536;
    const MAX_DEPTH: usize = 32;

    pub(super) fn extract(bytes: &[u8]) -> CoreResult<String> {
        if bytes.len() as u64 > MAX_INDEX_BYTES {
            return Err(large());
        }
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut doc = Document::load_mem_with_options(
            bytes,
            pdf_extract::LoadOptions {
                strict: true,
                ..Default::default()
            },
        )
        .map_err(|_| parse())?;
        if doc.is_encrypted() || doc.was_encrypted() {
            return Err(CoreError::new(
                "EncryptedDocument",
                "encrypted PDF indexing is unsupported",
            ));
        }
        if doc.objects.len() > MAX_PDF_OBJECTS
            || doc.reference_table.entries.len() > MAX_PDF_OBJECTS
        {
            return Err(complex("PDF exceeds 4096 objects"));
        }
        let mut nodes = 0usize;
        for object in doc
            .objects
            .values()
            .chain(std::iter::once(&Object::Dictionary(doc.trailer.clone())))
        {
            let mut stack = vec![(object, 0usize)];
            while let Some((object, depth)) = stack.pop() {
                nodes += 1;
                if depth > MAX_DEPTH || nodes > MAX_NODES {
                    return Err(complex("PDF object structure exceeds its depth/node limit"));
                }
                match object {
                    Object::Array(items) => stack.extend(items.iter().map(|v| (v, depth + 1))),
                    Object::Dictionary(dict) => {
                        if dict.has_type(b"Pages") {
                            let count = dict
                                .get(b"Count")
                                .and_then(Object::as_i64)
                                .map_err(|_| parse())?;
                            if count < 0 {
                                return Err(parse());
                            }
                            if count > MAX_PDF_PAGES as i64 {
                                return Err(complex("PDF exceeds 128 pages"));
                            }
                        }
                        stack.extend(dict.iter().map(|(_, v)| (v, depth + 1)));
                    }
                    Object::Stream(stream) => {
                        stack.extend(stream.dict.iter().map(|(_, v)| (v, depth + 1)))
                    }
                    _ => {}
                }
            }
        }
        // This accounting follows the parser's own load/decode allocations. It
        // bounds retained/executed data, not the parser process's peak heap.
        let mut decoded = 0usize;
        for object in doc.objects.values_mut() {
            if let Object::Stream(stream) = object {
                if stream.dict.get(b"Subtype").and_then(Object::as_name).ok() == Some(b"Image") {
                    // No image decoder or OCR. Do operators on images become empty.
                    stream.set_plain_content(Vec::new());
                    continue;
                }
                if stream.content.len() > MAX_STREAM {
                    return Err(large());
                }
                let plain = stream.get_plain_content().map_err(|_| parse())?;
                decoded = decoded.checked_add(plain.len()).ok_or_else(large)?;
                if plain.len() > MAX_STREAM || decoded > MAX_STREAMS {
                    return Err(large());
                }
                stream.set_plain_content(plain);
                check_time(deadline)?;
            }
        }
        // Do not trust a declared page count or allocate based on iterator hints.
        let mut pages = Vec::new();
        for id in doc.page_iter() {
            if pages.len() == MAX_PDF_PAGES {
                return Err(complex("PDF exceeds 128 pages"));
            }
            pages.push(id);
        }
        if pages.is_empty() {
            return Err(parse());
        }
        let empty = Dictionary::new();
        let mut operations = 0usize;
        for id in &pages {
            validate_parent_chain(&doc, *id)?;
            let media = inherited(&doc, *id, b"MediaBox")?
                .ok_or_else(parse)?
                .as_array()
                .map_err(|_| parse())?;
            if media.len() != 4
                || media
                    .iter()
                    .any(|v| v.as_float().map(|v| !v.is_finite()).unwrap_or(true))
            {
                return Err(parse());
            }
            let resources = inherited(&doc, *id, b"Resources")?
                .map(|o| dictionary(&doc, o))
                .transpose()?
                .unwrap_or(&empty);
            let content = doc.get_page_content(*id).map_err(|_| parse())?;
            if content.len() > MAX_STREAM {
                return Err(large());
            }
            validate_content(
                &doc,
                &content,
                resources,
                &mut BTreeSet::new(),
                &mut operations,
                0,
                deadline,
            )?;
        }
        let mut writer = BoundedText {
            bytes: Vec::new(),
            full: false,
            timed_out: false,
            deadline,
        };
        for page in 1..=pages.len() {
            check_time(deadline)?;
            let mut output = PlainTextOutput::new(&mut writer as &mut dyn Write);
            let result = pdf_extract::output_doc_page(&doc, &mut output, page as u32);
            if writer.full {
                return Err(large());
            }
            if writer.timed_out {
                return Err(timeout());
            }
            result.map_err(|_| parse())?;
            writer.write_all(b"\n").map_err(|_| large())?;
        }
        let text = String::from_utf8(writer.bytes).map_err(|_| parse())?;
        if text.trim().is_empty() {
            return Err(CoreError::new(
                "NoExtractableText",
                "PDF contains no extractable text; OCR is unsupported",
            ));
        }
        Ok(text.trim().to_owned())
    }

    fn validate_parent_chain(doc: &Document, id: ObjectId) -> CoreResult<()> {
        let mut seen = BTreeSet::new();
        let mut next = Some(id);
        while let Some(id) = next {
            if !seen.insert(id) {
                return Err(parse());
            }
            if seen.len() > MAX_DEPTH {
                return Err(complex("PDF page inheritance exceeds 32 levels"));
            }
            let dict = doc.get_dictionary(id).map_err(|_| parse())?;
            next = dict
                .get(b"Parent")
                .ok()
                .map(Object::as_reference)
                .transpose()
                .map_err(|_| parse())?;
        }
        Ok(())
    }

    fn inherited<'a>(
        doc: &'a Document,
        mut id: ObjectId,
        key: &[u8],
    ) -> CoreResult<Option<&'a Object>> {
        for _ in 0..MAX_DEPTH {
            let dict = doc.get_dictionary(id).map_err(|_| parse())?;
            if let Ok(object) = dict.get(key) {
                return doc
                    .dereference(object)
                    .map(|(_, o)| Some(o))
                    .map_err(|_| parse());
            }
            match dict.get(b"Parent") {
                Ok(parent) => id = parent.as_reference().map_err(|_| parse())?,
                Err(_) => return Ok(None),
            }
        }
        Err(complex("PDF inheritance exceeds 32 levels"))
    }
    fn dictionary<'a>(doc: &'a Document, object: &'a Object) -> CoreResult<&'a Dictionary> {
        doc.dereference(object)
            .and_then(|(_, o)| o.as_dict())
            .map_err(|_| parse())
    }

    fn validate_content(
        doc: &Document,
        bytes: &[u8],
        resources: &Dictionary,
        active: &mut BTreeSet<ObjectId>,
        operations: &mut usize,
        depth: usize,
        deadline: Instant,
    ) -> CoreResult<()> {
        if depth > 16 {
            return Err(complex("PDF form nesting exceeds 16 levels"));
        }
        check_time(deadline)?;
        let content = Content::decode(bytes).map_err(|_| parse())?;
        *operations = operations
            .checked_add(content.operations.len())
            .ok_or_else(|| complex("PDF operation limit exceeded"))?;
        if *operations > MAX_OPERATIONS {
            return Err(complex("PDF exceeds 65536 expanded content operations"));
        }
        for operation in content.operations {
            if operation.operator == "Do" {
                let name = operation
                    .operands
                    .first()
                    .ok_or_else(parse)?
                    .as_name()
                    .map_err(|_| parse())?;
                let objects = dictionary(doc, resources.get(b"XObject").map_err(|_| parse())?)?;
                let object = objects.get(name).map_err(|_| parse())?;
                let id = object.as_reference().map_err(|_| parse())?;
                if !active.insert(id) {
                    return Err(parse());
                }
                let stream = doc
                    .get_object(id)
                    .and_then(Object::as_stream)
                    .map_err(|_| parse())?;
                let nested = stream
                    .dict
                    .get(b"Resources")
                    .ok()
                    .map(|o| dictionary(doc, o))
                    .transpose()?
                    .unwrap_or(resources);
                validate_content(
                    doc,
                    &stream.content,
                    nested,
                    active,
                    operations,
                    depth + 1,
                    deadline,
                )?;
                active.remove(&id);
            }
        }
        Ok(())
    }

    struct BoundedText {
        bytes: Vec<u8>,
        full: bool,
        timed_out: bool,
        deadline: Instant,
    }
    impl Write for BoundedText {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if Instant::now() >= self.deadline {
                self.timed_out = true;
                return Err(std::io::ErrorKind::TimedOut.into());
            }
            if self.bytes.len().saturating_add(bytes.len()) > MAX_TEXT_BYTES {
                self.full = true;
                return Err(std::io::ErrorKind::FileTooLarge.into());
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    fn check_time(deadline: Instant) -> CoreResult<()> {
        if Instant::now() >= deadline {
            Err(timeout())
        } else {
            Ok(())
        }
    }
    fn timeout() -> CoreError {
        CoreError::new(
            "DocumentTimeout",
            "PDF extraction exceeded its cooperative deadline",
        )
    }
    fn parse() -> CoreError {
        CoreError::new(
            "DocumentParseError",
            "PDF document is malformed or uses unsupported content",
        )
    }
    fn large() -> CoreError {
        CoreError::new(
            "DocumentTooLarge",
            "PDF decoded content or extracted text exceeds its byte limit",
        )
    }
    fn complex(message: &str) -> CoreError {
        CoreError::new("DocumentTooComplex", message)
    }
}

fn extract(bytes: &[u8], mime: &str) -> CoreResult<String> {
    if mime == "application/pdf" || bytes.starts_with(b"%PDF-") {
        #[cfg(feature = "pdf")]
        return pdf::extract(bytes);
        #[cfg(not(feature = "pdf"))]
        return Err(CoreError::new(
            "CapabilityUnavailable",
            "PDF text extraction requires the optional pdf feature; OCR is unsupported",
        ));
    }
    if !mime.starts_with("text/")
        && !matches!(
            mime,
            "application/xhtml+xml" | "application/json" | "application/xml"
        )
    {
        return Err(CoreError::new(
            "UnsupportedContent",
            "document is not a supported text or HTML format",
        ));
    }
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let source = std::str::from_utf8(bytes).map_err(|_| {
        CoreError::new(
            "DocumentParseError",
            "document must contain valid UTF-8 text",
        )
    })?;
    if source.contains('\0') {
        return Err(CoreError::new(
            "DocumentParseError",
            "document contains binary NUL bytes",
        ));
    }
    let text = if matches!(mime, "text/html" | "application/xhtml+xml") {
        if source.bytes().filter(|b| *b == b'<').count() > 16_384 {
            return Err(CoreError::new(
                "DocumentTooComplex",
                "HTML document exceeds the markup complexity limit",
            ));
        }
        let html = scraper::Html::parse_document(source);
        let mut output = String::new();
        for node in html.tree.nodes() {
            if let scraper::Node::Text(text) = node.value() {
                let mut hidden = false;
                for (depth, ancestor) in node.ancestors().enumerate() {
                    if depth > 256 {
                        return Err(CoreError::new(
                            "DocumentTooComplex",
                            "HTML nesting exceeds 256 levels",
                        ));
                    }
                    if matches!(ancestor.value(), scraper::Node::Element(e) if matches!(e.name(), "script"|"style"|"noscript"|"template"|"head"))
                    {
                        hidden = true;
                    }
                }
                if !hidden {
                    if output.len().saturating_add(text.len()).saturating_add(1) > MAX_TEXT_BYTES {
                        return Err(CoreError::new(
                            "DocumentTooLarge",
                            "extracted document text exceeds 256 KiB",
                        ));
                    }
                    output.push_str(text);
                    output.push('\n');
                }
            }
        }
        output
    } else {
        source.to_owned()
    };
    if text.len() > MAX_TEXT_BYTES {
        return Err(CoreError::new(
            "DocumentTooLarge",
            "extracted document text exceeds 256 KiB",
        ));
    }
    if text.trim().is_empty() {
        return Err(CoreError::new(
            "DocumentParseError",
            "document contains no extractable text",
        ));
    }
    Ok(text.trim().to_owned())
}

fn ready(asset: &Asset) -> CoreResult<()> {
    if asset.state == "ready" {
        Ok(())
    } else {
        Err(CoreError::new(
            "AssetNotReady",
            "managed file is not complete",
        ))
    }
}
fn check_account(principal: &Principal, grant: &Grant, account: Option<&str>) -> CoreResult<()> {
    if account.is_some_and(str::is_empty) {
        return Err(CoreError::invalid(
            "account_id must be omitted for anonymous files",
        ));
    }
    grant.check_account(principal, account)
}
fn validate_id(id: &str) -> CoreResult<()> {
    if Uuid::parse_str(id)
        .ok()
        .is_some_and(|v| v.get_version_num() == 4 && v.to_string() == id)
    {
        Ok(())
    } else {
        Err(CoreError::invalid(
            "asset_id must be a canonical managed UUID v4",
        ))
    }
}
fn validate_label(value: &str, label: &str, max: usize) -> CoreResult<()> {
    if value.trim().is_empty()
        || value.len() > max
        || value
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\'))
    {
        return Err(CoreError::invalid(format!("invalid {label}")));
    }
    Ok(())
}
fn validate_mime(value: &str) -> CoreResult<String> {
    let mime = value
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if mime.len() > 127
        || !mime.contains('/')
        || !mime
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/!#$&^_.+-".contains(&b))
    {
        return Err(CoreError::invalid("invalid MIME type"));
    }
    Ok(mime)
}
fn validate_sha(value: &str) -> CoreResult<String> {
    if value.len() != 64 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(CoreError::invalid(
            "sha256 must contain 64 hexadecimal characters",
        ));
    }
    Ok(value.to_ascii_lowercase())
}
fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn file_hash(path: &Path) -> CoreResult<String> {
    let mut input = File::open(path)?.take(MAX_FILE_BYTES + 1);
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
    }
    Ok(hex::encode(digest.finalize()))
}
fn now() -> String {
    Utc::now().to_rfc3339()
}
fn not_found() -> CoreError {
    CoreError::new("NotFound", "managed file not found")
}
fn part_path(root: &Path, id: &str) -> PathBuf {
    root.join(format!("{id}.part"))
}
fn header<'a>(headers: &'a BTreeMap<String, String>, name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}
fn strong_etag(value: Option<&str>) -> Option<String> {
    value
        .filter(|v| {
            v.len() >= 2
                && v.len() <= 512
                && v.starts_with('"')
                && v.ends_with('"')
                && v.as_bytes()[1..v.len() - 1]
                    .iter()
                    .all(|b| *b >= 0x21 && *b != 0x22 && *b != 0x7f)
        })
        .map(str::to_owned)
}
fn validate_complete_range(value: Option<&str>, offset: u64, final_size: u64) -> CoreResult<()> {
    let parsed = value
        .and_then(|v| v.strip_prefix("bytes "))
        .and_then(|v| v.split_once('/'))
        .and_then(|(extent, total)| {
            let (start, end) = extent.split_once('-')?;
            Some((
                start.parse::<u64>().ok()?,
                end.parse::<u64>().ok()?,
                total.parse::<u64>().ok()?,
            ))
        });
    if parsed.is_some_and(|(start, end, total)| {
        start == offset
            && end >= start
            && end.checked_add(1) == Some(final_size)
            && total == final_size
    }) {
        Ok(())
    } else {
        Err(CoreError::new(
            "InvalidResponse",
            "resume did not return a complete, consistent Content-Range",
        ))
    }
}
fn safe_error_code(code: &str) -> String {
    if code.len() <= 64 && code.bytes().all(|b| b.is_ascii_alphanumeric()) {
        code.into()
    } else {
        "DownloadFailed".into()
    }
}
fn sql_bytes(value: u64) -> CoreResult<i64> {
    i64::try_from(value).map_err(|_| {
        CoreError::new(
            "QuotaExceeded",
            "managed byte count exceeds SQLite integer range",
        )
    })
}
fn row_bytes(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}
fn regular_directory(path: &Path) -> CoreResult<()> {
    let meta = std::fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(CoreError::new(
            "UnsafeAssetPath",
            "managed assets directory cannot be a link",
        ));
    }
    Ok(())
}
fn regular_size(path: &Path) -> CoreResult<Option<u64>> {
    match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_symlink() || !m.is_file() => Err(CoreError::new(
            "UnsafeAssetPath",
            "managed asset cannot be a link or directory",
        )),
        Ok(m) => Ok(Some(m.len())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}
fn lock_asset(root: &Path, id: &str) -> CoreResult<File> {
    let path = root.join(format!("{id}.lock"));
    regular_size(&path)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)?;
    lock.try_lock_exclusive().map_err(|e| {
        if e.kind() == std::io::ErrorKind::WouldBlock
            || e.raw_os_error() == fs2::lock_contended_error().raw_os_error()
        {
            CoreError::new("AssetBusy", "managed file is in use")
        } else {
            e.into()
        }
    })?;
    Ok(lock)
}
