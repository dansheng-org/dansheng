use super::{model::*, protocol::*, service::MailService, *};
use async_trait::async_trait;
use dansheng_core::{
    CoreError, CoreResult, PlatformPort, Principal, PrincipalKind,
    network::Network,
    policy::Grant,
    services::{CoreService, ServiceContext},
    store::Store,
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

const MIME:&[u8]=b"From: Offline Sender <sender@example.invalid>\r\nTo: reader@example.invalid\r\nSubject: =?UTF-8?B?5rWL6K+V?=\r\nMessage-ID: <offline-fixture@example.invalid>\r\nDate: Thu, 05 Nov 2026 12:00:00 +0000\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=outer\r\n\r\n--outer\r\nContent-Type: multipart/alternative; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\noffline=20fixture\r\n--inner\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>offline <b>fixture</b></p>\r\n--inner--\r\n--outer\r\nContent-Type: application/octet-stream; name=sample.txt\r\nContent-Disposition: attachment; filename=sample.txt\r\nContent-Transfer-Encoding: base64\r\n\r\naGVsbG8=\r\n--outer--\r\n";

#[derive(Default)]
struct Vault {
    values: Mutex<BTreeMap<String, Value>>,
    reads: AtomicUsize,
}
#[async_trait]
impl PlatformPort for Vault {
    fn capabilities(&self) -> Vec<String> {
        vec![
            "vault.set".into(),
            "vault.get".into(),
            "vault.delete".into(),
        ]
    }
    async fn call(&self, capability: &str, input: Value) -> CoreResult<Value> {
        let key = input["key"].as_str().unwrap().to_owned();
        let mut values = self.values.lock().unwrap();
        match capability {
            "vault.set" => {
                values.insert(key, input["value"].clone());
                Ok(json!({"ok":true}))
            }
            "vault.get" => {
                self.reads.fetch_add(1, Ordering::SeqCst);
                Ok(json!({"value":values.get(&key).cloned().unwrap_or(Value::Null)}))
            }
            "vault.delete" => {
                values.remove(&key);
                Ok(json!({"ok":true}))
            }
            _ => Err(CoreError::new(
                "CapabilityUnavailable",
                "offline vault only",
            )),
        }
    }
}
#[derive(Default)]
struct Backend {
    calls: AtomicUsize,
    batches: Mutex<VecDeque<SyncBatch>>,
    attachment_messages: Mutex<VecDeque<CoreResult<RawMail>>>,
    attachment_reads: AtomicUsize,
    sent_messages: Mutex<Vec<Vec<u8>>>,
    sends: AtomicUsize,
    uncertain: AtomicUsize,
    native: Option<NativeBackend>,
}
#[async_trait]
impl MailBackend for Backend {
    async fn attachment_message(
        &self,
        _: &MailConfig,
        _: &MailCredentials,
        _: &str,
        _: u32,
        _: u32,
    ) -> CoreResult<RawMail> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.attachment_reads.fetch_add(1, Ordering::SeqCst);
        self.attachment_messages
            .lock()
            .unwrap()
            .pop_front()
            .expect("offline attachment response")
    }
    async fn folders(&self, _: &MailConfig, _: &MailCredentials) -> CoreResult<Vec<MailboxFolder>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(vec![MailboxFolder {
            name: "INBOX".into(),
            delimiter: Some("/".into()),
            selectable: true,
            attributes: vec![],
        }])
    }
    async fn sync(
        &self,
        _: &MailConfig,
        _: &MailCredentials,
        _: &str,
        _: &FolderState,
        _: u32,
    ) -> CoreResult<SyncBatch> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(self
            .batches
            .lock()
            .unwrap()
            .pop_front()
            .expect("offline batch"))
    }
    async fn flags(
        &self,
        _: &MailConfig,
        _: &MailCredentials,
        _: &str,
        _: u32,
        _: u32,
        _: Option<&BTreeMap<String, bool>>,
    ) -> CoreResult<Vec<String>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(vec!["\\Seen".into()])
    }
    async fn send(
        &self,
        config: &MailConfig,
        credentials: &MailCredentials,
        envelope: &lettre::address::Envelope,
        bytes: &[u8],
    ) -> Result<SendReceipt, SendFailure> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.sends.fetch_add(1, Ordering::SeqCst);
        self.sent_messages.lock().unwrap().push(bytes.to_vec());
        if let Some(native) = &self.native {
            return native.send(config, credentials, envelope, bytes).await;
        }
        if self.uncertain.load(Ordering::SeqCst) == 2 {
            return std::future::pending().await;
        }
        if self.uncertain.load(Ordering::SeqCst) > 0 {
            Err(SendFailure {
                uncertain: true,
                code: "NeedsReconciliation",
            })
        } else {
            Ok(SendReceipt { code: "250".into() })
        }
    }
}
struct Harness {
    store: Store,
    network: Network,
    vault: Vault,
    backend: Arc<Backend>,
    service: MailService,
    _temp: tempfile::TempDir,
}
impl Harness {
    fn new() -> Self {
        Self::with_backend(Arc::new(Backend::default()))
    }
    fn with_backend(backend: Arc<Backend>) -> Self {
        let temp = tempfile::tempdir().unwrap();
        // Keep restore's retained previous/staging siblings inside the guard.
        let store = Store::open(&temp.path().join("profile")).unwrap();
        let service = MailService::with_backend(backend.clone());
        Self {
            _temp: temp,
            store,
            network: Network::default(),
            vault: Vault::default(),
            backend,
            service,
        }
    }
    async fn call(
        &self,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> CoreResult<Value> {
        self.service
            .call(
                ServiceContext {
                    store: &self.store,
                    network: &self.network,
                    platform: &self.vault,
                },
                principal,
                grant,
                method,
                params,
            )
            .await
    }
    async fn owner(&self, method: &str, params: Value) -> Value {
        self.call(&Principal::owner(), &Grant::default(), method, params)
            .await
            .unwrap()
    }
    async fn configure(&self) {
        self.owner("mail.configure",json!({"account_id":"campus","config":config(),"credentials":{"password":"synthetic-offline-only-password"}})).await;
    }
    fn reopen(self) -> Self {
        self.reopen_after_restore(None)
    }
    fn reopen_after_restore(self, snapshot: Option<&std::path::Path>) -> Self {
        let Self {
            store,
            network: _,
            vault,
            backend,
            service: _,
            _temp,
        } = self;
        let profile = store.directory.clone();
        drop(store);
        if let Some(snapshot) = snapshot {
            dansheng_core::backup::restore(&profile, snapshot).unwrap();
        }
        let store = Store::open(&profile).unwrap();
        let service = MailService::with_backend(backend.clone());
        Self {
            store,
            network: Network::default(),
            vault,
            backend,
            service,
            _temp,
        }
    }
}
fn config() -> MailConfig {
    MailConfig {
        address: "reader@example.invalid".into(),
        username: "offline-reader".into(),
        imap: MailEndpoint {
            host: "imap.example.invalid".into(),
            port: 993,
            tls: TlsMode::Implicit,
        },
        smtp: MailEndpoint {
            host: "smtp.example.invalid".into(),
            port: 465,
            tls: TlsMode::Implicit,
        },
    }
}
fn client() -> Principal {
    Principal {
        id: "offline-mcp".into(),
        kind: PrincipalKind::Mcp,
    }
}
fn grant(caps: &[&str]) -> Grant {
    let mut grant = Grant::default();
    grant.account_ids.insert("campus".into());
    grant.capabilities.extend(caps.iter().map(|v| (*v).into()));
    grant
}
fn batch(validity: u32, uid: u32) -> SyncBatch {
    SyncBatch {
        validity,
        next: uid + 1,
        through: uid,
        flags_cursor: 1,
        messages: vec![RawMail {
            uid,
            size: MIME.len() as u32,
            flags: vec![],
            raw: MIME.to_vec(),
        }],
        refreshed: None,
    }
}

// Mutate only a disposable synthetic snapshot, then recompute its integrity
// inventory: hashes protect bytes, not the authority of imported configuration.
fn replace_snapshot_mail_configuration(snapshot: &std::path::Path, configuration: &Value) {
    use sha2::Digest;
    let scratch = tempfile::tempdir().unwrap();
    std::fs::copy(
        snapshot.join("dansheng.db"),
        scratch.path().join("dansheng.db"),
    )
    .unwrap();
    let image = Store::open(scratch.path()).unwrap();
    image
        .kv_set("service:mail:campus", "configuration", configuration)
        .unwrap();
    // Export a portable DELETE-journal database rather than leaving Store's WAL
    // header in the fixture. Core's backup test separately injects epoch authority.
    let rewritten = dansheng_core::backup::create(&image).unwrap();
    drop(image);
    std::fs::copy(
        std::path::Path::new(rewritten["path"].as_str().unwrap()).join("dansheng.db"),
        snapshot.join("dansheng.db"),
    )
    .unwrap();
    let bytes = std::fs::read(snapshot.join("dansheng.db")).unwrap();
    let hash: String = sha2::Sha256::digest(&bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let path = snapshot.join("manifest.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let entry = manifest["files"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|entry| entry["path"] == "dansheng.db")
        .unwrap();
    entry["size"] = json!(bytes.len());
    entry["sha256"] = json!(hash);
    std::fs::write(path, serde_json::to_vec(&manifest).unwrap()).unwrap();
}

async fn assert_credential_binding_blocks_network(h: &Harness, draft: &Value) {
    let vault_reads = h.vault.reads.load(Ordering::SeqCst);
    let calls = h.backend.calls.load(Ordering::SeqCst);
    let sends = h.backend.sends.load(Ordering::SeqCst);
    let id = &draft["draft"]["id"];
    // A valid, approved send must reach the credential gate, rather than fail at
    // an unrelated approval/UID/cache check and give false security evidence.
    let preview = h
        .owner(
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"phase":"preview"}),
        )
        .await;
    for (method, params) in [
        ("mail.status", json!({"account_id":"campus"})),
        ("mail.sync", json!({"account_id":"campus"})),
        (
            "mail.folders",
            json!({"account_id":"campus","refresh":true}),
        ),
        (
            "mail.read",
            json!({"account_id":"campus","uid_validity":77,"uid":1,"refresh_flags":true}),
        ),
        (
            "mail.set_flags",
            json!({"account_id":"campus","uid_validity":77,"uid":1,"flags":{"seen":true}}),
        ),
        (
            "mail.attachment.read",
            json!({"account_id":"campus","uid_validity":77,"uid":1,"part":"attachment:0"}),
        ),
        (
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"preview_hash":preview["preview_hash"],"confirm":true}),
        ),
    ] {
        let error = h
            .call(&Principal::owner(), &Grant::default(), method, params)
            .await
            .unwrap_err();
        assert_eq!(error.code, "ConfigurationRequired", "{method}");
    }
    assert_eq!(h.vault.reads.load(Ordering::SeqCst), vault_reads);
    assert_eq!(h.backend.calls.load(Ordering::SeqCst), calls);
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), sends);
}

#[tokio::test]
async fn credential_binding_restore_keeps_offline_mail_and_sent_identities() {
    let h = Harness::new();
    h.configure().await;
    let mut other_endpoint = config();
    other_endpoint.imap.host = "previous-imap.example.invalid".into();
    other_endpoint.smtp.host = "previous-smtp.example.invalid".into();
    h.owner("mail.configure", json!({"account_id":"campus","config":other_endpoint,"credentials":{"password":"synthetic-former-endpoint-password"}})).await;
    let old_configuration = h
        .store
        .kv_get("service:mail:campus", "configuration")
        .unwrap();
    let old_epoch = h.store.credential_binding_epoch().unwrap().unwrap();
    h.backend.batches.lock().unwrap().push_back(batch(77, 1));
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    let draft = h.owner("mail.draft.save", json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"retained offline draft"}})).await;
    let sent = h.owner("mail.draft.save", json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"confirmed synthetic submission"}})).await;
    let sent_id = &sent["draft"]["id"];
    h.owner("mail.send", json!({"account_id":"campus","draft_id":sent_id,"preview_hash":sent["preview_hash"],"confirm":true})).await;
    let replay = h.owner("mail.draft.save", json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"imported Message-ID fixture"}})).await;
    let replay_id = &replay["draft"]["id"];
    let mut imported = replay["draft"].clone();
    imported["message_id"] = sent["draft"]["message_id"].clone();
    h.store
        .kv_set(
            "service:mail:campus",
            &format!("draft:{}", replay_id.as_str().unwrap()),
            &imported,
        )
        .unwrap();

    // Snapshot the current endpoint, then replace it with an older internally
    // valid endpoint/key pair whose credentials survive in the external vault.
    h.configure().await;
    let captured = dansheng_core::backup::create(&h.store).unwrap();
    let path = std::path::PathBuf::from(captured["path"].as_str().unwrap());
    replace_snapshot_mail_configuration(&path, &old_configuration);
    let external_values = h.vault.values.lock().unwrap().clone();
    assert!(external_values.contains_key(old_configuration["vault_key"].as_str().unwrap()));
    let h = h.reopen_after_restore(Some(&path));
    assert_eq!(*h.vault.values.lock().unwrap(), external_values);
    assert_eq!(h.store.credential_binding_epoch().unwrap(), None);
    let h = h.reopen();
    assert_eq!(h.store.credential_binding_epoch().unwrap(), None);
    assert_credential_binding_blocks_network(&h, &draft).await;

    let reads = h.vault.reads.load(Ordering::SeqCst);
    assert_eq!(
        h.owner("mail.list", json!({"account_id":"campus"})).await["messages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        h.owner(
            "mail.read",
            json!({"account_id":"campus","uid_validity":77,"uid":1})
        )
        .await["text"],
        "offline fixture"
    );
    let drafts = h
        .owner(
            "mail.draft.list",
            json!({"account_id":"campus","include_body":true}),
        )
        .await;
    assert!(
        drafts["drafts"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["draft"]["content"]["text"] == "retained offline draft")
    );
    for id in [sent_id, replay_id] {
        let receipt = h
            .owner(
                "mail.send",
                json!({"account_id":"campus","draft_id":id,"confirm":true}),
            )
            .await;
        assert_eq!(receipt["already_submitted"], true);
        assert_eq!(
            receipt["submission"]["message_id"],
            sent["draft"]["message_id"]
        );
    }
    assert_eq!(h.vault.reads.load(Ordering::SeqCst), reads);
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.configure",
            json!({"account_id":"campus","config":other_endpoint})
        )
        .await
        .unwrap_err()
        .code,
        "ConfigurationRequired"
    );
    assert_eq!(h.store.credential_binding_epoch().unwrap(), None);
    assert_eq!(h.call(&client(), &grant(&["mail.write"]), "mail.configure", json!({"account_id":"campus","config":other_endpoint,"credentials":{"password":"synthetic-untrusted-input"}})).await.unwrap_err().code, "PermissionDenied");
    assert_eq!(*h.vault.values.lock().unwrap(), external_values);

    // Establishing a new profile epoch for a different account must not adopt
    // the saved epoch of this restored account or reactivate its old key.
    h.owner("mail.configure", json!({"account_id":"other","config":config(),"credentials":{"password":"synthetic-other-account-password"}})).await;
    let new_epoch = h.store.credential_binding_epoch().unwrap().unwrap();
    assert_ne!(new_epoch, old_epoch);
    assert_credential_binding_blocks_network(&h, &draft).await;
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.configure",
            json!({"account_id":"campus","config":other_endpoint})
        )
        .await
        .unwrap_err()
        .code,
        "ConfigurationRequired"
    );

    h.owner("mail.configure", json!({"account_id":"campus","config":other_endpoint,"credentials":{"password":"synthetic-fresh-explicit-password"}})).await;
    assert_eq!(
        h.vault
            .values
            .lock()
            .unwrap()
            .get(old_configuration["vault_key"].as_str().unwrap()),
        Some(
            &json!({"imap_password":"synthetic-fresh-explicit-password","smtp_password":"synthetic-fresh-explicit-password"})
        )
    );
    assert_eq!(
        h.store
            .kv_get("service:mail:campus", "configuration")
            .unwrap()["credential_binding_epoch"],
        new_epoch
    );
    assert_eq!(
        h.owner("mail.status", json!({"account_id":"campus"})).await["credentials_available"],
        true
    );
    h.backend.batches.lock().unwrap().push_back(batch(77, 2));
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    for id in [sent_id, replay_id] {
        assert_eq!(
            h.owner(
                "mail.send",
                json!({"account_id":"campus","draft_id":id,"confirm":true})
            )
            .await["already_submitted"],
            true
        );
    }
    assert_eq!(h.call(&Principal::owner(), &Grant::default(), "mail.draft.save", json!({"account_id":"campus","draft_id":sent_id,"draft":{"to":["recipient@example.invalid"],"text":"edit confirmed"}})).await.unwrap_err().code, "DraftAlreadySent");
    let preview = h
        .owner(
            "mail.send",
            json!({"account_id":"campus","draft_id":draft["draft"]["id"],"phase":"preview"}),
        )
        .await;
    h.owner("mail.send", json!({"account_id":"campus","draft_id":draft["draft"]["id"],"preview_hash":preview["preview_hash"],"confirm":true})).await;
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn credential_binding_legacy_missing_empty_and_mismatched_epochs_fail_closed() {
    let h = Harness::new();
    h.configure().await;
    h.backend.batches.lock().unwrap().push_back(batch(77, 1));
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    let draft = h.owner("mail.draft.save", json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"legacy offline draft"}})).await;
    let ns = "service:mail:campus";
    let original = h.store.kv_get(ns, "configuration").unwrap();
    let epoch = original["credential_binding_epoch"].clone();
    for (current, bound) in [
        (None, None), // Legacy None == None is never trust.
        (None, Some(epoch.clone())),
        (Some(epoch.clone()), None),
        (Some(epoch.clone()), Some(json!(""))),
        (Some(json!("")), Some(json!(""))),
        (Some(Value::Null), Some(Value::Null)),
        (Some(json!(uuid::Uuid::new_v4().to_string())), Some(epoch)),
    ] {
        let mut configuration = original.clone();
        configuration
            .as_object_mut()
            .unwrap()
            .remove("credential_binding_epoch");
        if let Some(bound) = bound {
            configuration["credential_binding_epoch"] = bound;
        }
        h.store.kv_set(ns, "configuration", &configuration).unwrap();
        h.store
            .kv_delete("core:credential-bindings", "epoch")
            .unwrap();
        if let Some(current) = &current {
            h.store
                .kv_set("core:credential-bindings", "epoch", current)
                .unwrap();
        }
        assert_credential_binding_blocks_network(&h, &draft).await;
        assert_eq!(
            h.owner(
                "mail.read",
                json!({"account_id":"campus","uid_validity":77,"uid":1})
            )
            .await["text"],
            "offline fixture"
        );
        assert_eq!(
            h.owner(
                "mail.draft.list",
                json!({"account_id":"campus","include_body":true})
            )
            .await["drafts"][0]["draft"]["content"]["text"],
            "legacy offline draft"
        );
        assert_eq!(
            h.call(
                &Principal::owner(),
                &Grant::default(),
                "mail.configure",
                json!({"account_id":"campus","config":config()})
            )
            .await
            .unwrap_err()
            .code,
            "ConfigurationRequired"
        );
        assert_eq!(
            h.store.kv_get("core:credential-bindings", "epoch").unwrap(),
            current.unwrap_or(Value::Null)
        );
    }
    // Reading legacy configuration never silently writes a binding into it.
    h.store.kv_set(ns, "configuration", &original).unwrap();
    h.store
        .kv_delete("core:credential-bindings", "epoch")
        .unwrap();
    let h = h.reopen();
    assert_eq!(h.store.credential_binding_epoch().unwrap(), None);
    assert_credential_binding_blocks_network(&h, &draft).await;
}

#[tokio::test]
async fn credential_binding_same_configuration_may_keep_an_existing_valid_binding() {
    let h = Harness::new();
    h.configure().await;
    let epoch = h.store.credential_binding_epoch().unwrap();
    let credentials = h.vault.values.lock().unwrap().clone();
    h.owner(
        "mail.configure",
        json!({"account_id":"campus","config":config()}),
    )
    .await;
    assert_eq!(h.store.credential_binding_epoch().unwrap(), epoch);
    assert_eq!(*h.vault.values.lock().unwrap(), credentials);
    assert_eq!(
        h.owner("mail.status", json!({"account_id":"campus"})).await["credentials_available"],
        true
    );
}

#[tokio::test]
async fn credential_binding_restore_retains_uncertain_send_and_legacy_confirmed_receipts() {
    use sha2::Digest;
    for confirmed in [false, true] {
        let h = Harness::new();
        h.configure().await;
        if !confirmed {
            h.backend.uncertain.store(1, Ordering::SeqCst);
        }
        let draft = h.owner("mail.draft.save", json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"synthetic durable submission"}})).await;
        let id = draft["draft"]["id"].as_str().unwrap();
        let params = json!({"account_id":"campus","draft_id":id,"preview_hash":draft["preview_hash"],"confirm":true});
        let result = h
            .call(
                &Principal::owner(),
                &Grant::default(),
                "mail.send",
                params.clone(),
            )
            .await;
        if confirmed {
            result.unwrap();
            // Exercise legacy send_active receipt recovery after binding reset.
            h.store
                .kv_delete("service:mail:campus", &format!("sent_draft:{id}"))
                .unwrap();
            let hash: String =
                sha2::Sha256::digest(draft["draft"]["message_id"].as_str().unwrap().as_bytes())
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect();
            h.store
                .kv_delete("service:mail:campus", &format!("sent_message:{hash}"))
                .unwrap();
        } else {
            assert_eq!(result.unwrap_err().code, "NeedsReconciliation");
        }
        let captured = dansheng_core::backup::create(&h.store).unwrap();
        let path = std::path::PathBuf::from(captured["path"].as_str().unwrap());
        let h = h.reopen_after_restore(Some(&path));
        let reads = h.vault.reads.load(Ordering::SeqCst);
        let result = h
            .call(
                &Principal::owner(),
                &Grant::default(),
                "mail.send",
                params.clone(),
            )
            .await;
        if confirmed {
            assert_eq!(result.unwrap()["already_submitted"], true);
        } else {
            assert_eq!(result.unwrap_err().code, "NeedsReconciliation");
        }
        assert_eq!(h.vault.reads.load(Ordering::SeqCst), reads);
        h.configure().await;
        let result = h
            .call(&Principal::owner(), &Grant::default(), "mail.send", params)
            .await;
        if confirmed {
            assert_eq!(result.unwrap()["already_submitted"], true);
        } else {
            assert_eq!(result.unwrap_err().code, "NeedsReconciliation");
            let status = h
                .owner(
                    "mail.send",
                    json!({"account_id":"campus","draft_id":id,"phase":"status"}),
                )
                .await;
            h.owner("mail.send", json!({"account_id":"campus","draft_id":id,"phase":"reconcile","attempt_id":status["submission"]["attempt_id"],"outcome":"sent","confirmed":true,"evidence":"synthetic acceptance receipt"})).await;
            assert_eq!(
                h.owner(
                    "mail.send",
                    json!({"account_id":"campus","draft_id":id,"confirm":true})
                )
                .await["already_submitted"],
                true
            );
        }
        assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
    }
}

fn raw_attachment(raw: &[u8]) -> RawMail {
    RawMail {
        uid: 1,
        size: raw.len() as u32,
        flags: vec![],
        raw: raw.to_vec(),
    }
}

fn binary_mime(bytes: &[u8]) -> Vec<u8> {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let mut raw = b"From: fixture@example.invalid\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=fixture\r\n\r\n--fixture\r\nContent-Type: text/plain\r\n\r\nsynthetic body\r\n--fixture\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=offline.bin\r\nContent-Transfer-Encoding: base64\r\n\r\n".to_vec();
    for line in STANDARD.encode(bytes).as_bytes().chunks(76) {
        raw.extend_from_slice(line);
        raw.extend_from_slice(b"\r\n");
    }
    raw.extend_from_slice(b"--fixture--\r\n");
    raw
}

#[test]
fn damaged_truncated_and_oversized_attachments_never_claim_complete_bytes() {
    assert_eq!(
        mime::attachment(MIME, MIME.len() as u32 + 1, 0)
            .unwrap_err()
            .code,
        "MailAttachmentIncomplete"
    );
    let truncated = &MIME[..MIME.len() - 12];
    assert_eq!(
        mime::attachment(truncated, truncated.len() as u32, 0)
            .unwrap_err()
            .code,
        "MailAttachmentIncomplete"
    );
    let malformed = String::from_utf8(MIME.to_vec())
        .unwrap()
        .replace("aGVsbG8=", "aG!VsbG8=");
    assert_eq!(
        mime::attachment(malformed.as_bytes(), malformed.len() as u32, 0)
            .unwrap_err()
            .code,
        "MailAttachmentIncomplete"
    );
    let meta = mime::parse(
        "INBOX",
        1,
        1,
        malformed.len() as u32,
        vec![],
        malformed.as_bytes(),
    )
    .unwrap();
    assert!(!meta.attachments[0].content_complete);
    assert!(!meta.attachments[0].size_complete);
    let oversized = binary_mime(&vec![7; MAX_ATTACHMENT_BYTES + 1]);
    assert_eq!(
        mime::attachment(&oversized, oversized.len() as u32, 0)
            .unwrap_err()
            .code,
        "MailLimitExceeded"
    );
}

#[tokio::test]
async fn attachment_read_is_account_scoped_epoch_bound_and_chunk_hash_bound() {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let h = Harness::new();
    h.configure().await;
    h.backend.batches.lock().unwrap().push_back(batch(77, 1));
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    let input =
        json!({"account_id":"campus","uid_validity":77,"uid":1,"part":"attachment:0","length":2});
    for g in [Grant::default(), grant(&["mail.sync"])] {
        assert_eq!(
            h.call(&client(), &g, "mail.attachment.read", input.clone())
                .await
                .unwrap_err()
                .code,
            "PermissionDenied"
        );
    }
    let mut wrong = grant(&["mail.read"]);
    wrong.account_ids.clear();
    assert_eq!(
        h.call(&client(), &wrong, "mail.attachment.read", input.clone())
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    let mut stale = input.clone();
    stale["uid_validity"] = json!(76);
    assert_eq!(
        h.call(
            &client(),
            &grant(&["mail.read"]),
            "mail.attachment.read",
            stale
        )
        .await
        .unwrap_err()
        .code,
        "UidValidityChanged"
    );
    let mut range = input.clone();
    range["length"] = json!(MAX_ATTACHMENT_CHUNK + 1);
    assert_eq!(
        h.call(
            &client(),
            &grant(&["mail.read"]),
            "mail.attachment.read",
            range
        )
        .await
        .unwrap_err()
        .code,
        "InvalidInput"
    );
    assert_eq!(h.backend.attachment_reads.load(Ordering::SeqCst), 0);
    h.backend
        .attachment_messages
        .lock()
        .unwrap()
        .push_back(Ok(raw_attachment(MIME)));
    let first = h
        .call(
            &client(),
            &grant(&["mail.read"]),
            "mail.attachment.read",
            input.clone(),
        )
        .await
        .unwrap();
    assert_eq!(
        STANDARD.decode(first["data"].as_str().unwrap()).unwrap(),
        b"he"
    );
    assert_eq!(first["eof"], false);
    assert_eq!(first["marked_seen"], false);
    assert_eq!(first["content_complete"], true);
    let mut rest = input;
    rest["offset"] = json!(2);
    rest["length"] = json!(100);
    assert_eq!(
        h.call(
            &client(),
            &grant(&["mail.read"]),
            "mail.attachment.read",
            rest.clone()
        )
        .await
        .unwrap_err()
        .code,
        "InvalidInput"
    );
    rest["sha256"] = first["sha256"].clone();
    h.backend
        .attachment_messages
        .lock()
        .unwrap()
        .push_back(Ok(raw_attachment(MIME)));
    let last = h
        .call(
            &client(),
            &grant(&["mail.read"]),
            "mail.attachment.read",
            rest.clone(),
        )
        .await
        .unwrap();
    assert_eq!(
        STANDARD.decode(last["data"].as_str().unwrap()).unwrap(),
        b"llo"
    );
    assert_eq!(last["eof"], true);
    rest["sha256"] = json!("0".repeat(64));
    h.backend
        .attachment_messages
        .lock()
        .unwrap()
        .push_back(Ok(raw_attachment(MIME)));
    assert_eq!(
        h.call(
            &client(),
            &grant(&["mail.read"]),
            "mail.attachment.read",
            rest
        )
        .await
        .unwrap_err()
        .code,
        "MailAttachmentChanged"
    );
}

#[tokio::test]
async fn complete_attachment_fetch_upgrades_prefix_metadata_and_refuses_truncation() {
    let h = Harness::new();
    h.configure().await;
    let raw = binary_mime(&vec![17; 900 * 1024]);
    let mut initial = batch(81, 1);
    initial.messages[0] = RawMail {
        uid: 1,
        size: raw.len() as u32,
        flags: vec![],
        raw: raw[..MAX_RAW_BYTES].to_vec(),
    };
    h.backend.batches.lock().unwrap().push_back(initial);
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    let input = json!({"account_id":"campus","uid_validity":81,"uid":1,"part":"attachment:0"});
    let before = h.owner("mail.read", input.clone()).await;
    assert_eq!(before["mime_complete"], false);
    assert_eq!(before["attachments"][0]["content_complete"], false);
    h.backend
        .attachment_messages
        .lock()
        .unwrap()
        .push_back(Ok(RawMail {
            uid: 1,
            size: raw.len() as u32,
            flags: vec![],
            raw: raw[..MAX_RAW_BYTES].to_vec(),
        }));
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.attachment.read",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "MailAttachmentIncomplete"
    );
    h.backend
        .attachment_messages
        .lock()
        .unwrap()
        .push_back(Ok(raw_attachment(&raw)));
    let read = h.owner("mail.attachment.read", input.clone()).await;
    assert_eq!(read["total_size"], 900 * 1024);
    assert_eq!(read["length"], MAX_ATTACHMENT_CHUNK);
    let after = h.owner("mail.read", input).await;
    assert_eq!(after["mime_complete"], true);
    assert_eq!(after["attachments"][0]["content_complete"], true);
    assert_eq!(after["flags"], json!([]));
}

/// Test assets enter only through the real managed-download API and a local server.
async fn managed_attachment(h: &Harness, bytes: Vec<u8>, account: &str, source: &str) -> Value {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    h.network
        .set_session(account, &origin, None, vec![])
        .unwrap();
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                let mut buf = [0u8; 2048];
                let n = socket.read(&mut buf).await.unwrap();
                assert!(n > 0);
                request.extend_from_slice(&buf[..n]);
                if request.windows(4).any(|v| v == b"\r\n\r\n") {
                    break;
                }
                assert!(request.len() < 32768);
            }
            assert!(request.starts_with(b"HEAD ") || request.starts_with(b"GET "));
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        bytes.len()
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
            if request.starts_with(b"GET ") {
                socket.write_all(&bytes).await.unwrap();
            }
        }
    });
    let local_download_grant = Grant {
        allow_private_network: true,
        ..Grant::default()
    };
    let result = dansheng_core::assets::dispatch(&h.store, &h.network, &Principal::owner(), &local_download_grant,
        "files.download", json!({"url":format!("{origin}/fixture"),"account_id":account,"source_id":source,"name":"core-original.bin","mime_type":"application/octet-stream"})).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();
    result
}

fn attachment_draft(asset: &Value) -> Value {
    json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"offline body","html":"<p>offline body</p>",
        "attachments":[{"asset_id":asset["asset_id"],"account_id":asset["account_id"],"name":"实验.bin","mime_type":"application/octet-stream"}]}})
}

#[tokio::test]
async fn outgoing_assets_use_original_file_account_source_and_capability_grants() {
    let h = Harness::new();
    h.configure().await;
    let asset = managed_attachment(
        &h,
        b"offline bytes".to_vec(),
        "campus",
        "fixture.attachments",
    )
    .await;
    let input = attachment_draft(&asset);
    assert_eq!(
        h.call(
            &client(),
            &grant(&["mail.write"]),
            "mail.draft.save",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    let mut allowed = grant(&["mail.write", "files.read"]);
    assert_eq!(
        h.call(&client(), &allowed, "mail.draft.save", input.clone())
            .await
            .unwrap_err()
            .code,
        "NotFound"
    );
    allowed.source_ids.insert("fixture.attachments".into());
    h.store
        .require_source_capabilities(
            &Principal::owner().id,
            "fixture.attachments",
            &["mail.read".into()].into(),
        )
        .unwrap();
    assert_eq!(
        h.call(&client(), &allowed, "mail.draft.save", input.clone())
            .await
            .unwrap_err()
            .code,
        "NotFound"
    );
    allowed.capabilities.insert("mail.read".into());
    let saved = h
        .call(&client(), &allowed, "mail.draft.save", input.clone())
        .await
        .unwrap();
    assert_eq!(saved["preview"]["attachments"][0]["size"], 13);
    assert_eq!(saved["preview"]["attachments"][0]["name"], "实验.bin");
    assert_eq!(
        saved["preview"]["attachments"][0]["mime_type"],
        "application/octet-stream"
    );
    assert!(
        saved["preview"]["attachments"][0]["sha256"]
            .as_str()
            .unwrap()
            .len()
            == 64
    );
    assert!(!allowed.allows("files.export"));
    assert!(!allowed.allows("files.list"));
    // Adding a sensitive source label after preview must still gate the send.
    h.store
        .require_source_capabilities(
            &Principal::owner().id,
            "fixture.attachments",
            &["academic.read".into()].into(),
        )
        .unwrap();
    let mut send_grant = allowed.clone();
    send_grant
        .capabilities
        .extend(["mail.send".into(), "mail.send:any".into()]);
    assert_eq!(h.call(&client(), &send_grant, "mail.send", json!({"account_id":"campus","draft_id":saved["draft"]["id"],"preview_hash":saved["preview_hash"],"confirm":true})).await.unwrap_err().code, "NotFound");
    let foreign = managed_attachment(
        &h,
        b"other account".to_vec(),
        "other-account",
        "fixture.attachments",
    )
    .await;
    assert_eq!(
        h.call(
            &client(),
            &allowed,
            "mail.draft.save",
            attachment_draft(&foreign)
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    let mut path = input;
    path["draft"]["attachments"][0]["path"] = json!("C:/arbitrary/file");
    assert!(
        h.call(&client(), &allowed, "mail.draft.save", path)
            .await
            .is_err()
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn changed_asset_invalidates_preview_and_actual_mime_contains_exact_attachment() {
    let h = Harness::new();
    h.configure().await;
    let original = vec![0, 255, 13, 10, 0, 128];
    let asset = managed_attachment(&h, original.clone(), "campus", "fixture.attachments").await;
    let saved = h.owner("mail.draft.save", attachment_draft(&asset)).await;
    let id = saved["draft"]["id"].as_str().unwrap();
    let mut allowed = grant(&["mail.send", "files.read", "mail.send:any"]);
    allowed.source_ids.insert("fixture.attachments".into());
    let send = json!({"account_id":"campus","draft_id":id,"preview_hash":saved["preview_hash"],"confirm":true});
    let mut revoked = allowed.clone();
    revoked.capabilities.remove("files.read");
    assert_eq!(
        h.call(&client(), &revoked, "mail.send", send.clone())
            .await
            .unwrap_err()
            .code,
        "PermissionDenied"
    );
    let changed = vec![128, 0, 10, 13, 255, 0];
    // Mutate only this test's generated managed file, retaining the same size.
    std::fs::write(
        h.store
            .directory
            .join("assets")
            .join(asset["asset_id"].as_str().unwrap()),
        &changed,
    )
    .unwrap();
    assert_eq!(
        h.call(&client(), &allowed, "mail.send", send.clone())
            .await
            .unwrap_err()
            .code,
        "MailAttachmentChanged"
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 0);
    let refreshed = h
        .call(
            &client(),
            &allowed,
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"phase":"preview"}),
        )
        .await
        .unwrap();
    assert_ne!(refreshed["preview_hash"], saved["preview_hash"]);
    assert_eq!(
        h.call(&client(), &allowed, "mail.send", send.clone())
            .await
            .unwrap_err()
            .code,
        "ApprovalRequired"
    );
    let mut send = send;
    send["preview_hash"] = refreshed["preview_hash"].clone();
    assert_eq!(
        h.call(&client(), &allowed, "mail.send", send.clone())
            .await
            .unwrap()["submission"]["state"],
        "sent"
    );
    let wire = h.backend.sent_messages.lock().unwrap().clone();
    let parsed = mail_parser::MessageParser::new().parse(&wire[0]).unwrap();
    let part = parsed.attachments().next().unwrap();
    assert_eq!(part.attachment_name(), Some("实验.bin"));
    assert_eq!(part.content_transfer_encoding(), Some("base64"));
    assert_eq!(part.decoded_checked().0.as_ref(), changed);
    assert!(part.decoded_checked().1.is_empty());
    assert!(parsed.body_text(0).unwrap().contains("offline body"));
    assert!(parsed.body_html(0).unwrap().contains("<p>offline body</p>"));
    drop(wire);
    // A confirmed receipt remains readable after asset deletion or grants revoke.
    std::fs::remove_file(
        h.store
            .directory
            .join("assets")
            .join(asset["asset_id"].as_str().unwrap()),
    )
    .unwrap();
    let receipt = h
        .call(&client(), &grant(&["mail.send"]), "mail.send", send)
        .await
        .unwrap();
    assert_eq!(receipt["already_submitted"], true);
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn uncertain_attachment_submission_cannot_be_edited_or_retried_after_asset_loss() {
    let h = Harness::new();
    h.configure().await;
    let asset = managed_attachment(
        &h,
        b"uncertain attachment".to_vec(),
        "campus",
        "fixture.attachments",
    )
    .await;
    let draft = attachment_draft(&asset);
    let saved = h.owner("mail.draft.save", draft.clone()).await;
    let id = saved["draft"]["id"].as_str().unwrap();
    h.backend.uncertain.store(1, Ordering::SeqCst);
    let send = json!({"account_id":"campus","draft_id":id,"preview_hash":saved["preview_hash"],"confirm":true});
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.send",
            send.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NeedsReconciliation"
    );
    std::fs::remove_file(
        h.store
            .directory
            .join("assets")
            .join(asset["asset_id"].as_str().unwrap()),
    )
    .unwrap();
    let h = h.reopen();
    let mut edit = draft;
    edit["draft_id"] = json!(id);
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.draft.save",
            edit
        )
        .await
        .unwrap_err()
        .code,
        "NeedsReconciliation"
    );
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.send",
            send.clone()
        )
        .await
        .unwrap_err()
        .code,
        "NeedsReconciliation"
    );
    let status = h
        .owner(
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"phase":"status"}),
        )
        .await;
    h.owner("mail.send", json!({"account_id":"campus","draft_id":id,"phase":"reconcile","attempt_id":status["submission"]["attempt_id"],"outcome":"sent","confirmed":true,"evidence":"synthetic provider log"})).await;
    assert_eq!(h.owner("mail.send", send).await["already_submitted"], true);
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[test]
fn mime_decodes_bodies_addresses_and_attachment_metadata() {
    let value = mime::parse("INBOX", 8, 1, MIME.len() as u32, vec![], MIME).unwrap();
    assert!(value.subject.as_deref() == Some("测试"));
    assert!(value.text.unwrap().contains("offline fixture"));
    assert!(value.html.unwrap().contains("<b>fixture</b>"));
    assert!(value.attachments[0].name.as_deref() == Some("sample.txt"));
    assert_eq!(value.attachments[0].decoded_size, 5);
    assert!(value.mime_complete);
    assert!(
        !mime::parse("INBOX", 8, 1, MIME.len() as u32 + 10, vec![], MIME)
            .unwrap()
            .mime_complete
    );
}

#[test]
fn uid_windows_never_use_star_or_reuse_previous_epoch() {
    let previous = FolderState {
        uid_validity: 10,
        uid_next: 100,
        scanned_through: 50,
        ..Default::default()
    };
    assert_eq!(scan_window(10, 100, &previous, 16).unwrap(), Some((51, 66)));
    assert_eq!(scan_window(11, 100, &previous, 16).unwrap(), Some((1, 16)));
    assert!(scan_window(10, 1, &previous, 16).is_err());
    assert_eq!(scan_window(10, 51, &previous, 16).unwrap(), None);
    assert!(scan_window(10, 100, &previous, MAX_WINDOW + 1).is_err());
}

#[tokio::test]
async fn account_scope_owner_configuration_and_no_secret_persistence() {
    let h = Harness::new();
    h.configure().await;
    let ordinary = client();
    let granted = grant(&["mail.read", "mail.write"]);
    assert_eq!(
        h.call(
            &ordinary,
            &Grant::default(),
            "mail.status",
            json!({"account_id":"campus"})
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    assert_eq!(
        h.call(
            &ordinary,
            &granted,
            "mail.status",
            json!({"account_id":"other"})
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    assert_eq!(
        h.call(
            &ordinary,
            &granted,
            "mail.configure",
            json!({"account_id":"campus","config":config()})
        )
        .await
        .unwrap_err()
        .code,
        "PermissionDenied"
    );
    let h = h.reopen();
    let status = h
        .call(
            &ordinary,
            &granted,
            "mail.status",
            json!({"account_id":"campus"}),
        )
        .await
        .unwrap();
    assert_eq!(status["credentials_available"], true);
    assert_eq!(status["authenticated"], "not_probed");
    let cached = h
        .store
        .kv_get("service:mail:campus", "configuration")
        .unwrap()
        .to_string();
    assert!(!cached.contains("synthetic-offline-only-password"));
    assert!(
        !status
            .to_string()
            .contains("synthetic-offline-only-password")
    );
    assert!(
        h.store
            .kv_get("offline-mcp", "configuration")
            .unwrap()
            .is_null()
    );
}

#[tokio::test]
async fn shared_cache_epoch_switch_and_flag_tombstones() {
    let h = Harness::new();
    h.configure().await;
    h.backend.batches.lock().unwrap().push_back(batch(100, 1));
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    let ordinary = client();
    let granted = grant(&["mail.read", "mail.sync", "mail.write"]);
    let messages = h
        .call(
            &ordinary,
            &granted,
            "mail.list",
            json!({"account_id":"campus"}),
        )
        .await
        .unwrap();
    assert_eq!(messages["messages"].as_array().unwrap().len(), 1);
    assert!(messages["messages"][0].get("text").is_none());
    let value = h
        .call(
            &ordinary,
            &granted,
            "mail.read",
            json!({"account_id":"campus","uid":1,"uid_validity":100}),
        )
        .await
        .unwrap();
    assert!(value["text"].as_str().unwrap().contains("offline fixture"));
    h.backend.batches.lock().unwrap().push_back(SyncBatch {
        validity: 100,
        next: 2,
        through: 1,
        flags_cursor: 1,
        messages: vec![],
        refreshed: Some(FlagScan {
            start: 1,
            end: 1,
            flags: BTreeMap::new(),
        }),
    });
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    assert!(
        h.owner("mail.list", json!({"account_id":"campus"})).await["messages"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    h.backend.batches.lock().unwrap().push_back(batch(101, 1));
    assert_eq!(
        h.owner("mail.sync", json!({"account_id":"campus"})).await["epoch_changed"],
        true
    );
    assert_eq!(
        h.call(
            &ordinary,
            &granted,
            "mail.read",
            json!({"account_id":"campus","uid":1,"uid_validity":100})
        )
        .await
        .unwrap_err()
        .code,
        "UidValidityChanged"
    );
    let flags = h
        .call(
            &ordinary,
            &granted,
            "mail.set_flags",
            json!({"account_id":"campus","uid":1,"uid_validity":101,"flags":{"seen":true}}),
        )
        .await
        .unwrap();
    assert_eq!(flags["flags"][0], "\\Seen");
    assert!(
        h.call(
            &ordinary,
            &granted,
            "mail.set_flags",
            json!({"account_id":"campus","uid":1,"uid_validity":101,"flags":{"deleted":true}})
        )
        .await
        .is_err()
    );
}

#[tokio::test]
async fn preview_hash_authority_sent_draft_is_immutable_and_receipt_idempotent() {
    let h = Harness::new();
    h.configure().await;
    let ordinary = client();
    let mut granted = grant(&["mail.write", "mail.read", "mail.send"]);
    let draft=h.call(&ordinary,&granted,"mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"subject":"offline","text":"local test only"}})).await.unwrap();
    let id = draft["draft"]["id"].as_str().unwrap();
    let hash = draft["preview_hash"].as_str().unwrap();
    let params = json!({"account_id":"campus","draft_id":id,"preview_hash":hash,"confirm":true});
    assert_eq!(
        h.call(&ordinary, &granted, "mail.send", params.clone())
            .await
            .unwrap_err()
            .code,
        "ApprovalRequired"
    );
    granted
        .action_inputs
        .insert("mail:campus:send".into(), hash.into());
    assert_eq!(
        h.call(&ordinary, &granted, "mail.send", params.clone())
            .await
            .unwrap()["submission"]["state"],
        "sent"
    );
    assert_eq!(
        h.call(&ordinary, &granted, "mail.send", params.clone())
            .await
            .unwrap()["already_submitted"],
        true
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
    let h = h.reopen();
    let list = h
        .owner(
            "mail.draft.list",
            json!({"account_id":"campus","include_body":true}),
        )
        .await;
    assert_eq!(
        list["drafts"][0]["draft"]["content"]["text"],
        "local test only"
    );
    assert_eq!(h.call(&Principal::owner(),&Grant::default(),"mail.draft.save",json!({"account_id":"campus","draft_id":id,"draft":{"to":["recipient@example.invalid"],"subject":"edited","text":"local test only"}})).await.unwrap_err().code,"DraftAlreadySent");
    assert_eq!(
        h.call(&ordinary, &granted, "mail.send", params)
            .await
            .unwrap()["already_submitted"],
        true
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn uncertain_submission_is_persistent_and_never_automatically_retried() {
    let h = Harness::new();
    h.configure().await;
    h.backend.uncertain.store(1, Ordering::SeqCst);
    let draft=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"offline only"}})).await;
    let id = draft["draft"]["id"].as_str().unwrap();
    let params = json!({"account_id":"campus","draft_id":id,"preview_hash":draft["preview_hash"],"confirm":true});
    for _ in 0..2 {
        assert_eq!(
            h.call(
                &Principal::owner(),
                &Grant::default(),
                "mail.send",
                params.clone()
            )
            .await
            .unwrap_err()
            .code,
            "NeedsReconciliation"
        );
    }
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.draft.save",
            json!({"account_id":"campus","draft_id":id,"draft":{"text":"edited"}})
        )
        .await
        .unwrap_err()
        .code,
        "NeedsReconciliation"
    );
    let status = h
        .owner(
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"phase":"status"}),
        )
        .await;
    assert_eq!(status["submission"]["state"], "needs_reconciliation");
    let value=h.owner("mail.send",json!({"account_id":"campus","draft_id":id,"phase":"reconcile","attempt_id":status["submission"]["attempt_id"],"outcome":"sent","confirmed":true,"evidence":"synthetic provider acceptance evidence"})).await;
    assert_eq!(value["retried"], false);
    assert_eq!(
        h.owner("mail.send", params).await["already_submitted"],
        true
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_edited_unsent_draft_requires_a_new_preview_approval() {
    let h = Harness::new();
    h.configure().await;
    let original=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"subject":"original","text":"offline"}})).await;
    let id = original["draft"]["id"].as_str().unwrap();
    let changed=h.owner("mail.draft.save",json!({"account_id":"campus","draft_id":id,"draft":{"to":["recipient@example.invalid"],"subject":"edited","text":"offline"}})).await;
    let mut granted = grant(&["mail.send"]);
    granted.action_inputs.insert(
        "mail:campus:send".into(),
        original["preview_hash"].as_str().unwrap().into(),
    );
    for hash in [&original["preview_hash"], &changed["preview_hash"]] {
        assert_eq!(
            h.call(
                &client(),
                &granted,
                "mail.send",
                json!({"account_id":"campus","draft_id":id,"preview_hash":hash,"confirm":true})
            )
            .await
            .unwrap_err()
            .code,
            "ApprovalRequired"
        );
    }
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn legacy_confirmed_receipts_and_reused_message_ids_remain_deduplicated() {
    use sha2::Digest;
    let h = Harness::new();
    h.configure().await;
    let draft=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"offline legacy receipt fixture"}})).await;
    let id = draft["draft"]["id"].as_str().unwrap();
    let message_id = draft["draft"]["message_id"].as_str().unwrap();
    h.owner("mail.send",json!({"account_id":"campus","draft_id":id,"preview_hash":draft["preview_hash"],"confirm":true})).await;
    // An older cache has only send_active, with no immutable identity indexes.
    let ns = "service:mail:campus";
    h.store.kv_delete(ns, &format!("sent_draft:{id}")).unwrap();
    let hash: String = sha2::Sha256::digest(message_id.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    h.store
        .kv_delete(ns, &format!("sent_message:{hash}"))
        .unwrap();
    let active_key = format!("send_active:{id}");
    let mut legacy = h.store.kv_get(ns, &active_key).unwrap();
    legacy.as_object_mut().unwrap().remove("draft_id");
    h.store.kv_set(ns, &active_key, &legacy).unwrap();
    let h = h.reopen();
    assert_eq!(
        h.owner(
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"confirm":true})
        )
        .await["already_submitted"],
        true
    );
    assert_eq!(
        h.store.kv_get(ns, &format!("sent_draft:{id}")).unwrap()["state"],
        "sent"
    );

    let fresh=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"separate local draft"}})).await;
    let fresh_id = fresh["draft"]["id"].as_str().unwrap();
    // Simulate a legacy imported draft preserving a previously accepted Message-ID.
    let mut imported = fresh["draft"].clone();
    imported["message_id"] = json!(message_id);
    h.store
        .kv_set(ns, &format!("draft:{fresh_id}"), &imported)
        .unwrap();
    let response=h.owner("mail.send",json!({"account_id":"campus","draft_id":fresh_id,"preview_hash":fresh["preview_hash"],"confirm":true})).await;
    assert_eq!(response["already_submitted"], true);
    assert_eq!(response["submission"]["message_id"], message_id);
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn cached_mail_index_and_search_require_mail_read_as_well_as_account_access() {
    let h = Harness::new();
    h.configure().await;
    h.backend.batches.lock().unwrap().push_back(batch(200, 1));
    h.owner("mail.sync", json!({"account_id":"campus"})).await;
    h.store
        .record_upsert(
            "service:campus",
            "campus",
            "courses",
            "visible-course",
            "course",
            &json!({"title":"ordinary course"}),
        )
        .unwrap();
    for principal in [
        client(),
        Principal {
            id: "plugin:offline-reader".into(),
            kind: PrincipalKind::Plugin,
        },
    ] {
        let mut granted = grant(&["sources.read"]);
        let rows = h
            .store
            .records(&principal, &granted, &json!({"account_id":"campus"}), None)
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["kind"], "course");
        for query in [Some("fixture"), Some("fi")] {
            assert!(
                h.store
                    .records(&principal, &granted, &json!({"account_id":"campus"}), query)
                    .unwrap()
                    .is_empty()
            );
        }
        assert!(
            h.store
                .records(
                    &principal,
                    &granted,
                    &json!({"account_id":"campus","kind":"mail.message"}),
                    None
                )
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            h.call(
                &principal,
                &granted,
                "mail.read",
                json!({"account_id":"campus","uid":1,"uid_validity":200})
            )
            .await
            .unwrap_err()
            .code,
            "PermissionDenied"
        );

        granted.capabilities.insert("mail.read".into());
        let rows = h
            .store
            .records(
                &principal,
                &granted,
                &json!({"account_id":"campus","kind":"mail.message"}),
                None,
            )
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert!(
            rows[0]["data"]["text"]
                .as_str()
                .unwrap()
                .contains("offline fixture")
        );
        assert_eq!(
            h.store
                .records(
                    &principal,
                    &granted,
                    &json!({"account_id":"campus"}),
                    Some("fixture")
                )
                .unwrap()
                .len(),
            1
        );
        assert!(
            h.call(
                &principal,
                &granted,
                "mail.read",
                json!({"account_id":"campus","uid":1,"uid_validity":200})
            )
            .await
            .unwrap()["html"]
                .as_str()
                .unwrap()
                .contains("<b>fixture</b>")
        );

        granted.account_ids.clear();
        granted.account_ids.insert("other".into());
        assert!(
            h.store
                .records(&principal, &granted, &json!({"account_id":"campus"}), None)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            h.call(
                &principal,
                &granted,
                "mail.read",
                json!({"account_id":"campus","uid":1,"uid_validity":200})
            )
            .await
            .unwrap_err()
            .code,
            "PermissionDenied"
        );
    }
}

#[tokio::test]
async fn cancellation_leaves_a_durable_submitting_ledger() {
    let h = Harness::new();
    h.configure().await;
    h.backend.uncertain.store(2, Ordering::SeqCst);
    let draft=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"synthetic local fixture"}})).await;
    let id = draft["draft"]["id"].as_str().unwrap();
    let params = json!({"account_id":"campus","draft_id":id,"preview_hash":draft["preview_hash"],"confirm":true});
    let owner = Principal::owner();
    let grant = Grant::default();
    assert!(
        tokio::time::timeout(
            std::time::Duration::from_millis(20),
            h.call(&owner, &grant, "mail.send", params.clone())
        )
        .await
        .is_err()
    );
    let h = h.reopen();
    assert_eq!(
        h.owner(
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"phase":"status"})
        )
        .await["submission"]["state"],
        "submitting"
    );
    assert_eq!(
        h.call(&owner, &grant, "mail.send", params)
            .await
            .unwrap_err()
            .code,
        "NeedsReconciliation"
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn broad_send_authority_does_not_override_an_explicit_input_binding() {
    let h = Harness::new();
    h.configure().await;
    let draft=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"offline"}})).await;
    let params = json!({"account_id":"campus","draft_id":draft["draft"]["id"],"preview_hash":draft["preview_hash"],"confirm":true});
    let mut granted = grant(&["mail.send", "mail.send:any"]);
    let caller = client();
    granted
        .action_inputs
        .insert("mail:send".into(), "0".repeat(64));
    assert_eq!(
        h.call(&caller, &granted, "mail.send", params.clone())
            .await
            .unwrap_err()
            .code,
        "ApprovalRequired"
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 0);
    granted.action_inputs.insert(
        "mail:send".into(),
        draft["preview_hash"].as_str().unwrap().into(),
    );
    assert_eq!(
        h.call(&caller, &granted, "mail.send", params)
            .await
            .unwrap()["submission"]["state"],
        "sent"
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn stored_endpoint_cannot_be_rebound_to_an_existing_secret_key() {
    let h = Harness::new();
    h.configure().await;
    let mut value = h
        .store
        .kv_get("service:mail:campus", "configuration")
        .unwrap();
    value["config"]["imap"]["host"] = json!("different.example.invalid");
    h.store
        .kv_set("service:mail:campus", "configuration", &value)
        .unwrap();
    assert_eq!(
        h.call(
            &client(),
            &grant(&["mail.sync"]),
            "mail.sync",
            json!({"account_id":"campus"})
        )
        .await
        .unwrap_err()
        .code,
        "MailCacheError"
    );
}

mod sync_interruption {
    use super::*;
    use sha2::{Digest, Sha256};
    use tokio::{
        io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt},
        sync::oneshot,
    };

    const OLD_EPOCH: u32 = 401;
    const NEW_EPOCH: u32 = 402;
    const NS: &str = "service:mail:campus";
    type Peer = tokio::io::BufReader<tokio_rustls::server::TlsStream<tokio::net::TcpStream>>;

    #[derive(Clone, Copy)]
    enum Cut {
        DisconnectLiteral,
        CancelLiteral,
        DisconnectFlags,
        FlagsTaggedNo,
        FlagsTaggedBad,
    }
    impl Cut {
        fn at_flags(self) -> bool {
            matches!(
                self,
                Self::DisconnectFlags | Self::FlagsTaggedNo | Self::FlagsTaggedBad
            )
        }
        fn rejection(self) -> Option<&'static str> {
            match self {
                Self::FlagsTaggedNo => Some("NO"),
                Self::FlagsTaggedBad => Some("BAD"),
                _ => None,
            }
        }
    }

    // This harness installs the production NativeBackend directly. It never
    // passes through the mock Backend/batches queue used by other unit tests.
    struct NativeHarness {
        store: Store,
        network: Network,
        vault: Arc<Vault>,
        service: MailService,
        roots: Vec<u8>,
        temp: tempfile::TempDir,
    }
    impl NativeHarness {
        fn new(roots: Vec<u8>) -> Self {
            let temp = tempfile::tempdir().unwrap();
            let store = Store::open(temp.path()).unwrap();
            Self {
                store,
                network: Network::default(),
                vault: Arc::new(Vault::default()),
                service: MailService::with_backend(Arc::new(NativeBackend::with_test_root(
                    roots.clone(),
                ))),
                roots,
                temp,
            }
        }
        async fn call(&self, method: &str, params: Value) -> CoreResult<Value> {
            self.service
                .call(
                    ServiceContext {
                        store: &self.store,
                        network: &self.network,
                        platform: self.vault.as_ref(),
                    },
                    &client(),
                    &grant(&["mail.read", "mail.sync"]),
                    method,
                    params,
                )
                .await
        }
        async fn configure(&self, port: u16) {
            let mut config = config();
            config.imap.host = "localhost".into();
            config.imap.port = port;
            self.service.call(ServiceContext { store: &self.store, network: &self.network, platform: self.vault.as_ref() },
                &Principal::owner(), &Grant::default(), "mail.configure",
                json!({"account_id":"campus","config":config,"credentials":{"password":"synthetic-interruption-only"}})).await.unwrap();
        }
        async fn write_flags(&self, params: Value) -> CoreResult<Value> {
            self.service
                .call(
                    ServiceContext {
                        store: &self.store,
                        network: &self.network,
                        platform: self.vault.as_ref(),
                    },
                    &client(),
                    &grant(&["mail.read", "mail.write"]),
                    "mail.set_flags",
                    params,
                )
                .await
        }
        fn key(&self) -> String {
            let config = self.store.kv_get(NS, "configuration").unwrap();
            Sha256::digest(format!("{}\0INBOX", config["generation"].as_str().unwrap()).as_bytes())
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect()
        }
        fn checkpoint(&self) -> Value {
            self.store
                .kv_get(
                    &format!("checkpoint:service:mail:mail.{}", self.key()),
                    "campus",
                )
                .unwrap()
        }
        fn rows(&self) -> Vec<Value> {
            self.store.records(&Principal::owner(), &Grant::default(),
                &json!({"account_id":"campus","record_owner":"service:mail","source_id":format!("mail.{}",self.key()),"kind":"mail.message","limit":100}), None).unwrap()
        }
        fn reopen(self) -> Self {
            let Self {
                store,
                network: _,
                vault,
                service,
                roots,
                temp,
            } = self;
            drop(service);
            drop(store);
            Self {
                store: Store::open(temp.path()).unwrap(),
                network: Network::default(),
                vault,
                service: MailService::with_backend(Arc::new(NativeBackend::with_test_root(
                    roots.clone(),
                ))),
                roots,
                temp,
            }
        }
    }

    fn message(epoch: u32, uid: u32) -> Vec<u8> {
        format!("From: fixture@example.invalid\r\nTo: reader@example.invalid\r\nSubject: synthetic epoch {epoch} uid {uid}\r\nMessage-ID: <synthetic-{epoch}-{uid}@example.invalid>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nsynthetic epoch={epoch} uid={uid}\r\n").into_bytes()
    }
    fn wire_flags(uid: u32) -> &'static str {
        if uid == 1 { "\\Flagged" } else { "" }
    }
    async fn write_message(io: &mut Peer, epoch: u32, uid: u32, complete: bool) {
        let body = message(epoch, uid);
        io.get_mut()
            .write_all(
                format!(
                    "* {uid} FETCH (UID {uid} FLAGS ({}) RFC822.SIZE {} BODY[]<0> {{{}}}\r\n",
                    wire_flags(uid),
                    body.len(),
                    body.len()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        io.get_mut()
            .write_all(if complete {
                &body
            } else {
                &body[..body.len() / 2]
            })
            .await
            .unwrap();
        if complete {
            io.get_mut().write_all(b")\r\n").await.unwrap();
        }
    }

    struct Script {
        port: u16,
        roots: Vec<u8>,
        partial: oneshot::Receiver<()>,
        closed: oneshot::Receiver<()>,
        task: tokio::task::JoinHandle<()>,
        commands: Arc<Mutex<Vec<(usize, String)>>>,
    }
    async fn server(cut: Cut, changed_epoch: bool) -> Script {
        assert!(!changed_epoch || !cut.at_flags());
        let (roots, tls) = test_tls();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let commands = Arc::new(Mutex::new(Vec::new()));
        let trace = commands.clone();
        let (partial, receiver) = oneshot::channel();
        let mut partial = Some(partial);
        let (closed, closed_receiver) = oneshot::channel();
        let mut closed = Some(closed);
        let task = tokio::spawn(async move {
            // Seed -> interrupted batch -> retry after reopen -> no-new-data sync.
            for session in 0..4 {
                let (tcp, peer) = listener.accept().await.unwrap();
                assert!(peer.ip().is_loopback());
                let mut io = tokio::io::BufReader::new(tls.accept(tcp).await.unwrap());
                io.get_mut()
                    .write_all(b"* OK synthetic interruption TLS IMAP\r\n")
                    .await
                    .unwrap();
                let epoch = if session == 0 || !changed_epoch {
                    OLD_EPOCH
                } else {
                    NEW_EPOCH
                };
                let last = if session == 0 {
                    1
                } else if changed_epoch {
                    2
                } else {
                    3
                };
                let range = match session {
                    0 => Some((1, 1)),
                    1 | 2 => Some((if changed_epoch { 1 } else { 2 }, last)),
                    _ => None,
                };
                let flag_range = match session {
                    0 => None,
                    1 if cut.at_flags() => Some((1, 1)),
                    2 if !changed_epoch => Some((1, 1)),
                    3 => Some((1, last)),
                    _ => None,
                };
                let mut authenticated = false;
                let mut examined = false;
                let mut body_fetch = false;
                let mut flag_fetch = false;
                let mut line = String::new();
                loop {
                    line.clear();
                    assert!(
                        io.read_line(&mut line).await.unwrap() > 0,
                        "fixture client left before completing its script"
                    );
                    let (tag, command) = line.trim_end().split_once(' ').unwrap();
                    if command.starts_with("LOGIN ") {
                        assert!(!authenticated);
                        authenticated = true;
                        // LOGIN and credential bytes are deliberately not recorded.
                        io.get_mut()
                            .write_all(format!("{tag} OK authenticated\r\n").as_bytes())
                            .await
                            .unwrap();
                    } else {
                        assert!(authenticated);
                        trace.lock().unwrap().push((session, command.to_owned()));
                        if command.starts_with("EXAMINE ") {
                            assert!(!examined);
                            examined = true;
                            io.get_mut().write_all(format!("* {last} EXISTS\r\n* FLAGS (\\Seen \\Flagged)\r\n* OK [UIDVALIDITY {epoch}] epoch\r\n* OK [UIDNEXT {}] next\r\n{tag} OK [READ-ONLY] selected\r\n", last+1).as_bytes()).await.unwrap();
                        } else if command.starts_with("UID FETCH ") {
                            assert!(examined);
                            if command.contains("BODY.") {
                                assert!(!body_fetch);
                                body_fetch = true;
                                let (start, end) = range.expect("no body fetch expected on repeat");
                                assert_eq!(
                                    command,
                                    format!(
                                        "UID FETCH {start}:{end} (UID FLAGS RFC822.SIZE BODY.PEEK[]<0.{MAX_RAW_BYTES}>)"
                                    )
                                );
                                for uid in start..=end {
                                    let cut_literal = session == 1 && !cut.at_flags() && uid == end;
                                    write_message(&mut io, epoch, uid, !cut_literal).await;
                                    if cut_literal {
                                        // The first FETCH literal/closing ')' is complete;
                                        // the second literal is announced but only half sent.
                                        assert!(uid > start);
                                        io.get_mut().flush().await.unwrap();
                                        let _ = partial.take().unwrap().send(());
                                        if matches!(cut, Cut::CancelLiteral) {
                                            let mut byte = [0u8; 1];
                                            match tokio::time::timeout(
                                                std::time::Duration::from_secs(5),
                                                io.read(&mut byte),
                                            )
                                            .await
                                            .unwrap()
                                            {
                                                Ok(0) => {}
                                                Err(error)
                                                    if matches!(
                                                        error.kind(),
                                                        std::io::ErrorKind::UnexpectedEof
                                                            | std::io::ErrorKind::ConnectionReset
                                                    ) => {}
                                                _ => panic!(
                                                    "cancel must close the pending TLS stream"
                                                ),
                                            }
                                        } else {
                                            let _ = io.get_mut().shutdown().await;
                                        }
                                        let _ = closed.take().unwrap().send(());
                                        break;
                                    }
                                }
                                if session == 1 && !cut.at_flags() {
                                    break;
                                }
                                io.get_mut()
                                    .write_all(
                                        format!("{tag} OK complete body window\r\n").as_bytes(),
                                    )
                                    .await
                                    .unwrap();
                            } else {
                                assert!(!flag_fetch);
                                flag_fetch = true;
                                let (start, end) = flag_range.expect("unexpected flags scan");
                                assert_eq!(command, format!("UID FETCH {start}:{end} (UID FLAGS)"));
                                if session == 1 {
                                    if let Some(status) = cut.rejection() {
                                        // A real negative completion on a live TLS
                                        // connection. Wait for LOGOUT instead of EOF,
                                        // so transport failure cannot explain rejection.
                                        io.get_mut()
                                            .write_all(
                                                format!(
                                                    "{tag} {status} synthetic FLAGS rejection\r\n"
                                                )
                                                .as_bytes(),
                                            )
                                            .await
                                            .unwrap();
                                        io.get_mut().flush().await.unwrap();
                                        let _ = partial.take().unwrap().send(());
                                        continue;
                                    }
                                    assert!(matches!(cut, Cut::DisconnectFlags));
                                    // Both new bodies are complete, but this old-UID
                                    // FLAGS scan gets EOF before any response/tagged OK.
                                    // UID 1 still exists with its unchanged server flags.
                                    io.get_mut().flush().await.unwrap();
                                    let _ = partial.take().unwrap().send(());
                                    let _ = io.get_mut().shutdown().await;
                                    let _ = closed.take().unwrap().send(());
                                    break;
                                }
                                for uid in start..=end {
                                    io.get_mut()
                                        .write_all(
                                            format!(
                                                "* {uid} FETCH (UID {uid} FLAGS ({}))\r\n",
                                                wire_flags(uid)
                                            )
                                            .as_bytes(),
                                        )
                                        .await
                                        .unwrap();
                                }
                                io.get_mut()
                                    .write_all(format!("{tag} OK flags observed\r\n").as_bytes())
                                    .await
                                    .unwrap();
                            }
                        } else if command == "LOGOUT" {
                            assert_eq!(body_fetch, range.is_some());
                            assert_eq!(flag_fetch, flag_range.is_some());
                            io.get_mut()
                                .write_all(
                                    format!("* BYE fixture closed\r\n{tag} OK logout\r\n")
                                        .as_bytes(),
                                )
                                .await
                                .unwrap();
                            io.get_mut().flush().await.unwrap();
                            if session == 1 && cut.rejection().is_some() {
                                let _ = closed.take().unwrap().send(());
                            }
                            break;
                        } else {
                            panic!(
                                "IMAP fixture accepts only EXAMINE, UID FETCH PEEK/FLAGS and LOGOUT; no SELECT/STORE/EXPUNGE"
                            );
                        }
                    }
                    io.get_mut().flush().await.unwrap();
                }
            }
        });
        Script {
            port,
            roots,
            partial: receiver,
            closed: closed_receiver,
            task,
            commands,
        }
    }

    async fn listed(h: &NativeHarness) -> Value {
        h.call("mail.list", json!({"account_id":"campus"}))
            .await
            .unwrap()
    }
    async fn assert_old_boundary(
        h: &NativeHarness,
        checkpoint: &Value,
        rows: &[Value],
        attempted_epoch: u32,
        attempted_uid: u32,
    ) {
        assert_eq!(&h.checkpoint(), checkpoint);
        assert_eq!(h.rows(), rows);
        let messages = listed(h).await;
        assert_eq!(messages["uid_validity"], OLD_EPOCH);
        assert_eq!(messages["messages"].as_array().unwrap().len(), 1);
        assert_eq!(messages["messages"][0]["uid"], 1);
        assert_eq!(messages["messages"][0]["flags"], json!(["\\Flagged"]));
        let existing = h
            .call(
                "mail.read",
                json!({"account_id":"campus","uid_validity":OLD_EPOCH,"uid":1}),
            )
            .await
            .unwrap();
        assert!(
            existing["text"]
                .as_str()
                .unwrap()
                .contains("epoch=401 uid=1")
        );
        let forbidden = h
            .call(
                "mail.read",
                json!({"account_id":"campus","uid_validity":attempted_epoch,"uid":attempted_uid}),
            )
            .await
            .unwrap_err();
        assert_eq!(
            forbidden.code,
            if attempted_epoch == OLD_EPOCH {
                "NotFound"
            } else {
                "UidValidityChanged"
            }
        );
        assert!(
            h.store
                .kv_get(
                    NS,
                    &format!("message:{}:{attempted_epoch}:{attempted_uid}", h.key())
                )
                .unwrap()
                .is_null()
        );
    }

    async fn exercise(cut: Cut, changed_epoch: bool) {
        let Script {
            port,
            roots,
            partial,
            closed,
            task,
            commands,
        } = server(cut, changed_epoch).await;
        let h = NativeHarness::new(roots);
        h.configure(port).await;
        let seed = h
            .call("mail.sync", json!({"account_id":"campus","window":16}))
            .await
            .unwrap();
        assert_eq!(seed["scanned_through"], 1);
        assert_eq!(seed["uid_validity"], OLD_EPOCH);
        let checkpoint = h.checkpoint();
        let rows = h.rows();
        assert_eq!(rows.len(), 1);
        let epoch = if changed_epoch { NEW_EPOCH } else { OLD_EPOCH };
        let first_new = if changed_epoch { 1 } else { 2 };
        if matches!(cut, Cut::CancelLiteral) {
            {
                let operation = h.call("mail.sync", json!({"account_id":"campus","window":16}));
                tokio::pin!(operation);
                tokio::select! { result = &mut operation => panic!("sync returned before the incomplete literal barrier: {}", result.is_ok()),
                reached = partial => reached.unwrap() }
                assert!(futures_util::poll!(&mut operation).is_pending());
                assert_eq!(h.checkpoint(), checkpoint);
                assert_eq!(h.rows(), rows);
                // Drop the actual MailService/NativeBackend future while its
                // real TLS literal is pending, not a mock scheduler token.
            }
        } else {
            let result = h
                .call("mail.sync", json!({"account_id":"campus","window":16}))
                .await;
            if result.is_ok() {
                let visible = listed(&h).await;
                let seed = h
                    .call(
                        "mail.read",
                        json!({"account_id":"campus","uid_validity":OLD_EPOCH,"uid":1}),
                    )
                    .await
                    .unwrap();
                panic!(
                    "incomplete IMAP batch was committed: scanned_before={}, scanned_after={}, source_rows={}, visible_messages={}, seed_deleted_remotely={}",
                    checkpoint["scanned_through"],
                    h.checkpoint()["scanned_through"],
                    h.rows().len(),
                    visible["messages"].as_array().unwrap().len(),
                    seed["deleted_remotely"]
                );
            }
            let error = result.unwrap_err();
            assert_eq!(error.code, "MailProtocolError");
        }
        tokio::time::timeout(std::time::Duration::from_secs(5), closed)
            .await
            .unwrap()
            .unwrap();
        assert_old_boundary(&h, &checkpoint, &rows, epoch, first_new).await;
        let h = h.reopen(); // Retain only this synthetic external vault; no reconfigure.
        assert_old_boundary(&h, &checkpoint, &rows, epoch, first_new).await;
        let recovered = h
            .call("mail.sync", json!({"account_id":"campus","window":16}))
            .await
            .unwrap();
        assert_eq!(recovered["fetched"], 2);
        assert_eq!(recovered["epoch_changed"], changed_epoch);
        let through = if changed_epoch { 2 } else { 3 };
        assert_eq!(h.checkpoint()["scanned_through"], through);
        assert_eq!(h.checkpoint()["uid_validity"], epoch);
        assert_eq!(h.checkpoint()["uid_next"], through + 1);
        let current = listed(&h).await;
        let current_uids: std::collections::BTreeSet<_> = current["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["uid"].as_u64().unwrap())
            .collect();
        assert_eq!(current_uids, (1..=through).collect());
        assert_eq!(
            current["messages"].as_array().unwrap().len(),
            through as usize
        );
        for uid in 1..=through {
            let mail = h
                .call(
                    "mail.read",
                    json!({"account_id":"campus","uid_validity":epoch,"uid":uid}),
                )
                .await
                .unwrap();
            assert!(
                mail["text"]
                    .as_str()
                    .unwrap()
                    .contains(&format!("epoch={epoch} uid={uid}"))
            );
            assert!(
                !mail["flags"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|flag| flag == "\\Seen")
            );
        }
        let committed = h.rows();
        assert_eq!(committed.len(), 3); // Old epoch row is archived, never deleted.
        let identities: std::collections::BTreeSet<_> = committed
            .iter()
            .map(|row| {
                (
                    row["data"]["uid_validity"].as_u64().unwrap(),
                    row["data"]["uid"].as_u64().unwrap(),
                )
            })
            .collect();
        assert_eq!(identities.len(), committed.len());
        assert_eq!(
            identities
                .iter()
                .filter(|(validity, _)| *validity == u64::from(epoch))
                .count(),
            through as usize
        );
        if changed_epoch {
            assert!(identities.contains(&(u64::from(OLD_EPOCH), 1)));
            assert_eq!(
                h.call(
                    "mail.read",
                    json!({"account_id":"campus","uid_validity":OLD_EPOCH,"uid":1})
                )
                .await
                .unwrap_err()
                .code,
                "UidValidityChanged"
            );
        }
        let repeated = h
            .call("mail.sync", json!({"account_id":"campus","window":16}))
            .await
            .unwrap();
        assert_eq!(repeated["fetched"], 0);
        assert_eq!(repeated["scanned_through"], through);
        assert_eq!(h.rows().len(), committed.len());
        assert_eq!(
            listed(&h).await["messages"].as_array().unwrap().len(),
            through as usize
        );
        tokio::time::timeout(std::time::Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap();
        let trace = commands.lock().unwrap();
        assert_eq!(
            trace
                .iter()
                .filter(|(_, v)| v.starts_with("EXAMINE "))
                .count(),
            4
        );
        let body_queries: Vec<_> = trace
            .iter()
            .filter(|(_, v)| v.contains("BODY.PEEK[]"))
            .collect();
        assert_eq!(body_queries.len(), 3);
        assert_eq!(body_queries[1].1, body_queries[2].1);
        if cut.rejection().is_some() {
            let rejected_session: Vec<_> = trace
                .iter()
                .filter(|(session, _)| *session == 1)
                .map(|(_, command)| command.as_str())
                .collect();
            assert_eq!(rejected_session.last(), Some(&"LOGOUT"));
            assert_eq!(
                rejected_session
                    .iter()
                    .filter(|command| **command == "LOGOUT")
                    .count(),
                1
            );
        }
        assert!(trace.iter().all(|(_, v)| v.starts_with("EXAMINE ")
            || v.starts_with("UID FETCH ")
            || v == "LOGOUT"));
        assert!(trace.iter().all(|(_, v)| !v.contains("STORE")
            && !v.contains("BODY[]")
            && !v.contains("SELECT")
            && !v.contains("EXPUNGE")));
    }

    #[tokio::test]
    async fn literal_disconnect_keeps_old_commit_and_reopens_without_skips_or_duplicates() {
        exercise(Cut::DisconnectLiteral, false).await;
    }
    #[tokio::test]
    async fn cancelled_pending_tls_sync_keeps_old_commit_and_reopens_without_skips() {
        exercise(Cut::CancelLiteral, false).await;
    }
    #[tokio::test]
    async fn epoch_change_disconnect_does_not_publish_new_epoch_until_retry_commits() {
        exercise(Cut::DisconnectLiteral, true).await;
    }
    #[tokio::test]
    async fn interrupted_flag_refresh_does_not_commit_already_received_new_messages() {
        exercise(Cut::DisconnectFlags, false).await;
    }
    #[tokio::test]
    async fn flags_tagged_no_keeps_commit_boundary_and_recovers_after_restart() {
        exercise(Cut::FlagsTaggedNo, false).await;
    }
    #[tokio::test]
    async fn flags_tagged_bad_keeps_commit_boundary_and_recovers_after_restart() {
        exercise(Cut::FlagsTaggedBad, false).await;
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum StoreAck {
        Ok,
        No,
        Bad,
        Eof,
    }

    #[tokio::test]
    async fn real_tls_uid_store_ack_controls_readback_and_persistent_reconciliation() {
        for ack in [StoreAck::Ok, StoreAck::No, StoreAck::Bad, StoreAck::Eof] {
            let (roots, tls) = test_tls();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let transcript = Arc::new(Mutex::new(Vec::<(usize, String)>::new()));
            let trace = transcript.clone();
            let remote_seen = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let server_seen = remote_seen.clone();
            let (wire_done, wire_completed) = oneshot::channel();
            let (finish, finished) = oneshot::channel();
            let server = tokio::spawn(async move {
                // A real read-only seed sync, followed by one flag-write session.
                for session in 0..2 {
                    let (tcp, peer) = listener.accept().await.unwrap();
                    assert!(peer.ip().is_loopback());
                    let mut io = tokio::io::BufReader::new(tls.accept(tcp).await.unwrap());
                    io.get_mut()
                        .write_all(b"* OK synthetic STORE acknowledgement fixture\r\n")
                        .await
                        .unwrap();
                    let mut authenticated = false;
                    let mut selected = false;
                    let mut stored = false;
                    let mut fetched = false;
                    let mut line = String::new();
                    loop {
                        line.clear();
                        assert!(
                            io.read_line(&mut line).await.unwrap() > 0,
                            "STORE fixture session ended before expected commands"
                        );
                        let (tag, command) = line.trim_end().split_once(' ').unwrap();
                        if command.starts_with("LOGIN ") {
                            assert!(!authenticated);
                            authenticated = true;
                            // Do not retain or print credential-bearing commands.
                            io.get_mut()
                                .write_all(format!("{tag} OK authenticated\r\n").as_bytes())
                                .await
                                .unwrap();
                        } else {
                            assert!(authenticated);
                            trace.lock().unwrap().push((session, command.to_owned()));
                            if (session == 0 && command.starts_with("EXAMINE "))
                                || (session == 1 && command.starts_with("SELECT "))
                            {
                                assert!(!selected);
                                selected = true;
                                let access = if session == 0 {
                                    "READ-ONLY"
                                } else {
                                    "READ-WRITE"
                                };
                                io.get_mut().write_all(format!("* 1 EXISTS\r\n* FLAGS (\\Seen \\Flagged)\r\n* OK [UIDVALIDITY {OLD_EPOCH}] epoch\r\n* OK [UIDNEXT 2] next\r\n{tag} OK [{access}] selected\r\n").as_bytes()).await.unwrap();
                            } else if command.starts_with("UID STORE ") {
                                assert_eq!(session, 1);
                                assert!(selected);
                                assert!(
                                    !stored,
                                    "must not repeat STORE after a missing/rejected acknowledgement"
                                );
                                assert_eq!(command, "UID STORE 1 +FLAGS.SILENT (\\Seen)");
                                stored = true;
                                if matches!(ack, StoreAck::Ok | StoreAck::Eof) {
                                    server_seen.store(true, Ordering::SeqCst);
                                }
                                if ack == StoreAck::Eof {
                                    // Server applied the flag, but its acknowledgement is lost.
                                    let _ = io.get_mut().shutdown().await;
                                    break;
                                }
                                let status = match ack {
                                    StoreAck::Ok => "OK",
                                    StoreAck::No => "NO",
                                    StoreAck::Bad => "BAD",
                                    StoreAck::Eof => unreachable!(),
                                };
                                io.get_mut()
                                    .write_all(
                                        format!("{tag} {status} synthetic STORE outcome\r\n")
                                            .as_bytes(),
                                    )
                                    .await
                                    .unwrap();
                            } else if command.starts_with("UID FETCH ") {
                                assert!(selected);
                                assert!(!fetched, "no repeated FETCH/read-back command");
                                fetched = true;
                                if session == 0 {
                                    assert_eq!(
                                        command,
                                        format!(
                                            "UID FETCH 1:1 (UID FLAGS RFC822.SIZE BODY.PEEK[]<0.{MAX_RAW_BYTES}>)"
                                        )
                                    );
                                    write_message(&mut io, OLD_EPOCH, 1, true).await;
                                } else {
                                    assert!(stored);
                                    assert_eq!(
                                        ack,
                                        StoreAck::Ok,
                                        "read-back is allowed only after a positive STORE completion"
                                    );
                                    assert_eq!(command, "UID FETCH 1 (UID FLAGS)");
                                    io.get_mut()
                                        .write_all(
                                            b"* 1 FETCH (UID 1 FLAGS (\\Flagged \\Seen))\r\n",
                                        )
                                        .await
                                        .unwrap();
                                }
                                io.get_mut()
                                    .write_all(format!("{tag} OK fetched\r\n").as_bytes())
                                    .await
                                    .unwrap();
                            } else if command == "LOGOUT" {
                                if session == 0 {
                                    assert!(fetched);
                                    assert!(!stored);
                                } else {
                                    assert!(stored);
                                    assert_eq!(fetched, ack == StoreAck::Ok);
                                }
                                io.get_mut()
                                    .write_all(
                                        format!("* BYE fixture closed\r\n{tag} OK logout\r\n")
                                            .as_bytes(),
                                    )
                                    .await
                                    .unwrap();
                                io.get_mut().flush().await.unwrap();
                                break;
                            } else {
                                panic!("unexpected command in isolated UID STORE fixture");
                            }
                        }
                        io.get_mut().flush().await.unwrap();
                    }
                }
                let _ = wire_done.send(());
                // Keep listening through the explicit repeat and Store reopen.
                // Any transport reconnect/retry is an observable test failure.
                tokio::select! {
                    _ = finished => {},
                    _ = listener.accept() => panic!("unexpected IMAP reconnect/retry after STORE outcome"),
                }
            });
            let h = NativeHarness::new(roots);
            h.configure(port).await;
            h.call("mail.sync", json!({"account_id":"campus"}))
                .await
                .unwrap();
            let checkpoint = h.checkpoint();
            let original_rows = h.rows();
            let request = json!({"account_id":"campus","uid_validity":OLD_EPOCH,"uid":1,"flags":{"seen":true}});
            let result = h.write_flags(request.clone()).await;
            tokio::time::timeout(std::time::Duration::from_secs(5), wire_completed)
                .await
                .unwrap()
                .unwrap();
            let pending_key = format!("flags_pending:{}:{OLD_EPOCH}:1", h.key());
            if ack == StoreAck::Ok {
                let value = result.unwrap();
                assert!(
                    value["flags"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|flag| flag == "\\Seen")
                );
                assert_eq!(
                    h.store.kv_get(NS, &pending_key).unwrap()["state"],
                    "observed"
                );
                assert_eq!(h.checkpoint(), checkpoint);
                let cached = h
                    .call(
                        "mail.read",
                        json!({"account_id":"campus","uid_validity":OLD_EPOCH,"uid":1}),
                    )
                    .await
                    .unwrap();
                assert!(
                    cached["flags"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|flag| flag == "\\Seen")
                );
                assert_eq!(h.rows().len(), 1);
            } else {
                assert_eq!(result.unwrap_err().code, "NeedsReconciliation", "{ack:?}");
                assert_eq!(
                    h.store.kv_get(NS, &pending_key).unwrap()["state"],
                    "needs_reconciliation"
                );
                assert_eq!(h.rows(), original_rows);
                assert_eq!(
                    h.write_flags(request.clone()).await.unwrap_err().code,
                    "NeedsReconciliation"
                );
                let h = h.reopen();
                assert_eq!(
                    h.store.kv_get(NS, &pending_key).unwrap()["state"],
                    "needs_reconciliation"
                );
                assert_eq!(
                    h.write_flags(request).await.unwrap_err().code,
                    "NeedsReconciliation"
                );
                assert_eq!(h.checkpoint(), checkpoint);
                assert_eq!(h.rows(), original_rows);
            }
            assert_eq!(
                remote_seen.load(Ordering::SeqCst),
                matches!(ack, StoreAck::Ok | StoreAck::Eof)
            );
            finish.send(()).unwrap();
            tokio::time::timeout(std::time::Duration::from_secs(5), server)
                .await
                .unwrap()
                .unwrap();
            let trace = transcript.lock().unwrap();
            let writes: Vec<_> = trace
                .iter()
                .filter(|(session, _)| *session == 1)
                .map(|(_, cmd)| cmd.as_str())
                .collect();
            assert_eq!(
                writes
                    .iter()
                    .filter(|cmd| cmd.starts_with("UID STORE "))
                    .count(),
                1
            );
            assert_eq!(
                writes
                    .iter()
                    .filter(|cmd| cmd.starts_with("UID FETCH "))
                    .count(),
                usize::from(ack == StoreAck::Ok)
            );
            if ack != StoreAck::Eof {
                assert_eq!(writes.last(), Some(&"LOGOUT"));
            }
        }
    }
}

fn test_tls() -> (Vec<u8>, tokio_rustls::TlsAcceptor) {
    let generated = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let der = generated.cert.der().to_vec();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(generated.signing_key.serialize_der());
    let server = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(
        vec![rustls::pki_types::CertificateDer::from(der.clone())],
        key.into(),
    )
    .unwrap();
    (der, tokio_rustls::TlsAcceptor::from(Arc::new(server)))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_tls_imap_folder_list_partial_fetch_and_read_only_uid_sync() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let (der, tls) = test_tls();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut io = tokio::io::BufReader::new(tls.accept(tcp).await.unwrap());
            io.get_mut()
                .write_all(b"* OK offline TLS IMAP fixture\r\n")
                .await
                .unwrap();
            let mut authenticated = false;
            let mut line = String::new();
            loop {
                line.clear();
                match io.read_line(&mut line).await {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
                    Err(_) => panic!("IMAP fixture read failed"),
                }
                let (tag, command) = line.trim_end().split_once(' ').unwrap();
                let response = if command.starts_with("LOGIN ") {
                    authenticated = true;
                    format!("{tag} OK authenticated\r\n")
                } else {
                    assert!(
                        authenticated,
                        "protocol commands require synthetic authentication"
                    );
                    if command == "LOGOUT" {
                        format!("* BYE fixture closed\r\n{tag} OK logout\r\n")
                    } else if command.starts_with("LIST ") {
                        format!("* LIST () \"/\" \"INBOX\"\r\n{tag} OK folders\r\n")
                    } else if command.starts_with("EXAMINE ") {
                        format!(
                            "* FLAGS (\\Seen \\Flagged)\r\n* 1 EXISTS\r\n* OK [UIDVALIDITY 909] epoch\r\n* OK [UIDNEXT 2] next\r\n{tag} OK [READ-ONLY] selected\r\n"
                        )
                    } else if command.starts_with("UID FETCH ") {
                        assert!(command.contains("1:1"));
                        assert!(command.contains("BODY.PEEK[]<0.1048576>"));
                        let prefix = format!(
                            "* 1 FETCH (UID 1 FLAGS (\\Seen) RFC822.SIZE {} BODY[]<0> {{{}}}\r\n",
                            MIME.len(),
                            MIME.len()
                        );
                        io.get_mut().write_all(prefix.as_bytes()).await.unwrap();
                        io.get_mut().write_all(MIME).await.unwrap();
                        format!(")\r\n{tag} OK fetched\r\n")
                    } else {
                        panic!(
                            "unexpected IMAP operation; fixture permits only read-only protocol commands"
                        )
                    }
                };
                io.get_mut().write_all(response.as_bytes()).await.unwrap();
                io.get_mut().flush().await.unwrap();
            }
        }
    });
    let backend = NativeBackend::with_test_root(der);
    let mut config = config();
    config.imap.host = "localhost".into();
    config.imap.port = port;
    let secret = MailCredentials {
        imap_password: "synthetic-loopback-only".into(),
        smtp_password: "synthetic-loopback-only".into(),
    };
    let folders = backend.folders(&config, &secret).await.unwrap();
    assert_eq!(folders[0].name, "INBOX");
    let batch = backend
        .sync(&config, &secret, "INBOX", &FolderState::default(), 16)
        .await
        .unwrap();
    assert_eq!(batch.validity, 909);
    assert_eq!(batch.through, 1);
    assert_eq!(batch.messages.len(), 1);
    assert!(batch.messages[0].raw == MIME);
    assert_eq!(batch.messages[0].flags, ["\\Seen"]);
    tokio::time::timeout(std::time::Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();
}

async fn imap_attachment_fixture(
    raw: Vec<u8>,
    size: u32,
    validity: u32,
    requested_validity: u32,
) -> (CoreResult<RawMail>, usize) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let (der, tls) = test_tls();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let bodies = Arc::new(AtomicUsize::new(0));
    let requests = bodies.clone();
    let server = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut io = tokio::io::BufReader::new(tls.accept(tcp).await.unwrap());
        io.get_mut()
            .write_all(b"* OK offline attachment IMAP\r\n")
            .await
            .unwrap();
        let mut authenticated = false;
        let mut examined = false;
        let mut line = String::new();
        loop {
            line.clear();
            match io.read_line(&mut line).await {
                Ok(0) => break,
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(_) => panic!("attachment IMAP fixture read failed"),
            }
            let (tag, command) = line.trim_end().split_once(' ').unwrap();
            let response = if command.starts_with("LOGIN ") {
                authenticated = true;
                format!("{tag} OK authenticated\r\n")
            } else {
                assert!(authenticated);
                if command == "LOGOUT" {
                    format!("* BYE closed\r\n{tag} OK logout\r\n")
                } else if command.starts_with("EXAMINE ") {
                    examined = true;
                    format!(
                        "* 1 EXISTS\r\n* OK [UIDVALIDITY {validity}] epoch\r\n* OK [UIDNEXT 2] next\r\n{tag} OK [READ-ONLY] selected\r\n"
                    )
                } else if command == "UID FETCH 1 (UID RFC822.SIZE)" {
                    assert!(examined);
                    format!("* 1 FETCH (UID 1 RFC822.SIZE {size})\r\n{tag} OK size\r\n")
                } else if command
                    == format!(
                        "UID FETCH 1 (UID FLAGS RFC822.SIZE BODY.PEEK[]<0.{MAX_ATTACHMENT_RAW_BYTES}>)"
                    )
                {
                    assert!(examined);
                    requests.fetch_add(1, Ordering::SeqCst);
                    let prefix = format!(
                        "* 1 FETCH (UID 1 FLAGS () RFC822.SIZE {size} BODY[]<0> {{{}}}\r\n",
                        raw.len()
                    );
                    io.get_mut().write_all(prefix.as_bytes()).await.unwrap();
                    io.get_mut().write_all(&raw).await.unwrap();
                    format!(")\r\n{tag} OK attachment\r\n")
                } else {
                    panic!(
                        "fixture rejects SELECT, BODY[], STORE and every non-read-only operation"
                    )
                }
            };
            if io.get_mut().write_all(response.as_bytes()).await.is_err() {
                break;
            }
            if io.get_mut().flush().await.is_err() {
                break;
            }
        }
    });
    let backend = NativeBackend::with_test_root(der);
    let mut config = config();
    config.imap.host = "localhost".into();
    config.imap.port = port;
    let credentials = MailCredentials {
        imap_password: "synthetic-loopback-only".into(),
        smtp_password: "synthetic-loopback-only".into(),
    };
    let result = backend
        .attachment_message(&config, &credentials, "INBOX", requested_validity, 1)
        .await;
    tokio::time::timeout(std::time::Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();
    (result, bodies.load(Ordering::SeqCst))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_tls_attachment_peek_download_exceeds_sync_prefix_without_marking_seen() {
    let bytes = vec![213; 900 * 1024];
    let raw = binary_mime(&bytes);
    assert!(raw.len() > MAX_RAW_BYTES);
    let (result, bodies) = imap_attachment_fixture(raw.clone(), raw.len() as u32, 991, 991).await;
    let mail = result.ok().unwrap();
    assert!(mail.flags.is_empty());
    assert_eq!(mail.raw, raw);
    let (_, decoded) = mime::attachment(&mail.raw, mail.size, 0).unwrap();
    assert_eq!(decoded, bytes);
    assert_eq!(bodies, 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_tls_attachment_refuses_epoch_changes_oversize_and_truncation() {
    let (changed, bodies) =
        imap_attachment_fixture(MIME.to_vec(), MIME.len() as u32, 992, 991).await;
    assert_eq!(changed.err().unwrap().code, "UidValidityChanged");
    assert_eq!(bodies, 0);
    let (oversized, bodies) =
        imap_attachment_fixture(Vec::new(), MAX_ATTACHMENT_RAW_BYTES as u32 + 1, 991, 991).await;
    assert_eq!(oversized.err().unwrap().code, "MailLimitExceeded");
    assert_eq!(bodies, 0);
    let (truncated, bodies) =
        imap_attachment_fixture(MIME[..100].to_vec(), MIME.len() as u32, 991, 991).await;
    assert_eq!(truncated.err().unwrap().code, "MailAttachmentIncomplete");
    assert_eq!(bodies, 1);
}

#[tokio::test]
async fn outgoing_attachment_per_file_total_and_count_limits_precede_smtp() {
    let h = Harness::new();
    h.configure().await;
    let oversized = managed_attachment(
        &h,
        vec![5; MAX_ATTACHMENT_BYTES + 1],
        "campus",
        "fixture.attachments",
    )
    .await;
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.draft.save",
            attachment_draft(&oversized)
        )
        .await
        .unwrap_err()
        .code,
        "MailLimitExceeded"
    );
    let asset = managed_attachment(
        &h,
        vec![6; 3 * 1024 * 1024],
        "campus",
        "fixture.attachments",
    )
    .await;
    let mut input = attachment_draft(&asset);
    let item = input["draft"]["attachments"][0].clone();
    input["draft"]["attachments"] = json!(vec![item.clone(); 3]);
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.draft.save",
            input.clone()
        )
        .await
        .unwrap_err()
        .code,
        "MailLimitExceeded"
    );
    input["draft"]["attachments"] = json!(vec![item; MAX_ATTACHMENTS + 1]);
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.draft.save",
            input
        )
        .await
        .unwrap_err()
        .code,
        "InvalidInput"
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 0);
}

async fn smtp_server(
    drop_after_data: bool,
    mode: TlsMode,
) -> (u16, Vec<u8>, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let (der, tls) = test_tls();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let accepted = Arc::new(AtomicUsize::new(0));
    let count = accepted.clone();
    let server = tokio::spawn(async move {
        let (mut tcp, _) = listener.accept().await.unwrap();
        if mode == TlsMode::Starttls {
            let mut plain = tokio::io::BufReader::new(tcp);
            plain
                .get_mut()
                .write_all(b"220 localhost STARTTLS fixture\r\n")
                .await
                .unwrap();
            let mut command = String::new();
            plain.read_line(&mut command).await.unwrap();
            assert!(command.starts_with("EHLO "));
            plain
                .get_mut()
                .write_all(b"250-localhost\r\n250 STARTTLS\r\n")
                .await
                .unwrap();
            command.clear();
            plain.read_line(&mut command).await.unwrap();
            assert_eq!(command, "STARTTLS\r\n");
            plain
                .get_mut()
                .write_all(b"220 ready for TLS\r\n")
                .await
                .unwrap();
            tcp = plain.into_inner();
        }
        let Ok(stream) = tls.accept(tcp).await else {
            return;
        };
        let mut io = tokio::io::BufReader::new(stream);
        if mode == TlsMode::Implicit {
            io.get_mut()
                .write_all(b"220 localhost offline TLS SMTP\r\n")
                .await
                .unwrap();
        }
        let mut line = String::new();
        let mut challenge = false;
        let mut authenticated = false;
        loop {
            line.clear();
            match io.read_line(&mut line).await {
                Ok(0) => break,
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(_) => panic!("SMTP fixture read failed"),
            }
            let response = if challenge {
                challenge = false;
                authenticated = true;
                "235 2.7.0 authenticated\r\n"
            } else if line.starts_with("EHLO ") {
                "250-localhost\r\n250 AUTH PLAIN LOGIN\r\n"
            } else if line.starts_with("AUTH ") {
                if line.trim_end().split(' ').count() < 3 {
                    challenge = true;
                    "334 \r\n"
                } else {
                    authenticated = true;
                    "235 2.7.0 authenticated\r\n"
                }
            } else if line.starts_with("MAIL FROM:") || line.starts_with("RCPT TO:") {
                assert!(authenticated);
                "250 2.1.0 accepted\r\n"
            } else if line == "DATA\r\n" {
                assert!(authenticated);
                io.get_mut()
                    .write_all(b"354 finish with dot\r\n")
                    .await
                    .unwrap();
                let mut bytes = 0;
                loop {
                    line.clear();
                    assert!(io.read_line(&mut line).await.unwrap() > 0);
                    if line == ".\r\n" {
                        break;
                    }
                    bytes += line.len();
                    assert!(bytes < 128 * 1024);
                }
                count.fetch_add(1, Ordering::SeqCst);
                if drop_after_data {
                    return;
                }
                "250 2.0.0 synthetic acceptance\r\n"
            } else if line == "QUIT\r\n" {
                "221 closed\r\n"
            } else {
                panic!("unexpected SMTP fixture command")
            };
            io.get_mut().write_all(response.as_bytes()).await.unwrap();
            io.get_mut().flush().await.unwrap();
        }
    });
    (port, der, accepted, server)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn managed_attachment_mime_is_submitted_only_to_synthetic_tls_smtp() {
    let (port, der, accepted, server) = smtp_server(false, TlsMode::Implicit).await;
    let h = Harness::with_backend(Arc::new(Backend {
        native: Some(NativeBackend::with_test_root(der)),
        ..Backend::default()
    }));
    let mut config = config();
    config.smtp.host = "localhost".into();
    config.smtp.port = port;
    h.owner("mail.configure", json!({"account_id":"campus","config":config,"credentials":{"password":"synthetic-loopback-only"}})).await;
    let content = vec![0, 128, 255, 1, 2, 13, 10, 0];
    let asset = managed_attachment(&h, content.clone(), "campus", "fixture.attachments").await;
    let saved = h.owner("mail.draft.save", attachment_draft(&asset)).await;
    let send = json!({"account_id":"campus","draft_id":saved["draft"]["id"],"preview_hash":saved["preview_hash"],"confirm":true});
    let result = h.owner("mail.send", send.clone()).await;
    assert_eq!(result["submission"]["state"], "sent");
    assert_eq!(h.owner("mail.send", send).await["already_submitted"], true);
    assert_eq!(accepted.load(Ordering::SeqCst), 1);
    let messages = h.backend.sent_messages.lock().unwrap().clone();
    let message = mail_parser::MessageParser::new()
        .parse(&messages[0])
        .unwrap();
    assert_eq!(
        message
            .attachments()
            .next()
            .unwrap()
            .decoded_checked()
            .0
            .as_ref(),
        content
    );
    drop(messages);
    tokio::time::timeout(std::time::Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();
}

async fn smtp_fixture(
    drop_after_data: bool,
    trusted: bool,
    mode: TlsMode,
) -> (Result<SendReceipt, SendFailure>, usize) {
    let (port, der, accepted, server) = smtp_server(drop_after_data, mode).await;
    let backend = if trusted {
        NativeBackend::with_test_root(der)
    } else {
        NativeBackend::default()
    };
    let mut config = config();
    config.smtp.host = "localhost".into();
    config.smtp.port = port;
    config.smtp.tls = mode;
    let secret = MailCredentials {
        imap_password: "synthetic-loopback-only".into(),
        smtp_password: "synthetic-loopback-only".into(),
    };
    let envelope = lettre::address::Envelope::new(
        Some("sender@example.invalid".parse().unwrap()),
        vec!["recipient@example.invalid".parse().unwrap()],
    )
    .unwrap();
    let result=backend.send(&config,&secret,&envelope,b"From: sender@example.invalid\r\nTo: recipient@example.invalid\r\nSubject: loopback only\r\n\r\nsynthetic fixture\r\n").await;
    tokio::time::timeout(std::time::Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();
    (result, accepted.load(Ordering::SeqCst))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_tls_smtp_final_ack_and_disconnect_are_distinct() {
    let (result, count) = smtp_fixture(false, true, TlsMode::Implicit).await;
    assert!(result.is_ok());
    assert_eq!(count, 1);
    let (result, count) = smtp_fixture(true, true, TlsMode::Implicit).await;
    assert_eq!(count, 1);
    assert!(result.err().unwrap().uncertain);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn confirmed_smtp_identity_is_not_replayed_after_configuration_changes() {
    let (port, der, accepted, server) = smtp_server(false, TlsMode::Implicit).await;
    let backend = Arc::new(Backend {
        native: Some(NativeBackend::with_test_root(der)),
        ..Default::default()
    });
    let h = Harness::with_backend(backend);
    let mut config = config();
    config.smtp.host = "localhost".into();
    config.smtp.port = port;
    h.owner("mail.configure",json!({"account_id":"campus","config":config,"credentials":{"password":"synthetic-loopback-only"}})).await;
    let draft=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"subject":"identity replay regression","text":"synthetic local SMTP fixture"}})).await;
    let id = draft["draft"]["id"].as_str().unwrap();
    let message_id = draft["draft"]["message_id"].clone();
    let original_params = json!({"account_id":"campus","draft_id":id,"preview_hash":draft["preview_hash"],"confirm":true});
    let first = h.owner("mail.send", original_params.clone()).await;
    assert_eq!(first["submission"]["state"], "sent");
    assert_eq!(first["submission"]["message_id"], message_id);
    tokio::time::timeout(std::time::Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(accepted.load(Ordering::SeqCst), 1);
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);

    config.address = "Changed Sender <changed@example.invalid>".into();
    config.imap.host = "changed-imap.example.invalid".into();
    h.owner("mail.configure",json!({"account_id":"campus","config":config,"credentials":{"password":"synthetic-loopback-only"}})).await;
    let preview = h
        .owner(
            "mail.send",
            json!({"account_id":"campus","draft_id":id,"phase":"preview"}),
        )
        .await;
    assert!(preview["preview_hash"] != draft["preview_hash"]);
    let new_params = json!({"account_id":"campus","draft_id":id,"preview_hash":preview["preview_hash"],"confirm":true});
    for params in [original_params, new_params.clone()] {
        let repeated = h.owner("mail.send", params).await;
        assert_eq!(repeated["already_submitted"], true);
        assert_eq!(repeated["submission"]["message_id"], message_id);
        assert_eq!(
            repeated["submission"]["preview_hash"],
            draft["preview_hash"]
        );
    }
    let h = h.reopen();
    assert_eq!(
        h.owner("mail.send", new_params).await["already_submitted"],
        true
    );
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
    assert_eq!(accepted.load(Ordering::SeqCst), 1);
    assert_eq!(
        h.call(
            &Principal::owner(),
            &Grant::default(),
            "mail.draft.save",
            json!({"account_id":"campus","draft_id":id,"draft":{"text":"edited after send"}})
        )
        .await
        .unwrap_err()
        .code,
        "DraftAlreadySent"
    );
    let fresh=h.owner("mail.draft.save",json!({"account_id":"campus","draft":{"to":["recipient@example.invalid"],"text":"new explicit draft"}})).await;
    assert!(fresh["draft"]["id"] != draft["draft"]["id"]);
    assert!(fresh["draft"]["message_id"] != message_id);
    assert_eq!(h.backend.sends.load(Ordering::SeqCst), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_tls_smtp_rejects_an_untrusted_certificate_before_data() {
    let (result, count) = smtp_fixture(false, false, TlsMode::Implicit).await;
    assert_eq!(count, 0);
    assert!(!result.err().unwrap().uncertain);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_smtp_starttls_authenticates_only_after_upgrade() {
    let (result, count) = smtp_fixture(false, true, TlsMode::Starttls).await;
    assert!(result.is_ok());
    assert_eq!(count, 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_imap_starttls_upgrades_before_login_and_never_downgrades() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let (der, tls) = test_tls();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut plain = tokio::io::BufReader::new(tcp);
        plain
            .get_mut()
            .write_all(b"* OK STARTTLS fixture\r\n")
            .await
            .unwrap();
        let mut line = String::new();
        plain.read_line(&mut line).await.unwrap();
        let (tag, command) = line.trim_end().split_once(' ').unwrap();
        assert_eq!(command, "STARTTLS");
        plain
            .get_mut()
            .write_all(format!("{tag} OK upgrade\r\n").as_bytes())
            .await
            .unwrap();
        let mut encrypted =
            tokio::io::BufReader::new(tls.accept(plain.into_inner()).await.unwrap());
        loop {
            line.clear();
            match encrypted.read_line(&mut line).await {
                Ok(0) => break,
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(_) => panic!("STARTTLS fixture read failed"),
            }
            let (tag, command) = line.trim_end().split_once(' ').unwrap();
            let response = if command.starts_with("LOGIN ") {
                format!("{tag} OK authenticated over TLS\r\n")
            } else if command.starts_with("LIST ") {
                format!("* LIST () \"/\" \"INBOX\"\r\n{tag} OK folders\r\n")
            } else if command == "LOGOUT" {
                format!("* BYE done\r\n{tag} OK logout\r\n")
            } else {
                panic!("unexpected STARTTLS fixture operation")
            };
            encrypted
                .get_mut()
                .write_all(response.as_bytes())
                .await
                .unwrap();
        }
    });
    let mut config = config();
    config.imap.host = "localhost".into();
    config.imap.port = port;
    config.imap.tls = TlsMode::Starttls;
    let credentials = MailCredentials {
        imap_password: "synthetic-loopback-only".into(),
        smtp_password: "synthetic-loopback-only".into(),
    };
    assert_eq!(
        NativeBackend::with_test_root(der)
            .folders(&config, &credentials)
            .await
            .unwrap()[0]
            .name,
        "INBOX"
    );
    tokio::time::timeout(std::time::Duration::from_secs(10), server)
        .await
        .unwrap()
        .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    config.imap.port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut plain = tokio::io::BufReader::new(tcp);
        plain
            .get_mut()
            .write_all(b"* OK STARTTLS unsupported fixture\r\n")
            .await
            .unwrap();
        let mut line = String::new();
        plain.read_line(&mut line).await.unwrap();
        let (tag, command) = line.trim_end().split_once(' ').unwrap();
        assert_eq!(command, "STARTTLS");
        plain
            .get_mut()
            .write_all(format!("{tag} NO TLS unavailable\r\n").as_bytes())
            .await
            .unwrap();
        line.clear();
        assert_eq!(
            plain.read_line(&mut line).await.unwrap(),
            0,
            "LOGIN must not be attempted without TLS"
        );
    });
    assert_eq!(
        NativeBackend::default()
            .folders(&config, &credentials)
            .await
            .err()
            .unwrap()
            .code,
        "MailTlsError"
    );
    server.await.unwrap();
}
