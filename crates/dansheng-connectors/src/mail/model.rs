use dansheng_core::{CoreError, CoreResult};
use lettre::message::Mailbox;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

pub const MAX_RAW_BYTES: usize = 1024 * 1024;
pub const MAX_BODY_BYTES: usize = 128 * 1024;
pub const MAX_WINDOW: u32 = 128;
pub const DEFAULT_WINDOW: u32 = 16;
pub const INDEX_PAGE: u32 = 512;
pub const MAX_FOLDERS: usize = 256;
pub const MAX_ATTACHMENT_RAW_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_ATTACHMENT_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_ATTACHMENT_CHUNK: usize = 256 * 1024;
pub const MAX_OUTGOING_ATTACHMENT_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_SMTP_BYTES: usize = 12 * 1024 * 1024;
pub const MAX_ATTACHMENTS: usize = 8;

#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TlsMode {
    #[default]
    Implicit,
    Starttls,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MailEndpoint {
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub tls: TlsMode,
}
impl MailEndpoint {
    pub fn validate(&self) -> CoreResult<()> {
        if self.port == 0
            || self.host.is_empty()
            || self.host.len() > 253
            || self
                .host
                .bytes()
                .any(|c| !c.is_ascii_alphanumeric() && !b".-:".contains(&c))
            || self.host.starts_with('.')
            || self.host.ends_with('.')
        {
            return Err(CoreError::invalid("invalid mail server endpoint"));
        }
        rustls::pki_types::ServerName::try_from(self.host.clone())
            .map_err(|_| CoreError::invalid("invalid TLS mail server name"))?;
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MailConfig {
    pub address: String,
    pub username: String,
    pub imap: MailEndpoint,
    pub smtp: MailEndpoint,
}
impl MailConfig {
    pub fn validate(&self) -> CoreResult<()> {
        self.imap.validate()?;
        self.smtp.validate()?;
        mailbox(&self.address)?;
        if self.username.is_empty()
            || self.username.len() > 320
            || self.username.chars().any(char::is_control)
        {
            return Err(CoreError::invalid("invalid mail login name"));
        }
        Ok(())
    }
}

// Deliberately no Debug implementation or public serialization endpoint.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MailCredentials {
    pub imap_password: String,
    pub smtp_password: String,
}
impl MailCredentials {
    pub fn validate(&self) -> CoreResult<()> {
        if [&self.imap_password, &self.smtp_password]
            .iter()
            .any(|v| v.is_empty() || v.len() > 4096 || v.contains(['\r', '\n', '\0']))
        {
            return Err(CoreError::invalid(
                "mail credentials are missing or invalid",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct MailboxFolder {
    /// Exact IMAP wire name. Preserve it when issuing later requests (including modified UTF-7).
    pub name: String,
    pub delimiter: Option<String>,
    pub selectable: bool,
    pub attributes: Vec<String>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct FolderState {
    pub uid_validity: u32,
    pub uid_next: u32,
    pub scanned_through: u32,
    pub flags_cursor: u32,
    #[serde(default)]
    pub index_pages: BTreeSet<u32>,
    pub last_sync_at: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct MailAddress {
    pub name: Option<String>,
    pub address: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AttachmentMetadata {
    pub part: String,
    pub name: Option<String>,
    pub content_type: String,
    pub decoded_size: usize,
    pub size_complete: bool,
    /// False for prefix-only, structurally damaged or malformed transfer encoding.
    #[serde(default)]
    pub content_complete: bool,
    pub content_id: Option<String>,
}

/// Outgoing MIME labels are explicit draft input, never a filesystem path.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DraftAttachment {
    pub asset_id: String,
    /// Optional asset account filter. Both accounts must be granted for cross-account mail.
    pub account_id: Option<String>,
    pub name: String,
    pub mime_type: String,
}
impl DraftAttachment {
    pub fn validate(&self) -> CoreResult<()> {
        if uuid::Uuid::parse_str(&self.asset_id)
            .ok()
            .is_none_or(|id| id.get_version_num() != 4 || id.to_string() != self.asset_id)
            || self.name.is_empty()
            || self.name.len() > 255
            || self.name == "."
            || self.name == ".."
            || self
                .name
                .chars()
                .any(|c| c.is_control() || c == '/' || c == '\\')
            || self.mime_type.len() > 128
            || self.mime_type.chars().any(char::is_control)
            || self
                .mime_type
                .parse::<lettre::message::header::ContentType>()
                .is_err()
        {
            return Err(CoreError::invalid(
                "invalid managed mail attachment or MIME labels",
            ));
        }
        if let Some(account) = &self.account_id {
            account_id(account)?;
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentBinding {
    pub asset_id: String,
    pub account_id: Option<String>,
    pub name: String,
    pub mime_type: String,
    pub size: usize,
    pub sha256: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct MailMessage {
    pub folder: String,
    pub uid_validity: u32,
    pub uid: u32,
    pub size: u32,
    pub flags: Vec<String>,
    pub message_id: Option<String>,
    pub subject: Option<String>,
    pub from: Vec<MailAddress>,
    pub to: Vec<MailAddress>,
    pub cc: Vec<MailAddress>,
    pub date: Option<String>,
    pub text: Option<String>,
    /// Untrusted email HTML, never a UI execution surface. Render with sanitization and remote images disabled.
    pub html: Option<String>,
    pub attachments: Vec<AttachmentMetadata>,
    pub mime_complete: bool,
    pub body_truncated: bool,
    #[serde(default)]
    pub deleted_remotely: bool,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DraftInput {
    #[serde(default)]
    pub to: Vec<String>,
    #[serde(default)]
    pub cc: Vec<String>,
    #[serde(default)]
    pub bcc: Vec<String>,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub html: Option<String>,
    #[serde(default)]
    pub attachments: Vec<DraftAttachment>,
}
impl DraftInput {
    pub fn validate(&self) -> CoreResult<()> {
        if self.to.len() + self.cc.len() + self.bcc.len() > 100
            || self.attachments.len() > MAX_ATTACHMENTS
            || self.subject.len() > 4096
            || self.subject.contains(['\r', '\n', '\0'])
            || self.text.len() + self.html.as_ref().map_or(0, String::len) > 384 * 1024
        {
            return Err(CoreError::invalid(
                "draft exceeds mail limits or contains invalid header characters",
            ));
        }
        for address in self.to.iter().chain(&self.cc).chain(&self.bcc) {
            mailbox(address)?;
        }
        for attachment in &self.attachments {
            attachment.validate()?;
        }
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Draft {
    pub id: String,
    pub message_id: String,
    pub created_at: String,
    pub updated_at: String,
    pub content: DraftInput,
    /// Last explicitly generated preview, containing no attachment bytes or paths.
    #[serde(default)]
    pub attachment_bindings: Vec<AttachmentBinding>,
}

pub(super) fn mailbox(address: &str) -> CoreResult<Mailbox> {
    if address.is_empty() || address.len() > 512 || address.chars().any(char::is_control) {
        return Err(CoreError::invalid("invalid mail address"));
    }
    address
        .parse::<Mailbox>()
        .map_err(|_| CoreError::invalid("invalid mail address"))
}
pub(super) fn account_id(value: &str) -> CoreResult<&str> {
    if value.is_empty()
        || value.len() > 80
        || !value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
    {
        return Err(CoreError::invalid("invalid mail account id"));
    }
    Ok(value)
}
pub(super) fn folder_name(value: &str) -> CoreResult<&str> {
    if value.is_empty() || value.len() > 1024 || value.chars().any(char::is_control) {
        return Err(CoreError::invalid("invalid mailbox folder"));
    }
    Ok(value)
}
