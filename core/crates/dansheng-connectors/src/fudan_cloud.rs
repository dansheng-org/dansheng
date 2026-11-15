// SPDX-License-Identifier: GPL-3.0-or-later
//! Fudan cloud drive (`cloud.fudan.edu.cn`): read-only folder listing and
//! downloads over the site's Protobuf API.
//!
//! Message numbers come from the site's own public client bundle (proto2
//! packages `com.bjtxra.cloud.*`). Only the handful of fields used here are
//! decoded; every other field is skipped, so additions on the server side do
//! not break parsing. No upload, rename, delete or share operation exists here.
//!
//! The drive keeps its own accounts: a student number with a password set on
//! the drive, not the UIS password. Paths are `gtype/gpid/bucket/path`
//! (`3/<user id>/directory/...` for personal files, `2/<group id>/...` for
//! groups) and act as opaque handles; they are validated before every use and
//! are never logged.

use chrono::{DateTime, TimeZone, Utc};
use serde::Serialize;
use url::Url;

use crate::models::SourceContext;
use crate::transport::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth, check_response, check_write_response, parse_error,
};

pub const ORIGIN: &str = "https://cloud.fudan.edu.cn";
const SOURCE: &str = "FudanCloud";
const MAX_LISTING_BYTES: usize = 8 * 1024 * 1024;
const MAX_ITEMS: usize = 10_000;
const MAX_FIELDS: usize = 200_000;
const MAX_PATH: usize = 4096;

// Message field numbers (see the module documentation).
const GTYPE_GROUP: u64 = 2;
const GTYPE_USER: u64 = 3;
const OBJECT_TREE: u64 = 2;
const OBJECT_BLOB: u64 = 3;
const PERMISSION_DOWNLOAD: u64 = 6;
const PERMISSION_CREATE: u64 = 8;
const PERMISSION_EDIT: u64 = 9;
const PERMISSION_DELETE: u64 = 10;
const PERMISSION_SHARE: u64 = 15;
const GRANT_ACCEPTED: u64 = 2;
const UPDATE_ADD: u64 = 1;
const UPDATE_DELETE: u64 = 2;
const ORIGIN_NORMAL: u64 = 1;
/// Files up to this size travel inside the index update itself.
const INLINE_MAX: usize = 128 * 1024;
/// The host's binary request limit; larger uploads are refused up front.
pub const MAX_UPLOAD: usize = 8 * 1024 * 1024;
const MAX_NAME: usize = 200;

// --- Minimal proto2 wire format -----------------------------------------------

enum Wire<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Fixed,
}

struct Field<'a> {
    number: u32,
    value: Wire<'a>,
}

fn varint(buf: &[u8], pos: &mut usize) -> Result<u64, ConnectorError> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let byte = *buf.get(*pos).ok_or(parse_error(SOURCE, "varint"))?;
        *pos += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(parse_error(SOURCE, "varint"))
}

fn fields(buf: &[u8]) -> Result<Vec<Field<'_>>, ConnectorError> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        if out.len() >= MAX_FIELDS {
            return Err(ConnectorError::LimitExceeded);
        }
        let key = varint(buf, &mut pos)?;
        let number = u32::try_from(key >> 3).map_err(|_| parse_error(SOURCE, "field"))?;
        if number == 0 {
            return Err(parse_error(SOURCE, "field"));
        }
        let value = match key & 7 {
            0 => Wire::Varint(varint(buf, &mut pos)?),
            2 => {
                let len = usize::try_from(varint(buf, &mut pos)?)
                    .map_err(|_| parse_error(SOURCE, "length"))?;
                let end = pos
                    .checked_add(len)
                    .filter(|end| *end <= buf.len())
                    .ok_or(parse_error(SOURCE, "length"))?;
                let bytes = &buf[pos..end];
                pos = end;
                Wire::Bytes(bytes)
            }
            1 | 5 => {
                let width = if key & 7 == 1 { 8 } else { 4 };
                pos = pos
                    .checked_add(width)
                    .filter(|end| *end <= buf.len())
                    .ok_or(parse_error(SOURCE, "fixed"))?;
                Wire::Fixed
            }
            _ => return Err(parse_error(SOURCE, "wire type")),
        };
        out.push(Field { number, value });
    }
    Ok(out)
}

fn int_of(fields: &[Field<'_>], number: u32) -> Option<u64> {
    fields.iter().rev().find_map(|f| match f.value {
        Wire::Varint(v) if f.number == number => Some(v),
        _ => None,
    })
}

fn bytes_of<'a>(fields: &[Field<'a>], number: u32) -> Option<&'a [u8]> {
    fields.iter().rev().find_map(|f| match f.value {
        Wire::Bytes(b) if f.number == number => Some(b),
        _ => None,
    })
}

fn all_bytes<'a>(fields: &'a [Field<'a>], number: u32) -> impl Iterator<Item = &'a [u8]> + 'a {
    fields.iter().filter_map(move |f| match f.value {
        Wire::Bytes(b) if f.number == number => Some(b),
        _ => None,
    })
}

fn text_of(fields: &[Field<'_>], number: u32) -> Result<Option<String>, ConnectorError> {
    bytes_of(fields, number)
        .map(|b| {
            std::str::from_utf8(b)
                .map(str::to_owned)
                .map_err(|_| parse_error(SOURCE, "text"))
        })
        .transpose()
}

fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    while value > 0x7f {
        out.push((value as u8 & 0x7f) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

fn put_text(out: &mut Vec<u8>, number: u64, text: &str) {
    put_bytes(out, number, text.as_bytes());
}

fn put_bytes(out: &mut Vec<u8>, number: u64, bytes: &[u8]) {
    put_varint(out, number << 3 | 2);
    put_varint(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

fn put_int(out: &mut Vec<u8>, number: u64, value: u64) {
    put_varint(out, number << 3);
    put_varint(out, value);
}

// --- Request helpers ------------------------------------------------------------

/// The web client's `csrftoken` query value: a random token in its own
/// self-describing encoding. It carries no secret; the server only checks shape.
pub fn csrf_token() -> String {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
    let random = uuid::Uuid::new_v4();
    let bytes = random.as_bytes();
    let token = format!(
        "token{}{}",
        CHARS[bytes[0] as usize % CHARS.len()] as char,
        CHARS[bytes[1] as usize % CHARS.len()] as char
    );
    STANDARD.encode(format!("{token}@{}", STANDARD.encode(&token)))
}

/// The login form wraps each credential as `{BASE64}<base64>` (an encoding,
/// not encryption; the request itself travels over HTTPS only).
fn wrapped(value: &str) -> String {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    format!("{{BASE64}}{}", STANDARD.encode(value))
}

/// `LoginInfo { username = 1; password = 2; isRemember = 3; }`.
pub fn login_body(student_id: &str, password: &str) -> Vec<u8> {
    let mut out = Vec::new();
    put_text(&mut out, 1, &wrapped(student_id));
    put_text(&mut out, 2, &wrapped(password));
    put_varint(&mut out, 3 << 3);
    put_varint(&mut out, 0);
    out
}

/// A drive path checked segment by segment: `gtype/gpid/bucket[/name...]`,
/// optionally led by the default root hash. Rejects traversal, empty or
/// control-character segments and anything outside the known owner types.
pub fn validate_path(path: &str) -> Result<Vec<String>, ConnectorError> {
    let invalid = ConnectorError::InvalidConfiguration("cloud path");
    if path.is_empty() || path.len() > MAX_PATH || path.contains('\\') {
        return Err(invalid);
    }
    let trimmed = path.trim_start_matches('/');
    let trailing = trimmed.ends_with('/');
    let mut segments: Vec<String> = trimmed
        .trim_end_matches('/')
        .split('/')
        .map(str::to_owned)
        .collect();
    if segments.first().is_some_and(|s| s == "default") {
        segments.remove(0);
    }
    if segments.len() < 3
        || segments
            .iter()
            .any(|s| s.is_empty() || s == "." || s == ".." || s.chars().any(char::is_control))
    {
        return Err(invalid);
    }
    let gtype: u64 = segments[0].parse().map_err(|_| invalid.clone())?;
    if ![GTYPE_GROUP, GTYPE_USER].contains(&gtype)
        || !segments[1].bytes().all(|b| b.is_ascii_digit())
        || segments[1].len() > 12
        || segments[2] != "directory"
    {
        return Err(invalid);
    }
    if trailing || segments.len() == 3 {
        segments.push(String::new());
    }
    Ok(segments)
}

fn endpoint(prefix: &str, path: &str) -> Result<Url, ConnectorError> {
    let segments = validate_path(path)?;
    let mut url = Url::parse(ORIGIN).expect("constant origin");
    url.path_segments_mut()
        .map_err(|_| ConnectorError::UnsafeUrl)?
        .clear()
        .extend(prefix.split('/'))
        .extend(segments.iter().map(String::as_str));
    url.query_pairs_mut()
        .append_pair("csrftoken", &csrf_token());
    Ok(url)
}

/// `parent` + one validated name.
pub fn child_path(parent: &str, name: &str) -> Result<String, ConnectorError> {
    let mut segments: Vec<String> = validate_path(parent)?
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect();
    segments.push(validate_name(name)?);
    let path = segments.join("/");
    validate_path(&path)?;
    Ok(path)
}

/// The folder holding `path`; a root has no parent.
pub fn parent_path(path: &str) -> Result<String, ConnectorError> {
    let mut segments: Vec<String> = validate_path(path)?
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect();
    if segments.len() < 4 {
        return Err(ConnectorError::InvalidConfiguration("cloud root"));
    }
    segments.pop();
    Ok(format!("{}/", segments.join("/")))
}

/// The GET address of one file, for the host's managed download.
pub fn download_url(path: &str) -> Result<Url, ConnectorError> {
    let segments = validate_path(path)?;
    if segments.last().is_some_and(String::is_empty) || segments.len() < 4 {
        return Err(ConnectorError::InvalidConfiguration("cloud file path"));
    }
    endpoint("download", path)
}

// --- Models -----------------------------------------------------------------------

/// A browsable top-level folder: personal files or one group's files.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct CloudRoot {
    pub kind: &'static str,
    pub name: String,
    pub path: String,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct CloudItem {
    pub name: String,
    pub path: String,
    pub is_folder: bool,
    pub size: Option<u64>,
    pub modified_at: Option<DateTime<Utc>>,
    pub content_type: Option<String>,
    pub children: Option<u64>,
    pub downloadable: bool,
    pub can_rename: bool,
    pub can_delete: bool,
    /// Link sharing is a per-account school policy; most student accounts
    /// do not have it.
    pub can_share: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct CloudListing {
    pub path: String,
    pub items: Vec<CloudItem>,
    /// Whether files and folders may be created here.
    pub can_create: bool,
}

/// A created share link. The fetch code, when present, is the link password.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct CloudShare {
    pub url: String,
    pub batch_link: String,
    pub fetch_code: Option<String>,
}

/// Fields the server needs to delete an entry, taken from a fresh listing.
struct RawEntry {
    full_path: String,
    object_type: u64,
    hash: String,
    size: u64,
    content_type: String,
    date: u64,
    security_level: u64,
}

/// The server writes Unix milliseconds; tolerate seconds as well.
fn timestamp(value: Option<u64>) -> Option<DateTime<Utc>> {
    let value = i64::try_from(value?).ok().filter(|v| *v > 0)?;
    let millis = if value < 100_000_000_000 {
        value.checked_mul(1000)?
    } else {
        value
    };
    Utc.timestamp_millis_opt(millis).single()
}

/// `PermissionControl { map<int32,int32> control = 1; }` — a right is granted
/// when its entry is `Accepted`. Missing control means the server did not
/// restrict the item; every operation is still authorized remotely.
fn permitted(control: Option<&[u8]>, permission: u64) -> Result<bool, ConnectorError> {
    let Some(control) = control else {
        return Ok(true);
    };
    let entries = fields(control)?;
    for entry in all_bytes(&entries, 1) {
        let pair = fields(entry)?;
        if int_of(&pair, 1) == Some(permission) {
            return Ok(int_of(&pair, 2) == Some(GRANT_ACCEPTED));
        }
    }
    Ok(false)
}

/// `TreeItem`: type 1, name 2, size 4, docType 5, fullPath 7, date 8,
/// children 9, contentType 10, control 25.
fn tree_item(buf: &[u8]) -> Result<Option<CloudItem>, ConnectorError> {
    let item = fields(buf)?;
    let name = text_of(&item, 2)?.unwrap_or_default();
    let Some(path) = text_of(&item, 7)? else {
        return Ok(None);
    };
    if name.is_empty() || validate_path(&path).is_err() {
        return Ok(None);
    }
    let doc_type = text_of(&item, 5)?;
    let is_folder = doc_type.as_deref() == Some("folder") || int_of(&item, 1) == Some(OBJECT_TREE);
    let control = bytes_of(&item, 25);
    Ok(Some(CloudItem {
        name: name.chars().filter(|c| !c.is_control()).collect(),
        path,
        is_folder,
        size: if is_folder { None } else { int_of(&item, 4) },
        modified_at: timestamp(int_of(&item, 8)),
        content_type: text_of(&item, 10)?.filter(|t| !t.is_empty() && t.len() <= 255),
        children: if is_folder { int_of(&item, 9) } else { None },
        downloadable: !is_folder && permitted(control, PERMISSION_DOWNLOAD)?,
        can_rename: permitted(control, PERMISSION_EDIT)?,
        can_delete: permitted(control, PERMISSION_DELETE)?,
        can_share: control.is_some() && permitted(control, PERMISSION_SHARE)?,
    }))
}

/// The delete fields of every entry in a listing body.
fn raw_entries(body: &[u8]) -> Result<Vec<RawEntry>, ConnectorError> {
    let refer = fields(body)?;
    let Some(store) = bytes_of(&refer, 4) else {
        return Ok(Vec::new());
    };
    let store = fields(store)?;
    let Some(tree) = bytes_of(&store, 5) else {
        return Ok(Vec::new());
    };
    let tree = fields(tree)?;
    let mut out = Vec::new();
    for raw in all_bytes(&tree, 1) {
        let item = fields(raw)?;
        let Some(full_path) = text_of(&item, 7)? else {
            continue;
        };
        out.push(RawEntry {
            full_path,
            object_type: int_of(&item, 1).unwrap_or(OBJECT_BLOB),
            hash: text_of(&item, 3)?.unwrap_or_default(),
            size: int_of(&item, 4).unwrap_or(0),
            content_type: text_of(&item, 10)?.unwrap_or_default(),
            date: int_of(&item, 8).unwrap_or(0),
            security_level: int_of(&item, 26).unwrap_or(0),
        });
    }
    Ok(out)
}

/// `StoreRefer { result 1; store 4 }`, `Store { tree 5 }`, `Tree { items 1 }`.
pub fn parse_listing(path: &str, body: &[u8]) -> Result<CloudListing, ConnectorError> {
    let refer = fields(body)?;
    // An empty folder arrives as an all-default message (often zero bytes).
    // An explicit non-OK result without content is a server-side failure.
    let store = match bytes_of(&refer, 4) {
        Some(store) => fields(store)?,
        None if int_of(&refer, 1).is_none_or(|code| code == 1) => Vec::new(),
        None => return Err(parse_error(SOURCE, "result")),
    };
    let mut items = Vec::new();
    if let Some(tree) = bytes_of(&store, 5) {
        let tree = fields(tree)?;
        for raw in all_bytes(&tree, 1) {
            if items.len() >= MAX_ITEMS {
                return Err(ConnectorError::LimitExceeded);
            }
            if let Some(item) = tree_item(raw)? {
                items.push(item);
            }
        }
    }
    items.sort_by(|a, b| {
        b.is_folder
            .cmp(&a.is_folder)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(CloudListing {
        path: path.to_owned(),
        items,
        // StoreRefer.control (10) is the folder's own permission map.
        can_create: permitted(bytes_of(&refer, 10), PERMISSION_CREATE)?,
    })
}

/// `OrgItem { gtype 1; gpid 2; fullname 4 }` of the signed-in user.
pub fn parse_user_root(body: &[u8]) -> Result<CloudRoot, ConnectorError> {
    let org = fields(body)?;
    let gpid = int_of(&org, 2)
        .filter(|id| *id > 0)
        .ok_or(parse_error(SOURCE, "user id"))?;
    if int_of(&org, 1) != Some(GTYPE_USER) {
        return Err(parse_error(SOURCE, "user type"));
    }
    Ok(CloudRoot {
        kind: "personal",
        name: "个人文件".into(),
        path: format!("{GTYPE_USER}/{gpid}/directory/"),
    })
}

/// `OrgItem.userInfo(11).hashSalt(70)`: appended to file bytes before hashing.
fn parse_salt(body: &[u8]) -> Result<Vec<u8>, ConnectorError> {
    let org = fields(body)?;
    let Some(info) = bytes_of(&org, 11) else {
        return Ok(Vec::new());
    };
    // The web client turns each character code into one byte.
    Ok(text_of(&fields(info)?, 70)?
        .unwrap_or_default()
        .chars()
        .map(|c| c as u32 as u8)
        .collect())
}

/// A new file or folder name: one path segment the drive will accept.
pub fn validate_name(name: &str) -> Result<String, ConnectorError> {
    let name = name.trim();
    if name.is_empty()
        || name.chars().count() > MAX_NAME
        || name == "."
        || name == ".."
        || name
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\'))
    {
        return Err(ConnectorError::InvalidConfiguration("cloud file name"));
    }
    Ok(name.to_owned())
}

/// `name.ext` → `name (1).ext` … until it is free, like the web client.
fn unique_name(name: &str, taken: &[String]) -> String {
    let lower: Vec<String> = taken.iter().map(|t| t.to_lowercase()).collect();
    if !lower.contains(&name.to_lowercase()) {
        return name.to_owned();
    }
    let (stem, ext) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    (1..)
        .map(|n| format!("{stem} ({n}){ext}"))
        .find(|candidate| !lower.contains(&candidate.to_lowercase()))
        .expect("an unused name exists")
}

/// The drive's content hash: SHA-1 of the bytes followed by the user's salt.
pub fn content_hash(data: &[u8], salt: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(data);
    hasher.update(salt);
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Proof that the uploader holds the bytes behind an already-known hash. The
/// server names a window as `start/len` (start in 1/256ths of the file).
pub fn possession_check(data: &[u8], salt: &[u8], setting: &str) -> Option<(String, u64)> {
    let (start, len) = setting.trim().split_once('/')?;
    let start: u64 = start.trim().parse().ok()?;
    let requested: u64 = len.trim().parse().ok()?;
    let size = data.len() as u64;
    let mut offset = start.saturating_mul(size) / 256;
    let mut take = requested;
    if offset >= size {
        offset = size / 2;
    }
    if offset + take >= size {
        take = size.saturating_sub(offset).saturating_sub(1);
    }
    let window = &data[offset as usize..(offset + take) as usize];
    Some((content_hash(window, salt), requested))
}

fn rejection(code: u64) -> ConnectorError {
    match code {
        16 => ConnectorError::Rejected("PermissionDenied"),
        17 | 10 => ConnectorError::Rejected("FileUnavailable"),
        18 => ConnectorError::Rejected("QuotaExceeded"),
        59 | 200 | 5900 | 200300 => ConnectorError::Rejected("NameConflict"),
        _ => ConnectorError::Rejected("SourceRejected"),
    }
}

/// `RspInfo`/`FileOpRspInfoList` start with `code = 1`; 1 is RETURN_OK.
fn expect_ok(body: &[u8]) -> Result<(), ConnectorError> {
    let parsed = fields(body)?;
    match int_of(&parsed, 1) {
        Some(1) => Ok(()),
        Some(code) => Err(rejection(code)),
        None => Err(parse_error(SOURCE, "result code")),
    }
}

/// Owner (`gtype`, `gpid`) and the path inside that owner's folder tree.
fn split_path(path: &str) -> Result<(String, String, String), ConnectorError> {
    let segments = validate_path(path)?;
    let names: Vec<&str> = segments[3..]
        .iter()
        .map(String::as_str)
        .filter(|s| !s.is_empty())
        .collect();
    Ok((
        segments[0].clone(),
        segments[1].clone(),
        format!("/{}", names.join("/")),
    ))
}

fn same_path(a: &str, b: &str) -> bool {
    match (validate_path(a), validate_path(b)) {
        (Ok(x), Ok(y)) => {
            let clean =
                |v: Vec<String>| v.into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>();
            clean(x) == clean(y)
        }
        _ => false,
    }
}

/// `TreeUpdateReq { path 1; roothash 2; repeated items 3; origin 20; taskId 25; operateId 26 }`.
fn tree_update(path: Option<&str>, items: &[Vec<u8>]) -> Vec<u8> {
    let id = uuid::Uuid::new_v4().to_string();
    let mut out = Vec::new();
    if let Some(path) = path {
        put_text(&mut out, 1, path);
        put_text(&mut out, 2, "default");
    }
    for item in items {
        put_bytes(&mut out, 3, item);
    }
    put_int(&mut out, 20, ORIGIN_NORMAL);
    put_text(&mut out, 25, &id);
    put_text(&mut out, 26, &id);
    out
}

/// One `TreeUpdateItem` adding a blob at `repo_path`.
#[allow(clippy::too_many_arguments)]
fn add_item(
    repo_path: &str,
    hash: &str,
    size: u64,
    content_type: &str,
    modified_ms: u64,
    inline: Option<&[u8]>,
    check: Option<(&str, u64)>,
) -> Vec<u8> {
    let mut out = Vec::new();
    put_int(&mut out, 1, OBJECT_BLOB);
    put_int(&mut out, 2, UPDATE_ADD);
    put_text(&mut out, 3, repo_path);
    put_text(&mut out, 4, hash);
    put_int(&mut out, 5, size);
    if let Some((check, check_size)) = check {
        put_text(&mut out, 6, check);
        put_int(&mut out, 7, check_size);
    }
    put_text(&mut out, 8, content_type);
    put_int(&mut out, 10, modified_ms);
    if let Some(data) = inline {
        put_bytes(&mut out, 12, data);
    }
    put_int(&mut out, 13, 0);
    out
}

fn delete_item(entry: &RawEntry, repo_path: &str) -> Vec<u8> {
    let mut out = Vec::new();
    put_int(&mut out, 1, entry.object_type);
    put_int(&mut out, 2, UPDATE_DELETE);
    put_text(&mut out, 3, "");
    put_text(&mut out, 4, &entry.hash);
    put_int(&mut out, 5, entry.size);
    put_text(&mut out, 8, &entry.content_type);
    put_text(&mut out, 9, repo_path);
    put_int(&mut out, 10, entry.date);
    put_int(&mut out, 13, entry.security_level);
    out
}

/// `FileShare` for one entry as a link with the given role and lifetime.
fn share_body(
    entry: &CloudItem,
    gtype: &str,
    gpid: &str,
    repo_path: &str,
    role: &[u8],
    until_ms: u64,
    with_code: bool,
) -> Vec<u8> {
    let mut info = Vec::new();
    put_text(&mut info, 1, &entry.name);
    put_text(&mut info, 2, repo_path);
    put_int(&mut info, 3, entry.size.unwrap_or(0));
    put_text(&mut info, 5, if entry.is_folder { "folder" } else { "" });
    put_int(
        &mut info,
        6,
        if entry.is_folder {
            OBJECT_TREE
        } else {
            OBJECT_BLOB
        },
    );
    put_text(&mut info, 7, entry.content_type.as_deref().unwrap_or(""));
    put_int(&mut info, 8, 0);
    put_int(&mut info, 21, gpid.parse().unwrap_or(0));
    put_int(&mut info, 22, gtype.parse().unwrap_or(0));
    put_text(&mut info, 23, "directory");
    let mut resource = Vec::new();
    put_bytes(&mut resource, 1, &info);
    let mut access = Vec::new();
    put_bytes(&mut access, 1, role);
    put_int(&mut access, 2, 0);
    put_int(&mut access, 3, until_ms);
    let mut link = Vec::new();
    put_bytes(&mut link, 1, &access);
    put_text(&mut link, 3, "");
    let mut share = Vec::new();
    put_bytes(&mut share, 1, &resource);
    put_int(&mut share, 3, 0);
    // PrivateLinkShare (7) carries a fetch code; PublicLinkShare (6) does not.
    put_int(&mut share, 4, if with_code { 7 } else { 6 });
    put_bytes(&mut share, 22, &link);
    share
}

/// The share role to grant: "downloader" when offered, else the first role.
fn pick_role(body: &[u8]) -> Result<Vec<u8>, ConnectorError> {
    let list = fields(body)?;
    let roles: Vec<&[u8]> = all_bytes(&list, 1).collect();
    for role in &roles {
        if text_of(&fields(role)?, 2)?.as_deref() == Some("downloader") {
            return Ok(role.to_vec());
        }
    }
    roles
        .first()
        .map(|r| r.to_vec())
        .ok_or(ConnectorError::Rejected("PermissionDenied"))
}

/// `RspInfoList { code 1; repeated RspInfo items 2; msg 3 }`; the message is a
/// JSON object with `batchLink` and `fetchCode` on success.
fn parse_share(body: &[u8]) -> Result<CloudShare, ConnectorError> {
    let list = fields(body)?;
    for item in all_bytes(&list, 2) {
        if let Some(code) = int_of(&fields(item)?, 1).filter(|c| *c != 1) {
            return Err(rejection(code));
        }
    }
    expect_ok(body)?;
    let msg = text_of(&list, 3)?.ok_or(parse_error(SOURCE, "share message"))?;
    let value: serde_json::Value =
        serde_json::from_str(&msg).map_err(|_| parse_error(SOURCE, "share message"))?;
    let batch = value["batchLink"]
        .as_str()
        .filter(|b| valid_batch_link(b))
        .ok_or(parse_error(SOURCE, "share link"))?;
    Ok(CloudShare {
        url: format!("{ORIGIN}/#routeview/s/{batch}"),
        batch_link: batch.to_owned(),
        fetch_code: value["fetchCode"]
            .as_str()
            .filter(|c| !c.is_empty() && c.len() <= 32)
            .map(str::to_owned),
    })
}

pub fn valid_batch_link(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// `OrgsList { repeated Orgs items = 1 }`, `Orgs { repeated OrgItem items = 1 }`.
pub fn parse_group_roots(body: &[u8]) -> Result<Vec<CloudRoot>, ConnectorError> {
    let list = fields(body)?;
    let mut roots = Vec::new();
    for orgs in all_bytes(&list, 1) {
        let orgs = fields(orgs)?;
        for org in all_bytes(&orgs, 1) {
            let org = fields(org)?;
            let (Some(GTYPE_GROUP), Some(gpid)) = (int_of(&org, 1), int_of(&org, 2)) else {
                continue;
            };
            if gpid == 0 || roots.len() >= 500 {
                continue;
            }
            roots.push(CloudRoot {
                kind: "group",
                name: text_of(&org, 4)?
                    .filter(|n| !n.trim().is_empty())
                    .unwrap_or_else(|| "群组".into()),
                path: format!("{GTYPE_GROUP}/{gpid}/directory/"),
            });
        }
    }
    Ok(roots)
}

// --- Client -----------------------------------------------------------------------

pub struct FudanCloudClient<T> {
    transport: T,
}

impl<T: ConnectorTransport> FudanCloudClient<T> {
    pub fn new(transport: T) -> Self {
        Self { transport }
    }

    /// One request; returns the body and the server's `Check-Setting` header.
    async fn send(
        &self,
        method: HttpMethod,
        url: Url,
        body: Option<(Vec<u8>, &str)>,
        source: &SourceContext,
    ) -> Result<(Vec<u8>, Option<String>), ConnectorError> {
        source.validate()?;
        let challenge = AuthChallenge {
            connector: "fudan-cloud".into(),
            origin: ORIGIN.into(),
            account_id: source.account_id.clone(),
            mode: AuthMode::HttpSession,
        };
        let mut headers = vec![
            ("Accept".into(), "application/x-protobuf".into()),
            ("csrftoken".into(), csrf_token()),
        ];
        let body = match body {
            Some((bytes, content_type)) => {
                headers.push(("Content-Type".into(), content_type.into()));
                Some(bytes)
            }
            // Like a browser, send `Content-Length: 0` on body-less writes; the
            // drive silently ignores a PUT/POST without it.
            None if method != HttpMethod::Get => Some(Vec::new()),
            None => None,
        };
        let response = self
            .transport
            .execute(ConnectorRequest {
                method,
                url: url.clone(),
                headers,
                body,
                auth: TransportAuth::HostSession {
                    account_id: source.account_id.clone(),
                },
            })
            .await
            .map_err(|error| {
                if method.is_mutating() {
                    error.after_write()
                } else {
                    error
                }
            })?;
        if method.is_mutating() {
            check_write_response(&response, &url, MAX_LISTING_BYTES)?;
        }
        check_response(
            &response,
            &Url::parse(ORIGIN).expect("constant origin"),
            challenge,
            MAX_LISTING_BYTES,
        )
        .map_err(|error| {
            if method.is_mutating() && (200..300).contains(&response.status) {
                ConnectorError::NeedsReconciliation
            } else {
                error
            }
        })?;
        let check = response
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("check-setting"))
            .map(|(_, v)| v.clone());
        Ok((response.body, check))
    }

    async fn get(&self, url: Url, source: &SourceContext) -> Result<Vec<u8>, ConnectorError> {
        Ok(self.send(HttpMethod::Get, url, None, source).await?.0)
    }

    fn fixed(path: &str) -> Url {
        let mut url = Url::parse(ORIGIN).expect("constant origin");
        url.set_path(path);
        url.query_pairs_mut()
            .append_pair("csrftoken", &csrf_token());
        url
    }

    /// The signed-in user's personal root; also proves the session is live.
    pub async fn user_root(&self, source: &SourceContext) -> Result<CloudRoot, ConnectorError> {
        parse_user_root(&self.get(Self::fixed("/user"), source).await?)
    }

    /// Creates `name` inside `parent`; returns the new folder's path.
    pub async fn create_folder(
        &self,
        source: &SourceContext,
        parent: &str,
        name: &str,
    ) -> Result<String, ConnectorError> {
        let name = validate_name(name)?;
        let path = child_path(parent, &name)?;
        let (body, _) = self
            .send(
                HttpMethod::Put,
                endpoint("filesop/folders", &path)?,
                None,
                source,
            )
            .await?;
        expect_ok(&body).map_err(ConnectorError::after_write)?;
        Ok(path)
    }

    pub async fn rename(
        &self,
        source: &SourceContext,
        path: &str,
        new_name: &str,
    ) -> Result<(), ConnectorError> {
        let new_name = validate_name(new_name)?;
        let segments = validate_path(path)?;
        if segments.len() < 4 || segments.last().is_some_and(String::is_empty) {
            return Err(ConnectorError::InvalidConfiguration("cloud path"));
        }
        let mut url = Url::parse(ORIGIN).expect("constant origin");
        url.path_segments_mut()
            .map_err(|_| ConnectorError::UnsafeUrl)?
            .clear()
            .extend(["filesop", "rename", new_name.as_str()])
            .extend(segments.iter().map(String::as_str));
        url.query_pairs_mut()
            .append_pair("csrftoken", &csrf_token());
        let (body, _) = self.send(HttpMethod::Put, url, None, source).await?;
        expect_ok(&body).map_err(ConnectorError::after_write)
    }

    /// Moves entries to the drive's recycle bin. Each entry is looked up in a
    /// fresh listing of its folder first, so a stale path deletes nothing.
    pub async fn delete(&self, source: &SourceContext, path: &str) -> Result<(), ConnectorError> {
        let (gtype, gpid, repo_path) = split_path(path)?;
        if repo_path == "/" {
            return Err(ConnectorError::InvalidConfiguration("cloud root"));
        }
        let parent = parent_path(path)?;
        let listing = self.get(endpoint("files", &parent)?, source).await?;
        let entry = raw_entries(&listing)?
            .into_iter()
            .find(|e| same_path(&e.full_path, path))
            .ok_or(ConnectorError::Rejected("FileUnavailable"))?;
        let body = tree_update(None, &[delete_item(&entry, &repo_path)]);
        let mut url = Url::parse(ORIGIN).expect("constant origin");
        url.path_segments_mut()
            .map_err(|_| ConnectorError::UnsafeUrl)?
            .clear()
            .extend([
                "upload",
                "default",
                gtype.as_str(),
                gpid.as_str(),
                "directory",
                "",
            ]);
        url.query_pairs_mut()
            .append_pair("csrftoken", &csrf_token());
        let (body, _) = self
            .send(
                HttpMethod::Post,
                url,
                Some((body, "application/cc-update-index")),
                source,
            )
            .await?;
        expect_ok(&body).map_err(ConnectorError::after_write)
    }

    /// Uploads `data` as `name` into `folder`, renaming on a clash. Small files
    /// go inline with the index update; larger ones are offered by hash first,
    /// sent as one blob when the server lacks them, then committed.
    pub async fn upload(
        &self,
        source: &SourceContext,
        folder: &str,
        name: &str,
        data: &[u8],
        content_type: &str,
        modified_ms: u64,
    ) -> Result<String, ConnectorError> {
        if data.len() > MAX_UPLOAD {
            return Err(ConnectorError::Rejected("AssetTooLarge"));
        }
        let name = validate_name(name)?;
        let (_, _, folder_repo) = split_path(folder)?;
        let (user, mut check_setting) = self
            .send(HttpMethod::Get, Self::fixed("/user"), None, source)
            .await?;
        let salt = parse_salt(&user)?;
        let (listing, check) = self
            .send(HttpMethod::Get, endpoint("files", folder)?, None, source)
            .await?;
        check_setting = check.or(check_setting);
        let taken: Vec<String> = parse_listing(folder, &listing)?
            .items
            .into_iter()
            .map(|i| i.name)
            .collect();
        let name = unique_name(&name, &taken);
        let target = child_path(folder, &name)?;
        let repo_path = if folder_repo == "/" {
            format!("/{name}")
        } else {
            format!("{folder_repo}/{name}")
        };
        let hash = content_hash(data, &salt);
        let content_type = if content_type.is_empty() {
            "application/octet-stream"
        } else {
            content_type
        };
        let item = if data.len() <= INLINE_MAX {
            add_item(
                &repo_path,
                &hash,
                data.len() as u64,
                content_type,
                modified_ms,
                Some(data),
                None,
            )
        } else {
            let setting = check_setting.ok_or(parse_error(SOURCE, "check setting"))?;
            let (check, check_size) = possession_check(data, &salt, &setting)
                .ok_or(parse_error(SOURCE, "check setting"))?;
            let has = |check: &str| {
                let mut url = Self::fixed("/has");
                url.query_pairs_mut()
                    .append_pair("hash", &hash)
                    .append_pair("check", check)
                    .append_pair("size", &check_size.to_string());
                url
            };
            let (offer, _) = self
                .send(HttpMethod::Post, has(&check), None, source)
                .await?;
            // RETURN_NEED_UPLOAD_FILE (21): the server does not hold these bytes.
            if int_of(&fields(&offer)?, 1) == Some(21) {
                let mut url = endpoint("upload/default", &target)?;
                url.query_pairs_mut()
                    .append_pair("lastmodified", &modified_ms.to_string())
                    .append_pair("hash", &hash);
                let (sent, _) = self
                    .send(
                        HttpMethod::Post,
                        url,
                        Some((data.to_vec(), "application/octet-stream")),
                        source,
                    )
                    .await?;
                expect_ok(&sent).map_err(ConnectorError::after_write)?;
                let (confirm, _) = self
                    .send(HttpMethod::Post, has(&check), None, source)
                    .await
                    .map_err(|_| ConnectorError::NeedsReconciliation)?;
                expect_ok(&confirm).map_err(|_| ConnectorError::NeedsReconciliation)?;
            } else {
                expect_ok(&offer).map_err(ConnectorError::after_write)?;
            }
            add_item(
                &repo_path,
                &hash,
                data.len() as u64,
                content_type,
                modified_ms,
                None,
                Some((&check, check_size)),
            )
        };
        let segments = validate_path(folder)?;
        let index_path = format!(
            "default/{}",
            segments
                .iter()
                .filter(|s| !s.is_empty())
                .cloned()
                .collect::<Vec<_>>()
                .join("/")
        );
        let body = tree_update(Some(&index_path), &[item]);
        let (body, _) = self
            .send(
                HttpMethod::Post,
                endpoint("upload/default", folder)?,
                Some((body, "application/cc-update-index")),
                source,
            )
            .await?;
        expect_ok(&body).map_err(ConnectorError::after_write)?;
        Ok(target)
    }

    /// Creates a link share for one entry. Most student accounts lack the
    /// right; the server then answers `PermissionDenied`.
    pub async fn share(
        &self,
        source: &SourceContext,
        path: &str,
        days: u32,
        with_code: bool,
    ) -> Result<CloudShare, ConnectorError> {
        let (gtype, gpid, repo_path) = split_path(path)?;
        let parent = parent_path(path)?;
        let entry = parse_listing(
            &parent,
            &self.get(endpoint("files", &parent)?, source).await?,
        )?
        .items
        .into_iter()
        .find(|i| same_path(&i.path, path))
        .ok_or(ConnectorError::Rejected("FileUnavailable"))?;
        if !entry.can_share {
            return Err(ConnectorError::Rejected("PermissionDenied"));
        }
        let role = pick_role(&self.get(Self::fixed("/permission/role/1"), source).await?)?;
        let until = Utc::now().timestamp_millis().max(0) as u64
            + u64::from(days.clamp(1, 365)) * 86_400_000;
        let body = share_body(&entry, &gtype, &gpid, &repo_path, &role, until, with_code);
        let (reply, _) = self
            .send(
                HttpMethod::Post,
                Self::fixed("/sharefile/create"),
                Some((body, "application/x-protobuf")),
                source,
            )
            .await?;
        parse_share(&reply).map_err(ConnectorError::after_write)
    }

    pub async fn revoke_share(
        &self,
        source: &SourceContext,
        batch_link: &str,
    ) -> Result<(), ConnectorError> {
        if !valid_batch_link(batch_link) {
            return Err(ConnectorError::InvalidConfiguration("share link"));
        }
        let mut url = Url::parse(ORIGIN).expect("constant origin");
        url.path_segments_mut()
            .map_err(|_| ConnectorError::UnsafeUrl)?
            .clear()
            .extend(["sharefile", "batchlink", batch_link]);
        url.query_pairs_mut()
            .append_pair("csrftoken", &csrf_token());
        let (body, _) = self.send(HttpMethod::Delete, url, None, source).await?;
        expect_ok(&body).map_err(ConnectorError::after_write)
    }

    /// Personal files first, then every group the user belongs to. A failed
    /// group lookup does not hide personal files.
    pub async fn roots(&self, source: &SourceContext) -> Result<Vec<CloudRoot>, ConnectorError> {
        let mut roots = vec![self.user_root(source).await?];
        let mut groups = Url::parse(ORIGIN).expect("constant origin");
        groups.set_path("/usergroup/groups");
        groups
            .query_pairs_mut()
            .append_pair("csrftoken", &csrf_token());
        match self.get(groups, source).await {
            Ok(body) => roots.extend(parse_group_roots(&body)?),
            Err(ConnectorError::AuthRequired(challenge)) => {
                return Err(ConnectorError::AuthRequired(challenge));
            }
            Err(_) => {}
        }
        Ok(roots)
    }

    pub async fn list(
        &self,
        source: &SourceContext,
        path: &str,
    ) -> Result<CloudListing, ConnectorError> {
        let body = self.get(endpoint("files", path)?, source).await?;
        parse_listing(path, &body)
    }
}

// --- Login ------------------------------------------------------------------------

/// Session cookies for `ORIGIN`. Not proof of identity by itself; callers verify
/// with a private read (`/user`) after importing them.
#[cfg(feature = "login")]
pub struct CloudSession {
    pub cookies: Vec<String>,
}

#[cfg(feature = "login")]
fn login_error(code: u64) -> crate::login::LoginError {
    use crate::login::LoginError;
    match code {
        // RETURN_USER_NOT_EXIST, RETURN_USER_PASS_ERROR, RETURN_USER_INVALID
        3 | 15 | 316 => LoginError::InvalidCredentials,
        // RETURN_USER_PASS_BLANK, RETURN_PASSWORD_EMPTY
        4 | 7600 => LoginError::InvalidInput,
        // RETURN_LOGIN_OFTEN, RETURN_ACCOUNT_TEMP_LOCKED, RETURN_DEVICE_NOT_TRUST:
        // the person has to resolve these on the drive's own page.
        37 | 38 | 283 => LoginError::InteractiveLoginRequired,
        _ => LoginError::AuthenticationRejected,
    }
}

/// One `POST /login` with the drive's own password. Never retried: the drive
/// locks an account after repeated failures.
#[cfg(feature = "login")]
pub async fn login(
    student_id: &str,
    password: &str,
) -> Result<CloudSession, crate::login::LoginError> {
    use crate::login::LoginError;
    use reqwest::header::{ACCEPT, CONTENT_TYPE, SET_COOKIE};
    if !(4..=64).contains(&student_id.len())
        || !student_id.bytes().all(|b| b.is_ascii_alphanumeric())
        || password.is_empty()
        || password.len() > 256
        || password.chars().any(|c| matches!(c, '\0' | '\r' | '\n'))
    {
        return Err(LoginError::InvalidInput);
    }
    let client = crate::login::verified_login_client()?
        .build()
        .map_err(|_| LoginError::NetworkError)?;
    let mut url = Url::parse(ORIGIN).expect("constant origin");
    url.set_path("/login");
    url.query_pairs_mut()
        .append_pair("csrftoken", &csrf_token());
    let response = client
        .post(url)
        .header(ACCEPT, "application/x-protobuf")
        .header(CONTENT_TYPE, "application/logininfo")
        .body(login_body(student_id, password))
        .send()
        .await
        .map_err(|e| {
            if e.is_timeout() {
                LoginError::Timeout
            } else {
                LoginError::NetworkError
            }
        })?;
    let status = response.status();
    let cookies: Vec<String> = response
        .headers()
        .get_all(SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .filter(|v| v.len() <= 4096)
        .filter(|v| {
            // Only host-only cookies or ones scoped to the drive itself.
            !v.split(';').skip(1).any(|attr| {
                let attr = attr.trim().to_ascii_lowercase();
                attr.starts_with("domain=")
                    && attr.trim_start_matches("domain=").trim_start_matches('.')
                        != "cloud.fudan.edu.cn"
            })
        })
        .take(16)
        .map(str::to_owned)
        .collect();
    let body = response
        .bytes()
        .await
        .map_err(|_| LoginError::NetworkError)?;
    if body.len() > 64 * 1024 {
        return Err(LoginError::ResponseTooLarge);
    }
    if status.is_server_error() || status.as_u16() == 429 {
        return Err(LoginError::ServiceUnavailable);
    }
    // RspInfo { code = 1 }; RETURN_OK = 1.
    let code = fields(&body)
        .ok()
        .and_then(|f| int_of(&f, 1))
        .ok_or(LoginError::ProtocolChanged)?;
    if code != 1 {
        return Err(login_error(code));
    }
    if !cookies.iter().any(|c| c.starts_with("session=")) {
        return Err(LoginError::SessionUnavailable);
    }
    Ok(CloudSession { cookies })
}

#[cfg(test)]
mod tests {
    use super::*;

    type WireReply = Result<(u16, Vec<u8>), ConnectorError>;

    struct Replies {
        replies: std::sync::Mutex<std::collections::VecDeque<WireReply>>,
        sent: std::sync::atomic::AtomicUsize,
    }

    #[async_trait::async_trait]
    impl ConnectorTransport for Replies {
        async fn execute(
            &self,
            request: ConnectorRequest,
        ) -> Result<crate::ConnectorResponse, ConnectorError> {
            self.sent.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let (status, body) = self
                .replies
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected retry")?;
            Ok(crate::ConnectorResponse {
                status,
                body,
                final_url: request.url,
                headers: vec![("Check-Setting".into(), "0/32".into())],
            })
        }
    }

    fn replies(values: Vec<WireReply>) -> FudanCloudClient<Replies> {
        FudanCloudClient::new(Replies {
            replies: std::sync::Mutex::new(values.into()),
            sent: 0.into(),
        })
    }

    fn source() -> SourceContext {
        SourceContext {
            account_id: "synthetic".into(),
            source_id: "official.fudan.cloud".into(),
            observed_at: Utc::now(),
        }
    }

    #[tokio::test]
    async fn drive_write_uncertainty_preserves_rejections_and_never_retries() {
        for (response, expected) in [
            (Ok((500, vec![])), ConnectorError::NeedsReconciliation),
            (Ok((502, vec![])), ConnectorError::NeedsReconciliation),
            (Ok((507, vec![])), ConnectorError::NeedsReconciliation),
            (Ok((408, vec![])), ConnectorError::NeedsReconciliation),
            (Ok((302, vec![])), ConnectorError::NeedsReconciliation),
            (Ok((200, vec![0xff])), ConnectorError::NeedsReconciliation),
            (Ok((200, vec![])), ConnectorError::NeedsReconciliation),
            (
                Ok((200, b"<html><form>password login</form></html>".to_vec())),
                ConnectorError::NeedsReconciliation,
            ),
            (
                Ok((200, vec![8, 16])),
                ConnectorError::Rejected("PermissionDenied"),
            ),
            (Ok((403, vec![])), ConnectorError::PermissionDenied),
            (
                Err(ConnectorError::TransportUnavailable),
                ConnectorError::NeedsReconciliation,
            ),
            (
                Err(ConnectorError::Timeout),
                ConnectorError::NeedsReconciliation,
            ),
            (
                Err(ConnectorError::NeedsReconciliation),
                ConnectorError::NeedsReconciliation,
            ),
            (
                Err(ConnectorError::PermissionDenied),
                ConnectorError::PermissionDenied,
            ),
            (
                Err(ConnectorError::CapabilityUnavailable),
                ConnectorError::CapabilityUnavailable,
            ),
        ] {
            let client = replies(vec![response]);
            assert_eq!(
                client
                    .create_folder(&source(), "3/42/directory/", "new")
                    .await
                    .unwrap_err(),
                expected
            );
            assert_eq!(
                client
                    .transport
                    .sent
                    .load(std::sync::atomic::Ordering::SeqCst),
                1
            );
        }
        let client = replies(vec![]);
        assert!(matches!(
            client
                .create_folder(&source(), "3/42/directory/", "../bad")
                .await,
            Err(ConnectorError::InvalidConfiguration(_))
        ));
        assert_eq!(
            client
                .transport
                .sent
                .load(std::sync::atomic::Ordering::SeqCst),
            0
        );
    }

    #[tokio::test]
    async fn drive_write_reply_parsing_is_uncertain_only_after_the_write() {
        let file = msg(&[
            (1, Int(3)),
            (2, Text("a.txt")),
            (7, Text("3/42/directory/a.txt")),
            (25, Msg(msg(&[(1, Msg(msg(&[(1, Int(15)), (2, Int(2))])))]))),
        ]);
        let listing = msg(&[(4, Msg(msg(&[(5, Msg(msg(&[(1, Msg(file))])))])))]);
        let client = replies(vec![Ok((200, vec![]))]);
        assert_eq!(
            client
                .rename(&source(), "3/42/directory/a.txt", "b.txt")
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        let client = replies(vec![Ok((200, listing.clone())), Ok((200, vec![]))]);
        assert_eq!(
            client
                .delete(&source(), "3/42/directory/a.txt")
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        let client = replies(vec![
            Ok((200, vec![])),
            Ok((200, vec![])),
            Ok((200, vec![])),
        ]);
        assert_eq!(
            client
                .upload(
                    &source(),
                    "3/42/directory/",
                    "a.txt",
                    b"abc",
                    "text/plain",
                    1
                )
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        assert_eq!(
            client
                .transport
                .sent
                .load(std::sync::atomic::Ordering::SeqCst),
            3
        );
        let role = msg(&[(1, Msg(msg(&[(1, Int(9)), (2, Text("downloader"))])))]);
        let client = replies(vec![
            Ok((200, listing)),
            Ok((200, role)),
            Ok((200, vec![8, 1])),
        ]);
        assert_eq!(
            client
                .share(&source(), "3/42/directory/a.txt", 7, true)
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        let client = replies(vec![Ok((200, vec![]))]);
        assert_eq!(
            client
                .revoke_share(&source(), "synthetic-link")
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );

        // Malformed preparatory reads have not dispatched a file mutation.
        let client = replies(vec![Ok((200, vec![0xff]))]);
        assert!(matches!(
            client.delete(&source(), "3/42/directory/a.txt").await,
            Err(ConnectorError::Parse { .. })
        ));
        assert_eq!(
            client
                .transport
                .sent
                .load(std::sync::atomic::Ordering::SeqCst),
            1
        );
    }

    #[tokio::test]
    async fn drive_upload_lost_confirmation_after_blob_is_not_a_safe_rejection() {
        let client = replies(vec![
            Ok((200, vec![])),
            Ok((200, vec![])),
            Ok((200, vec![8, 21])),
            Ok((200, vec![8, 1])),
            Ok((403, vec![])),
        ]);
        let bytes = vec![b'x'; INLINE_MAX + 1];
        assert_eq!(
            client
                .upload(
                    &source(),
                    "3/42/directory/",
                    "large.bin",
                    &bytes,
                    "application/octet-stream",
                    1
                )
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        assert_eq!(
            client
                .transport
                .sent
                .load(std::sync::atomic::Ordering::SeqCst),
            5
        );
    }

    fn msg(parts: &[(u64, Part)]) -> Vec<u8> {
        let mut out = Vec::new();
        for (number, part) in parts {
            match part {
                Part::Int(v) => {
                    put_varint(&mut out, number << 3);
                    put_varint(&mut out, *v);
                }
                Part::Text(t) => put_text(&mut out, *number, t),
                Part::Msg(m) => {
                    put_varint(&mut out, number << 3 | 2);
                    put_varint(&mut out, m.len() as u64);
                    out.extend_from_slice(m);
                }
            }
        }
        out
    }
    enum Part {
        Int(u64),
        Text(&'static str),
        Msg(Vec<u8>),
    }
    use Part::*;

    fn control(download: u64) -> Vec<u8> {
        msg(&[
            (1, Msg(msg(&[(1, Int(1)), (2, Int(2))]))),
            (1, Msg(msg(&[(1, Int(6)), (2, Int(download))]))),
        ])
    }

    #[test]
    fn listing_decodes_folders_files_and_download_rights() {
        let folder = msg(&[
            (1, Int(2)),
            (2, Text("课件")),
            (5, Text("folder")),
            (7, Text("3/42/directory/课件")),
            (8, Int(1_731_000_000_000)),
            (9, Int(3)),
        ]);
        let file = msg(&[
            (1, Int(3)),
            (2, Text("讲义.pdf")),
            (4, Int(2048)),
            (5, Text("pdf")),
            (7, Text("3/42/directory/讲义.pdf")),
            (8, Int(1_731_000_000)),
            (10, Text("application/pdf")),
            (25, Msg(control(2))),
            (999, Text("unknown field is skipped")),
        ]);
        let locked = msg(&[
            (2, Text("只读.docx")),
            (7, Text("3/42/directory/只读.docx")),
            (25, Msg(control(3))),
        ]);
        let traversal = msg(&[(2, Text("x")), (7, Text("3/42/directory/../../etc"))]);
        let tree = msg(&[
            (1, Msg(file)),
            (1, Msg(folder)),
            (1, Msg(locked)),
            (1, Msg(traversal)),
        ]);
        let body = msg(&[(1, Int(1)), (4, Msg(msg(&[(5, Msg(tree))])))]);
        let listing = parse_listing("3/42/directory/", &body).unwrap();
        assert_eq!(listing.items.len(), 3);
        let folder = &listing.items[0];
        assert!(folder.is_folder && folder.name == "课件" && folder.children == Some(3));
        assert!(!folder.downloadable && folder.size.is_none());
        let pdf = listing.items.iter().find(|i| i.name == "讲义.pdf").unwrap();
        assert!(pdf.downloadable);
        assert_eq!(pdf.size, Some(2048));
        assert_eq!(pdf.content_type.as_deref(), Some("application/pdf"));
        // Seconds and milliseconds land on the same instant.
        assert_eq!(
            pdf.modified_at,
            folder.modified_at.map(|_| pdf.modified_at.unwrap())
        );
        assert_eq!(pdf.modified_at.unwrap().timestamp(), 1_731_000_000);
        let docx = listing
            .items
            .iter()
            .find(|i| i.name == "只读.docx")
            .unwrap();
        assert!(!docx.downloadable);
    }

    #[test]
    fn empty_folder_and_malformed_bodies() {
        let empty = msg(&[(1, Int(1)), (4, Msg(msg(&[(5, Msg(Vec::new()))])))]);
        assert!(
            parse_listing("3/1/directory/", &empty)
                .unwrap()
                .items
                .is_empty()
        );
        assert!(
            parse_listing("3/1/directory/", &[])
                .unwrap()
                .items
                .is_empty()
        );
        assert!(parse_listing("3/1/directory/", &msg(&[(1, Int(16))])).is_err());
        assert!(parse_listing("3/1/directory/", &[0x0a, 0xff]).is_err());
        assert!(parse_listing("3/1/directory/", &[0xff; 11]).is_err());
    }

    #[test]
    fn roots_come_from_the_user_and_group_lists() {
        let user = msg(&[(1, Int(3)), (2, Int(42)), (4, Text("学生"))]);
        assert_eq!(parse_user_root(&user).unwrap().path, "3/42/directory/");
        assert!(parse_user_root(&msg(&[(1, Int(1)), (2, Int(42))])).is_err());
        let orgs = msg(&[
            (
                1,
                Msg(msg(&[(1, Int(2)), (2, Int(7)), (4, Text("课题组"))])),
            ),
            (1, Msg(msg(&[(1, Int(1)), (2, Int(8)), (4, Text("部门"))]))),
        ]);
        let groups = parse_group_roots(&msg(&[(1, Msg(orgs))])).unwrap();
        assert_eq!(
            groups,
            vec![CloudRoot {
                kind: "group",
                name: "课题组".into(),
                path: "2/7/directory/".into()
            }]
        );
    }

    #[test]
    fn paths_are_validated_and_encoded_segment_by_segment() {
        for ok in [
            "3/42/directory/",
            "/3/42/directory",
            "default/2/7/directory/a b/c#?.pdf",
        ] {
            assert!(validate_path(ok).is_ok(), "{ok}");
        }
        for bad in [
            "",
            "3/42",
            "1/42/directory/",
            "3/x/directory/",
            "3/42/share$abc/",
            "3/42/directory/../x",
            "3/42/directory//x",
            "3/42/directory/a\\b",
            "3/42/directory/a\nb",
            "https://evil.test/3/42/directory/",
        ] {
            assert!(validate_path(bad).is_err(), "{bad}");
        }
        let url = download_url("3/42/directory/课件/a b#?.pdf").unwrap();
        assert_eq!(url.origin().ascii_serialization(), ORIGIN);
        assert!(url.path().starts_with("/download/3/42/directory/"));
        assert!(url.path().ends_with("/a%20b%23%3F.pdf"));
        assert_eq!(url.query_pairs().count(), 1);
        assert!(download_url("3/42/directory/").is_err());
        let list = endpoint("files", "3/42/directory/").unwrap();
        assert_eq!(list.path(), "/files/3/42/directory/");
    }

    #[test]
    fn login_body_and_csrf_token_match_the_web_client() {
        use base64::{Engine as _, engine::general_purpose::STANDARD};
        let body = login_body("24100000000", "a,./");
        let parsed = fields(&body).unwrap();
        let user = text_of(&parsed, 1).unwrap().unwrap();
        let pass = text_of(&parsed, 2).unwrap().unwrap();
        assert_eq!(
            user,
            format!("{{BASE64}}{}", STANDARD.encode("24100000000"))
        );
        assert_eq!(pass, format!("{{BASE64}}{}", STANDARD.encode("a,./")));
        assert_eq!(int_of(&parsed, 3), Some(0));
        let token = String::from_utf8(STANDARD.decode(csrf_token()).unwrap()).unwrap();
        let (plain, inner) = token.split_once('@').unwrap();
        assert!(plain.starts_with("token") && plain.len() == 7);
        assert_eq!(STANDARD.decode(inner).unwrap(), plain.as_bytes());
    }

    #[test]
    fn hashes_and_possession_checks_match_the_web_client() {
        // SHA-1("abc") with no salt is the standard test vector.
        assert_eq!(
            content_hash(b"abc", b""),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        assert_eq!(content_hash(b"ab", b"c"), content_hash(b"abc", b""));
        let data: Vec<u8> = (0..1000u32).map(|i| (i % 251) as u8).collect();
        // start 128/256 of 1000 = 500, 100 bytes.
        let (check, size) = possession_check(&data, b"s", "128/100").unwrap();
        assert_eq!(size, 100);
        assert_eq!(check, content_hash(&data[500..600], b"s"));
        // A window past the end is clamped like the web client does.
        let (check, size) = possession_check(&data, b"s", "250/100").unwrap();
        assert_eq!(size, 100);
        assert_eq!(check, content_hash(&data[976..999], b"s"));
        assert!(possession_check(&data, b"s", "bad").is_none());
    }

    #[test]
    fn write_bodies_carry_the_expected_fields() {
        let item = add_item("/资料/a.txt", "h", 3, "text/plain", 9, Some(b"abc"), None);
        let parsed = fields(&item).unwrap();
        assert_eq!(int_of(&parsed, 1), Some(OBJECT_BLOB));
        assert_eq!(int_of(&parsed, 2), Some(UPDATE_ADD));
        assert_eq!(text_of(&parsed, 3).unwrap().as_deref(), Some("/资料/a.txt"));
        assert_eq!(bytes_of(&parsed, 12), Some(&b"abc"[..]));
        assert!(bytes_of(&parsed, 6).is_none());
        let update = tree_update(Some("default/3/42/directory/资料"), &[item]);
        let parsed = fields(&update).unwrap();
        assert_eq!(
            text_of(&parsed, 1).unwrap().as_deref(),
            Some("default/3/42/directory/资料")
        );
        assert_eq!(text_of(&parsed, 2).unwrap().as_deref(), Some("default"));
        assert_eq!(all_bytes(&parsed, 3).count(), 1);
        assert_eq!(int_of(&parsed, 20), Some(ORIGIN_NORMAL));
        assert_eq!(text_of(&parsed, 25).unwrap(), text_of(&parsed, 26).unwrap());
        // Deletes carry no path; the owner is in the URL.
        assert!(
            text_of(&fields(&tree_update(None, &[])).unwrap(), 1)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn names_and_paths_for_writes() {
        assert_eq!(validate_name("  报告.pdf ").unwrap(), "报告.pdf");
        for bad in ["", " ", ".", "..", "a/b", "a\\b", "a\nb"] {
            assert!(validate_name(bad).is_err(), "{bad:?}");
        }
        let taken = vec!["a.txt".to_owned(), "A (1).txt".to_owned(), "dir".to_owned()];
        assert_eq!(unique_name("a.txt", &taken), "a (2).txt");
        assert_eq!(unique_name("dir", &taken), "dir (1)");
        assert_eq!(unique_name(".env", &taken), ".env");
        assert_eq!(
            child_path("3/42/directory/", "资料").unwrap(),
            "3/42/directory/资料"
        );
        assert_eq!(
            parent_path("3/42/directory/资料/a.txt").unwrap(),
            "3/42/directory/资料/"
        );
        assert_eq!(
            parent_path("default/3/42/directory/资料").unwrap(),
            "3/42/directory/"
        );
        assert!(parent_path("3/42/directory/").is_err());
        assert_eq!(
            split_path("default/3/42/directory/资料/a.txt").unwrap(),
            ("3".into(), "42".into(), "/资料/a.txt".into())
        );
        assert!(same_path("default/3/42/directory/a", "3/42/directory/a/"));
        assert!(!same_path("3/42/directory/a", "3/42/directory/b"));
    }

    #[test]
    fn share_replies_and_refusals() {
        let ok = msg(&[
            (1, Int(1)),
            (2, Msg(msg(&[(1, Int(1)), (2, Text("a.txt"))]))),
            (3, Text(r#"{"batchLink":"Ab_9-x","fetchCode":"k3x9"}"#)),
        ]);
        let share = parse_share(&ok).unwrap();
        assert_eq!(share.url, format!("{ORIGIN}/#routeview/s/Ab_9-x"));
        assert_eq!(share.fetch_code.as_deref(), Some("k3x9"));
        // What the server returns for an account without the share right.
        let denied = msg(&[
            (1, Int(1)),
            (2, Msg(msg(&[(1, Int(16)), (2, Text("a.txt"))]))),
        ]);
        assert!(matches!(
            parse_share(&denied),
            Err(ConnectorError::Rejected("PermissionDenied"))
        ));
        let unsafe_link = msg(&[(1, Int(1)), (3, Text(r#"{"batchLink":"../x"}"#))]);
        assert!(parse_share(&unsafe_link).is_err());
        assert!(valid_batch_link("Ab_9-x") && !valid_batch_link("a/b") && !valid_batch_link(""));
        let roles = msg(&[
            (1, Msg(msg(&[(1, Int(7)), (2, Text("reviewer"))]))),
            (1, Msg(msg(&[(1, Int(9)), (2, Text("downloader"))]))),
        ]);
        assert_eq!(
            int_of(&fields(&pick_role(&roles).unwrap()).unwrap(), 1),
            Some(9)
        );
        assert!(pick_role(&[]).is_err());
    }

    #[test]
    fn listing_exposes_folder_and_item_rights() {
        let rights = |pairs: &[(u64, u64)]| {
            let mut out = Vec::new();
            for (k, v) in pairs {
                put_bytes(&mut out, 1, &msg(&[(1, Int(*k)), (2, Int(*v))]));
            }
            out
        };
        let file = msg(&[
            (2, Text("a.txt")),
            (7, Text("3/42/directory/a.txt")),
            (25, Msg(rights(&[(6, 2), (9, 2), (10, 3)]))),
        ]);
        let tree = msg(&[(1, Msg(file))]);
        let body = msg(&[
            (4, Msg(msg(&[(5, Msg(tree))]))),
            (10, Msg(rights(&[(8, 3)]))),
        ]);
        let listing = parse_listing("3/42/directory/", &body).unwrap();
        assert!(!listing.can_create);
        let item = &listing.items[0];
        assert!(item.downloadable && item.can_rename && !item.can_delete && !item.can_share);
        assert_eq!(
            parse_salt(&msg(&[(11, Msg(msg(&[(70, Text("aBc"))])))])).unwrap(),
            b"aBc"
        );
    }

    #[cfg(feature = "login")]
    #[test]
    fn login_codes_map_to_fixed_errors() {
        use crate::login::LoginError;
        assert_eq!(login_error(15), LoginError::InvalidCredentials);
        assert_eq!(login_error(37), LoginError::InteractiveLoginRequired);
        assert_eq!(login_error(38), LoginError::InteractiveLoginRequired);
        assert_eq!(login_error(39), LoginError::AuthenticationRejected);
        assert_eq!(login_error(2), LoginError::AuthenticationRejected);
    }
}
