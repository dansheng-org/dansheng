//! Bounded source-package ZIP extraction. Extraction supplies no publisher trust
//! or permissions: published packages must still use install_catalog_package.

use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
};

use uuid::Uuid;
use zip::ZipArchive;

use super::{
    PluginError, PluginPackage,
    manifest::portable_segment,
    package::{
        MAX_DEPTH, MAX_ENTRIES, MAX_PACKAGE_BYTES, PackageSnapshot, checked_directory,
        package_file_limit, reject_links, validate_package, validate_source_file,
    },
};

const MAX_ARCHIVE_BYTES: usize = 32 * 1024 * 1024;

struct Entry {
    zip_name: String,
    name: String,
    directory: bool,
    size: u64,
    compressed: u64,
}
struct Node {
    name: String,
    directory: bool,
    explicit: bool,
}
struct Plan {
    entries: Vec<Entry>,
    nodes: BTreeMap<String, Node>,
}

/// Extract a classic, single-disk Stored/Deflate ZIP into an absent or empty
/// destination whose parent already exists. No entry metadata or permissions
/// are restored. Every path, file type, size, CRC and manifest is validated in
/// bounded memory before filesystem creation, then a private staging directory
/// is promoted. A nonempty destination is never overwritten.
///
/// This synchronous helper should run off the embedding application's I/O
/// workers. It does no networking, signature approval, grant or enablement work.
pub fn extract_package_archive(
    archive_path: impl AsRef<Path>,
    destination: impl AsRef<Path>,
) -> Result<PluginPackage, PluginError> {
    reject_links(archive_path.as_ref())?;
    if !fs::symlink_metadata(archive_path.as_ref())
        .map_err(|_| PluginError::io())?
        .is_file()
    {
        return Err(invalid_error());
    }
    let file = File::open(archive_path.as_ref()).map_err(|_| PluginError::io())?;
    let metadata = file.metadata().map_err(|_| PluginError::io())?;
    if !metadata.is_file() || metadata.len() > MAX_ARCHIVE_BYTES as u64 {
        return Err(limit_error());
    }
    let mut bytes = Vec::new();
    file.take(MAX_ARCHIVE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid_error())?;
    if bytes.len() > MAX_ARCHIVE_BYTES {
        return Err(limit_error());
    }
    // zip 2 indexes filenames and may collapse exact duplicates. Scan the raw
    // central directory first, before its parser allocates or deduplicates it.
    let plan = preflight(&bytes)?;
    let mut zip = ZipArchive::new(Cursor::new(&bytes)).map_err(|_| invalid_error())?;
    if zip.len() != plan.entries.len() {
        return Err(invalid_error());
    }
    let mut files = BTreeMap::new();
    let mut actual_total = 0usize;
    for (index, entry) in plan.entries.iter().enumerate() {
        let mut file = zip.by_index(index).map_err(|_| invalid_error())?;
        if file.name_raw() != entry.zip_name.as_bytes()
            || file.name() != entry.zip_name
            || file.size() != entry.size
            || file.compressed_size() != entry.compressed
            || file.is_dir() != entry.directory
            || file.encrypted()
        {
            return Err(invalid_error());
        }
        let mut data = Vec::new();
        // Bound actual output independently of the advertised size. The extra
        // byte detects lying metadata without expanding the rest of a bomb.
        (&mut file)
            .take(entry.size + 1)
            .read_to_end(&mut data)
            .map_err(|_| invalid_error())?;
        if data.len() as u64 != entry.size {
            return Err(limit_error());
        }
        actual_total = actual_total
            .checked_add(data.len())
            .ok_or_else(limit_error)?;
        if actual_total > MAX_PACKAGE_BYTES {
            return Err(limit_error());
        }
        if !entry.directory {
            validate_source_file(&entry.name, &data)?;
            files.insert(entry.name.clone(), Arc::<[u8]>::from(data));
        }
    }
    let snapshot = PackageSnapshot {
        root: PathBuf::new(),
        files,
    };
    let manifest = snapshot.manifest()?;
    snapshot.check_entry(&manifest)?;
    write_package(snapshot, plan, destination.as_ref())
}

fn preflight(bytes: &[u8]) -> Result<Plan, PluginError> {
    if bytes.len() < 22 {
        return Err(invalid_error());
    }
    let start = bytes.len().saturating_sub(22 + u16::MAX as usize);
    let end = (start..=bytes.len() - 22)
        .rev()
        .find(|&offset| {
            bytes.get(offset..offset + 4) == Some(b"PK\x05\x06")
                && offset + 22 + u16_at(bytes, offset + 20).unwrap_or(0) as usize == bytes.len()
        })
        .ok_or_else(invalid_error)?;
    let count = u16_at(bytes, end + 10)? as usize;
    if count == 0 || count > MAX_ENTRIES {
        return Err(limit_error());
    }
    if u16_at(bytes, end + 4)? != 0
        || u16_at(bytes, end + 6)? != 0
        || u16_at(bytes, end + 8)? as usize != count
    {
        return Err(unsupported_error());
    }
    let central_size = u32_at(bytes, end + 12)? as usize;
    let central_start = u32_at(bytes, end + 16)? as usize;
    if central_start.checked_add(central_size) != Some(end) {
        return Err(invalid_error());
    }
    let mut offset = central_start;
    let mut plan = Plan {
        entries: Vec::new(),
        nodes: BTreeMap::new(),
    };
    let mut declared_total = 0usize;
    for _ in 0..count {
        if offset.checked_add(46).is_none_or(|next| next > end)
            || bytes.get(offset..offset + 4) != Some(b"PK\x01\x02")
        {
            return Err(invalid_error());
        }
        let flags = u16_at(bytes, offset + 8)?;
        let method = u16_at(bytes, offset + 10)?;
        if flags & 0x2041 != 0 || !matches!(method, 0 | 8) {
            return Err(unsupported_error());
        }
        let compressed = u32_at(bytes, offset + 20)?;
        let size = u32_at(bytes, offset + 24)?;
        let name_size = u16_at(bytes, offset + 28)? as usize;
        let extra_size = u16_at(bytes, offset + 30)? as usize;
        let comment_size = u16_at(bytes, offset + 32)? as usize;
        let local = u32_at(bytes, offset + 42)?;
        if compressed == u32::MAX
            || size == u32::MAX
            || local == u32::MAX
            || u16_at(bytes, offset + 34)? != 0
        {
            return Err(unsupported_error());
        }
        let next = offset
            .checked_add(46 + name_size + extra_size + comment_size)
            .ok_or_else(invalid_error)?;
        if next > end {
            return Err(invalid_error());
        }
        let name_bytes = &bytes[offset + 46..offset + 46 + name_size];
        let zip_name = std::str::from_utf8(name_bytes).map_err(|_| PluginError::path())?;
        let directory = zip_name.ends_with('/');
        let name = zip_name.strip_suffix('/').unwrap_or(zip_name);
        validate_name(name, directory)?;
        validate_file_type(u32_at(bytes, offset + 38)?, directory)?;
        let limit = if directory {
            0
        } else {
            package_file_limit(name)?
        };
        if size as usize > limit {
            return Err(limit_error());
        }
        declared_total = declared_total
            .checked_add(size as usize)
            .ok_or_else(limit_error)?;
        if declared_total > MAX_PACKAGE_BYTES {
            return Err(limit_error());
        }
        validate_extra(&bytes[offset + 46 + name_size..offset + 46 + name_size + extra_size])?;
        validate_local(
            bytes,
            local as usize,
            central_start,
            name_bytes,
            flags,
            method,
            compressed,
            size,
            u32_at(bytes, offset + 16)?,
        )?;
        register_path(&mut plan.nodes, name, directory)?;
        plan.entries.push(Entry {
            zip_name: zip_name.into(),
            name: name.into(),
            directory,
            size: size as u64,
            compressed: compressed as u64,
        });
        offset = next;
    }
    if offset != end {
        return Err(invalid_error());
    }
    Ok(plan)
}

fn validate_name(name: &str, directory: bool) -> Result<(), PluginError> {
    if name.len() > (MAX_DEPTH + 1) * 256 || name.split('/').any(|part| !portable_segment(part)) {
        return Err(PluginError::path());
    }
    let depth = name.split('/').count();
    if depth > MAX_DEPTH + usize::from(!directory) {
        return Err(limit_error());
    }
    Ok(())
}

fn register_path(
    nodes: &mut BTreeMap<String, Node>,
    name: &str,
    directory: bool,
) -> Result<(), PluginError> {
    let parts: Vec<_> = name.split('/').collect();
    for index in 0..parts.len() {
        let prefix = parts[..=index].join("/");
        // Conservative Unicode case folding also catches expanding case pairs
        // such as sharp-s/SS, while retaining the exact portable spelling.
        let folded = prefix.to_uppercase().to_lowercase();
        let leaf = index + 1 == parts.len();
        let is_directory = !leaf || directory;
        if let Some(existing) = nodes.get_mut(&folded) {
            if existing.name != prefix
                || existing.directory != is_directory
                || (leaf && existing.explicit)
            {
                return Err(PluginError::new(
                    "ARCHIVE_DUPLICATE_PATH",
                    "Archive paths conflict or alias across platforms",
                ));
            }
            if leaf {
                existing.explicit = true;
            }
        } else {
            nodes.insert(
                folded,
                Node {
                    name: prefix,
                    directory: is_directory,
                    explicit: leaf,
                },
            );
            if nodes.len() > MAX_ENTRIES {
                return Err(limit_error());
            }
        }
    }
    Ok(())
}

fn validate_file_type(attributes: u32, directory: bool) -> Result<(), PluginError> {
    let kind = (attributes >> 16) & 0o170000;
    if !matches!(kind, 0 | 0o100000 | 0o040000)
        || (kind == 0o040000 && !directory)
        || (kind == 0o100000 && directory)
        || attributes & 0x0440 != 0
        || (attributes & 0x10 != 0 && !directory)
    {
        return Err(PluginError::new(
            "ARCHIVE_ENTRY_TYPE",
            "Archive links, devices and special files are not accepted",
        ));
    }
    Ok(())
}

fn validate_extra(mut extra: &[u8]) -> Result<(), PluginError> {
    while !extra.is_empty() {
        let tag = u16_at(extra, 0)?;
        let length = u16_at(extra, 2)? as usize;
        if tag == 0x0001 || tag == 0x000d || tag == 0x756e {
            return Err(unsupported_error());
        }
        extra = extra.get(4 + length..).ok_or_else(invalid_error)?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_local(
    bytes: &[u8],
    local: usize,
    central: usize,
    name: &[u8],
    flags: u16,
    method: u16,
    compressed: u32,
    size: u32,
    crc: u32,
) -> Result<(), PluginError> {
    if local.checked_add(30).is_none_or(|end| end > central)
        || bytes.get(local..local + 4) != Some(b"PK\x03\x04")
        || u16_at(bytes, local + 6)? != flags
        || u16_at(bytes, local + 8)? != method
    {
        return Err(invalid_error());
    }
    let name_size = u16_at(bytes, local + 26)? as usize;
    let extra_size = u16_at(bytes, local + 28)? as usize;
    let data = local
        .checked_add(30 + name_size + extra_size)
        .ok_or_else(invalid_error)?;
    if data
        .checked_add(compressed as usize)
        .is_none_or(|end| end > central)
        || bytes.get(local + 30..local + 30 + name_size) != Some(name)
    {
        return Err(invalid_error());
    }
    validate_extra(&bytes[local + 30 + name_size..data])?;
    if flags & 8 == 0
        && (u32_at(bytes, local + 14)? != crc
            || u32_at(bytes, local + 18)? != compressed
            || u32_at(bytes, local + 22)? != size)
    {
        return Err(invalid_error());
    }
    Ok(())
}

fn write_package(
    snapshot: PackageSnapshot,
    plan: Plan,
    destination: &Path,
) -> Result<PluginPackage, PluginError> {
    let basename = destination
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| portable_segment(s))
        .ok_or_else(PluginError::path)?;
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let parent = fs::canonicalize(parent).map_err(|_| PluginError::io())?;
    let destination = parent.join(basename);
    ensure_empty_destination(&destination)?;
    let staging = parent.join(format!(".extract-{}", Uuid::new_v4()));
    fs::create_dir(&staging).map_err(|_| PluginError::io())?;
    let staging = fs::canonicalize(staging).map_err(|_| PluginError::io())?;
    let mut cleanup = StagingCleanup(Some(staging.clone()));
    for node in plan.nodes.values().filter(|node| node.directory) {
        let mut path = staging.clone();
        for segment in node.name.split('/') {
            path = checked_directory(&path, segment)?;
        }
    }
    for (name, bytes) in &snapshot.files {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(staging.join(name))
            .map_err(|_| PluginError::io())?;
        file.write_all(bytes).map_err(|_| PluginError::io())?;
    }
    let staged = validate_package(&staging)?;
    let removed_empty = ensure_empty_destination(&destination)?;
    if removed_empty {
        fs::remove_dir(&destination).map_err(|_| PluginError::io())?;
    }
    if fs::rename(&staging, &destination).is_err() {
        if removed_empty {
            let _ = fs::create_dir(&destination);
        }
        return Err(PluginError::io());
    }
    cleanup.0 = None;
    Ok(PluginPackage {
        package_dir: destination,
        manifest: staged.manifest,
    })
}

fn ensure_empty_destination(destination: &Path) -> Result<bool, PluginError> {
    match fs::symlink_metadata(destination) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(PluginError::io()),
        Ok(metadata) => {
            reject_links(destination)?;
            if !metadata.is_dir()
                || fs::read_dir(destination)
                    .map_err(|_| PluginError::io())?
                    .next()
                    .is_some()
            {
                return Err(PluginError::new(
                    "ARCHIVE_DESTINATION",
                    "Archive destination must be absent or empty",
                ));
            }
            Ok(true)
        }
    }
}

struct StagingCleanup(Option<PathBuf>);
impl Drop for StagingCleanup {
    fn drop(&mut self) {
        if let Some(path) = &self.0 {
            let _ = fs::remove_dir_all(path);
        }
    }
}

fn u16_at(bytes: &[u8], offset: usize) -> Result<u16, PluginError> {
    let value: [u8; 2] = bytes
        .get(offset..offset.checked_add(2).ok_or_else(invalid_error)?)
        .ok_or_else(invalid_error)?
        .try_into()
        .map_err(|_| invalid_error())?;
    Ok(u16::from_le_bytes(value))
}
fn u32_at(bytes: &[u8], offset: usize) -> Result<u32, PluginError> {
    let value: [u8; 4] = bytes
        .get(offset..offset.checked_add(4).ok_or_else(invalid_error)?)
        .ok_or_else(invalid_error)?
        .try_into()
        .map_err(|_| invalid_error())?;
    Ok(u32::from_le_bytes(value))
}
fn invalid_error() -> PluginError {
    PluginError::new(
        "ARCHIVE_INVALID",
        "Malformed or inconsistent plugin ZIP archive",
    )
}
fn limit_error() -> PluginError {
    PluginError::new(
        "ARCHIVE_LIMIT",
        "Plugin archive exceeds its bounded extraction limits",
    )
}
fn unsupported_error() -> PluginError {
    PluginError::new(
        "ARCHIVE_UNSUPPORTED",
        "Archive format, compression or metadata is not supported",
    )
}
