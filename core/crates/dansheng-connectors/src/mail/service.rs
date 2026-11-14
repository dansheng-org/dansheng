use super::{
    mime,
    model::*,
    protocol::{MailBackend, NativeBackend},
};
use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::Utc;
use dansheng_core::{
    CoreError, CoreResult, Principal, assets,
    policy::Grant,
    services::{CoreService, ServiceContext},
    store::Store,
};
use lettre::{
    Message,
    message::{
        Attachment, Body, MultiPart, SinglePart,
        header::{ContentTransferEncoding, ContentType},
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    sync::{Arc, Mutex, Weak},
};

const OWNER: &str = "service:mail";
const METHODS: &[(&str, &str)] = &[
    ("mail.configure", "mail.write"),
    ("mail.status", "mail.read"),
    ("mail.sync", "mail.sync"),
    ("mail.folders", "mail.read"),
    ("mail.list", "mail.read"),
    ("mail.read", "mail.read"),
    ("mail.attachment.read", "mail.read"),
    ("mail.draft.save", "mail.write"),
    ("mail.draft.list", "mail.read"),
    ("mail.send", "mail.send"),
    ("mail.set_flags", "mail.write"),
];

/// One native implementation shared by embedded UI, desktop IPC and authorized MCP clients.
pub struct MailService {
    backend: Arc<dyn MailBackend>,
    gates: Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>>,
}
impl Default for MailService {
    fn default() -> Self {
        Self {
            backend: Arc::new(NativeBackend::default()),
            gates: Mutex::new(HashMap::new()),
        }
    }
}
#[derive(Serialize, Deserialize)]
struct Configured {
    config: MailConfig,
    generation: String,
    vault_key: String,
    // Legacy/imported configurations remain usable for offline cache access.
    #[serde(default)]
    credential_binding_epoch: Option<String>,
}

struct PreparedAttachment {
    binding: AttachmentBinding,
    bytes: Vec<u8>,
}

// Always dispatch with the original caller and grant. The mail service identity
// must never confer access to another client's files or bypass source labels.
async fn prepare_attachments(
    context: &ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    input: &DraftInput,
) -> CoreResult<Vec<PreparedAttachment>> {
    input.validate()?;
    let mut prepared = Vec::new();
    let mut total = 0usize;
    for attachment in &input.attachments {
        let mut bytes = Vec::new();
        loop {
            // One extra byte distinguishes an exactly-at-limit file from an
            // oversized file, including a missing/false EOF from a provider.
            let remaining = MAX_ATTACHMENT_BYTES.min(MAX_OUTGOING_ATTACHMENT_BYTES - total);
            let length = MAX_ATTACHMENT_CHUNK.min(remaining.saturating_sub(bytes.len()) + 1);
            let read = assets::dispatch(
                context.store,
                context.network,
                principal,
                grant,
                "files.read",
                json!({"asset_id":attachment.asset_id,
                    "account_id":attachment.account_id,"offset":bytes.len(),"length":length}),
            )
            .await?;
            let data = read["data"]
                .as_str()
                .ok_or_else(|| CoreError::new("MailAssetError", "invalid managed file response"))?;
            if data.len() > length.div_ceil(3) * 4 {
                return Err(CoreError::new(
                    "MailAssetError",
                    "managed file chunk exceeds requested limit",
                ));
            }
            let chunk = STANDARD
                .decode(data)
                .map_err(|_| CoreError::new("MailAssetError", "invalid managed file encoding"))?;
            let next = bytes.len() + chunk.len();
            if read["asset_id"] != attachment.asset_id
                || read["encoding"] != "base64"
                || read["offset"].as_u64() != Some(bytes.len() as u64)
                || read["length"].as_u64() != Some(chunk.len() as u64)
                || read["next_offset"].as_u64() != Some(next as u64)
                || chunk.len() > length
                || read["eof"].as_bool().is_none()
                || (chunk.is_empty() && read["eof"] != true)
            {
                return Err(CoreError::new(
                    "MailAssetError",
                    "inconsistent managed file chunk",
                ));
            }
            if next > remaining {
                return Err(CoreError::new(
                    "MailLimitExceeded",
                    "mail attachments exceed per-file 4 MiB or total 8 MiB limit",
                ));
            }
            bytes.extend_from_slice(&chunk);
            if read["eof"] == true {
                break;
            }
        }
        total += bytes.len();
        prepared.push(PreparedAttachment {
            binding: AttachmentBinding {
                asset_id: attachment.asset_id.clone(),
                account_id: attachment.account_id.clone(),
                name: attachment.name.clone(),
                mime_type: attachment.mime_type.clone(),
                size: bytes.len(),
                sha256: digest(&bytes),
            },
            bytes,
        });
    }
    Ok(prepared)
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn namespace(account: &str) -> String {
    format!("service:mail:{account}")
}
fn required<'a>(params: &'a Value, key: &str) -> CoreResult<&'a str> {
    dansheng_core::api::required_string(params, key)
}
fn load<T: serde::de::DeserializeOwned>(
    store: &Store,
    namespace: &str,
    key: &str,
) -> CoreResult<Option<T>> {
    let value = store.kv_get(namespace, key)?;
    if value.is_null() {
        Ok(None)
    } else {
        serde_json::from_value(value).map(Some).map_err(|_| {
            CoreError::new(
                "MailCacheError",
                "local mail data has an unsupported format",
            )
        })
    }
}
fn save(store: &Store, namespace: &str, key: &str, value: &impl Serialize) -> CoreResult<()> {
    store.kv_set(namespace, key, &serde_json::to_value(value)?)
}
fn configured(store: &Store, ns: &str) -> CoreResult<Configured> {
    let value: Configured = load(store, ns, "configuration")?
        .ok_or_else(|| CoreError::new("MailNotConfigured", "configure this mail account first"))?;
    value.config.validate()?;
    let account = ns
        .strip_prefix("service:mail:")
        .ok_or_else(|| CoreError::new("InternalError", "invalid mail namespace"))?;
    let generation = digest(&serde_json::to_vec(&value.config)?);
    let expected = format!("mail:{}:{generation}", digest(account.as_bytes()));
    if value.generation != generation || value.vault_key != expected {
        return Err(CoreError::new(
            "MailCacheError",
            "mail configuration binding is invalid",
        ));
    }
    Ok(value)
}
fn require_credential_binding(store: &Store, config: &Configured) -> CoreResult<String> {
    let bound = config
        .credential_binding_epoch
        .as_deref()
        .filter(|epoch| !epoch.is_empty());
    match (bound, store.credential_binding_epoch()?) {
        (Some(bound), Some(current)) if bound == current => Ok(current),
        _ => Err(CoreError::new(
            "ConfigurationRequired",
            "explicitly configure this mail account with credentials before network access",
        )),
    }
}
fn folder(params: &Value) -> CoreResult<String> {
    let name = folder_name(params["folder"].as_str().unwrap_or("INBOX"))?;
    Ok(if name.eq_ignore_ascii_case("INBOX") {
        "INBOX".into()
    } else {
        name.into()
    })
}
fn folder_key(config: &Configured, folder: &str) -> String {
    digest(format!("{}\0{folder}", config.generation).as_bytes())
}
fn message_key(folder: &str, validity: u32, uid: u32) -> String {
    format!("message:{folder}:{validity}:{uid}")
}
fn page_key(folder: &str, validity: u32, page: u32) -> String {
    format!("index:{folder}:{validity}:{page}")
}
fn state(store: &Store, ns: &str, folder: &str) -> CoreResult<FolderState> {
    let account = ns
        .strip_prefix("service:mail:")
        .ok_or_else(|| CoreError::new("InternalError", "invalid mail service namespace"))?;
    Ok(load(store, &format!("checkpoint:{OWNER}:mail.{folder}"), account)?.unwrap_or_default())
}
fn current_upper_bound(state: &FolderState) -> u32 {
    state.uid_next.min(state.scanned_through.saturating_add(1))
}
fn uid(params: &Value) -> CoreResult<u32> {
    params["uid"]
        .as_u64()
        .and_then(|v| u32::try_from(v).ok())
        .filter(|v| *v > 0)
        .ok_or_else(|| CoreError::invalid("positive message uid is required"))
}
fn validity(params: &Value, active: &FolderState) -> CoreResult<u32> {
    let value = params["uid_validity"]
        .as_u64()
        .and_then(|v| u32::try_from(v).ok())
        .ok_or_else(|| CoreError::invalid("uid_validity is required"))?;
    if value == 0 || value != active.uid_validity {
        return Err(CoreError::new(
            "UidValidityChanged",
            "mailbox epoch changed; refresh the local listing",
        ));
    }
    Ok(value)
}
fn draft_id(value: &str) -> CoreResult<&str> {
    if value.is_empty()
        || value.len() > 80
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
    {
        return Err(CoreError::invalid("invalid draft id"));
    }
    Ok(value)
}
fn pending(value: &Value) -> bool {
    matches!(
        value["state"].as_str(),
        Some("submitting" | "needs_reconciliation")
    )
}
fn seal_sent(store: &Store, ns: &str, id: &str, receipt: &Value) -> CoreResult<Value> {
    let message_id = receipt["message_id"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            CoreError::new(
                "MailCacheError",
                "confirmed mail submission has no message identity",
            )
        })?;
    if receipt["state"] != "sent" {
        return Err(CoreError::new(
            "MailCacheError",
            "only confirmed mail submissions can be sealed",
        ));
    }
    let mut receipt = receipt.clone();
    receipt["draft_id"] = json!(id);
    save(store, ns, &format!("sent_draft:{id}"), &receipt)?;
    save(
        store,
        ns,
        &format!("sent_message:{}", digest(message_id.as_bytes())),
        &receipt,
    )?;
    Ok(receipt)
}
fn confirmed_submission(
    store: &Store,
    ns: &str,
    id: &str,
    message_id: Option<&str>,
    active: &Value,
) -> CoreResult<Option<Value>> {
    let by_draft = store.kv_get(ns, &format!("sent_draft:{id}"))?;
    if !by_draft.is_null() {
        if by_draft["state"] != "sent"
            || by_draft["draft_id"] != id
            || by_draft["message_id"].as_str().is_none_or(str::is_empty)
        {
            return Err(CoreError::new(
                "MailCacheError",
                "confirmed draft identity is invalid",
            ));
        }
        return Ok(Some(by_draft));
    }
    // Backfill immutable identity markers for receipts created by earlier builds.
    if active["state"] == "sent" {
        return seal_sent(store, ns, id, active).map(Some);
    }
    if let Some(message_id) = message_id {
        let by_message = store.kv_get(
            ns,
            &format!("sent_message:{}", digest(message_id.as_bytes())),
        )?;
        if !by_message.is_null() {
            if by_message["state"] != "sent" || by_message["message_id"] != message_id {
                return Err(CoreError::new(
                    "MailCacheError",
                    "confirmed message identity is invalid",
                ));
            }
            return Ok(Some(by_message));
        }
    }
    Ok(None)
}
fn summary(message: &MailMessage) -> CoreResult<Value> {
    let mut value = serde_json::to_value(message)?;
    if let Some(object) = value.as_object_mut() {
        object.remove("text");
        object.remove("html");
    }
    Ok(value)
}

impl MailService {
    #[cfg(test)]
    pub(super) fn with_backend(backend: Arc<dyn MailBackend>) -> Self {
        Self {
            backend,
            gates: Mutex::new(HashMap::new()),
        }
    }
    fn gate(&self, account: &str) -> CoreResult<Arc<tokio::sync::Mutex<()>>> {
        let mut gates = self
            .gates
            .lock()
            .map_err(|_| CoreError::new("InternalError", "mail operation gate unavailable"))?;
        gates.retain(|_, gate| gate.strong_count() > 0);
        if let Some(gate) = gates.get(account).and_then(Weak::upgrade) {
            return Ok(gate);
        }
        let gate = Arc::new(tokio::sync::Mutex::new(()));
        gates.insert(account.into(), Arc::downgrade(&gate));
        Ok(gate)
    }
    async fn credentials(
        context: &ServiceContext<'_>,
        config: &Configured,
    ) -> CoreResult<MailCredentials> {
        require_credential_binding(context.store, config)?;
        let response = context
            .platform
            .call("vault.get", json!({"key":config.vault_key}))
            .await?;
        let value = response
            .get("value")
            .filter(|value| !value.is_null())
            .ok_or_else(|| {
                CoreError::new(
                    "AuthenticationRequired",
                    "mail credentials are not available in the platform vault",
                )
            })?;
        let credentials: MailCredentials = serde_json::from_value(value.clone()).map_err(|_| {
            CoreError::new(
                "AuthenticationRequired",
                "stored mail credentials have an invalid format",
            )
        })?;
        credentials.validate()?;
        Ok(credentials)
    }
    async fn configure(
        &self,
        context: &ServiceContext<'_>,
        principal: &Principal,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        if !principal.is_owner() {
            return Err(CoreError::new(
                "PermissionDenied",
                "mail account configuration requires the trusted owner",
            ));
        }
        let config: MailConfig = serde_json::from_value(params["config"].clone())?;
        config.validate()?;
        let ns = namespace(account);
        let generation = digest(&serde_json::to_vec(&config)?);
        let vault_key = format!("mail:{}:{generation}", digest(account.as_bytes()));
        let credential_binding_epoch = if let Some(value) = params.get("credentials") {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Provision {
                password: Option<String>,
                imap_password: Option<String>,
                smtp_password: Option<String>,
            }
            let input: Provision = serde_json::from_value(value.clone())?;
            let credentials = MailCredentials {
                imap_password: input
                    .imap_password
                    .or_else(|| input.password.clone())
                    .unwrap_or_default(),
                smtp_password: input.smtp_password.or(input.password).unwrap_or_default(),
            };
            credentials.validate()?;
            let response = context
                .platform
                .call("vault.set", json!({"key":vault_key,"value":credentials}))
                .await?;
            if response["ok"] != true {
                return Err(CoreError::new(
                    "VaultError",
                    "platform did not confirm credential storage",
                ));
            }
            context.store.ensure_credential_binding_epoch()?
        } else {
            let previous = configured(context.store, &ns)?;
            let epoch = require_credential_binding(context.store, &previous)?;
            if previous.generation != generation {
                return Err(CoreError::invalid(
                    "initial configuration and endpoint changes require explicit credentials",
                ));
            }
            epoch
        };
        let configured = Configured {
            config,
            generation,
            vault_key,
            credential_binding_epoch: Some(credential_binding_epoch),
        };
        save(context.store, &ns, "configuration", &configured)?;
        Ok(json!({"account_id":account,"configured":true,"config":configured.config}))
    }
    fn cache_message(
        store: &Store,
        ns: &str,
        account: &str,
        key: &str,
        message: &MailMessage,
    ) -> CoreResult<()> {
        save(
            store,
            ns,
            &message_key(key, message.uid_validity, message.uid),
            message,
        )?;
        store.record_upsert(
            OWNER,
            account,
            &format!("mail.{key}"),
            &format!("{key}:{}:{}", message.uid_validity, message.uid),
            "mail.message",
            &serde_json::to_value(message)?,
        )?;
        Ok(())
    }
    async fn synchronize(
        &self,
        context: &ServiceContext<'_>,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let folder = folder(params)?;
        let key = folder_key(&config, &folder);
        let previous = state(context.store, &ns, &key)?;
        let window = params["window"].as_u64().unwrap_or(DEFAULT_WINDOW as u64);
        if window == 0 || window > MAX_WINDOW as u64 {
            return Err(CoreError::invalid(
                "sync window must be 1 to 128 UID positions",
            ));
        }
        let credentials = Self::credentials(context, &config).await?;
        let batch = self
            .backend
            .sync(
                &config.config,
                &credentials,
                &folder,
                &previous,
                window as u32,
            )
            .await?;
        if batch.validity == 0 || batch.next == 0 || batch.messages.len() > window as usize {
            return Err(CoreError::new(
                "MailProtocolError",
                "invalid bounded sync response",
            ));
        }
        let reset = previous.uid_validity != batch.validity;
        let mut current = if reset {
            FolderState::default()
        } else {
            previous
        };
        current.uid_validity = batch.validity;
        current.uid_next = batch.next;
        current.scanned_through = batch.through;
        current.flags_cursor = batch.flags_cursor;
        let mut inserted = 0;
        let mut rows = Vec::new();
        for raw in batch.messages {
            let message = mime::parse(
                &folder,
                batch.validity,
                raw.uid,
                raw.size,
                raw.flags,
                &raw.raw,
            )?;
            save(
                context.store,
                &ns,
                &message_key(&key, batch.validity, message.uid),
                &message,
            )?;
            rows.push((
                format!("{key}:{}:{}", batch.validity, message.uid),
                serde_json::to_value(&message)?,
            ));
            let page = message.uid / INDEX_PAGE;
            current.index_pages.insert(page);
            if current.index_pages.len() > 4096 {
                return Err(CoreError::new(
                    "MailCacheLimit",
                    "mail UID index exceeds the local cache limit",
                ));
            }
            let page_key = page_key(&key, batch.validity, page);
            let mut uids: BTreeSet<u32> = load(context.store, &ns, &page_key)?.unwrap_or_default();
            uids.insert(message.uid);
            save(context.store, &ns, &page_key, &uids)?;
            inserted += 1;
        }
        if let Some(refreshed) = batch.refreshed {
            for page in current
                .index_pages
                .range((refreshed.start / INDEX_PAGE)..=(refreshed.end / INDEX_PAGE))
            {
                let uids: BTreeSet<u32> =
                    load(context.store, &ns, &page_key(&key, batch.validity, *page))?
                        .unwrap_or_default();
                for id in uids.range(refreshed.start..=refreshed.end) {
                    if let Some(mut message) = load::<MailMessage>(
                        context.store,
                        &ns,
                        &message_key(&key, batch.validity, *id),
                    )? {
                        match refreshed.flags.get(id) {
                            Some(flags) => {
                                message.flags = flags.clone();
                                message.deleted_remotely = false
                            }
                            None => message.deleted_remotely = true,
                        }
                        save(
                            context.store,
                            &ns,
                            &message_key(&key, batch.validity, *id),
                            &message,
                        )?;
                        rows.push((
                            format!("{key}:{}:{id}", batch.validity),
                            serde_json::to_value(&message)?,
                        ));
                        save(
                            context.store,
                            &ns,
                            &format!("flags_pending:{key}:{}:{id}", batch.validity),
                            &json!({"state":"observed","uid_validity":batch.validity,"flags":message.flags,"deleted_remotely":message.deleted_remotely}),
                        )?;
                    }
                }
            }
        }
        current.last_sync_at = Some(Utc::now().to_rfc3339());
        // Authoritative source rows and the UID checkpoint commit together. KV
        // bodies/index pages are staged first; list/read hide UIDs beyond the
        // committed cursor, so an interrupted batch cannot publish a partial scan.
        context.store.commit_source(
            OWNER,
            account,
            &format!("mail.{key}"),
            "mail.message",
            &rows,
            &serde_json::to_value(&current)?,
        )?;
        Ok(
            json!({"account_id":account,"folder":folder,"uid_validity":batch.validity,"epoch_changed":reset,"fetched":inserted,
            "scanned_through":current.scanned_through,"uid_next":current.uid_next,"has_more":current.scanned_through.saturating_add(1)<current.uid_next}),
        )
    }
    fn list(context: &ServiceContext<'_>, account: &str, params: &Value) -> CoreResult<Value> {
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let folder = folder(params)?;
        let key = folder_key(&config, &folder);
        let state = state(context.store, &ns, &key)?;
        let before = params["before_uid"]
            .as_u64()
            .unwrap_or(state.uid_next as u64)
            .min(current_upper_bound(&state) as u64) as u32;
        let limit = params["limit"].as_u64().unwrap_or(20).clamp(1, 100) as usize;
        let mut messages = vec![];
        let mut next = None;
        let mut bytes = 0;
        'pages: for page in state
            .index_pages
            .range(..=(before / INDEX_PAGE))
            .rev()
            .take(64)
        {
            let ids: BTreeSet<u32> = load(
                context.store,
                &ns,
                &page_key(&key, state.uid_validity, *page),
            )?
            .unwrap_or_default();
            for id in ids.range(..before).rev() {
                next = Some(*id);
                if let Some(message) = load::<MailMessage>(
                    context.store,
                    &ns,
                    &message_key(&key, state.uid_validity, *id),
                )? {
                    if message.deleted_remotely && params["include_deleted"] != true {
                        continue;
                    }
                    let value = summary(&message)?;
                    bytes += serde_json::to_vec(&value)?.len();
                    if bytes > 2 * 1024 * 1024 {
                        next = Some(id.saturating_add(1));
                        break 'pages;
                    }
                    messages.push(value);
                    if messages.len() >= limit {
                        break 'pages;
                    }
                }
            }
        }
        Ok(
            json!({"folder":folder,"uid_validity":state.uid_validity,"messages":messages,"next_before_uid":next}),
        )
    }
    async fn read(
        &self,
        context: &ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let folder = folder(params)?;
        let key = folder_key(&config, &folder);
        let active = state(context.store, &ns, &key)?;
        let validity = validity(params, &active)?;
        let uid = uid(params)?;
        if uid > active.scanned_through {
            return Err(CoreError::new(
                "NotFound",
                "message is beyond the committed local sync cursor",
            ));
        }
        let mut message: MailMessage = load(context.store, &ns, &message_key(&key, validity, uid))?
            .ok_or_else(|| CoreError::new("NotFound", "mail message is not in the local cache"))?;
        if params["refresh_flags"] == true {
            grant.check(principal, "mail.sync")?;
            let credentials = Self::credentials(context, &config).await?;
            message.flags = self
                .backend
                .flags(&config.config, &credentials, &folder, validity, uid, None)
                .await?;
            message.deleted_remotely = false;
            Self::cache_message(context.store, &ns, account, &key, &message)?;
        }
        Ok(serde_json::to_value(message)?)
    }
    async fn read_attachment(
        &self,
        context: &ServiceContext<'_>,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Input {
            account_id: String,
            folder: Option<String>,
            uid_validity: u32,
            uid: u32,
            part: String,
            #[serde(default)]
            offset: usize,
            length: Option<usize>,
            sha256: Option<String>,
        }
        let input: Input = serde_json::from_value(params.clone())?;
        // account/folder/UID gates also run before any vault or network access.
        debug_assert_eq!(input.account_id, account);
        if let Some(folder) = &input.folder {
            folder_name(folder)?;
        }
        let length = input.length.unwrap_or(MAX_ATTACHMENT_CHUNK);
        let index = input
            .part
            .strip_prefix("attachment:")
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|index| *index < 128 && input.part == format!("attachment:{index}"))
            .ok_or_else(|| {
                CoreError::invalid("attachment part must be a cached attachment:<index> identifier")
            })?;
        if length == 0
            || length > MAX_ATTACHMENT_CHUNK
            || input.offset > MAX_ATTACHMENT_BYTES
            || (input.offset > 0 && input.sha256.is_none())
            || input.sha256.as_ref().is_some_and(|hash| {
                hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit())
            })
        {
            return Err(CoreError::invalid(
                "invalid attachment chunk range or missing continuation SHA-256",
            ));
        }
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let folder = folder(params)?;
        let key = folder_key(&config, &folder);
        let active = state(context.store, &ns, &key)?;
        let epoch = validity(params, &active)?;
        let uid = uid(params)?;
        debug_assert_eq!((input.uid_validity, input.uid), (epoch, uid));
        if uid > active.scanned_through {
            return Err(CoreError::new(
                "NotFound",
                "message is beyond the committed local sync cursor",
            ));
        }
        let cached: MailMessage = load(context.store, &ns, &message_key(&key, epoch, uid))?
            .ok_or_else(|| {
                CoreError::new(
                    "NotFound",
                    "sync this mail message before reading its attachments",
                )
            })?;
        if cached.deleted_remotely {
            return Err(CoreError::new(
                "NotFound",
                "mail message was deleted remotely",
            ));
        }
        if cached.size as usize > MAX_ATTACHMENT_RAW_BYTES {
            return Err(CoreError::new(
                "MailLimitExceeded",
                "attachment message exceeds 8 MiB raw MIME limit",
            ));
        }
        let credentials = Self::credentials(context, &config).await?;
        let raw = self
            .backend
            .attachment_message(&config.config, &credentials, &folder, epoch, uid)
            .await?;
        if raw.uid != uid || raw.size != cached.size {
            return Err(CoreError::new(
                "MailAttachmentChanged",
                "mail message changed since its cached attachment listing",
            ));
        }
        let (metadata, bytes) = mime::attachment(&raw.raw, raw.size, index)?;
        let hash = digest(&bytes);
        if input
            .sha256
            .as_ref()
            .is_some_and(|expected| !expected.eq_ignore_ascii_case(&hash))
        {
            return Err(CoreError::new(
                "MailAttachmentChanged",
                "attachment hash changed; restart the download",
            ));
        }
        if input.offset > bytes.len() {
            return Err(CoreError::invalid("attachment offset is past end of file"));
        }
        let end = bytes.len().min(input.offset + length);
        let message = mime::parse_full(&folder, epoch, uid, raw.size, raw.flags, &raw.raw)?;
        Self::cache_message(context.store, &ns, account, &key, &message)?;
        Ok(
            json!({"account_id":account,"folder":folder,"uid_validity":epoch,"uid":uid,
            "attachment":metadata,"total_size":bytes.len(),"sha256":hash,"content_complete":true,
            "encoding":"base64","data":STANDARD.encode(&bytes[input.offset..end]),
            "offset":input.offset,"length":end-input.offset,"next_offset":end,"eof":end==bytes.len(),"marked_seen":false}),
        )
    }
    fn preview(account: &str, config: &Configured, draft: &Draft) -> CoreResult<(Value, String)> {
        let value = json!({"account_id":account,"config_revision":config.generation,"draft_id":draft.id,"message_id":draft.message_id,
            "from":config.config.address,"content":draft.content,"attachments":draft.attachment_bindings});
        let hash = digest(&serde_json::to_vec(&value)?);
        Ok((value, hash))
    }
    async fn save_draft(
        context: &ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let content: DraftInput = serde_json::from_value(params["draft"].clone())?;
        content.validate()?;
        let id = params["draft_id"]
            .as_str()
            .map(draft_id)
            .transpose()?
            .map(str::to_owned)
            .unwrap_or_else(|| uuid::Uuid::new_v4().simple().to_string());
        let ledger = context.store.kv_get(&ns, &format!("send_active:{id}"))?;
        let previous: Option<Draft> = load(context.store, &ns, &format!("draft:{id}"))?;
        if confirmed_submission(
            context.store,
            &ns,
            &id,
            previous.as_ref().map(|draft| draft.message_id.as_str()),
            &ledger,
        )?
        .is_some()
        {
            return Err(CoreError::new(
                "DraftAlreadySent",
                "confirmed drafts are immutable; create a new draft and Message-ID for another send",
            ));
        }
        if pending(&ledger) {
            return Err(CoreError::new(
                "NeedsReconciliation",
                "reconcile the previous submission before editing this draft",
            ));
        }
        let prepared = prepare_attachments(context, principal, grant, &content).await?;
        let unchanged = previous.as_ref().is_some_and(|v| {
            serde_json::to_value(&v.content).ok() == serde_json::to_value(&content).ok()
        });
        let at = Utc::now().to_rfc3339();
        let draft = Draft {
            id: id.clone(),
            message_id: if unchanged {
                previous.as_ref().unwrap().message_id.clone()
            } else {
                format!("<{}@dansheng.invalid>", uuid::Uuid::new_v4().simple())
            },
            created_at: previous.map(|v| v.created_at).unwrap_or_else(|| at.clone()),
            updated_at: at,
            content,
            attachment_bindings: prepared.into_iter().map(|item| item.binding).collect(),
        };
        let mut index: Vec<String> = load(context.store, &ns, "draft_index")?.unwrap_or_default();
        index.retain(|existing| existing != &id);
        if index.len() >= 1000 {
            return Err(CoreError::new(
                "MailCacheLimit",
                "local draft limit reached",
            ));
        }
        index.push(id.clone());
        save(context.store, &ns, &format!("draft:{id}"), &draft)?;
        save(context.store, &ns, "draft_index", &index)?;
        let (preview, hash) = Self::preview(account, &config, &draft)?;
        Ok(
            json!({"draft":draft,"preview":preview,"preview_hash":hash,"server_draft_modified":false}),
        )
    }
    fn list_drafts(
        context: &ServiceContext<'_>,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let index: Vec<String> = load(context.store, &ns, "draft_index")?.unwrap_or_default();
        let before = if let Some(id) = params["before_id"].as_str() {
            index
                .iter()
                .position(|item| item == id)
                .ok_or_else(|| CoreError::invalid("draft pagination cursor is not present"))?
        } else {
            index.len()
        };
        let include = params["include_body"] == true;
        let max = if include { 5 } else { 100 };
        let limit = params["limit"].as_u64().unwrap_or(20).clamp(1, max) as usize;
        let mut drafts = vec![];
        let mut next = None;
        for id in index[..before].iter().rev().take(limit) {
            if let Some(draft) = load::<Draft>(context.store, &ns, &format!("draft:{id}"))? {
                let (_, hash) = Self::preview(account, &config, &draft)?;
                let ledger = context.store.kv_get(&ns, &format!("send_active:{id}"))?;
                drafts.push(if include {json!({"draft":draft,"preview_hash":hash,"submission":ledger})}else{json!({"draft_id":draft.id,"message_id":draft.message_id,"subject":draft.content.subject,
                    "to":draft.content.to,"cc":draft.content.cc,"bcc":draft.content.bcc,"updated_at":draft.updated_at,"preview_hash":hash,"submission":ledger})});
                next = Some(id.clone());
            }
        }
        Ok(json!({"drafts":drafts,"next_before_id":next}))
    }
    fn build_message(
        config: &MailConfig,
        draft: &Draft,
        attachments: Vec<PreparedAttachment>,
    ) -> CoreResult<Message> {
        draft.content.validate()?;
        if draft.content.to.is_empty()
            && draft.content.cc.is_empty()
            && draft.content.bcc.is_empty()
        {
            return Err(CoreError::invalid("at least one recipient is required"));
        }
        let mut builder = Message::builder()
            .from(mailbox(&config.address)?)
            .subject(&draft.content.subject)
            .message_id(Some(draft.message_id.clone()));
        for address in &draft.content.to {
            builder = builder.to(mailbox(address)?);
        }
        for address in &draft.content.cc {
            builder = builder.cc(mailbox(address)?);
        }
        for address in &draft.content.bcc {
            builder = builder.bcc(mailbox(address)?);
        }
        let result = if !attachments.is_empty() {
            let mut mixed = if let Some(html) = &draft.content.html {
                MultiPart::mixed().multipart(
                    MultiPart::alternative()
                        .singlepart(SinglePart::plain(draft.content.text.clone()))
                        .singlepart(SinglePart::html(html.clone())),
                )
            } else {
                MultiPart::mixed().singlepart(SinglePart::plain(draft.content.text.clone()))
            };
            for item in attachments {
                let mime = item
                    .binding
                    .mime_type
                    .parse::<ContentType>()
                    .map_err(|_| CoreError::invalid("invalid attachment MIME type"))?;
                let body = Body::new_with_encoding(item.bytes, ContentTransferEncoding::Base64)
                    .map_err(|_| CoreError::invalid("attachment could not be MIME encoded"))?;
                mixed = mixed.singlepart(Attachment::new(item.binding.name).body(body, mime));
            }
            builder.multipart(mixed)
        } else if let Some(html) = &draft.content.html {
            builder.multipart(
                MultiPart::alternative()
                    .singlepart(SinglePart::plain(draft.content.text.clone()))
                    .singlepart(SinglePart::html(html.clone())),
            )
        } else {
            builder
                .header(ContentType::TEXT_PLAIN)
                .body(draft.content.text.clone())
        };
        result.map_err(|_| CoreError::invalid("draft could not be encoded as a mail message"))
    }
    async fn send(
        &self,
        context: &ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let id = draft_id(required(params, "draft_id")?)?;
        let mut draft: Draft = load(context.store, &ns, &format!("draft:{id}"))?
            .ok_or_else(|| CoreError::new("NotFound", "local draft not found"))?;
        let (preview, hash) = Self::preview(account, &config, &draft)?;
        let phase = params["phase"].as_str().unwrap_or("send");
        let ledger_key = format!("send_active:{id}");
        let mut ledger = context.store.kv_get(&ns, &ledger_key)?;
        if let Some(confirmed) =
            confirmed_submission(context.store, &ns, id, Some(&draft.message_id), &ledger)?
        {
            if phase == "send" {
                // The caller/account capability gate already ran. This is a
                // receipt lookup, independent of current configuration or input
                // approval, and must never dispatch SMTP again.
                return Ok(
                    json!({"submission":confirmed,"already_submitted":true,"new_draft_required":true}),
                );
            }
            ledger = confirmed;
        }
        if phase == "preview" {
            if pending(&ledger) || ledger["state"] == "sent" {
                return Ok(
                    json!({"preview":preview,"preview_hash":hash,"submission":ledger,"attachments_revalidated":false}),
                );
            }
            let prepared = prepare_attachments(context, principal, grant, &draft.content).await?;
            draft.attachment_bindings = prepared.into_iter().map(|item| item.binding).collect();
            save(context.store, &ns, &format!("draft:{id}"), &draft)?;
            let (preview, hash) = Self::preview(account, &config, &draft)?;
            return Ok(
                json!({"preview":preview,"preview_hash":hash,"submission":ledger,"attachments_revalidated":true}),
            );
        }
        if phase == "status" {
            return Ok(
                json!({"draft_id":id,"message_id":draft.message_id,"preview_hash":hash,"submission":ledger}),
            );
        }
        if phase == "reconcile" {
            if !principal.is_owner() {
                return Err(CoreError::new(
                    "PermissionDenied",
                    "submission reconciliation requires the trusted owner",
                ));
            }
            if !pending(&ledger) {
                return Err(CoreError::invalid("this draft has no uncertain submission"));
            }
            let outcome = required(params, "outcome")?;
            if !["sent", "not_sent"].contains(&outcome)
                || params["confirmed"] != true
                || required(params, "evidence")?.len() > 4096
            {
                return Err(CoreError::invalid(
                    "confirmed sent/not_sent reconciliation evidence is required",
                ));
            }
            if params["attempt_id"] != ledger["attempt_id"] {
                return Err(CoreError::invalid("submission attempt id does not match"));
            }
            ledger["state"] = Value::String(outcome.into());
            ledger["reconciled_at"] = json!(Utc::now().to_rfc3339());
            // Store only an evidence digest, never arbitrary user-entered mail content in diagnostics.
            ledger["evidence_sha256"] = json!(digest(required(params, "evidence")?.as_bytes()));
            save(context.store, &ns, &ledger_key, &ledger)?;
            if outcome == "sent" {
                ledger = seal_sent(context.store, &ns, id, &ledger).map_err(|_| {
                    CoreError::new(
                        "NeedsReconciliation",
                        "confirmed SMTP identity could not be fully persisted",
                    )
                })?;
            }
            return Ok(json!({"submission":ledger,"retried":false}));
        }
        if phase != "send" {
            return Err(CoreError::invalid("unknown mail send phase"));
        }
        if pending(&ledger) {
            return Err(CoreError::new(
                "NeedsReconciliation",
                "previous SMTP submission is uncertain; reconcile it before another send",
            ));
        }
        if params["confirm"] != true || params["preview_hash"] != hash {
            return Err(CoreError::new(
                "ApprovalRequired",
                "confirm the current draft preview hash before sending",
            ));
        }
        let bindings = [
            grant.action_inputs.get(&format!("mail:{account}:send")),
            grant.action_inputs.get("mail:send"),
        ];
        if !principal.is_owner() && bindings.iter().flatten().any(|expected| **expected != hash) {
            return Err(CoreError::new(
                "ApprovalRequired",
                "mail input differs from the explicitly bound preview grant",
            ));
        }
        if !principal.is_owner()
            && !grant.allows("mail.send:any")
            && bindings.iter().all(|binding| binding.is_none())
        {
            return Err(CoreError::new(
                "ApprovalRequired",
                "mail send requires the exact preview hash grant or explicit mail.send:any authority",
            ));
        }
        let attachments = prepare_attachments(context, principal, grant, &draft.content).await?;
        if attachments
            .iter()
            .map(|item| &item.binding)
            .ne(draft.attachment_bindings.iter())
        {
            return Err(CoreError::new(
                "MailAttachmentChanged",
                "attachment content changed; generate and confirm a new draft preview before sending",
            ));
        }
        let message = Self::build_message(&config.config, &draft, attachments)?;
        let bytes = message.formatted();
        if bytes.len() > MAX_SMTP_BYTES {
            return Err(CoreError::new(
                "MailLimitExceeded",
                "encoded draft exceeds the SMTP input limit",
            ));
        }
        let credentials = Self::credentials(context, &config).await?;
        let attempt = uuid::Uuid::new_v4().simple().to_string();
        ledger = json!({"state":"submitting","draft_id":id,"attempt_id":attempt,"message_id":draft.message_id,"preview_hash":hash,"started_at":Utc::now().to_rfc3339()});
        save(context.store, &ns, &ledger_key, &ledger)?;
        match self
            .backend
            .send(&config.config, &credentials, message.envelope(), &bytes)
            .await
        {
            Ok(receipt) => {
                ledger["state"] = json!("sent");
                ledger["smtp_code"] = json!(receipt.code);
                ledger["accepted_at"] = json!(Utc::now().to_rfc3339());
                save(context.store, &ns, &ledger_key, &ledger).map_err(|_| {
                    CoreError::new(
                        "NeedsReconciliation",
                        "SMTP accepted the message but the local receipt could not be persisted",
                    )
                })?;
                ledger=seal_sent(context.store,&ns,id,&ledger).map_err(|_|CoreError::new("NeedsReconciliation","SMTP accepted the message but the immutable identity receipt could not be fully persisted"))?;
                Ok(json!({"submission":ledger,"draft_retained":true,"delivery_guaranteed":false}))
            }
            Err(error) => {
                ledger["state"] = json!(if error.uncertain {
                    "needs_reconciliation"
                } else {
                    "not_sent"
                });
                ledger["error_code"] = json!(error.code);
                save(context.store, &ns, &ledger_key, &ledger)?;
                Err(CoreError::new(
                    error.code,
                    if error.uncertain {
                        "SMTP outcome is uncertain; inspect Sent/provider logs by Message-ID and reconcile before retrying"
                    } else {
                        "SMTP did not accept this submission; no automatic retry was performed"
                    },
                ))
            }
        }
    }
    async fn set_flags(
        &self,
        context: &ServiceContext<'_>,
        account: &str,
        params: &Value,
    ) -> CoreResult<Value> {
        let ns = namespace(account);
        let config = configured(context.store, &ns)?;
        let folder = folder(params)?;
        let key = folder_key(&config, &folder);
        let active = state(context.store, &ns, &key)?;
        let validity = validity(params, &active)?;
        let uid = uid(params)?;
        let mut message: MailMessage = load(context.store, &ns, &message_key(&key, validity, uid))?
            .ok_or_else(|| CoreError::new("NotFound", "mail message not in local cache"))?;
        let pending_key = format!("flags_pending:{key}:{validity}:{uid}");
        let pending = context.store.kv_get(&ns, &pending_key)?;
        let reconcile = params["reconcile"] == true;
        if !reconcile
            && matches!(
                pending["state"].as_str(),
                Some("submitting" | "needs_reconciliation")
            )
        {
            return Err(CoreError::new(
                "NeedsReconciliation",
                "inspect previous flag write before changing flags again",
            ));
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Changes {
            seen: Option<bool>,
            flagged: Option<bool>,
            answered: Option<bool>,
        }
        let mut changes = BTreeMap::new();
        if !reconcile {
            let input: Changes = serde_json::from_value(params["flags"].clone())?;
            for (name, value) in [
                ("\\Seen", input.seen),
                ("\\Flagged", input.flagged),
                ("\\Answered", input.answered),
            ] {
                if let Some(value) = value {
                    changes.insert(name.into(), value);
                }
            }
            if changes.is_empty() {
                return Err(CoreError::invalid(
                    "at least one supported flag change is required",
                ));
            }
        }
        let credentials = Self::credentials(context, &config).await?;
        if !reconcile {
            save(
                context.store,
                &ns,
                &pending_key,
                &json!({"state":"submitting","uid_validity":validity,"changes":changes}),
            )?;
        }
        let result = self
            .backend
            .flags(
                &config.config,
                &credentials,
                &folder,
                validity,
                uid,
                (!reconcile).then_some(&changes),
            )
            .await;
        match result {
            Ok(flags) => {
                message.flags = flags;
                message.deleted_remotely = false;
                Self::cache_message(context.store, &ns, account, &key, &message)?;
                save(
                    context.store,
                    &ns,
                    &pending_key,
                    &json!({"state":"observed","flags":message.flags,"uid_validity":validity}),
                )?;
                Ok(
                    json!({"uid":uid,"uid_validity":validity,"flags":message.flags,"reconciled":reconcile}),
                )
            }
            Err(error) => {
                if !reconcile {
                    save(
                        context.store,
                        &ns,
                        &pending_key,
                        &json!({"state":"needs_reconciliation","uid_validity":validity,"changes":changes}),
                    )?;
                }
                Err(error)
            }
        }
    }
}

#[async_trait]
impl CoreService for MailService {
    fn methods(&self) -> Vec<(&'static str, &'static str)> {
        METHODS.to_vec()
    }
    async fn call(
        &self,
        context: ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> CoreResult<Value> {
        let capability = METHODS
            .iter()
            .find(|(name, _)| *name == method)
            .map(|(_, cap)| *cap)
            .ok_or_else(|| CoreError::new("MethodNotFound", "unknown mail method"))?;
        grant.check(principal, capability)?;
        let account = account_id(required(&params, "account_id")?)?;
        grant.check_account(principal, Some(account))?;
        let gate = self.gate(account)?;
        let _guard = gate.lock().await;
        match method {
            "mail.configure" => self.configure(&context, principal, account, &params).await,
            "mail.sync" => self.synchronize(&context, account, &params).await,
            "mail.list" => Self::list(&context, account, &params),
            "mail.read" => {
                self.read(&context, principal, grant, account, &params)
                    .await
            }
            "mail.attachment.read" => self.read_attachment(&context, account, &params).await,
            "mail.draft.save" => {
                Self::save_draft(&context, principal, grant, account, &params).await
            }
            "mail.draft.list" => Self::list_drafts(&context, account, &params),
            "mail.send" => {
                self.send(&context, principal, grant, account, &params)
                    .await
            }
            "mail.set_flags" => self.set_flags(&context, account, &params).await,
            "mail.folders" => {
                let ns = namespace(account);
                let config = configured(context.store, &ns)?;
                let cache = format!("folders:{}", config.generation);
                if params["refresh"] == true {
                    grant.check(principal, "mail.sync")?;
                    let credentials = Self::credentials(&context, &config).await?;
                    let folders = self.backend.folders(&config.config, &credentials).await?;
                    save(context.store, &ns, &cache, &folders)?;
                }
                let folders: Vec<MailboxFolder> =
                    load(context.store, &ns, &cache)?.unwrap_or_default();
                Ok(json!({"folders":folders}))
            }
            "mail.status" => {
                let ns = namespace(account);
                let config: Option<Configured> = load(context.store, &ns, "configuration")?;
                match config {
                    Some(_) => {
                        let config = configured(context.store, &ns)?;
                        let _credentials = Self::credentials(&context, &config).await?;
                        Ok(
                            json!({"configured":true,"account_id":account,"config":config.config,"credentials_available":true,"authenticated":"not_probed"}),
                        )
                    }
                    None => Ok(json!({"configured":false,"account_id":account})),
                }
            }
            _ => Err(CoreError::new("MethodNotFound", "unknown mail method")),
        }
    }
}
