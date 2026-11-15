// SPDX-License-Identifier: GPL-3.0-or-later
//! A generic WebDAV drive (Nextcloud, ownCloud, 坚果云, Synology over HTTPS…).
//!
//! The server is configured by its HTTPS base URL; credentials are HTTP Basic
//! and live only in the host's network session for that exact origin. Paths
//! are `/`-separated and relative to the base URL; every segment is validated
//! and percent-encoded on the way out, and every `href` coming back must stay
//! under the base path.

use chrono::{DateTime, Utc};
use serde::Serialize;
use url::Url;

use crate::models::SourceContext;
use crate::transport::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod,
    TransportAuth, check_write_response, parse_error,
};

const SOURCE: &str = "WebDAV";
const MAX_LISTING_BYTES: usize = 8 * 1024 * 1024;
const MAX_ITEMS: usize = 10_000;
const MAX_NAME: usize = 255;
const MAX_PATH: usize = 4096;
/// The host's binary request limit.
pub const MAX_UPLOAD: usize = 8 * 1024 * 1024;

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>"#;

/// A configured server's base URL: HTTPS, no credentials, query or fragment,
/// always ending in `/`.
pub fn validate_base(raw: &str) -> Result<Url, ConnectorError> {
    let invalid = ConnectorError::InvalidConfiguration("WebDAV address");
    let mut url = Url::parse(raw.trim()).map_err(|_| invalid.clone())?;
    if url.scheme() != "https"
        || url.host_str().is_none_or(str::is_empty)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.as_str().len() > 1024
    {
        return Err(invalid);
    }
    if !url.path().ends_with('/') {
        let path = format!("{}/", url.path());
        url.set_path(&path);
    }
    Ok(url)
}

/// A path relative to the base: `/`, `/a`, `/a/b.txt`. Returns its segments.
pub fn validate_path(path: &str) -> Result<Vec<String>, ConnectorError> {
    let invalid = ConnectorError::InvalidConfiguration("WebDAV path");
    if path.len() > MAX_PATH || path.contains('\\') || !path.starts_with('/') {
        return Err(invalid);
    }
    let segments: Vec<String> = path
        .trim_matches('/')
        .split('/')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    if path.trim_matches('/').split('/').any(str::is_empty) && !path.trim_matches('/').is_empty() {
        return Err(invalid);
    }
    if segments
        .iter()
        .any(|s| s == "." || s == ".." || s.chars().any(char::is_control))
    {
        return Err(invalid);
    }
    Ok(segments)
}

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
        return Err(ConnectorError::InvalidConfiguration("WebDAV file name"));
    }
    Ok(name.to_owned())
}

pub fn join(path: &str, name: &str) -> Result<String, ConnectorError> {
    let mut segments = validate_path(path)?;
    segments.push(validate_name(name)?);
    Ok(format!("/{}", segments.join("/")))
}

pub fn parent(path: &str) -> Result<String, ConnectorError> {
    let mut segments = validate_path(path)?;
    if segments.pop().is_none() {
        return Err(ConnectorError::InvalidConfiguration("WebDAV root"));
    }
    Ok(format!("/{}", segments.join("/")))
}

/// The absolute URL of `path` under `base`; collections end in `/`.
pub fn resource_url(base: &Url, path: &str, collection: bool) -> Result<Url, ConnectorError> {
    let segments = validate_path(path)?;
    let mut url = base.clone();
    {
        let mut parts = url
            .path_segments_mut()
            .map_err(|_| ConnectorError::UnsafeUrl)?;
        parts.pop_if_empty();
        parts.extend(segments.iter().map(String::as_str));
        if collection || segments.is_empty() {
            parts.push("");
        }
    }
    Ok(url)
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct DavItem {
    pub name: String,
    pub path: String,
    pub is_folder: bool,
    pub size: Option<u64>,
    pub modified_at: Option<DateTime<Utc>>,
    pub content_type: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct DavListing {
    pub path: String,
    pub items: Vec<DavItem>,
}

// --- Minimal XML reading -----------------------------------------------------------

#[derive(Debug, PartialEq)]
enum Token {
    Open(String, bool),
    Close(String),
    Text(String),
}

fn local(name: &str) -> String {
    name.rsplit(':').next().unwrap_or(name).to_ascii_lowercase()
}

fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        let Some(end) = rest.find(';').filter(|e| *e <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| entity.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => out.push(c),
            None => out.push_str(&rest[..=end]),
        }
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    out
}

/// Tags by local name (namespace prefixes vary between servers) and text.
/// Declarations, comments and processing instructions are skipped.
fn tokens(xml: &str) -> Result<Vec<Token>, ConnectorError> {
    let mut out = Vec::new();
    let mut rest = xml;
    while !rest.is_empty() {
        if out.len() > MAX_ITEMS * 40 {
            return Err(ConnectorError::LimitExceeded);
        }
        let Some(lt) = rest.find('<') else {
            if !rest.trim().is_empty() {
                out.push(Token::Text(unescape(rest)));
            }
            break;
        };
        if lt > 0 {
            let text = &rest[..lt];
            if !text.trim().is_empty() {
                out.push(Token::Text(unescape(text)));
            }
        }
        rest = &rest[lt..];
        if let Some(body) = rest.strip_prefix("<![CDATA[") {
            let end = body.find("]]>").ok_or(parse_error(SOURCE, "cdata"))?;
            out.push(Token::Text(body[..end].to_owned()));
            rest = &body[end + 3..];
            continue;
        }
        if rest.starts_with("<!--") {
            let end = rest.find("-->").ok_or(parse_error(SOURCE, "comment"))?;
            rest = &rest[end + 3..];
            continue;
        }
        let gt = rest.find('>').ok_or(parse_error(SOURCE, "tag"))?;
        let tag = &rest[1..gt];
        rest = &rest[gt + 1..];
        if tag.starts_with('?') || tag.starts_with('!') {
            continue;
        }
        if let Some(name) = tag.strip_prefix('/') {
            out.push(Token::Close(local(name.trim())));
            continue;
        }
        let self_closing = tag.ends_with('/');
        let name = tag
            .trim_end_matches('/')
            .split(|c: char| c.is_whitespace())
            .next()
            .unwrap_or("");
        out.push(Token::Open(local(name), self_closing));
    }
    Ok(out)
}

/// Decodes an `href` (absolute URL or absolute path) to a path relative to
/// `base`; `None` when it points outside the base.
fn relative_path(base: &Url, href: &str) -> Option<String> {
    let url = base.join(href.trim()).ok()?;
    if url.origin() != base.origin() {
        return None;
    }
    let decode = |p: &str| {
        percent_encoding::percent_decode_str(p)
            .decode_utf8()
            .ok()
            .map(|s| s.into_owned())
    };
    let full = decode(url.path())?;
    let base_path = decode(base.path())?;
    let tail = full.strip_prefix(base_path.trim_end_matches('/'))?;
    let tail = if tail.is_empty() { "/" } else { tail };
    if !tail.starts_with('/') {
        return None;
    }
    let normalized = format!("/{}", tail.trim_matches('/'));
    validate_path(&normalized).ok()?;
    Some(normalized)
}

/// A `207 Multi-Status` PROPFIND body for `folder` (Depth: 1).
pub fn parse_multistatus(
    base: &Url,
    folder: &str,
    body: &[u8],
) -> Result<DavListing, ConnectorError> {
    let xml = std::str::from_utf8(body).map_err(|_| parse_error(SOURCE, "encoding"))?;
    let folder_norm = format!("/{}", validate_path(folder)?.join("/"));
    let mut items = Vec::new();
    let mut stack: Vec<String> = Vec::new();
    #[derive(Default)]
    struct Entry {
        href: Option<String>,
        collection: bool,
        size: Option<u64>,
        modified: Option<String>,
        content_type: Option<String>,
        ok: bool,
        status_seen: bool,
    }
    let mut entry: Option<Entry> = None;
    let mut saw_multistatus = false;
    for token in tokens(xml)? {
        match token {
            Token::Open(name, self_closing) => {
                if name == "multistatus" {
                    saw_multistatus = true;
                }
                if name == "response" {
                    entry = Some(Entry::default());
                }
                if name == "collection"
                    && stack.iter().any(|t| t == "resourcetype")
                    && let Some(e) = entry.as_mut()
                {
                    e.collection = true;
                }
                if !self_closing {
                    stack.push(name);
                }
            }
            Token::Close(name) => {
                if let Some(pos) = stack.iter().rposition(|t| *t == name) {
                    stack.truncate(pos);
                }
                if name == "response" {
                    let Some(e) = entry.take() else { continue };
                    if e.status_seen && !e.ok {
                        continue;
                    }
                    let Some(path) = e.href.as_deref().and_then(|h| relative_path(base, h)) else {
                        continue;
                    };
                    if path == folder_norm {
                        continue;
                    }
                    if parent(&path).ok().as_deref() != Some(folder_norm.as_str()) {
                        continue;
                    }
                    if items.len() >= MAX_ITEMS {
                        return Err(ConnectorError::LimitExceeded);
                    }
                    let name = path.rsplit('/').next().unwrap_or("").to_owned();
                    items.push(DavItem {
                        name,
                        path,
                        is_folder: e.collection,
                        size: if e.collection { None } else { e.size },
                        modified_at: e
                            .modified
                            .and_then(|m| DateTime::parse_from_rfc2822(m.trim()).ok())
                            .map(|d| d.with_timezone(&Utc)),
                        content_type: e
                            .content_type
                            .filter(|t| !t.is_empty() && t.len() <= 255 && !e.collection),
                    });
                }
            }
            Token::Text(text) => {
                let Some(e) = entry.as_mut() else { continue };
                match stack.last().map(String::as_str) {
                    Some("href") if !stack.iter().any(|t| t == "propstat") => {
                        e.href = Some(text.trim().to_owned());
                    }
                    Some("getcontentlength") => e.size = text.trim().parse().ok(),
                    Some("getlastmodified") => e.modified = Some(text),
                    Some("getcontenttype") => e.content_type = Some(text.trim().to_owned()),
                    // A propstat's status describes those properties; a
                    // response-level status (no propstat) describes the entry.
                    Some("status") if !stack.iter().any(|t| t == "propstat") => {
                        e.status_seen = true;
                        e.ok = text.contains(" 2");
                    }
                    _ => {}
                }
            }
        }
    }
    if !saw_multistatus {
        return Err(parse_error(SOURCE, "multistatus"));
    }
    items.sort_by(|a, b| {
        b.is_folder
            .cmp(&a.is_folder)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(DavListing {
        path: folder_norm,
        items,
    })
}

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
        .find(|c| !lower.contains(&c.to_lowercase()))
        .expect("an unused name exists")
}

// --- Client -----------------------------------------------------------------------

pub struct WebDavClient<T> {
    transport: T,
    base: Url,
}

impl<T: ConnectorTransport> WebDavClient<T> {
    pub fn new(transport: T, base: Url) -> Self {
        Self { transport, base }
    }

    async fn send(
        &self,
        source: &SourceContext,
        method: HttpMethod,
        url: Url,
        headers: Vec<(String, String)>,
        body: Option<Vec<u8>>,
        expect: &[u16],
    ) -> Result<Vec<u8>, ConnectorError> {
        source.validate()?;
        let challenge = AuthChallenge {
            connector: "webdav".into(),
            origin: self.base.origin().ascii_serialization(),
            account_id: source.account_id.clone(),
            mode: AuthMode::Token,
        };
        let response = self
            .transport
            .execute(ConnectorRequest {
                method,
                url: url.clone(),
                headers,
                body: body.or_else(|| (method != HttpMethod::Get).then(Vec::new)),
                auth: TransportAuth::HostToken {
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
        match response.status {
            401 => Err(ConnectorError::AuthRequired(challenge)),
            403 => Err(ConnectorError::Rejected("PermissionDenied")),
            404 | 410 => Err(ConnectorError::Rejected("FileUnavailable")),
            405 | 409 | 412 => Err(ConnectorError::Rejected("NameConflict")),
            413 | 507 => Err(ConnectorError::Rejected("QuotaExceeded")),
            status if expect.contains(&status) => {
                if response.body.len() > MAX_LISTING_BYTES {
                    return Err(ConnectorError::LimitExceeded);
                }
                Ok(response.body)
            }
            status if method.is_mutating() && !(400..500).contains(&status) => {
                Err(ConnectorError::NeedsReconciliation)
            }
            status => Err(ConnectorError::HttpStatus(status)),
        }
    }

    pub async fn list(
        &self,
        source: &SourceContext,
        folder: &str,
    ) -> Result<DavListing, ConnectorError> {
        let url = resource_url(&self.base, folder, true)?;
        let body = self
            .send(
                source,
                HttpMethod::Propfind,
                url,
                vec![
                    ("Depth".into(), "1".into()),
                    (
                        "Content-Type".into(),
                        "application/xml; charset=utf-8".into(),
                    ),
                ],
                Some(PROPFIND_BODY.as_bytes().to_vec()),
                &[207],
            )
            .await?;
        parse_multistatus(&self.base, folder, &body)
    }

    /// Verifies the stored credentials against the base collection.
    pub async fn verify(&self, source: &SourceContext) -> Result<(), ConnectorError> {
        self.send(
            source,
            HttpMethod::Propfind,
            self.base.clone(),
            vec![
                ("Depth".into(), "0".into()),
                (
                    "Content-Type".into(),
                    "application/xml; charset=utf-8".into(),
                ),
            ],
            Some(PROPFIND_BODY.as_bytes().to_vec()),
            &[207],
        )
        .await
        .map(|_| ())
    }

    pub async fn create_folder(
        &self,
        source: &SourceContext,
        parent: &str,
        name: &str,
    ) -> Result<String, ConnectorError> {
        let path = join(parent, name)?;
        let url = resource_url(&self.base, &path, true)?;
        self.send(source, HttpMethod::Mkcol, url, Vec::new(), None, &[201])
            .await?;
        Ok(path)
    }

    pub async fn delete(
        &self,
        source: &SourceContext,
        path: &str,
        folder: bool,
    ) -> Result<(), ConnectorError> {
        if validate_path(path)?.is_empty() {
            return Err(ConnectorError::InvalidConfiguration("WebDAV root"));
        }
        let url = resource_url(&self.base, path, folder)?;
        self.send(
            source,
            HttpMethod::Delete,
            url,
            Vec::new(),
            None,
            &[200, 204],
        )
        .await
        .map(|_| ())
    }

    /// Renames in place; never overwrites an existing entry.
    pub async fn rename(
        &self,
        source: &SourceContext,
        path: &str,
        new_name: &str,
        folder: bool,
    ) -> Result<String, ConnectorError> {
        let target = join(&parent(path)?, new_name)?;
        let from = resource_url(&self.base, path, folder)?;
        let to = resource_url(&self.base, &target, folder)?;
        self.send(
            source,
            HttpMethod::Move,
            from,
            vec![
                ("Destination".into(), to.to_string()),
                ("Overwrite".into(), "F".into()),
            ],
            None,
            &[201, 204],
        )
        .await?;
        Ok(target)
    }

    /// Uploads `data` as `name` into `folder`, renaming on a clash.
    pub async fn upload(
        &self,
        source: &SourceContext,
        folder: &str,
        name: &str,
        data: &[u8],
        content_type: &str,
    ) -> Result<String, ConnectorError> {
        if data.len() > MAX_UPLOAD {
            return Err(ConnectorError::Rejected("AssetTooLarge"));
        }
        let name = validate_name(name)?;
        let taken: Vec<String> = self
            .list(source, folder)
            .await?
            .items
            .into_iter()
            .map(|i| i.name)
            .collect();
        let path = join(folder, &unique_name(&name, &taken))?;
        let url = resource_url(&self.base, &path, false)?;
        self.send(
            source,
            HttpMethod::Put,
            url,
            vec![
                (
                    "Content-Type".into(),
                    if content_type.is_empty() {
                        "application/octet-stream".into()
                    } else {
                        content_type.into()
                    },
                ),
                ("If-None-Match".into(), "*".into()),
            ],
            Some(data.to_vec()),
            &[200, 201, 204],
        )
        .await?;
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Url {
        validate_base("https://dav.example/remote.php/dav/files/me").unwrap()
    }

    #[test]
    fn base_and_paths_are_validated() {
        assert_eq!(
            base().as_str(),
            "https://dav.example/remote.php/dav/files/me/"
        );
        for bad in [
            "http://dav.example/",
            "https://u:p@dav.example/",
            "https://dav.example/?x=1",
            "ftp://dav.example/",
        ] {
            assert!(validate_base(bad).is_err(), "{bad}");
        }
        for ok in ["/", "/a", "/a/b c.txt", "/中文/文件.pdf"] {
            assert!(validate_path(ok).is_ok(), "{ok}");
        }
        for bad in ["", "a", "/a/../b", "/a//b", "/a\\b", "/a\nb", "/."] {
            assert!(validate_path(bad).is_err(), "{bad}");
        }
        let url = resource_url(&base(), "/资料/a b#?.pdf", false).unwrap();
        assert_eq!(url.origin(), base().origin());
        assert!(url.path().starts_with("/remote.php/dav/files/me/"));
        assert!(url.path().ends_with("/a%20b%23%3F.pdf"));
        assert!(
            resource_url(&base(), "/资料", true)
                .unwrap()
                .path()
                .ends_with('/')
        );
        assert_eq!(join("/a", "b.txt").unwrap(), "/a/b.txt");
        assert_eq!(parent("/a/b.txt").unwrap(), "/a");
        assert_eq!(parent("/a").unwrap(), "/");
        assert!(parent("/").is_err());
    }

    #[test]
    fn multistatus_lists_children_and_skips_self_and_outsiders() {
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response><d:href>/remote.php/dav/files/me/%E8%B5%84%E6%96%99/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/me/%E8%B5%84%E6%96%99/%E8%AF%BE%E4%BB%B6/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Tue, 10 Nov 2026 08:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <D:response xmlns:D="DAV:"><D:href>https://dav.example/remote.php/dav/files/me/%E8%B5%84%E6%96%99/a%20b.pdf</D:href>
  <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>2048</D:getcontentlength><D:getcontenttype>application/pdf</D:getcontenttype>
  <D:getlastmodified>Tue, 10 Nov 2026 08:00:00 GMT</D:getlastmodified><D:displayname>x &amp; y</D:displayname></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  <D:propstat><D:prop><oc:size/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
 <d:response><d:href>/remote.php/dav/files/other/secret.txt</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response>
 <d:response><d:href>https://evil.test/remote.php/dav/files/me/%E8%B5%84%E6%96%99/x</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response>
 <d:response><d:href>/remote.php/dav/files/me/%E8%B5%84%E6%96%99/gone.txt</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
 <!-- comment --><d:response><d:href><![CDATA[/remote.php/dav/files/me/%E8%B5%84%E6%96%99/c.txt]]></d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>"#;
        let listing = parse_multistatus(&base(), "/资料", xml.as_bytes()).unwrap();
        let names: Vec<_> = listing.items.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(names, ["课件", "a b.pdf", "c.txt"]);
        assert!(listing.items[0].is_folder && listing.items[0].size.is_none());
        let pdf = &listing.items[1];
        assert_eq!(pdf.path, "/资料/a b.pdf");
        assert_eq!(pdf.size, Some(2048));
        assert_eq!(pdf.content_type.as_deref(), Some("application/pdf"));
        assert_eq!(pdf.modified_at.unwrap().timestamp(), 1_794_297_600);
        assert!(parse_multistatus(&base(), "/", b"<html>login</html>").is_err());
    }

    use crate::transport::ConnectorResponse;
    use std::sync::Mutex;

    struct Mock {
        seen: Mutex<Vec<ConnectorRequest>>,
        replies: Mutex<Vec<(u16, &'static str)>>,
    }

    #[async_trait::async_trait]
    impl ConnectorTransport for Mock {
        async fn execute(
            &self,
            request: ConnectorRequest,
        ) -> Result<ConnectorResponse, ConnectorError> {
            let url = request.url.clone();
            self.seen.lock().unwrap().push(request);
            let (status, body) = self.replies.lock().unwrap().remove(0);
            Ok(ConnectorResponse {
                status,
                final_url: url,
                headers: Vec::new(),
                body: body.as_bytes().to_vec(),
            })
        }
    }

    fn mock(replies: Vec<(u16, &'static str)>) -> WebDavClient<Mock> {
        WebDavClient::new(
            Mock {
                seen: Mutex::new(Vec::new()),
                replies: Mutex::new(replies),
            },
            base(),
        )
    }

    fn source() -> SourceContext {
        SourceContext {
            account_id: "a".into(),
            source_id: "official.webdav.test".into(),
            observed_at: Utc::now(),
        }
    }

    const EMPTY: &str = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/remote.php/dav/files/me/</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/remote.php/dav/files/me/a.txt</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#;

    #[tokio::test]
    async fn requests_use_the_right_methods_headers_and_conflict_rules() {
        let client = mock(vec![
            (207, EMPTY),
            (201, ""),
            (201, ""),
            (204, ""),
            (401, ""),
        ]);
        let saved = client
            .upload(&source(), "/", "a.txt", b"x", "text/plain")
            .await
            .unwrap();
        assert_eq!(saved, "/a (1).txt");
        client
            .rename(&source(), "/a (1).txt", "b.txt", false)
            .await
            .unwrap();
        client.delete(&source(), "/b.txt", false).await.unwrap();
        assert!(matches!(
            client.list(&source(), "/").await,
            Err(ConnectorError::AuthRequired(_))
        ));
        // The root itself can never be deleted.
        assert!(client.delete(&source(), "/", true).await.is_err());
        let seen = client.transport.seen.lock().unwrap();
        assert_eq!(seen[0].method, HttpMethod::Propfind);
        assert!(seen[0].headers.contains(&("Depth".into(), "1".into())));
        assert!(
            seen[0]
                .body
                .as_ref()
                .is_some_and(|b| b.starts_with(b"<?xml"))
        );
        assert_eq!(seen[1].method, HttpMethod::Put);
        assert!(seen[1].url.path().ends_with("/a%20(1).txt"));
        assert!(
            seen[1]
                .headers
                .contains(&("If-None-Match".into(), "*".into()))
        );
        assert_eq!(seen[2].method, HttpMethod::Move);
        let destination = &seen[2]
            .headers
            .iter()
            .find(|(k, _)| k == "Destination")
            .unwrap()
            .1;
        assert!(destination.starts_with("https://dav.example/remote.php/dav/files/me/b.txt"));
        assert!(seen[2].headers.contains(&("Overwrite".into(), "F".into())));
        assert_eq!(seen[3].method, HttpMethod::Delete);
        assert!(
            seen.iter()
                .all(|r| matches!(r.auth, TransportAuth::HostToken { .. }))
        );
    }

    #[tokio::test]
    async fn server_refusals_map_to_fixed_codes() {
        let client = mock(vec![(405, ""), (507, "")]);
        assert!(matches!(
            client.create_folder(&source(), "/", "x").await,
            Err(ConnectorError::Rejected("NameConflict"))
        ));
        assert!(matches!(
            client.create_folder(&source(), "/", "y").await,
            Err(ConnectorError::NeedsReconciliation)
        ));
    }

    #[tokio::test]
    async fn drive_write_responses_fail_uncertain_without_replaying() {
        for status in [302, 408, 500, 502, 507, 207] {
            let client = mock(vec![(status, "")]);
            assert_eq!(
                client
                    .create_folder(&source(), "/", "new")
                    .await
                    .unwrap_err(),
                ConnectorError::NeedsReconciliation
            );
            assert_eq!(client.transport.seen.lock().unwrap().len(), 1);
        }
        let client = mock(vec![(207, EMPTY), (503, "")]);
        assert_eq!(
            client
                .upload(&source(), "/", "a.txt", b"abc", "text/plain")
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        assert_eq!(client.transport.seen.lock().unwrap().len(), 2);
        let client = mock(vec![(500, "")]);
        assert_eq!(
            client
                .rename(&source(), "/a", "b", false)
                .await
                .unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        let client = mock(vec![(500, "")]);
        assert_eq!(
            client.delete(&source(), "/a", false).await.unwrap_err(),
            ConnectorError::NeedsReconciliation
        );
        // A malformed listing before upload dispatched no PUT.
        let client = mock(vec![(207, "<html>bad listing</html>")]);
        assert!(matches!(
            client.upload(&source(), "/", "a", b"a", "text/plain").await,
            Err(ConnectorError::Parse { .. })
        ));
        assert_eq!(client.transport.seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn unescape_and_unique_names() {
        assert_eq!(
            unescape("a&amp;b &lt;&#x4E2D;&#25991;&gt; &bogus; &"),
            "a&b <中文> &bogus; &"
        );
        let taken = vec!["a.txt".to_owned(), "a (1).txt".to_owned()];
        assert_eq!(unique_name("A.TXT", &taken), "A (2).TXT");
        assert_eq!(unique_name("new.txt", &taken), "new.txt");
    }
}
