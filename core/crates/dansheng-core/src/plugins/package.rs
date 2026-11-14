use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{
    PluginError, PluginManifest,
    catalog::{PackageVerification, integrity_error},
    manifest::{is_js, portable_segment, valid_id},
};

pub const MANIFEST_FILE: &str = "manifest.json";
pub(super) const MAX_PACKAGE_BYTES: usize = 16 * 1024 * 1024;
pub(super) const MAX_SOURCE_BYTES: usize = 1024 * 1024;
pub(super) const MAX_ENTRIES: usize = 1024;
pub(super) const MAX_DEPTH: usize = 32;

#[derive(Clone, Debug)]
pub struct PluginPackage {
    pub package_dir: PathBuf,
    pub manifest: PluginManifest,
}

impl PluginPackage {
    pub fn validate(package_dir: impl AsRef<Path>) -> Result<Self, PluginError> {
        validate_package(package_dir)
    }
}

/// An install receipt. Version directories are immutable to the installer and
/// are retained after promotion, including reinstalls of the same version.
#[derive(Clone, Debug)]
pub struct InstalledPlugin {
    pub package_dir: PathBuf,
    pub manifest: PluginManifest,
    pub previous_package_dir: Option<PathBuf>,
    /// The host must persist this disabled state even for upgrades and rollback.
    pub enabled: bool,
    pub requires_approval: bool,
    pub permission_changes: PermissionChanges,
    pub verification: Option<PackageVerification>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PermissionChanges {
    pub added_capabilities: Vec<String>,
    pub added_network_origins: Vec<String>,
    pub added_actions: Vec<String>,
    pub newly_mutating_actions: Vec<String>,
    pub publisher_changed: bool,
}

impl PermissionChanges {
    pub fn between(previous: Option<&PluginManifest>, next: &PluginManifest) -> Self {
        Self {
            added_capabilities: next
                .capabilities
                .iter()
                .filter(|cap| !previous.is_some_and(|old| old.capabilities.contains(cap)))
                .cloned()
                .collect(),
            added_network_origins: next
                .network
                .iter()
                .filter(|origin| !previous.is_some_and(|old| old.network.contains(origin)))
                .cloned()
                .collect(),
            added_actions: next
                .actions
                .keys()
                .filter(|id| !previous.is_some_and(|old| old.actions.contains_key(*id)))
                .cloned()
                .collect(),
            newly_mutating_actions: next
                .actions
                .iter()
                .filter(|(id, action)| {
                    action.mutating
                        && !previous
                            .and_then(|old| old.actions.get(*id))
                            .is_some_and(|action| action.mutating)
                })
                .map(|(id, _)| id.clone())
                .collect(),
            publisher_changed: previous.is_some_and(|old| old.publisher != next.publisher),
        }
    }

    pub fn requires_approval(&self) -> bool {
        self.publisher_changed
            || !self.added_capabilities.is_empty()
            || !self.added_network_origins.is_empty()
            || !self.added_actions.is_empty()
            || !self.newly_mutating_actions.is_empty()
    }
}

#[derive(Clone, Debug)]
pub struct UninstalledPlugin {
    pub plugin_id: String,
    pub package_dir: PathBuf,
    pub recovery_generation: String,
}

pub fn validate_package(package_dir: impl AsRef<Path>) -> Result<PluginPackage, PluginError> {
    let snapshot = PackageSnapshot::read(package_dir.as_ref())?;
    let manifest = snapshot.manifest()?;
    snapshot.check_entry(&manifest)?;
    Ok(PluginPackage {
        package_dir: snapshot.root,
        manifest,
    })
}

/// Install from a local directory only. This synchronous filesystem operation
/// should be dispatched by the embedding application off its I/O workers.
///
/// First copy a bounded, validated snapshot into a staging directory on the same
/// filesystem. Rename that directory to an immutable generation, then atomically
/// replace the small `current.json` pointer. A failed promotion leaves the old
/// pointer intact. No existing generation is removed. The pointer rename is the
/// commit point, so cancellation must be reconciled by reading installed_package.
pub fn install_local_package(
    source_dir: impl AsRef<Path>,
    install_root: impl AsRef<Path>,
) -> Result<InstalledPlugin, PluginError> {
    let snapshot = PackageSnapshot::read(source_dir.as_ref())?;
    if snapshot.manifest()?.publisher.is_some() {
        return Err(PluginError::new(
            "CATALOG_REQUIRED",
            "Published packages require a verified signed catalog",
        ));
    }
    install_snapshot(snapshot, install_root.as_ref(), None)
}

pub(super) fn install_snapshot(
    snapshot: PackageSnapshot,
    install_root: &Path,
    verification: Option<PackageVerification>,
) -> Result<InstalledPlugin, PluginError> {
    let manifest = snapshot.manifest()?;
    snapshot.check_entry(&manifest)?;
    fs::create_dir_all(install_root).map_err(|_| PluginError::io())?;
    reject_links(install_root)?;
    let root = fs::canonicalize(install_root).map_err(|_| PluginError::io())?;
    let plugin_root = checked_directory(&root, &manifest.id)?;
    let generations = checked_directory(&plugin_root, "versions")?;
    // A lock prevents competing promotions and makes previous_package_dir an
    // accurate receipt. A crash may leave this lock; never steal a live lock.
    let _lock = lock_installation(&plugin_root)?;
    let pointer_path = plugin_root.join("current.json");
    let previous = if pointer_path.try_exists().map_err(|_| PluginError::io())? {
        Some(read_current(&plugin_root, &manifest.id)?)
    } else {
        None
    };
    let previous_generation = if previous.is_some() {
        Some(load_pointer(&pointer_path)?.generation)
    } else {
        None
    };
    let generation = format!("{}-{}", manifest.version, Uuid::new_v4());
    let staging_path = plugin_root.join(format!(".staging-{}", Uuid::new_v4()));
    fs::create_dir(&staging_path).map_err(|_| PluginError::io())?;
    let mut staging = RemoveOnDrop(Some(staging_path.clone()), true);
    for (name, bytes) in &snapshot.files {
        let target = staging_path.join(name);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|_| PluginError::io())?;
        }
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&target)
            .map_err(|_| PluginError::io())?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| PluginError::io())?;
    }
    // Validate the actual staged bytes before any visible activation.
    validate_package(&staging_path)?;
    let package_dir = generations.join(&generation);
    fs::rename(&staging_path, &package_dir).map_err(|_| PluginError::io())?;
    staging.0 = None;
    let pointer = CurrentPackage {
        generation,
        version: manifest.version.clone(),
        previous_generation,
        manifest_sha256: Some(snapshot.manifest_digest()?),
        package_sha256: Some(snapshot.content_digest()),
        verification: verification.clone(),
    };
    write_history(&plugin_root, &pointer)?;
    write_pointer(&plugin_root, &pointer)?;
    Ok(install_receipt(
        PluginPackage {
            package_dir,
            manifest,
        },
        previous.as_ref(),
        verification,
    ))
}

fn write_pointer(plugin_root: &Path, pointer: &CurrentPackage) -> Result<(), PluginError> {
    let pointer_path = plugin_root.join("current.json");
    let pointer_bytes = bounded_json(pointer, 4096)?;
    let temporary_pointer = plugin_root.join(format!(".current-{}.json", Uuid::new_v4()));
    let _cleanup = RemoveOnDrop(Some(temporary_pointer.clone()), false);
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary_pointer)
        .map_err(|_| PluginError::io())?;
    file.write_all(pointer_bytes.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|_| PluginError::io())?;
    drop(file);
    if pointer_path.try_exists().map_err(|_| PluginError::io())? {
        reject_links(&pointer_path)?;
    }
    fs::rename(&temporary_pointer, &pointer_path).map_err(|_| PluginError::io())?;
    // Best-effort directory durability after the atomic commit; do not report a
    // failure after activation and mislead callers into blindly retrying it.
    #[cfg(unix)]
    {
        let _ = File::open(plugin_root).and_then(|dir| dir.sync_all());
    }
    Ok(())
}

fn write_history(plugin_root: &Path, pointer: &CurrentPackage) -> Result<(), PluginError> {
    let history = checked_directory(plugin_root, ".history")?;
    let path = history.join(format!("{}.json", pointer.generation));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .map_err(|_| PluginError::io())?;
    file.write_all(bounded_json(pointer, 4096)?.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|_| PluginError::io())
}

fn install_receipt(
    package: PluginPackage,
    previous: Option<&PluginPackage>,
    verification: Option<PackageVerification>,
) -> InstalledPlugin {
    let permission_changes =
        PermissionChanges::between(previous.map(|p| &p.manifest), &package.manifest);
    InstalledPlugin {
        package_dir: package.package_dir,
        manifest: package.manifest,
        previous_package_dir: previous.map(|p| p.package_dir.clone()),
        enabled: false,
        requires_approval: previous.is_none() || permission_changes.requires_approval(),
        permission_changes,
        verification,
    }
}

/// Activate a retained generation atomically, always disabled. None selects the
/// previous generation; an explicit generation can also restore an uninstall.
/// The embedding host must cancel active runs before changing installed state.
pub fn rollback_local_package(
    install_root: impl AsRef<Path>,
    plugin_id: &str,
    generation: Option<&str>,
) -> Result<InstalledPlugin, PluginError> {
    let plugin_root = existing_plugin_root(install_root.as_ref(), plugin_id)?;
    let _lock = lock_installation(&plugin_root)?;
    let current_path = plugin_root.join("current.json");
    let current = if current_path.try_exists().map_err(|_| PluginError::io())? {
        Some(load_pointer(&current_path)?)
    } else {
        None
    };
    // Recovery must work even when the currently selected package is corrupt.
    // An unreadable prior manifest conveys no approved permissions: the receipt
    // then requires approval and remains disabled. The target is still fully
    // validated against its retained integrity record before pointer promotion.
    let previous = if current.is_some() {
        read_current(&plugin_root, plugin_id).ok()
    } else {
        None
    };
    let generation = generation
        .or_else(|| {
            current
                .as_ref()
                .and_then(|p| p.previous_generation.as_deref())
        })
        .ok_or_else(|| {
            PluginError::new(
                "ROLLBACK_UNAVAILABLE",
                "No retained generation was selected",
            )
        })?;
    if !portable_segment(generation) {
        return Err(PluginError::path());
    }
    let history = plugin_root.join(".history");
    reject_links(&history)?;
    let mut target = load_pointer(&history.join(format!("{generation}.json")))?;
    if target.generation != generation {
        return Err(PluginError::package("Generation history identity mismatch"));
    }
    let package = read_generation(&plugin_root, plugin_id, &target)?;
    target.previous_generation = current.as_ref().map(|p| p.generation.clone());
    write_pointer(&plugin_root, &target)?;
    let mut receipt = install_receipt(package, previous.as_ref(), target.verification);
    receipt.previous_package_dir = current.map(|p| plugin_root.join("versions").join(p.generation));
    Ok(receipt)
}

/// Remove the active pointer atomically. Package generations are retained for
/// recovery; this never removes host-owned storage, credentials or job records.
/// Hosts must cancel active runs, revoke grants and remove their registry entry.
pub fn uninstall_local_package(
    install_root: impl AsRef<Path>,
    plugin_id: &str,
) -> Result<UninstalledPlugin, PluginError> {
    let plugin_root = existing_plugin_root(install_root.as_ref(), plugin_id)?;
    let _lock = lock_installation(&plugin_root)?;
    let current_path = plugin_root.join("current.json");
    let pointer = load_pointer(&current_path)?;
    fs::rename(
        &current_path,
        plugin_root.join(format!(".uninstalled-{}.json", Uuid::new_v4())),
    )
    .map_err(|_| PluginError::io())?;
    Ok(UninstalledPlugin {
        plugin_id: plugin_id.into(),
        package_dir: plugin_root.join("versions").join(&pointer.generation),
        recovery_generation: pointer.generation,
    })
}

pub fn installed_package(
    install_root: impl AsRef<Path>,
    plugin_id: &str,
) -> Result<PluginPackage, PluginError> {
    let plugin_root = existing_plugin_root(install_root.as_ref(), plugin_id)?;
    read_current(&plugin_root, plugin_id)
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CurrentPackage {
    generation: String,
    version: String,
    #[serde(default)]
    previous_generation: Option<String>,
    #[serde(default)]
    manifest_sha256: Option<String>,
    #[serde(default)]
    package_sha256: Option<String>,
    #[serde(default)]
    verification: Option<PackageVerification>,
}

fn read_current(plugin_root: &Path, plugin_id: &str) -> Result<PluginPackage, PluginError> {
    let pointer = load_pointer(&plugin_root.join("current.json"))?;
    read_generation(plugin_root, plugin_id, &pointer)
}

fn load_pointer(path: &Path) -> Result<CurrentPackage, PluginError> {
    if !path.try_exists().map_err(|_| PluginError::io())? {
        return Err(PluginError::new(
            "PLUGIN_NOT_INSTALLED",
            "Plugin generation pointer is absent",
        ));
    }
    let pointer: CurrentPackage = super::manifest::parse_unique_json(&read_file(path, 4096)?)
        .map_err(|_| PluginError::package("Malformed installed package pointer"))?;
    if !portable_segment(&pointer.generation) {
        return Err(PluginError::path());
    }
    Ok(pointer)
}

fn read_generation(
    plugin_root: &Path,
    plugin_id: &str,
    pointer: &CurrentPackage,
) -> Result<PluginPackage, PluginError> {
    let versions = plugin_root.join("versions");
    reject_links(&versions)?;
    let snapshot = PackageSnapshot::read(&versions.join(&pointer.generation))?;
    let manifest = snapshot.manifest()?;
    snapshot.check_entry(&manifest)?;
    if manifest.id != plugin_id || manifest.version != pointer.version {
        return Err(PluginError::package("Installed package identity mismatch"));
    }
    if pointer
        .manifest_sha256
        .as_ref()
        .is_some_and(|digest| snapshot.manifest_digest().ok().as_ref() != Some(digest))
        || pointer
            .package_sha256
            .as_ref()
            .is_some_and(|digest| snapshot.content_digest() != *digest)
        || pointer
            .verification
            .as_ref()
            .is_some_and(|proof| manifest.publisher.as_ref() != Some(&proof.publisher))
        || (manifest.publisher.is_some()
            && (pointer.verification.is_none()
                || pointer.manifest_sha256.is_none()
                || pointer.package_sha256.is_none()))
    {
        return Err(integrity_error());
    }
    Ok(PluginPackage {
        package_dir: snapshot.root,
        manifest,
    })
}

fn existing_plugin_root(install_root: &Path, plugin_id: &str) -> Result<PathBuf, PluginError> {
    if !valid_id(plugin_id) {
        return Err(PluginError::manifest("Invalid plugin id"));
    }
    reject_links(install_root)?;
    let root = fs::canonicalize(install_root).map_err(|_| PluginError::io())?;
    let plugin_root = root.join(plugin_id);
    reject_links(&plugin_root)?;
    Ok(plugin_root)
}

fn lock_installation(plugin_root: &Path) -> Result<InstallLock, PluginError> {
    let path = plugin_root.join(".install.lock");
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                PluginError::new("INSTALL_BUSY", "Plugin installation is already locked")
            } else {
                PluginError::io()
            }
        })?;
    Ok(InstallLock {
        path,
        file: Some(file),
    })
}

pub(super) fn checked_directory(parent: &Path, name: &str) -> Result<PathBuf, PluginError> {
    let path = parent.join(name);
    match fs::create_dir(&path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(PluginError::io()),
    }
    reject_links(&path)?;
    let canonical = fs::canonicalize(&path).map_err(|_| PluginError::io())?;
    if !canonical.starts_with(parent) || !canonical.is_dir() {
        return Err(PluginError::path());
    }
    Ok(canonical)
}

pub(super) struct PackageSnapshot {
    pub root: PathBuf,
    pub files: BTreeMap<String, Arc<[u8]>>,
}

impl PackageSnapshot {
    pub fn read(root: &Path) -> Result<Self, PluginError> {
        reject_links(root)?;
        let root = fs::canonicalize(root).map_err(|_| PluginError::io())?;
        if !root.is_dir() {
            return Err(PluginError::package("Package root is not a directory"));
        }
        let mut snapshot = Self {
            root: root.clone(),
            files: BTreeMap::new(),
        };
        let mut budget = (0, 0);
        snapshot.walk(&root, "", 0, &mut budget)?;
        Ok(snapshot)
    }

    fn walk(
        &mut self,
        dir: &Path,
        prefix: &str,
        depth: usize,
        budget: &mut (usize, usize),
    ) -> Result<(), PluginError> {
        if depth > MAX_DEPTH {
            return Err(PluginError::package("Package nesting exceeds limit"));
        }
        let mut folded_names = BTreeSet::new();
        for entry in fs::read_dir(dir).map_err(|_| PluginError::io())? {
            budget.0 += 1;
            if budget.0 > MAX_ENTRIES {
                return Err(PluginError::package("Package contains too many entries"));
            }
            let entry = entry.map_err(|_| PluginError::io())?;
            let segment = entry
                .file_name()
                .into_string()
                .map_err(|_| PluginError::path())?;
            if !portable_segment(&segment) || !folded_names.insert(segment.to_lowercase()) {
                return Err(PluginError::path());
            }
            let path = entry.path();
            reject_links(&path)?;
            if !fs::canonicalize(&path)
                .map_err(|_| PluginError::io())?
                .starts_with(&self.root)
            {
                return Err(PluginError::path());
            }
            let name = if prefix.is_empty() {
                segment
            } else {
                format!("{prefix}/{segment}")
            };
            let kind = entry.file_type().map_err(|_| PluginError::io())?;
            if kind.is_dir() {
                self.walk(&path, &name, depth + 1, budget)?;
            } else if kind.is_file() {
                let cap = package_file_limit(&name)?;
                let bytes = read_file(&path, cap.min(MAX_PACKAGE_BYTES - budget.1))?;
                budget.1 += bytes.len();
                validate_source_file(&name, &bytes)?;
                self.files.insert(name, bytes.into());
            } else {
                return Err(PluginError::package(
                    "Only regular files and directories are accepted",
                ));
            }
        }
        Ok(())
    }

    pub fn manifest(&self) -> Result<PluginManifest, PluginError> {
        let bytes = self
            .files
            .get(MANIFEST_FILE)
            .ok_or_else(|| PluginError::manifest("Package is missing manifest.json"))?;
        PluginManifest::from_slice(bytes)
    }

    pub fn check_entry(&self, manifest: &PluginManifest) -> Result<(), PluginError> {
        manifest.validate()?;
        let entry = manifest.entry.strip_prefix("./").unwrap_or(&manifest.entry);
        if !self.files.contains_key(entry) {
            return Err(PluginError::package("Entry source is missing"));
        }
        if manifest
            .integrity
            .as_ref()
            .is_some_and(|binding| binding.sha256 != self.content_digest())
        {
            return Err(integrity_error());
        }
        Ok(())
    }

    pub fn modules(&self) -> BTreeMap<String, Arc<[u8]>> {
        self.files
            .iter()
            .filter(|(name, _)| is_js(name))
            .map(|(name, bytes)| (name.clone(), bytes.clone()))
            .collect()
    }
}

fn read_file(path: &Path, limit: usize) -> Result<Vec<u8>, PluginError> {
    reject_links(path)?;
    let file = File::open(path).map_err(|_| PluginError::io())?;
    let meta = file.metadata().map_err(|_| PluginError::io())?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err(PluginError::package("Package file exceeds its size limit"));
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| PluginError::io())?;
    if bytes.len() > limit {
        return Err(PluginError::package("Package file exceeds its size limit"));
    }
    Ok(bytes)
}

pub(super) fn reject_links(path: &Path) -> Result<(), PluginError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| PluginError::io())?;
    if metadata.file_type().is_symlink() {
        return Err(PluginError::path());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(PluginError::path());
        }
    }
    Ok(())
}

pub(super) fn package_file_limit(name: &str) -> Result<usize, PluginError> {
    let lower = name.to_ascii_lowercase();
    let extension = Path::new(&lower)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    if matches!(
        extension,
        "dll" | "so" | "dylib" | "node" | "qjbc" | "qjsc" | "bc" | "wasm" | "exe"
    ) {
        return Err(PluginError::package(
            "Bytecode and native extensions are not accepted",
        ));
    }
    Ok(if lower == MANIFEST_FILE {
        super::MAX_MANIFEST_BYTES
    } else if is_js(&lower) {
        MAX_SOURCE_BYTES
    } else {
        MAX_PACKAGE_BYTES
    })
}

pub(super) fn validate_source_file(name: &str, bytes: &[u8]) -> Result<(), PluginError> {
    if is_js(&name.to_ascii_lowercase())
        && (std::str::from_utf8(bytes).is_err() || bytes.contains(&0))
    {
        return Err(PluginError::package(
            "Modules must contain UTF-8 JavaScript source",
        ));
    }
    Ok(())
}

struct InstallLock {
    path: PathBuf,
    file: Option<File>,
}
impl Drop for InstallLock {
    fn drop(&mut self) {
        drop(self.file.take());
        let _ = fs::remove_file(&self.path);
    }
}

struct RemoveOnDrop(Option<PathBuf>, bool);
impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        if let Some(path) = &self.0 {
            // Paths are generated exclusively under the canonical install root.
            if self.1 {
                let _ = fs::remove_dir_all(path);
            } else {
                let _ = fs::remove_file(path);
            }
        }
    }
}

pub(super) fn bounded_json<T: Serialize + ?Sized>(
    value: &T,
    limit: usize,
) -> Result<String, PluginError> {
    struct Bounded {
        bytes: Vec<u8>,
        limit: usize,
    }
    impl Write for Bounded {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
                return Err(std::io::Error::other("JSON size limit"));
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut writer = Bounded {
        bytes: Vec::new(),
        limit,
    };
    serde_json::to_writer(&mut writer, value).map_err(|_| PluginError::quota())?;
    String::from_utf8(writer.bytes).map_err(|_| PluginError::quota())
}
