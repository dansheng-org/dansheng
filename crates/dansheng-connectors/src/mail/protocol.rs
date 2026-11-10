//! Actual IMAP/SMTP protocol implementation. There is no plaintext production mode.
use super::model::*;
use async_trait::async_trait;
use dansheng_core::{CoreError, CoreResult};
use lettre::{
    address::Envelope,
    transport::smtp::{
        authentication::{Credentials, Mechanism},
        client::{AsyncSmtpConnection, Certificate, TlsParameters},
        extension::ClientId,
    },
};
use std::{
    collections::BTreeMap,
    fmt, io,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
    net::TcpStream,
};

pub(super) const TIMEOUT: Duration = Duration::from_secs(30);
const CONNECTION_BYTES: usize = 32 * 1024 * 1024;
pub(super) struct RawMail {
    pub uid: u32,
    pub size: u32,
    pub flags: Vec<String>,
    pub raw: Vec<u8>,
}
pub(super) struct FlagScan {
    pub start: u32,
    pub end: u32,
    pub flags: BTreeMap<u32, Vec<String>>,
}
pub(super) struct SyncBatch {
    pub validity: u32,
    pub next: u32,
    pub through: u32,
    pub flags_cursor: u32,
    pub messages: Vec<RawMail>,
    pub refreshed: Option<FlagScan>,
}
pub(super) struct SendReceipt {
    pub code: String,
}
pub(super) struct SendFailure {
    pub uncertain: bool,
    pub code: &'static str,
}
impl SendFailure {
    fn before() -> Self {
        Self {
            uncertain: false,
            code: "MailTransportError",
        }
    }
}

#[async_trait]
pub(super) trait MailBackend: Send + Sync {
    async fn folders(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
    ) -> CoreResult<Vec<MailboxFolder>>;
    async fn sync(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        folder: &str,
        state: &FolderState,
        window: u32,
    ) -> CoreResult<SyncBatch>;
    async fn flags(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        folder: &str,
        validity: u32,
        uid: u32,
        changes: Option<&BTreeMap<String, bool>>,
    ) -> CoreResult<Vec<String>>;
    async fn attachment_message(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        folder: &str,
        validity: u32,
        uid: u32,
    ) -> CoreResult<RawMail>;
    async fn send(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        envelope: &Envelope,
        bytes: &[u8],
    ) -> Result<SendReceipt, SendFailure>;
}

#[derive(Default)]
pub(super) struct NativeBackend {
    extra_roots: Vec<Vec<u8>>,
}
impl NativeBackend {
    #[cfg(test)]
    pub fn with_test_root(der: Vec<u8>) -> Self {
        Self {
            extra_roots: vec![der],
        }
    }
    fn tls(&self) -> CoreResult<Arc<rustls::ClientConfig>> {
        let mut roots =
            rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        for der in &self.extra_roots {
            roots
                .add(rustls::pki_types::CertificateDer::from(der.clone()))
                .map_err(|_| protocol_error())?;
        }
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|_| protocol_error())?
        .with_root_certificates(roots)
        .with_no_client_auth();
        Ok(Arc::new(tls))
    }
    async fn imap(&self, config: &MailConfig, credentials: &MailCredentials) -> CoreResult<Imap> {
        tokio::time::timeout(TIMEOUT, async {
            let tcp = TcpStream::connect((config.imap.host.as_str(), config.imap.port))
                .await
                .map_err(|_| transport_error())?;
            let tls = tokio_rustls::TlsConnector::from(self.tls()?);
            let name = rustls::pki_types::ServerName::try_from(config.imap.host.clone())
                .map_err(|_| protocol_error())?;
            let mut client = if config.imap.tls == TlsMode::Implicit {
                let stream = tls
                    .connect(name.clone(), tcp)
                    .await
                    .map_err(|_| tls_error())?;
                async_imap::Client::new(BoundedIo::new(Box::new(stream) as Box<dyn MailIo>))
            } else {
                async_imap::Client::new(BoundedIo::new(Box::new(tcp) as Box<dyn MailIo>))
            };
            if client
                .read_response()
                .await
                .map_err(|_| protocol_error())?
                .is_none()
            {
                return Err(protocol_error());
            }
            if config.imap.tls == TlsMode::Starttls {
                client
                    .run_command_and_check_ok("STARTTLS", None)
                    .await
                    .map_err(|_| tls_error())?;
                let stream = tls
                    .connect(name, client.into_inner().inner)
                    .await
                    .map_err(|_| tls_error())?;
                client =
                    async_imap::Client::new(BoundedIo::new(Box::new(stream) as Box<dyn MailIo>));
            }
            client
                .login(&config.username, &credentials.imap_password)
                .await
                .map_err(|_| CoreError::new("AuthenticationRequired", "IMAP authentication failed"))
        })
        .await
        .map_err(|_| CoreError::new("MailTimeout", "IMAP connection/authentication timed out"))?
    }
    fn smtp_tls(&self, host: &str) -> Result<TlsParameters, SendFailure> {
        let mut builder = TlsParameters::builder(host.to_owned());
        for der in &self.extra_roots {
            builder = builder.add_root_certificate(
                Certificate::from_der(der.clone()).map_err(|_| SendFailure::before())?,
            );
        }
        builder.build_rustls().map_err(|_| SendFailure::before())
    }
}

trait MailIo: AsyncRead + AsyncWrite + Unpin + Send + fmt::Debug {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send + fmt::Debug> MailIo for T {}
type Imap = async_imap::Session<BoundedIo<Box<dyn MailIo>>>;
async fn close_imap(session: &mut Imap) {
    let _ = tokio::time::timeout(Duration::from_secs(2), async {
        let _ = session.logout().await;
        session.as_mut().shutdown().await
    })
    .await;
}
struct BoundedIo<T> {
    inner: T,
    remaining: usize,
    guard: IncomingGuard,
}
impl<T> BoundedIo<T> {
    fn new(inner: T) -> Self {
        Self {
            inner,
            remaining: CONNECTION_BYTES,
            guard: IncomingGuard::default(),
        }
    }
}
impl<T> fmt::Debug for BoundedIo<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("BoundedMailConnection")
    }
}
impl<T: AsyncRead + Unpin> AsyncRead for BoundedIo<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        out: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if out.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        if self.remaining == 0 {
            return Poll::Ready(Err(io::Error::other("mail response budget exceeded")));
        }
        let mut scratch = [0u8; 8192];
        let available = out.remaining().min(self.remaining).min(scratch.len());
        let mut buffer = ReadBuf::new(&mut scratch[..available]);
        match Pin::new(&mut self.inner).poll_read(cx, &mut buffer) {
            Poll::Ready(Ok(())) => {
                self.remaining -= buffer.filled().len();
                if let Err(error) = self.guard.inspect(buffer.filled()) {
                    return Poll::Ready(Err(error));
                }
                out.put_slice(buffer.filled());
                Poll::Ready(Ok(()))
            }
            value => value,
        }
    }
}

/// Validate announced literal lengths before async-imap sees them: its parser
/// otherwise reserves the promised size before the stream byte budget is read.
struct IncomingGuard {
    line: Vec<u8>,
    literal_left: usize,
    literal_limit: usize,
}
impl Default for IncomingGuard {
    fn default() -> Self {
        Self {
            line: Vec::new(),
            literal_left: 0,
            literal_limit: MAX_RAW_BYTES,
        }
    }
}
impl IncomingGuard {
    fn inspect(&mut self, mut bytes: &[u8]) -> io::Result<()> {
        while !bytes.is_empty() {
            if self.literal_left > 0 {
                let take = self.literal_left.min(bytes.len());
                self.literal_left -= take;
                bytes = &bytes[take..];
                continue;
            }
            let byte = bytes[0];
            bytes = &bytes[1..];
            self.line.push(byte);
            if self.line.len() > 64 * 1024 {
                return Err(io::Error::other("IMAP response line exceeds limit"));
            }
            if byte == b'\n' {
                if self.line.ends_with(b"}\r\n")
                    && let Some(start) = self.line.iter().rposition(|b| *b == b'{')
                {
                    let digits = &self.line[start + 1..self.line.len() - 3];
                    let digits = digits.strip_suffix(b"+").unwrap_or(digits);
                    if !digits.is_empty() && digits.iter().all(u8::is_ascii_digit) {
                        let length = digits
                            .iter()
                            .try_fold(0usize, |value, digit| {
                                value.checked_mul(10)?.checked_add((digit - b'0') as usize)
                            })
                            .ok_or_else(|| io::Error::other("IMAP literal length overflow"))?;
                        if length > self.literal_limit {
                            return Err(io::Error::other("IMAP literal exceeds fetch limit"));
                        }
                        self.literal_left = length;
                    }
                }
                self.line.clear();
            }
        }
        Ok(())
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for BoundedIo<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, bytes)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
fn transport_error() -> CoreError {
    CoreError::new("MailTransportError", "mail server connection failed")
}
fn protocol_error() -> CoreError {
    CoreError::new(
        "MailProtocolError",
        "mail server returned an invalid or incomplete response",
    )
}
fn tls_error() -> CoreError {
    CoreError::new(
        "MailTlsError",
        "mail TLS negotiation or certificate validation failed",
    )
}
fn bounded_flag(flag: async_imap::types::Flag<'_>) -> String {
    use async_imap::types::Flag;
    match flag {
        Flag::Seen => "\\Seen".into(),
        Flag::Answered => "\\Answered".into(),
        Flag::Flagged => "\\Flagged".into(),
        Flag::Deleted => "\\Deleted".into(),
        Flag::Draft => "\\Draft".into(),
        Flag::Recent => "\\Recent".into(),
        Flag::MayCreate => "\\*".into(),
        Flag::Custom(value) => super::mime::bounded(&value, 128).0,
    }
}

/// async-imap's streaming FETCH/LIST helpers can end successfully without a
/// tagged OK (including clean EOF and tagged NO/BAD). Never use that stream end
/// as authority to advance a checkpoint, mark a UID absent, or confirm a write.
async fn checked_command(
    session: &mut Imap,
    command: &str,
    mut consume: impl FnMut(&async_imap::imap_proto::Response<'_>) -> CoreResult<()> + Send,
) -> CoreResult<()> {
    use async_imap::imap_proto::{Response, Status};
    let expected = session
        .run_command(command)
        .await
        .map_err(|_| protocol_error())?;
    for _ in 0..4096 {
        let response = session
            .read_response()
            .await
            .map_err(|_| protocol_error())?
            .ok_or_else(protocol_error)?;
        match response.parsed() {
            Response::Done { tag, status, .. } => {
                return if tag == &expected && status == &Status::Ok {
                    Ok(())
                } else {
                    Err(protocol_error())
                };
            }
            Response::Data {
                status: Status::Bye,
                ..
            } => return Err(protocol_error()),
            value => consume(value)?,
        }
    }
    Err(protocol_error())
}

struct CheckedFetch {
    uid: Option<u32>,
    size: Option<u32>,
    flags: Vec<String>,
    body: Option<Vec<u8>>,
}

async fn checked_fetch(
    session: &mut Imap,
    uids: String,
    query: &str,
) -> CoreResult<Vec<CheckedFetch>> {
    use async_imap::imap_proto::{AttributeValue, Response};
    let mut messages = Vec::new();
    checked_command(session, &format!("UID FETCH {uids} {query}"), |response| {
        let Response::Fetch(_, fields) = response else {
            return Ok(());
        };
        if messages.len() >= MAX_WINDOW as usize + 128 {
            return Err(protocol_error());
        }
        let mut value = CheckedFetch {
            uid: None,
            size: None,
            flags: Vec::new(),
            body: None,
        };
        for field in fields {
            match field {
                AttributeValue::Uid(uid) => {
                    if *uid == 0 || value.uid.replace(*uid).is_some() {
                        return Err(protocol_error());
                    }
                }
                AttributeValue::Rfc822Size(size) => {
                    if value.size.replace(*size).is_some() {
                        return Err(protocol_error());
                    }
                }
                AttributeValue::Flags(flags) => {
                    for flag in flags.iter().take(64usize.saturating_sub(value.flags.len())) {
                        value
                            .flags
                            .push(bounded_flag(async_imap::types::Flag::from(flag.as_ref())));
                    }
                }
                AttributeValue::BodySection {
                    section: None,
                    data: Some(body),
                    ..
                }
                | AttributeValue::Rfc822(Some(body)) => {
                    let previous = value.body.replace(body.as_ref().to_vec());
                    if previous.is_some() {
                        return Err(protocol_error());
                    }
                }
                _ => {}
            }
        }
        messages.push(value);
        Ok(())
    })
    .await?;
    Ok(messages)
}

pub(super) fn scan_window(
    validity: u32,
    next: u32,
    previous: &FolderState,
    window: u32,
) -> CoreResult<Option<(u32, u32)>> {
    if validity == 0 || next == 0 || window == 0 || window > MAX_WINDOW {
        return Err(protocol_error());
    }
    let through = if validity == previous.uid_validity {
        previous.scanned_through
    } else {
        0
    };
    if next <= through {
        return Err(CoreError::new(
            "UidRegression",
            "mailbox UIDNEXT regressed without a UIDVALIDITY change",
        ));
    }
    let start = through.saturating_add(1);
    let end = next.saturating_sub(1).min(start.saturating_add(window - 1));
    Ok((start <= end).then_some((start, end)))
}

#[async_trait]
impl MailBackend for NativeBackend {
    async fn attachment_message(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        folder: &str,
        validity: u32,
        uid: u32,
    ) -> CoreResult<RawMail> {
        let mut session = self.imap(config, credentials).await?;
        let result = tokio::time::timeout(TIMEOUT, async {
            let mailbox = session
                .examine(folder)
                .await
                .map_err(|_| protocol_error())?;
            if mailbox.uid_validity != Some(validity) || validity == 0 {
                return Err(CoreError::new(
                    "UidValidityChanged",
                    "mailbox epoch changed; sync before reading attachments",
                ));
            }
            // Ask size first, so a normal oversized mailbox message is rejected
            // without requesting its body or allocating its announced literal.
            let mut size = None;
            {
                let fetched =
                    checked_fetch(&mut session, uid.to_string(), "(UID RFC822.SIZE)").await?;
                for message in fetched {
                    if message.uid == Some(uid) {
                        if size.is_some() {
                            return Err(protocol_error());
                        }
                        size = Some(message.size.ok_or_else(protocol_error)?);
                    }
                }
            }
            let size =
                size.ok_or_else(|| CoreError::new("NotFound", "mail message no longer exists"))?;
            if size as usize > MAX_ATTACHMENT_RAW_BYTES {
                return Err(CoreError::new(
                    "MailLimitExceeded",
                    "attachment message exceeds 8 MiB raw MIME limit",
                ));
            }
            session.as_mut().guard.literal_limit = MAX_ATTACHMENT_RAW_BYTES;
            let query =
                format!("(UID FLAGS RFC822.SIZE BODY.PEEK[]<0.{MAX_ATTACHMENT_RAW_BYTES}>)");
            let fetched = checked_fetch(&mut session, uid.to_string(), &query).await?;
            let mut result = None;
            for message in fetched {
                if message.uid != Some(uid) {
                    continue;
                }
                if result.is_some() || message.size != Some(size) {
                    return Err(CoreError::new(
                        "MailAttachmentChanged",
                        "mail message identity or size changed during attachment fetch",
                    ));
                }
                let raw = message.body.ok_or_else(protocol_error)?;
                if raw.len() != size as usize {
                    return Err(CoreError::new(
                        "MailAttachmentIncomplete",
                        "IMAP attachment fetch returned a truncated message",
                    ));
                }
                result = Some(RawMail {
                    uid,
                    size,
                    flags: message.flags,
                    raw,
                });
            }
            result.ok_or_else(|| CoreError::new("NotFound", "mail message no longer exists"))
        })
        .await
        .map_err(|_| CoreError::new("MailTimeout", "IMAP attachment read timed out"))?;
        close_imap(&mut session).await;
        result
    }
    async fn folders(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
    ) -> CoreResult<Vec<MailboxFolder>> {
        let mut session = self.imap(config, credentials).await?;
        let result = tokio::time::timeout(TIMEOUT, async {
            let mut folders = vec![];
            checked_command(&mut session, "LIST \"\" \"*\"", |response| {
                use async_imap::imap_proto::{MailboxDatum, Response};
                let Response::MailboxData(MailboxDatum::List(name)) = response else {
                    return Ok(());
                };
                if folders.len() >= MAX_FOLDERS {
                    return Err(CoreError::new(
                        "MailLimitExceeded",
                        "mailbox folder count exceeds limit",
                    ));
                }
                folder_name(&name.name)?;
                folders.push(MailboxFolder {
                    name: name.name.to_string(),
                    delimiter: name.delimiter.as_deref().map(str::to_owned),
                    selectable: !name
                        .name_attributes
                        .iter()
                        .any(|a| matches!(a, async_imap::types::NameAttribute::NoSelect)),
                    attributes: name
                        .name_attributes
                        .iter()
                        .take(32)
                        .map(|a| super::mime::bounded(&format!("{a:?}"), 128).0)
                        .collect(),
                });
                Ok(())
            })
            .await?;
            Ok(folders)
        })
        .await
        .map_err(|_| CoreError::new("MailTimeout", "IMAP folder listing timed out"))?;
        close_imap(&mut session).await;
        result
    }
    async fn sync(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        folder: &str,
        state: &FolderState,
        window: u32,
    ) -> CoreResult<SyncBatch> {
        let mut session = self.imap(config, credentials).await?;
        let result = tokio::time::timeout(TIMEOUT, async {
            let mailbox = session
                .examine(folder)
                .await
                .map_err(|_| protocol_error())?;
            let validity = mailbox.uid_validity.ok_or_else(protocol_error)?;
            let next = mailbox.uid_next.ok_or_else(protocol_error)?;
            let range = scan_window(validity, next, state, window)?;
            let same_epoch = validity == state.uid_validity;
            let mut batch = SyncBatch {
                validity,
                next,
                through: if same_epoch { state.scanned_through } else { 0 },
                flags_cursor: 1,
                messages: vec![],
                refreshed: None,
            };
            if let Some((start, end)) = range {
                let query = format!("(UID FLAGS RFC822.SIZE BODY.PEEK[]<0.{MAX_RAW_BYTES}>)");
                let messages =
                    checked_fetch(&mut session, format!("{start}:{end}"), &query).await?;
                for message in messages {
                    let Some(uid) = message.uid.filter(|uid| *uid >= start && *uid <= end) else {
                        continue;
                    };
                    if batch.messages.len() >= window as usize {
                        return Err(protocol_error());
                    }
                    let raw = message.body.ok_or_else(protocol_error)?;
                    if raw.len() > MAX_RAW_BYTES {
                        return Err(CoreError::new(
                            "MailLimitExceeded",
                            "IMAP message exceeds fetch limit",
                        ));
                    }
                    batch.messages.push(RawMail {
                        uid,
                        size: message.size.ok_or_else(protocol_error)?,
                        flags: message.flags,
                        raw,
                    });
                }
                batch.through = end;
            }
            // Rotate a bounded UID flag scan, including absence/tombstone detection.
            if same_epoch && state.scanned_through > 0 {
                let start = state.flags_cursor.max(1).min(state.scanned_through);
                let end = state.scanned_through.min(start.saturating_add(window - 1));
                let fetched =
                    checked_fetch(&mut session, format!("{start}:{end}"), "(UID FLAGS)").await?;
                let mut updated = BTreeMap::new();
                for message in fetched {
                    if let Some(uid) = message.uid.filter(|uid| *uid >= start && *uid <= end) {
                        updated.insert(uid, message.flags);
                    }
                }
                batch.flags_cursor = if end >= state.scanned_through {
                    1
                } else {
                    end + 1
                };
                batch.refreshed = Some(FlagScan {
                    start,
                    end,
                    flags: updated,
                });
            }
            Ok(batch)
        })
        .await
        .map_err(|_| {
            CoreError::new(
                "MailTimeout",
                "bounded IMAP sync timed out; cursor was not advanced",
            )
        })?;
        close_imap(&mut session).await;
        result
    }
    async fn flags(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        folder: &str,
        validity: u32,
        uid: u32,
        changes: Option<&BTreeMap<String, bool>>,
    ) -> CoreResult<Vec<String>> {
        let mut session = self.imap(config, credentials).await?;
        let mailbox = tokio::time::timeout(TIMEOUT, session.select(folder))
            .await
            .map_err(|_| CoreError::new("MailTimeout", "IMAP selection timed out"))?
            .map_err(|_| protocol_error())?;
        if mailbox.uid_validity != Some(validity) {
            return Err(CoreError::new(
                "UidValidityChanged",
                "synchronize the mailbox before changing flags",
            ));
        }
        let result =
            tokio::time::timeout(TIMEOUT, async {
                if let Some(changes) = changes {
                    for enabled in [true, false] {
                        let names: Vec<_> = changes
                            .iter()
                            .filter(|(_, value)| **value == enabled)
                            .map(|(name, _)| name.as_str())
                            .collect();
                        if names.is_empty() {
                            continue;
                        }
                        let query = format!(
                            "{}FLAGS.SILENT ({})",
                            if enabled { "+" } else { "-" },
                            names.join(" ")
                        );
                        checked_command(&mut session, &format!("UID STORE {uid} {query}"), |_| {
                            Ok(())
                        })
                        .await?;
                    }
                }
                let fetched = checked_fetch(&mut session, uid.to_string(), "(UID FLAGS)").await?;
                for message in fetched {
                    if message.uid == Some(uid) {
                        return Ok(message.flags);
                    }
                }
                Err(CoreError::new("NotFound", "mail message no longer exists"))
            })
            .await;
        close_imap(&mut session).await;
        match result {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) if changes.is_none() => Err(error),
            Err(_) if changes.is_none() => Err(CoreError::new(
                "MailTimeout",
                "IMAP flag inspection timed out",
            )),
            _ => Err(CoreError::new(
                "NeedsReconciliation",
                "IMAP flag write outcome is uncertain; inspect flags before retrying",
            )),
        }
    }
    async fn send(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        envelope: &Envelope,
        bytes: &[u8],
    ) -> Result<SendReceipt, SendFailure> {
        let hello = ClientId::Domain("dansheng.local".into());
        let tls = self.smtp_tls(&config.smtp.host)?;
        let prepare = async {
            let mut connection = AsyncSmtpConnection::connect_tokio1(
                (config.smtp.host.as_str(), config.smtp.port),
                Some(TIMEOUT),
                &hello,
                (config.smtp.tls == TlsMode::Implicit).then(|| tls.clone()),
                None,
            )
            .await
            .map_err(|_| SendFailure::before())?;
            if config.smtp.tls == TlsMode::Starttls {
                connection
                    .starttls(tls, &hello)
                    .await
                    .map_err(|_| SendFailure::before())?;
            }
            if !connection.is_encrypted() {
                return Err(SendFailure::before());
            }
            connection
                .auth(
                    &[Mechanism::Plain, Mechanism::Login],
                    &Credentials::new(config.username.clone(), credentials.smtp_password.clone()),
                )
                .await
                .map_err(|_| SendFailure {
                    uncertain: false,
                    code: "AuthenticationRequired",
                })?;
            Ok(connection)
        };
        let mut connection = tokio::time::timeout(TIMEOUT, prepare)
            .await
            .map_err(|_| SendFailure::before())??;
        // Never retry or pool SMTP connections. Only a final positive DATA reply proves acceptance.
        let result = match tokio::time::timeout(TIMEOUT, connection.send(envelope, bytes)).await {
            Ok(Ok(response)) => Ok(SendReceipt {
                code: response.code().to_string(),
            }),
            Ok(Err(error)) if error.is_permanent() || error.is_transient() => Err(SendFailure {
                uncertain: false,
                code: "MailRejected",
            }),
            _ => Err(SendFailure {
                uncertain: true,
                code: "NeedsReconciliation",
            }),
        };
        // Acceptance was determined above; QUIT/close failure must never cause a resend.
        let _ = tokio::time::timeout(Duration::from_secs(2), connection.abort()).await;
        result
    }
}

#[cfg(test)]
mod bounds_tests {
    use super::*;
    #[test]
    fn literal_promises_are_bounded_before_parser_allocation() {
        let mut guard = IncomingGuard::default();
        assert!(
            guard
                .inspect(b"* 1 FETCH (BODY[] {4294967295}\r\n")
                .is_err()
        );
        let mut guard = IncomingGuard::default();
        guard.inspect(b"* 1 FETCH (BODY[] {13}\r\n").unwrap();
        guard.inspect(b"{99999999999}").unwrap();
        assert_eq!(guard.literal_left, 0);
        guard.inspect(b")\r\n").unwrap();
        assert!(
            IncomingGuard::default()
                .inspect(&vec![b'x'; 64 * 1024 + 1])
                .is_err()
        );
        let mut attachment = IncomingGuard {
            literal_limit: MAX_ATTACHMENT_RAW_BYTES,
            ..IncomingGuard::default()
        };
        let oversized = format!("* 1 FETCH (BODY[] {{{}}}\r\n", MAX_ATTACHMENT_RAW_BYTES + 1);
        assert!(attachment.inspect(oversized.as_bytes()).is_err());
        let mut attachment = IncomingGuard {
            literal_limit: MAX_ATTACHMENT_RAW_BYTES,
            ..IncomingGuard::default()
        };
        let bounded = format!("* 1 FETCH (BODY[] {{{MAX_ATTACHMENT_RAW_BYTES}}}\r\n");
        attachment.inspect(bounded.as_bytes()).unwrap();
        assert_eq!(attachment.literal_left, MAX_ATTACHMENT_RAW_BYTES);
    }
    #[tokio::test]
    async fn connection_byte_budget_is_enforced() {
        use tokio::io::AsyncReadExt;
        let mut io = BoundedIo::new(&b"abcdef"[..]);
        io.remaining = 4;
        let mut bytes = [0; 4];
        io.read_exact(&mut bytes).await.unwrap();
        assert!(io.read_u8().await.is_err());
    }
}
