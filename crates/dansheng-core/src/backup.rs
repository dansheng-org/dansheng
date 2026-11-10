//! Bounded local profile snapshots and offline, recoverable directory replacement.
//! Native host/CLI APIs only; no live-engine restore or caller-selected SQL.
use crate::{
    api::{CoreError, CoreResult},
    plugins,
    store::Store,
};
use chrono::Utc;
use fs2::FileExt;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    time::SystemTime,
};
use uuid::Uuid;

const FORMAT: &str = "dansheng-profile-snapshot";
const MAX_FILES: usize = 20_000;
const MAX_MANIFEST: u64 = 8 * 1024 * 1024;
const MAX_FILE: u64 = 1024 * 1024 * 1024;
const MAX_TOTAL: u64 = 2 * 1024 * 1024 * 1024;
const ROOT_VERSION: i64 = 3;
const ROOT_FILES: &[&str] = &[
    "dansheng.db",
    "dansheng.db-wal",
    "dansheng.db-shm",
    "core.lock",
];
const ROOT_DIRS: &[&str] = &[
    "assets",
    "plugins",
    "backups",
    "package-downloads",
    "host",
    "vault",
];

#[derive(Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format: String,
    version: u32,
    id: String,
    created_at: String,
    database_version: i64,
    directories: Vec<String>,
    files: Vec<ManifestFile>,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ManifestFile {
    path: String,
    size: u64,
    sha256: String,
}
#[derive(Clone, PartialEq, Eq)]
struct Stamp {
    size: u64,
    modified: Option<SystemTime>,
}
#[derive(Default, PartialEq, Eq)]
struct Inventory {
    files: BTreeMap<String, Stamp>,
    directories: BTreeSet<String>,
}
#[derive(Clone)]
struct Asset {
    id: String,
    size: u64,
    sha256: String,
}
struct Registry {
    id: String,
    path: String,
    manifest: Value,
    verification: Option<Value>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Pointer {
    generation: String,
    version: String,
    #[serde(default)]
    previous_generation: Option<String>,
    #[serde(default)]
    manifest_sha256: Option<String>,
    #[serde(default)]
    package_sha256: Option<String>,
    #[serde(default)]
    verification: Option<plugins::PackageVerification>,
}
#[derive(Default)]
struct Control {
    plugins: Vec<(String, String)>,
    source_access: Vec<(String, String, BTreeSet<String>)>,
    event_floor: i64,
}
enum RegistryPaths<'a> {
    Live,
    Snapshot,
    Restored(&'a Path),
}

/// Online SQLite backup plus immutable managed payloads. Only a completely
/// validated snapshot is renamed from `.incomplete-*` to its final UUID directory.
pub fn create(store: &Store) -> CoreResult<Value> {
    let root = existing_directory(&store.directory)?;
    check_profile_children(&root)?;
    let backups = checked_directory(&root, "backups")?;
    let id = Uuid::new_v4().to_string();
    let incomplete = backups.join(format!(".incomplete-{id}"));
    make_private_directory(&incomplete)?;
    let completed = backups.join(&id);
    let database = incomplete.join("dansheng.db");
    // The ONLY live-Store critical section. All schema checks, metadata reads,
    // payload locks/copies/hashes below operate on the independent image.
    store.with(|db| {
        db.backup(
            rusqlite::MAIN_DB,
            &database,
            None::<fn(rusqlite::backup::Progress)>,
        )?;
        Ok(())
    })?;
    let mut image = open_database(&database, false)?;
    check_database(&image)?;
    let assets = ready_assets(&image)?;
    let _plugin_locks = lock_plugins(&root)?;
    let _asset_locks = lock_assets(&root, &assets)?;
    let before = payload_inventory(&root, &assets, true).map_err(capture_error)?;
    // A promotion after the database instant is a retry, never a mixture of
    // the old registry with a new pointer. Immutable generations stay locked.
    let paths = validate_plugins(&root, &image, &RegistryPaths::Live).map_err(capture_error)?;
    sanitize_database(&mut image, None, false)?;
    for (plugin, path) in &paths {
        image.execute(
            "UPDATE plugins SET path=?,enabled=0 WHERE id=?",
            params![path, plugin],
        )?;
    }
    compact(&image)?;
    check_database(&image)?;
    drop(image);
    let mut entries = Vec::new();
    let mut total = 0;
    for directory in &before.directories {
        create_relative_directory(&incomplete, directory)?;
    }
    entries.push(hash_file_entry(&incomplete, "dansheng.db", &mut total)?);
    for (name, stamp) in &before.files {
        let entry = copy_file_checked(&root, &incomplete, name, Some(stamp), &mut total)?;
        if let Some(asset) = assets.iter().find(|a| name == &format!("assets/{}", a.id))
            && (entry.size != asset.size || entry.sha256 != asset.sha256)
        {
            return Err(changed());
        }
        entries.push(entry);
    }
    if payload_inventory(&root, &assets, true)? != before {
        return Err(changed());
    }
    // Re-read all selected source bytes. File locks coordinate compliant
    // writers; hashes also catch out-of-band modification during capture.
    for entry in entries.iter().filter(|e| e.path != "dansheng.db") {
        if digest_file(&root.join(&entry.path), MAX_FILE)?.1 != entry.sha256 {
            return Err(changed());
        }
    }
    entries.sort_by(|a, b| a.path.cmp(&b.path));
    let manifest = Manifest {
        format: FORMAT.into(),
        version: 1,
        id: id.clone(),
        created_at: Utc::now().to_rfc3339(),
        database_version: ROOT_VERSION,
        directories: before.directories.into_iter().collect(),
        files: entries,
    };
    write_manifest(&incomplete, &manifest)?;
    if validate_snapshot(&incomplete)? != manifest {
        return Err(changed());
    }
    if fs::symlink_metadata(&completed).is_ok() {
        return Err(unsafe_path());
    }
    // No fallible validation or copying follows the commit rename.
    fs::rename(&incomplete, &completed)?;
    sync_directory(&backups);
    Ok(
        json!({"snapshot_id":id,"path":completed,"complete":true,"format_version":1,"database_version":ROOT_VERSION,"files":manifest.files.len(),"bytes":total,"credentials":"excluded"}),
    )
}

/// OFFLINE ONLY. Validates the snapshot before profile mutation, then acquires
/// Store's stable sibling lock before staging or either directory rename.
/// Never recursively deletes/overlays an existing profile; retains a rollback.
pub fn restore(data_dir: &Path, snapshot: &Path) -> CoreResult<Value> {
    let source = existing_directory(snapshot)?;
    let manifest = validate_snapshot(&source)?;
    let target = resolve_target(data_dir)?;
    if source == target || target.starts_with(&source) {
        return Err(unsafe_path());
    }
    if target.exists() {
        check_profile_children(&target)?;
    }
    let parent = target.parent().ok_or_else(unsafe_path)?.to_path_buf();
    let _profile_lock = Store::acquire_profile_lock(&target)?;
    if !target.try_exists()? {
        make_private_directory(&target)?;
    }
    if existing_directory(&target)? != target {
        return Err(unsafe_path());
    }
    check_profile_children(&target)?;
    // Also reject a core predating the stable sibling lock, if one still holds core.lock.
    let legacy_lock = if target.join("core.lock").exists() {
        let file = open_regular(&target.join("core.lock"), true)?;
        file.try_lock_exclusive()
            .map_err(|_| CoreError::new("DataDirectoryInUse", "an active core owns the profile"))?;
        Some(file)
    } else {
        None
    };
    let control = read_control(&target)?;
    let before = profile_inventory(&target)?;
    let id = Uuid::new_v4().to_string();
    let stage = parent.join(format!(".dansheng-stage-{id}"));
    let previous = parent.join(format!(".dansheng-previous-{id}"));
    make_private_directory(&stage)?;
    same_parent(&parent, &stage)?;
    if previous.exists() {
        return Err(unsafe_path());
    }
    for directory in &manifest.directories {
        create_relative_directory(&stage, directory)?;
    }
    let mut total = 0;
    for entry in &manifest.files {
        let copied = copy_file_checked(&source, &stage, &entry.path, None, &mut total)?;
        if copied.size != entry.size || copied.sha256 != entry.sha256 {
            return Err(integrity());
        }
    }
    // Detect additions, removals, link substitutions, and altered bytes in the
    // caller-supplied source before any existing profile is moved.
    if validate_snapshot(&source)? != manifest {
        return Err(changed());
    }
    let mut image = open_database(&stage.join("dansheng.db"), false)?;
    check_database(&image)?;
    let plugins = validate_plugins(&stage, &image, &RegistryPaths::Snapshot)?;
    sanitize_database(&mut image, Some(&control), true)?;
    for (plugin, relative) in &plugins {
        let final_path = target.join(relative);
        if !final_path.starts_with(target.join("plugins")) {
            return Err(unsafe_path());
        }
        image.execute(
            "UPDATE plugins SET path=?,enabled=0 WHERE id=?",
            params![final_path.to_string_lossy(), plugin],
        )?;
    }
    compact(&image)?;
    check_database(&image)?;
    validate_payload(&stage, &image, &RegistryPaths::Restored(&target))?;
    drop(image);
    open_regular(&stage.join("dansheng.db"), true)?.sync_all()?;
    check_profile_children(&stage)?;
    sync_directory(&stage);
    // Revalidate resolved siblings and all old children immediately before swap.
    same_parent(&parent, &stage)?;
    same_parent(&parent, &target)?;
    if profile_inventory(&target)? != before {
        return Err(changed());
    }
    if fs::symlink_metadata(&previous).is_ok() {
        return Err(unsafe_path());
    }
    drop(legacy_lock);
    fs::rename(&target, &previous)?;
    if fs::rename(&stage, &target).is_err() {
        if fs::rename(&previous, &target).is_err() {
            return Err(CoreError::new(
                "RestoreNeedsRecovery",
                format!(
                    "activation failed; previous profile retained at {}",
                    previous.display()
                ),
            ));
        }
        return Err(CoreError::new(
            "RestoreFailed",
            "activation failed; original profile was restored and staging retained",
        ));
    }
    sync_directory(&parent);
    // The stable sibling lock is still held until the complete receipt is built.
    Ok(
        json!({"restored":true,"data_dir":target,"previous_profile":previous,"snapshot_id":manifest.id,"plugins_disabled":plugins.len(),"clients_reset":true,"grants_reset":true,"http_sessions":"reauthentication_required","publisher_trust":"current_target_preserved"}),
    )
}

fn unsafe_path() -> CoreError {
    CoreError::new(
        "UnsafeBackupPath",
        "snapshot/profile path is not an allowed regular app-owned path",
    )
}
fn integrity() -> CoreError {
    CoreError::new(
        "SnapshotIntegrityMismatch",
        "snapshot files, schema, or payload references do not match",
    )
}
fn changed() -> CoreError {
    CoreError::new(
        "SnapshotBusy",
        "profile files changed or are busy; retry after activity settles",
    )
}
fn capture_error(error: CoreError) -> CoreError {
    if matches!(error.code.as_str(), "IoError" | "SnapshotIntegrityMismatch") {
        changed()
    } else {
        error
    }
}
fn quota() -> CoreError {
    CoreError::new(
        "SnapshotTooLarge",
        "snapshot exceeds bounded file, byte, or manifest limits",
    )
}
fn uuid(value: &str) -> bool {
    Uuid::parse_str(value)
        .ok()
        .is_some_and(|u| u.get_version_num() == 4 && u.to_string() == value)
}
fn sha(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn segment(value: &str) -> bool {
    let stem = value.split('.').next().unwrap_or("").to_ascii_uppercase();
    !value.is_empty()
        && value.len() <= 255
        && !matches!(value, "." | "..")
        && !value.ends_with(['.', ' '])
        && !value
            .chars()
            .any(|c| c.is_control() || "\\/:*?\"<>|%#".contains(c))
        && !matches!(
            stem.as_str(),
            "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$" | "CLOCK$"
        )
        && !(stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        && !["COM", "LPT"].iter().any(|p| {
            stem.strip_prefix(p)
                .is_some_and(|v| matches!(v, "¹" | "²" | "³"))
        })
}
fn relative(value: &str) -> CoreResult<()> {
    if value.len() > 1024 || value.split('/').count() > 64 || value.split('/').any(|s| !segment(s))
    {
        return Err(unsafe_path());
    }
    Ok(())
}
fn no_links(path: &Path) -> CoreResult<fs::Metadata> {
    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Err(unsafe_path());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return Err(unsafe_path());
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.is_file() && meta.nlink() != 1 {
            return Err(unsafe_path());
        }
    }
    Ok(meta)
}
fn check_ancestors(path: &Path) -> CoreResult<()> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(unsafe_path());
    }
    for ancestor in path.ancestors() {
        no_links(ancestor)?;
    }
    Ok(())
}
fn existing_directory(path: &Path) -> CoreResult<PathBuf> {
    check_ancestors(path)?;
    if !no_links(path)?.is_dir() {
        return Err(unsafe_path());
    }
    Ok(fs::canonicalize(path)?)
}
fn resolve_target(path: &Path) -> CoreResult<PathBuf> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(unsafe_path());
    }
    let parent = existing_directory(path.parent().ok_or_else(unsafe_path)?)?;
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| segment(s))
        .ok_or_else(unsafe_path)?;
    let target = parent.join(name);
    if fs::symlink_metadata(&target).is_ok() {
        existing_directory(&target)
    } else {
        Ok(target)
    }
}
fn same_parent(parent: &Path, path: &Path) -> CoreResult<()> {
    if existing_directory(path)?.parent() != Some(parent) {
        return Err(unsafe_path());
    }
    Ok(())
}
fn make_private_directory(path: &Path) -> CoreResult<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new().mode(0o700).create(path)?;
    }
    #[cfg(not(unix))]
    fs::create_dir(path)?;
    Ok(())
}
fn checked_directory(parent: &Path, name: &str) -> CoreResult<PathBuf> {
    if !segment(name) {
        return Err(unsafe_path());
    }
    let path = parent.join(name);
    if !path.try_exists()? {
        make_private_directory(&path)?;
    }
    same_parent(parent, &path)?;
    Ok(path)
}
fn create_relative_directory(root: &Path, name: &str) -> CoreResult<()> {
    relative(name)?;
    let mut parent = root.to_path_buf();
    for part in name.split('/') {
        parent = checked_directory(&parent, part)?;
    }
    Ok(())
}
fn new_file(path: &Path) -> CoreResult<File> {
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    Ok(options.open(path)?)
}
fn open_regular(path: &Path, write: bool) -> CoreResult<File> {
    check_ancestors(path)?;
    let before = no_links(path)?;
    if !before.is_file() {
        return Err(unsafe_path());
    }
    let mut options = OpenOptions::new();
    options.read(true).write(write);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0o400000);
    }
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0x100);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() || stamp(&file.metadata()?) != stamp(&no_links(path)?) {
        return Err(changed());
    }
    Ok(file)
}
fn stamp(meta: &fs::Metadata) -> Stamp {
    Stamp {
        size: meta.len(),
        modified: meta.modified().ok(),
    }
}
fn sync_directory(path: &Path) {
    #[cfg(unix)]
    {
        let _ = File::open(path).and_then(|d| d.sync_all());
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

fn scan(
    root: &Path,
    dir: &Path,
    prefix: &str,
    result: &mut Inventory,
    skip_install_locks: bool,
    budget: &mut usize,
) -> CoreResult<()> {
    let mut folded = BTreeSet::new();
    if !no_links(dir)?.is_dir() || !fs::canonicalize(dir)?.starts_with(root) {
        return Err(unsafe_path());
    }
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        *budget += 1;
        if *budget > 200_000 {
            return Err(quota());
        }
        let name = entry.file_name().into_string().map_err(|_| unsafe_path())?;
        if !segment(&name) || !folded.insert(name.to_lowercase()) {
            return Err(unsafe_path());
        }
        let path = entry.path();
        let meta = no_links(&path)?;
        if skip_install_locks
            && name == ".install.lock"
            && prefix.split('/').count() == 2
            && meta.is_file()
        {
            continue;
        }
        let name = if prefix.is_empty() {
            name
        } else {
            format!("{prefix}/{name}")
        };
        relative(&name)?;
        if meta.is_dir() {
            result.directories.insert(name.clone());
            scan(root, &path, &name, result, skip_install_locks, budget)?;
        } else if meta.is_file() {
            result.files.insert(name, stamp(&meta));
        } else {
            #[cfg(unix)]
            {
                use std::os::unix::fs::FileTypeExt;
                if name == "host/ipc.sock" && meta.file_type().is_socket() {
                    result.files.insert(name, stamp(&meta));
                    continue;
                }
            }
            return Err(unsafe_path());
        }
    }
    Ok(())
}
fn check_profile_children(root: &Path) -> CoreResult<()> {
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name().into_string().map_err(|_| unsafe_path())?;
        let meta = no_links(&entry.path())?;
        if !(ROOT_FILES.contains(&name.as_str()) && meta.is_file()
            || ROOT_DIRS.contains(&name.as_str()) && meta.is_dir())
        {
            return Err(unsafe_path());
        }
    }
    Ok(())
}
fn profile_inventory(root: &Path) -> CoreResult<Inventory> {
    check_profile_children(root)?;
    let mut result = Inventory::default();
    scan(root, root, "", &mut result, false, &mut 0)?;
    Ok(result)
}

fn digest_file(path: &Path, max: u64) -> CoreResult<(u64, String)> {
    let mut file = open_regular(path, false)?;
    let before = stamp(&file.metadata()?);
    if before.size > max {
        return Err(quota());
    }
    let mut size = 0u64;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        if size > max {
            return Err(quota());
        }
        hash.update(&buffer[..n]);
    }
    if size != before.size
        || stamp(&file.metadata()?) != before
        || stamp(&no_links(path)?) != before
    {
        return Err(changed());
    }
    Ok((size, hex::encode(hash.finalize())))
}
fn hash_file_entry(root: &Path, name: &str, total: &mut u64) -> CoreResult<ManifestFile> {
    let (size, sha256) = digest_file(&root.join(name), MAX_FILE)?;
    *total = total.checked_add(size).ok_or_else(quota)?;
    if *total > MAX_TOTAL {
        return Err(quota());
    }
    Ok(ManifestFile {
        path: name.into(),
        size,
        sha256,
    })
}
fn copy_file_checked(
    source: &Path,
    target: &Path,
    name: &str,
    expected: Option<&Stamp>,
    total: &mut u64,
) -> CoreResult<ManifestFile> {
    relative(name)?;
    let source_path = source.join(name);
    let destination = target.join(name);
    if let Some(parent) = name.rsplit_once('/').map(|(p, _)| p) {
        create_relative_directory(target, parent)?;
    }
    let mut input = open_regular(&source_path, false)?;
    let before = stamp(&input.metadata()?);
    if before.size > MAX_FILE || expected.is_some_and(|s| s != &before) {
        return Err(changed());
    }
    let mut output = new_file(&destination)?;
    let mut size = 0u64;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        if size > MAX_FILE || total.saturating_add(size) > MAX_TOTAL {
            return Err(quota());
        }
        output.write_all(&buffer[..n])?;
        hash.update(&buffer[..n]);
    }
    output.sync_all()?;
    if size != before.size
        || stamp(&input.metadata()?) != before
        || stamp(&no_links(&source_path)?) != before
    {
        return Err(changed());
    }
    *total += size;
    Ok(ManifestFile {
        path: name.into(),
        size,
        sha256: hex::encode(hash.finalize()),
    })
}
fn read_bounded(path: &Path, limit: u64) -> CoreResult<Vec<u8>> {
    let file = open_regular(path, false)?;
    if file.metadata()?.len() > limit {
        return Err(quota());
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(quota());
    }
    Ok(bytes)
}
fn write_manifest(root: &Path, manifest: &Manifest) -> CoreResult<()> {
    let bytes = serde_json::to_vec_pretty(manifest)?;
    if bytes.len() as u64 > MAX_MANIFEST {
        return Err(quota());
    }
    let mut file = new_file(&root.join("manifest.json"))?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    sync_directory(root);
    Ok(())
}

fn has_table(db: &Connection, name: &str) -> CoreResult<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?)",
        [name],
        |r| r.get(0),
    )?)
}
fn open_database(path: &Path, readonly: bool) -> CoreResult<Connection> {
    let file = open_regular(path, !readonly)?;
    if file.metadata()?.len() > MAX_FILE {
        return Err(quota());
    }
    drop(file);
    let flags = if readonly {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    } else {
        OpenFlags::SQLITE_OPEN_READ_WRITE
    };
    let db = Connection::open_with_flags(path, flags | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    db.busy_timeout(std::time::Duration::from_secs(2))?;
    db.pragma_update(None, "trusted_schema", false)?;
    Ok(db)
}
fn normalized_sql(sql: &str) -> String {
    sql.chars()
        .filter(|c| !c.is_ascii_whitespace())
        .flat_map(char::to_lowercase)
        .collect::<String>()
        .trim_end_matches(';')
        .to_owned()
}
fn check_columns(db: &Connection, table: &str, columns: &[&str]) -> CoreResult<()> {
    let actual = db
        .prepare("SELECT name FROM pragma_table_info(?) ORDER BY cid")?
        .query_map([table], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    if actual != columns {
        return Err(integrity());
    }
    Ok(())
}
fn check_database(db: &Connection) -> CoreResult<()> {
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version != ROOT_VERSION {
        return Err(CoreError::new(
            "UnsupportedDatabaseVersion",
            "snapshot/target requires supported core schema version 3",
        ));
    }
    let required: [(&str, &[&str]); 10] = [
        ("accounts", &["id", "data"]),
        ("grants", &["subject", "data"]),
        ("clients", &["id", "kind", "token_hash"]),
        ("kv", &["namespace", "key", "data"]),
        (
            "records",
            &[
                "id",
                "owner",
                "account_id",
                "source_id",
                "external_id",
                "kind",
                "data",
                "search_text",
                "updated_at",
            ],
        ),
        ("source_access", &["owner", "source_id", "capabilities"]),
        (
            "jobs",
            &[
                "id",
                "owner",
                "data",
                "state",
                "run_at",
                "lease",
                "result",
                "updated_at",
                "dedup_key",
            ],
        ),
        ("events", &["sequence", "kind", "data", "at"]),
        (
            "plugins",
            &["id", "path", "manifest", "enabled", "verification"],
        ),
        ("sqlite_sequence", &["name", "seq"]),
    ];
    let optional: [(&str, &[&str]); 8] = [
        (
            "managed_assets_v1",
            &[
                "id",
                "owner",
                "account_id",
                "source_id",
                "name",
                "mime_type",
                "state",
                "size",
                "max_bytes",
                "reserved_bytes",
                "url_hash",
                "request_hash",
                "session_hash",
                "expected_sha256",
                "sha256",
                "etag",
                "created_at",
                "updated_at",
                "indexed_at",
                "error_code",
            ],
        ),
        ("organizer_schema", &["singleton", "version"]),
        (
            "organizer_items",
            &[
                "owner",
                "id",
                "kind",
                "body",
                "created_at",
                "updated_at",
                "record_owner",
                "account_id",
                "source_id",
                "external_id",
            ],
        ),
        (
            "organizer_reminders",
            &[
                "owner",
                "id",
                "item_id",
                "at",
                "timezone",
                "state",
                "created_at",
                "fired_at",
            ],
        ),
        (
            "organizer_sync",
            &["owner", "account_id", "source_id", "initialized"],
        ),
        (
            "organizer_activity",
            &[
                "owner",
                "id",
                "account_id",
                "source_id",
                "external_id",
                "title",
                "kind",
                "occurred_at",
                "notification",
                "read_at",
                "archived_at",
                "item_id",
            ],
        ),
        (
            "organizer_deliveries",
            &[
                "owner",
                "activity_id",
                "channel",
                "delivery_key",
                "state",
                "attempt",
                "lease_id",
                "lease_expires_at",
                "next_at",
                "delivered_at",
                "event_sequence",
            ],
        ),
        ("organizer_scheduler", &["singleton", "last_owner"]),
    ];
    let allowed: BTreeSet<&str> = required
        .iter()
        .chain(optional.iter())
        .map(|(n, _)| *n)
        .chain([
            "records_fts",
            "records_fts_data",
            "records_fts_idx",
            "records_fts_docsize",
            "records_fts_config",
            "sqlite_stat1",
        ])
        .collect();
    let triggers = BTreeMap::from([
        (
            "records_ai",
            "CREATE TRIGGER records_ai AFTER INSERT ON records BEGIN INSERT INTO records_fts(rowid,search_text) VALUES(new.id,new.search_text); END",
        ),
        (
            "records_ad",
            "CREATE TRIGGER records_ad AFTER DELETE ON records BEGIN INSERT INTO records_fts(records_fts,rowid,search_text) VALUES('delete',old.id,old.search_text); END",
        ),
        (
            "records_au",
            "CREATE TRIGGER records_au AFTER UPDATE ON records BEGIN INSERT INTO records_fts(records_fts,rowid,search_text) VALUES('delete',old.id,old.search_text); INSERT INTO records_fts(rowid,search_text) VALUES(new.id,new.search_text); END",
        ),
    ]);
    let mut stmt =
        db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY name LIMIT 257")?;
    let objects = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if objects.len() > 256 {
        return Err(quota());
    }
    let mut tables = BTreeSet::new();
    let mut seen_triggers = BTreeSet::new();
    for (kind, name, table, sql) in objects {
        if sql.as_ref().is_some_and(|s| s.len() > 64 * 1024) {
            return Err(quota());
        }
        match kind.as_str() {
            "table" if allowed.contains(name.as_str()) => {
                if name == "records_fts"
                    && sql.as_ref().map(|s| normalized_sql(s))
                        != Some(normalized_sql(
                            "CREATE VIRTUAL TABLE records_fts USING fts5(search_text,content='records',content_rowid='id',tokenize='trigram')",
                        ))
                {
                    return Err(integrity());
                }
                tables.insert(name);
            }
            "index" if allowed.contains(table.as_str()) => {
                // Expression indexes can invoke schema-supplied functions on writes.
                let expression: bool = db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM pragma_index_xinfo(?) WHERE cid=-2)",
                    [name],
                    |r| r.get(0),
                )?;
                if expression {
                    return Err(integrity());
                }
            }
            "trigger" if table == "records" => {
                let expected = triggers.get(name.as_str()).ok_or_else(integrity)?;
                if sql.as_ref().map(|s| normalized_sql(s)) != Some(normalized_sql(expected)) {
                    return Err(integrity());
                }
                seen_triggers.insert(name);
            }
            _ => {
                return Err(CoreError::new(
                    "UnsupportedSnapshotSchema",
                    "unknown table, view, trigger or schema object in profile",
                ));
            }
        }
    }
    for (name, columns) in required {
        if !tables.contains(name) {
            return Err(integrity());
        }
        check_columns(db, name, columns)?;
    }
    if !tables.contains("records_fts") || seen_triggers.len() != 3 {
        return Err(integrity());
    }
    for (name, columns) in optional {
        if tables.contains(name) {
            check_columns(db, name, columns)?;
        }
    }
    for table in &tables {
        let fks = db
            .prepare("SELECT \"table\",\"from\",\"to\",on_delete FROM pragma_foreign_key_list(?)")?
            .query_map([table], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<BTreeSet<_>, _>>()?;
        let expected = match table.as_str() {
            "organizer_reminders" => BTreeSet::from([
                (
                    "organizer_items".into(),
                    "owner".into(),
                    "owner".into(),
                    "CASCADE".into(),
                ),
                (
                    "organizer_items".into(),
                    "item_id".into(),
                    "id".into(),
                    "CASCADE".into(),
                ),
            ]),
            "organizer_deliveries" => BTreeSet::from([
                (
                    "organizer_activity".into(),
                    "owner".into(),
                    "owner".into(),
                    "CASCADE".into(),
                ),
                (
                    "organizer_activity".into(),
                    "activity_id".into(),
                    "id".into(),
                    "CASCADE".into(),
                ),
            ]),
            _ => BTreeSet::new(),
        };
        if fks != expected {
            return Err(integrity());
        }
    }
    if tables.contains("organizer_schema") {
        let versions = db
            .prepare("SELECT singleton,version FROM organizer_schema")?
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        if versions.len() != 1 || versions[0].0 != 1 || !(1..=2).contains(&versions[0].1) {
            return Err(CoreError::new(
                "UnsupportedSnapshotSchema",
                "unsupported organizer schema",
            ));
        }
        for name in [
            "organizer_items",
            "organizer_reminders",
            "organizer_sync",
            "organizer_activity",
        ] {
            if !tables.contains(name) {
                return Err(integrity());
            }
        }
        if versions[0].1 == 2
            && (!tables.contains("organizer_deliveries") || !tables.contains("organizer_scheduler"))
        {
            return Err(integrity());
        }
    } else if tables.iter().any(|s| s.starts_with("organizer_")) {
        return Err(integrity());
    }
    let checks = db
        .prepare("PRAGMA integrity_check(10)")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    if checks != ["ok"] || db.prepare("PRAGMA foreign_key_check")?.exists([])? {
        return Err(integrity());
    }
    Ok(())
}
fn ready_assets(db: &Connection) -> CoreResult<Vec<Asset>> {
    if !has_table(db, "managed_assets_v1")? {
        return Ok(Vec::new());
    }
    let mut stmt = db.prepare(
        "SELECT id,size,sha256 FROM managed_assets_v1 WHERE state='ready' ORDER BY id LIMIT 10001",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if rows.len() > 10_000 {
        return Err(quota());
    }
    let mut result = Vec::new();
    let mut total = 0u64;
    for (id, size, digest) in rows {
        let size = u64::try_from(size).map_err(|_| integrity())?;
        let digest = digest.ok_or_else(integrity)?;
        if !uuid(&id) || !sha(&digest) || size > crate::assets::MAX_FILE_BYTES {
            return Err(integrity());
        }
        total = total.checked_add(size).ok_or_else(quota)?;
        if total > crate::assets::MAX_TOTAL_BYTES {
            return Err(quota());
        }
        result.push(Asset {
            id,
            size,
            sha256: digest,
        });
    }
    Ok(result)
}
fn registries(db: &Connection) -> CoreResult<Vec<Registry>> {
    let mut stmt =
        db.prepare("SELECT id,path,manifest,verification FROM plugins ORDER BY id LIMIT 257")?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if rows.len() > 256 {
        return Err(quota());
    }
    rows.into_iter()
        .map(|(id, path, manifest, proof)| {
            Ok(Registry {
                id,
                path,
                manifest: serde_json::from_str(&manifest)?,
                verification: proof.map(|s| serde_json::from_str(&s)).transpose()?,
            })
        })
        .collect()
}

struct PluginLock(PathBuf, Option<File>);
impl Drop for PluginLock {
    fn drop(&mut self) {
        drop(self.1.take());
        let _ = fs::remove_file(&self.0);
    }
}
fn lock_plugins(root: &Path) -> CoreResult<Vec<PluginLock>> {
    let plugins = root.join("plugins");
    let mut locks = Vec::new();
    if !plugins.try_exists()? {
        return Ok(locks);
    }
    same_parent(root, &plugins)?;
    for entry in fs::read_dir(&plugins)? {
        let dir = entry?.path();
        same_parent(&plugins, &dir)?;
        let path = dir.join(".install.lock");
        let file = new_file(&path).map_err(|e| if e.code == "IoError" { changed() } else { e })?;
        locks.push(PluginLock(path, Some(file)));
    }
    Ok(locks)
}
fn lock_assets(root: &Path, assets: &[Asset]) -> CoreResult<Vec<File>> {
    let mut locks = Vec::new();
    if assets.is_empty() {
        return Ok(locks);
    }
    let directory = root.join("assets");
    same_parent(root, &directory)?;
    for asset in assets {
        let path = directory.join(format!("{}.lock", asset.id));
        if !path.try_exists()? {
            drop(new_file(&path)?);
        }
        let file = open_regular(&path, true)?;
        file.try_lock_exclusive().map_err(|_| changed())?;
        locks.push(file);
    }
    Ok(locks)
}
fn payload_inventory(
    root: &Path,
    assets: &[Asset],
    skip_install_locks: bool,
) -> CoreResult<Inventory> {
    let mut inventory = Inventory::default();
    if root.join("assets").try_exists()? {
        same_parent(root, &root.join("assets"))?;
        inventory.directories.insert("assets".into());
        // Even excluded partial/lock entries must not be symbolic links.
        for entry in fs::read_dir(root.join("assets"))? {
            if !no_links(&entry?.path())?.is_file() {
                return Err(unsafe_path());
            }
        }
    }
    for asset in assets {
        let path = format!("assets/{}", asset.id);
        let metadata = no_links(&root.join(&path))?;
        if !metadata.is_file() || metadata.len() != asset.size {
            return Err(integrity());
        }
        inventory.directories.insert("assets".into());
        inventory.files.insert(path, stamp(&metadata));
    }
    let plugins = root.join("plugins");
    if plugins.try_exists()? {
        same_parent(root, &plugins)?;
        inventory.directories.insert("plugins".into());
        scan(
            root,
            &plugins,
            "plugins",
            &mut inventory,
            skip_install_locks,
            &mut 0,
        )?;
    }
    if inventory.files.len() + 1 > MAX_FILES || inventory.directories.len() > MAX_FILES {
        return Err(quota());
    }
    Ok(inventory)
}

fn plugin_error(_: plugins::PluginError) -> CoreError {
    integrity()
}
fn pointer(root: &Path, name: &str) -> CoreResult<Pointer> {
    let value: Pointer = serde_json::from_slice(&read_bounded(&root.join(name), 4096)?)?;
    if !segment(&value.generation)
        || value
            .previous_generation
            .as_deref()
            .is_some_and(|v| !segment(v))
    {
        return Err(unsafe_path());
    }
    Ok(value)
}
fn validate_generation(root: &Path, id: &str, generation: &str, p: &Pointer) -> CoreResult<()> {
    if p.generation != generation {
        return Err(integrity());
    }
    let path = root.join("versions").join(generation);
    let package = plugins::validate_package(&path).map_err(plugin_error)?;
    if package.manifest.id != id || package.manifest.version != p.version {
        return Err(integrity());
    }
    let manifest_hash = digest_file(
        &path.join("manifest.json"),
        plugins::MAX_MANIFEST_BYTES as u64,
    )?
    .1;
    let content_hash = plugins::compute_package_integrity(&path)
        .map_err(plugin_error)?
        .sha256;
    if p.manifest_sha256.as_ref() != Some(&manifest_hash)
        || p.package_sha256.as_ref() != Some(&content_hash)
    {
        return Err(integrity());
    }
    if p.verification.as_ref().map(|v| &v.publisher) != package.manifest.publisher.as_ref() {
        return Err(integrity());
    }
    if let Some(previous) = &p.previous_generation
        && (!no_links(&root.join("versions").join(previous))?.is_dir()
            || !no_links(&root.join(".history").join(format!("{previous}.json")))?.is_file())
    {
        return Err(integrity());
    }
    Ok(())
}
fn validate_plugins(
    root: &Path,
    db: &Connection,
    paths: &RegistryPaths<'_>,
) -> CoreResult<BTreeMap<String, String>> {
    let registry = registries(db)?;
    let mut mapped = BTreeMap::new();
    let directory = root.join("plugins");
    if !directory.try_exists()? {
        if registry.is_empty() {
            return Ok(mapped);
        }
        return Err(integrity());
    }
    same_parent(root, &directory)?;
    for entry in fs::read_dir(&directory)? {
        let plugin_root = entry?.path();
        same_parent(&directory, &plugin_root)?;
        let id = plugin_root
            .file_name()
            .and_then(|n| n.to_str())
            .filter(|n| segment(n))
            .ok_or_else(unsafe_path)?;
        let mut versions = BTreeSet::new();
        let mut histories = BTreeSet::new();
        for child in fs::read_dir(&plugin_root)? {
            let child = child?;
            let name = child.file_name().into_string().map_err(|_| unsafe_path())?;
            let meta = no_links(&child.path())?;
            if name == ".install.lock" && meta.is_file() && matches!(paths, RegistryPaths::Live) {
                continue;
            }
            if name == "versions" && meta.is_dir() {
                for version in fs::read_dir(child.path())? {
                    let version = version?;
                    if !no_links(&version.path())?.is_dir() {
                        return Err(unsafe_path());
                    }
                    let generation = version
                        .file_name()
                        .into_string()
                        .map_err(|_| unsafe_path())?;
                    if !segment(&generation) {
                        return Err(unsafe_path());
                    }
                    versions.insert(generation);
                }
            } else if name == ".history" && meta.is_dir() {
                for history in fs::read_dir(child.path())? {
                    let history = history?;
                    if !no_links(&history.path())?.is_file() {
                        return Err(unsafe_path());
                    }
                    let name = history
                        .file_name()
                        .into_string()
                        .map_err(|_| unsafe_path())?;
                    let generation = name
                        .strip_suffix(".json")
                        .filter(|s| segment(s))
                        .ok_or_else(unsafe_path)?;
                    histories.insert(generation.to_string());
                }
            } else if (name == "current.json"
                || name
                    .strip_prefix(".uninstalled-")
                    .and_then(|s| s.strip_suffix(".json"))
                    .is_some_and(uuid))
                && meta.is_file()
            {
                // Validated after every retained generation has been checked.
            } else {
                return Err(changed());
            }
        }
        if versions.is_empty() || versions != histories {
            return Err(integrity());
        }
        for generation in &versions {
            let p = pointer(&plugin_root, &format!(".history/{generation}.json"))?;
            validate_generation(&plugin_root, id, generation, &p)?;
        }
        for child in fs::read_dir(&plugin_root)? {
            let name = child?
                .file_name()
                .into_string()
                .map_err(|_| unsafe_path())?;
            if name.starts_with(".uninstalled-") {
                let p = pointer(&plugin_root, &name)?;
                validate_generation(&plugin_root, id, &p.generation, &p)?;
            }
        }
        let row = registry.iter().find(|r| r.id == id);
        if plugin_root.join("current.json").try_exists()? {
            let current = pointer(&plugin_root, "current.json")?;
            validate_generation(&plugin_root, id, &current.generation, &current)?;
            let row = row.ok_or_else(changed)?;
            let installed = plugins::installed_package(&directory, id).map_err(plugin_error)?;
            if row.manifest != serde_json::to_value(&installed.manifest)?
                || row.verification
                    != current
                        .verification
                        .as_ref()
                        .map(serde_json::to_value)
                        .transpose()?
            {
                return Err(integrity());
            }
            let relative = format!("plugins/{id}/versions/{}", current.generation);
            match paths {
                RegistryPaths::Live => {
                    let path = Path::new(&row.path);
                    check_ancestors(path)?;
                    if fs::canonicalize(path)? != fs::canonicalize(root.join(&relative))? {
                        return Err(unsafe_path());
                    }
                }
                RegistryPaths::Snapshot => {
                    if row.path != relative {
                        return Err(unsafe_path());
                    }
                }
                RegistryPaths::Restored(target) => {
                    if Path::new(&row.path) != target.join(&relative) {
                        return Err(unsafe_path());
                    }
                }
            }
            mapped.insert(id.to_owned(), relative);
        } else if row.is_some() {
            return Err(integrity());
        }
    }
    if mapped.len() != registry.len() {
        return Err(integrity());
    }
    Ok(mapped)
}

fn validate_payload(root: &Path, db: &Connection, paths: &RegistryPaths<'_>) -> CoreResult<()> {
    for asset in ready_assets(db)? {
        let (size, hash) = digest_file(
            &root.join("assets").join(&asset.id),
            crate::assets::MAX_FILE_BYTES,
        )?;
        if size != asset.size || hash != asset.sha256 {
            return Err(integrity());
        }
    }
    validate_plugins(root, db, paths)?;
    Ok(())
}
fn valid_snapshot_file(name: &str) -> CoreResult<()> {
    relative(name)?;
    if name == "dansheng.db" {
        return Ok(());
    }
    let parts: Vec<_> = name.split('/').collect();
    if parts.len() == 2 && parts[0] == "assets" && uuid(parts[1]) {
        return Ok(());
    }
    if parts.len() >= 3 && parts[0] == "plugins" {
        return Ok(());
    }
    Err(unsafe_path())
}
fn validate_snapshot(root: &Path) -> CoreResult<Manifest> {
    let manifest: Manifest =
        serde_json::from_slice(&read_bounded(&root.join("manifest.json"), MAX_MANIFEST)?)?;
    if manifest.format != FORMAT
        || manifest.version != 1
        || !uuid(&manifest.id)
        || manifest.database_version != ROOT_VERSION
        || chrono::DateTime::parse_from_rfc3339(&manifest.created_at).is_err()
    {
        return Err(integrity());
    }
    if manifest.files.len() > MAX_FILES || manifest.directories.len() > MAX_FILES {
        return Err(quota());
    }
    let mut names = BTreeSet::from(["manifest.json".to_string()]);
    let mut directories = BTreeSet::new();
    let mut files = BTreeSet::from(["manifest.json".to_string()]);
    let mut total = 0u64;
    for name in &manifest.directories {
        relative(name)?;
        if !(name == "assets" || name == "plugins" || name.starts_with("plugins/"))
            || !names.insert(name.to_lowercase())
        {
            return Err(unsafe_path());
        }
        directories.insert(name.clone());
    }
    for entry in &manifest.files {
        valid_snapshot_file(&entry.path)?;
        if !sha(&entry.sha256) || !names.insert(entry.path.to_lowercase()) || entry.size > MAX_FILE
        {
            return Err(integrity());
        }
        total = total.checked_add(entry.size).ok_or_else(quota)?;
        if total > MAX_TOTAL {
            return Err(quota());
        }
        if digest_file(&root.join(&entry.path), MAX_FILE)? != (entry.size, entry.sha256.clone()) {
            return Err(integrity());
        }
        files.insert(entry.path.clone());
        let mut parent = entry.path.rsplit_once('/').map(|(p, _)| p);
        while let Some(name) = parent {
            if !directories.contains(name) {
                return Err(integrity());
            }
            parent = name.rsplit_once('/').map(|(p, _)| p);
        }
    }
    if !files.contains("dansheng.db") {
        return Err(integrity());
    }
    let mut inventory = Inventory::default();
    scan(root, root, "", &mut inventory, false, &mut 0)?;
    if inventory.files.keys().cloned().collect::<BTreeSet<_>>() != files
        || inventory.directories != directories
    {
        return Err(integrity());
    }
    let db = open_database(&root.join("dansheng.db"), true)?;
    let journal: String = db.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
    if journal != "delete" {
        return Err(integrity());
    }
    check_database(&db)?;
    validate_payload(root, &db, &RegistryPaths::Snapshot)?;
    let assets: BTreeSet<_> = ready_assets(&db)?
        .into_iter()
        .map(|a| format!("assets/{}", a.id))
        .collect();
    if files
        .iter()
        .filter(|p| p.starts_with("assets/"))
        .cloned()
        .collect::<BTreeSet<_>>()
        != assets
    {
        return Err(integrity());
    }
    Ok(manifest)
}

fn read_control(root: &Path) -> CoreResult<Control> {
    if !root.join("dansheng.db").try_exists()? {
        return Ok(Control::default());
    }
    let db = open_database(&root.join("dansheng.db"), true)?;
    check_database(&db)?;
    let plugins = db
        .prepare("SELECT key,data FROM kv WHERE namespace='core:plugins' ORDER BY key LIMIT 4097")?
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    if plugins.len() > 4096
        || plugins
            .iter()
            .map(|(k, v)| k.len() + v.len())
            .sum::<usize>()
            > 16 * 1024 * 1024
    {
        return Err(quota());
    }
    for (_, data) in &plugins {
        let _: Value = serde_json::from_str(data)?;
    }
    let source_access=db.prepare("SELECT owner,source_id,capabilities FROM source_access ORDER BY owner,source_id LIMIT 20001")?.query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?)))?.collect::<Result<Vec<_>,_>>()?;
    if source_access.len() > 20_000 {
        return Err(quota());
    }
    let source_access = source_access
        .into_iter()
        .map(|(o, s, c)| Ok((o, s, serde_json::from_str(&c)?)))
        .collect::<CoreResult<Vec<_>>>()?;
    let floor: i64 = db.query_row(
        "SELECT coalesce(max(seq),0) FROM sqlite_sequence WHERE name='events'",
        [],
        |r| r.get(0),
    )?;
    let max: i64 = db.query_row("SELECT coalesce(max(sequence),0) FROM events", [], |r| {
        r.get(0)
    })?;
    Ok(Control {
        plugins,
        source_access,
        event_floor: floor.max(max),
    })
}
fn sanitize_database(
    db: &mut Connection,
    control: Option<&Control>,
    restoring: bool,
) -> CoreResult<()> {
    check_database(db)?;
    db.pragma_update(None, "secure_delete", true)?;
    let tx = db.transaction()?;
    // Platform vaults can outlive a profile swap. Imported service configuration
    // must never regain access merely because its old vault entry still exists.
    tx.execute_batch("DELETE FROM clients; DELETE FROM grants; DELETE FROM kv WHERE namespace IN ('core:session-policy','core:network-routes','core:credential-bindings','core:plugins','core:catalogs'); UPDATE plugins SET enabled=0;")?;
    if has_table(&tx, "managed_assets_v1")? {
        tx.execute("DELETE FROM managed_assets_v1 WHERE state<>'ready'", [])?;
    }
    if let Some(control) = control {
        for (key, data) in &control.plugins {
            tx.execute(
                "INSERT INTO kv(namespace,key,data) VALUES('core:plugins',?,?)",
                params![key, data],
            )?;
        }
        for (owner, source, required) in &control.source_access {
            let old: Option<String> = tx
                .query_row(
                    "SELECT capabilities FROM source_access WHERE owner=? AND source_id=?",
                    params![owner, source],
                    |r| r.get(0),
                )
                .optional()?;
            let mut caps: BTreeSet<String> = old
                .map(|s| serde_json::from_str(&s))
                .transpose()?
                .unwrap_or_default();
            caps.extend(required.iter().cloned());
            tx.execute("INSERT INTO source_access VALUES(?,?,?) ON CONFLICT(owner,source_id) DO UPDATE SET capabilities=excluded.capabilities",params![owner,source,serde_json::to_string(&caps)?])?;
        }
        let floor: i64 = tx.query_row(
            "SELECT coalesce(max(seq),0) FROM sqlite_sequence WHERE name='events'",
            [],
            |r| r.get(0),
        )?;
        let floor = floor.max(control.event_floor);
        tx.execute("DELETE FROM sqlite_sequence WHERE name='events'", [])?;
        tx.execute(
            "INSERT INTO sqlite_sequence(name,seq) VALUES('events',?)",
            [floor],
        )?;
    }
    if restoring {
        tx.execute("UPDATE jobs SET state='needs_reconciliation',lease=NULL,updated_at=? WHERE state IN ('scheduled','running','waiting_for_auth','waiting_for_approval')",[Utc::now().to_rfc3339()])?;
        if has_table(&tx, "organizer_deliveries")? {
            tx.execute("UPDATE organizer_deliveries SET state='uncertain' WHERE state IN ('ready','leased')",[])?;
        }
        if has_table(&tx, "organizer_activity")? {
            tx.execute("UPDATE organizer_activity SET notification='suppressed' WHERE notification='pending'",[])?;
        }
        if has_table(&tx, "organizer_reminders")? {
            tx.execute(
                "UPDATE organizer_reminders SET state='cancelled' WHERE state='pending' AND at<=?",
                [Utc::now().timestamp_millis()],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}
fn compact(db: &Connection) -> CoreResult<()> {
    db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; VACUUM;")?;
    Ok(())
}
