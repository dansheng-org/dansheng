use crate::services::{CoreService, ServiceContext};
#[path = "native_jobs.rs"]
mod native_jobs;
use crate::{
    api::*,
    network::{HttpRequest, Network},
    platform::PlatformPort,
    plugins::{
        PluginCancellation, PluginError, PluginHost, PluginLimits, PluginManifest, PluginRunner,
    },
    policy::{Grant, capability_for},
    store::Store,
};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, RwLock,
        atomic::{AtomicBool, Ordering},
    },
};

type ServiceRegistry = HashMap<String, (String, Arc<dyn CoreService>)>;
type WorkflowLocks = HashMap<String, std::sync::Weak<tokio::sync::Mutex<()>>>;
pub struct Engine {
    pub store: Store,
    network: Network,
    platform: Arc<dyn PlatformPort>,
    running: Mutex<HashMap<String, (String, PluginCancellation)>>,
    session_gate: tokio::sync::Mutex<()>,
    catalog_gate: tokio::sync::Mutex<()>,
    plugin_lifecycle: tokio::sync::RwLock<()>,
    services: RwLock<ServiceRegistry>,
    plugin_slots: tokio::sync::Semaphore,
    workflow_locks: Mutex<WorkflowLocks>,
    native_running: Mutex<native_jobs::Running>,
    native_slots: tokio::sync::Semaphore,
}
impl Engine {
    pub fn open(
        data_dir: impl AsRef<Path>,
        platform: Arc<dyn PlatformPort>,
    ) -> CoreResult<Arc<Self>> {
        Ok(Self::from_store(Store::open(data_dir.as_ref())?, platform))
    }
    pub fn from_store(store: Store, platform: Arc<dyn PlatformPort>) -> Arc<Self> {
        Arc::new(Self {
            store,
            network: Network::default(),
            platform,
            running: Mutex::new(HashMap::new()),
            session_gate: tokio::sync::Mutex::new(()),
            catalog_gate: tokio::sync::Mutex::new(()),
            plugin_lifecycle: tokio::sync::RwLock::new(()),
            services: RwLock::new(HashMap::new()),
            workflow_locks: Mutex::new(HashMap::new()),
            native_running: Mutex::new(HashMap::new()),
            native_slots: tokio::sync::Semaphore::new(if cfg!(target_os = "android") {
                2
            } else {
                4
            }),
            plugin_slots: tokio::sync::Semaphore::new(if cfg!(target_os = "android") {
                2
            } else {
                4
            }),
        })
    }
    pub fn register_service(&self, service: Arc<dyn CoreService>) -> CoreResult<()> {
        let methods = service.methods();
        let mut services = self
            .services
            .write()
            .map_err(|_| CoreError::new("InternalError", "service registry unavailable"))?;
        for (name, _) in &methods {
            let namespace = name.split('.').next().unwrap_or("");
            if !name.contains('.')
                || [
                    "core",
                    "capabilities",
                    "permissions",
                    "clients",
                    "accounts",
                    "auth",
                    "http",
                    "storage",
                    "sources",
                    "search",
                    "events",
                    "plugins",
                    "actions",
                    "ui",
                    "jobs",
                    "browser",
                    "notifications",
                    "backup",
                    "files",
                    "todo",
                    "calendar",
                    "activity",
                    "reminders",
                ]
                .contains(&namespace)
                || services.contains_key(*name)
            {
                return Err(CoreError::invalid(
                    "service method conflicts with a reserved or registered method",
                ));
            }
        }
        for (name, capability) in methods {
            services.insert(name.into(), (capability.into(), service.clone()));
        }
        Ok(())
    }
    fn required_capability(&self, method: &str) -> String {
        self.services
            .read()
            .ok()
            .and_then(|s| s.get(method).map(|(cap, _)| cap.clone()))
            .unwrap_or_else(|| capability_for(method).into())
    }
    fn capability_available(&self, name: &str) -> bool {
        if name == "browser.write" {
            return self
                .platform
                .capabilities()
                .iter()
                .any(|cap| cap == "browser.request");
        }
        if name.starts_with("browser.")
            || name.starts_with("jobs.wake.")
            || matches!(name, "notifications.show" | "files.export")
        {
            return self.platform.capabilities().iter().any(|cap| cap == name);
        }
        if name == "files.index.pdf" {
            return cfg!(feature = "pdf");
        }
        if self
            .services
            .read()
            .is_ok_and(|s| s.values().any(|(cap, _)| cap == name))
        {
            return true;
        }
        [
            "http.request",
            "http.write",
            "auth.status",
            "auth.requireLogin",
            "storage.read",
            "storage.write",
            "sources.read",
            "sources.write",
            "jobs.schedule",
            "jobs.cancel",
            "jobs.status",
            "jobs.run",
            "jobs.resume",
            "jobs.reconcile",
            "plugins.run",
            "plugins.list",
            "ui.publish",
            "ui.get",
            "events.poll",
            "actions.preview",
            "files.download",
            "files.list",
            "files.read",
            "files.delete",
            "files.index",
            "todo.read",
            "todo.write",
            "calendar.read",
            "calendar.write",
            "activity.read",
            "activity.write",
            "reminders.read",
            "reminders.write",
        ]
        .contains(&name)
    }
    pub fn authenticate(&self, token: &str) -> CoreResult<Principal> {
        self.store.authenticate(token)
    }
    pub fn register_client(&self, id: &str, kind: PrincipalKind, token: &str) -> CoreResult<()> {
        self.store.register_client(id, kind, token)
    }
    pub async fn handle(self: &Arc<Self>, principal: Principal, request: Request) -> Response {
        if request.id.len() > 128
            || request.id.chars().any(char::is_control)
            || request.method.is_empty()
            || request.method.len() > 128
            || !request
                .method
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Response {
                id: String::new(),
                result: None,
                error: Some(CoreError::new(
                    "InvalidRequest",
                    "invalid request id or method",
                )),
            };
        }
        let started = std::time::Instant::now();
        let http_metadata = if request.method == "http.request" {
            json!({"method":request.params["method"].as_str().unwrap_or("GET"),"origin":request.params["url"].as_str().and_then(|u|url::Url::parse(u).ok()).map(|u|u.origin().ascii_serialization())})
        } else {
            Value::Null
        };
        let result = Box::pin(self.dispatch(&principal, &request.method, request.params)).await;
        // Audit records identify operations, never copy inputs, secrets, or response bodies.
        if !matches!(request.method.as_str(), "events.poll" | "core.info") {
            let _=self.store.event("audit",&json!({"principal":principal.id,"method":request.method,"ok":result.is_ok(),"elapsed_ms":started.elapsed().as_millis().min(u128::from(u64::MAX))as u64,"http":http_metadata,"http_status":result.as_ref().ok().and_then(|v|v["status"].as_u64()),"error_code":result.as_ref().err().map(|e|e.code.clone())}));
        }
        match result {
            Ok(value) => Response {
                id: request.id,
                result: Some(value),
                error: None,
            },
            Err(error) => Response {
                id: request.id,
                result: None,
                error: Some(error),
            },
        }
    }

    async fn dispatch(
        self: &Arc<Self>,
        principal: &Principal,
        method: &str,
        params: Value,
    ) -> CoreResult<Value> {
        let grant = self.store.grant(&principal.id)?;
        Box::pin(self.dispatch_with_grant(principal, method, params, grant)).await
    }
    async fn dispatch_with_grant(
        self: &Arc<Self>,
        principal: &Principal,
        method: &str,
        params: Value,
        grant: Grant,
    ) -> CoreResult<Value> {
        if !matches!(method, "core.info" | "capabilities.has") {
            grant.check(principal, &self.required_capability(method))?;
        }
        grant.check_account(principal, params["account_id"].as_str())?;
        let service = self
            .services
            .read()
            .map_err(|_| CoreError::new("InternalError", "service registry unavailable"))?
            .get(method)
            .map(|(capability, service)| (capability.clone(), service.clone()));
        if let Some((capability, service)) = service {
            let account = params["account_id"].as_str().map(str::to_owned);
            if let Some(account) = &account {
                self.ensure_session_loaded(account).await?;
            }
            let result = service
                .call(
                    ServiceContext {
                        store: &self.store,
                        network: &self.network,
                        platform: self.platform.as_ref(),
                    },
                    principal,
                    &grant,
                    method,
                    params,
                )
                .await;
            if let Some(account) = &account {
                self.refresh_saved_session(account).await;
            }
            // The service may have awaited a final page or a native protocol
            // response while authorization changed. Check after the last await
            // before allowing its response to leave this caller's boundary.
            let current = self.store.grant(&principal.id)?;
            current.check(principal, &capability)?;
            current.check_account(principal, account.as_deref())?;
            return result;
        }
        if crate::organizer::required_capability(method).is_some() {
            return crate::organizer::dispatch(&self.store, principal, &grant, method, params);
        }
        if method.starts_with("files.") {
            if method == "files.export"
                && self
                    .platform
                    .capabilities()
                    .contains(&"files.export".to_owned())
            {
                let descriptor =
                    crate::assets::export_descriptor(&self.store, principal, &grant, params)?;
                let asset_id = descriptor["asset_id"].clone();
                let response = self
                    .platform
                    .call(
                        "files.export",
                        json!({"principal":principal,"grant":grant,"input":descriptor}),
                    )
                    .await?;
                return Ok(
                    json!({"asset_id":asset_id,"exported":response["exported"].as_bool().unwrap_or(false)}),
                );
            }
            let account = params["account_id"].as_str().map(str::to_owned);
            if let Some(account) = &account {
                self.ensure_session_loaded(account).await?;
            }
            let result = Box::pin(crate::assets::dispatch(
                &self.store,
                &self.network,
                principal,
                &grant,
                method,
                params,
            ))
            .await;
            if let Some(account) = &account {
                self.refresh_saved_session(account).await;
            }
            return result;
        }
        let _plugin_lifecycle = if matches!(
            method,
            "plugins.install"
                | "plugins.enable"
                | "plugins.disable"
                | "plugins.rollback"
                | "plugins.uninstall"
                | "plugins.trust.set"
                | "plugins.catalog.install"
                | "plugins.storage.restore"
                | "plugins.storage.discard"
        ) {
            owner(principal)?;
            Some(self.plugin_lifecycle.write().await)
        } else {
            None
        };
        match method {
            "core.info" => Ok(
                json!({"name":"dansheng-core","version":env!("CARGO_PKG_VERSION"),"api_version":1,"platform_capabilities":self.platform.capabilities(),"principal":principal.id}),
            ),
            "capabilities.has" => {
                let name = required_string(&params, "name")?;
                let permission = if name == "files.index.pdf" {
                    "files.index"
                } else {
                    name
                };
                Ok(json!(
                    self.capability_available(name)
                        && (principal.is_owner() || grant.allows(permission))
                ))
            }
            "permissions.set" => {
                owner(principal)?;
                let subject = required_string(&params, "subject")?;
                if subject == "owner" {
                    return Err(CoreError::invalid("owner permissions are intrinsic"));
                }
                let value: Grant = serde_json::from_value(params["grant"].clone())?;
                if !value.private_network_origins.is_empty() {
                    return Err(CoreError::invalid(
                        "named private origins are an owner policy",
                    ));
                }
                if value
                    .organizer_scope
                    .as_deref()
                    .is_some_and(|scope| scope != "profile")
                {
                    return Err(CoreError::invalid(
                        "organizer_scope must be profile or omitted",
                    ));
                }
                if let Some(expiry) = &value.expires_at {
                    DateTime::parse_from_rfc3339(expiry)
                        .map_err(|_| CoreError::invalid("invalid grant expiry"))?;
                }
                for origin in &value.origins {
                    let u = url::Url::parse(origin)
                        .map_err(|_| CoreError::invalid("invalid network origin"))?;
                    if u.origin().ascii_serialization() != *origin {
                        return Err(CoreError::invalid(
                            "network origins must exclude path/query",
                        ));
                    }
                }
                self.store.set_grant(subject, &value)?;
                Ok(json!({"subject":subject,"granted":true}))
            }
            "permissions.get" => {
                owner(principal)?;
                Ok(serde_json::to_value(
                    self.store.grant(required_string(&params, "subject")?)?,
                )?)
            }
            "http.policy.set" => {
                owner(principal)?;
                let mut policy = self.store.grant("owner")?;
                if params.get("allow_private_network").is_some() {
                    policy.allow_private_network =
                        params["allow_private_network"].as_bool().ok_or_else(|| {
                            CoreError::invalid("allow_private_network must be boolean")
                        })?;
                } else if params.get("private_network_origins").is_none() {
                    return Err(CoreError::invalid("missing network policy"));
                }
                if let Some(origins) = params.get("private_network_origins") {
                    let items = origins
                        .as_array()
                        .filter(|a| a.len() <= 32)
                        .ok_or_else(|| CoreError::invalid("invalid private origin list"))?;
                    let mut names = std::collections::BTreeSet::new();
                    for item in items {
                        let name = item
                            .as_str()
                            .ok_or_else(|| CoreError::invalid("invalid private origin"))?;
                        let url = url::Url::parse(name)
                            .map_err(|_| CoreError::invalid("invalid private origin"))?;
                        if url.scheme() != "https"
                            || url.origin().ascii_serialization() != name
                            || !matches!(url.host(),Some(url::Host::Domain(domain)) if domain.contains('.') && !domain.ends_with(".localhost"))
                        {
                            return Err(CoreError::invalid(
                                "private origin must be a named HTTPS origin",
                            ));
                        }
                        names.insert(name.to_owned());
                    }
                    policy.private_network_origins = names;
                }
                self.store.set_grant("owner", &policy)?;
                Ok(
                    json!({"allow_private_network":policy.allow_private_network,"private_network_origins":policy.private_network_origins}),
                )
            }
            "http.routes.set" => {
                owner(principal)?;
                let account = required_string(&params, "account_id")?;
                if account.len() > 256 || account.chars().any(char::is_control) {
                    return Err(CoreError::invalid("invalid routing account"));
                }
                let routes: Vec<crate::network_routes::GatewayRoute> =
                    serde_json::from_value(params["routes"].clone())?;
                crate::network_routes::validate_routes(&routes)?;
                self.store.kv_set(
                    "core:network-routes",
                    account,
                    &serde_json::to_value(&routes)?,
                )?;
                self.network.set_routes(account, routes.clone())?;
                Ok(json!({"account_id":account,"routes":routes}))
            }
            "http.routes.get" => {
                owner(principal)?;
                let account = required_string(&params, "account_id")?;
                let value = self.store.kv_get("core:network-routes", account)?;
                Ok(json!({"account_id":account,"routes":if value.is_null(){json!([])}else{value}}))
            }
            "clients.register" => {
                owner(principal)?;
                let id = required_string(&params, "client_id")?;
                if id == "owner" || id.starts_with("plugin:") {
                    return Err(CoreError::invalid("reserved client id"));
                }
                let kind = if params["kind"] == "mcp" {
                    PrincipalKind::Mcp
                } else {
                    PrincipalKind::Client
                };
                self.register_client(id, kind, required_string(&params, "token")?)?;
                Ok(json!({"client_id":id}))
            }
            "accounts.upsert" => {
                owner(principal)?;
                let id = required_string(&params, "account_id")?;
                let value = json!({"id":id,"label":params["label"].as_str().unwrap_or(id),"provider":params["provider"].as_str().unwrap_or("custom")});
                self.store.account_upsert(id, &value)?;
                Ok(value)
            }
            "accounts.list" => Ok(json!(
                self.store
                    .accounts()?
                    .into_iter()
                    .filter(|a| principal.is_owner()
                        || a["id"]
                            .as_str()
                            .is_some_and(|id| grant.account_ids.contains(id)))
                    .collect::<Vec<_>>()
            )),
            "auth.status" => {
                let id = required_string(&params, "account_id")?;
                self.ensure_session_loaded(id).await?;
                Ok(
                    json!({"account_id":id,"authenticated":self.network.has_session(id),"verification":"local_credentials_only"}),
                )
            }
            "auth.session.set" => {
                owner(principal)?;
                let account = required_string(&params, "account_id")?;
                let origin = required_string(&params, "origin")?;
                let secret_headers =
                    crate::network::secret_headers_from_value(params.get("secret_headers"))?;
                let persist = params["persist"].as_bool().unwrap_or(true);
                if persist
                    && !self
                        .platform
                        .capabilities()
                        .contains(&"vault.set".to_owned())
                {
                    return Err(CoreError::new(
                        "CapabilityUnavailable",
                        "encrypted credential storage is unavailable; explicit persist=false permits an in-memory session",
                    ));
                }
                self.ensure_session_loaded(account).await?;
                let _guard = self.session_gate.lock().await;
                let cookies = params["cookies"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default();
                self.network.set_session_with_headers(
                    account,
                    origin,
                    params["bearer"].as_str().map(str::to_owned),
                    cookies,
                    secret_headers,
                )?;
                if persist {
                    self.platform.call("vault.set",json!({"key":format!("http-sessions:{account}"),"value":self.network.export_sessions(account)?})).await?;
                }
                self.store
                    .kv_set("core:session-policy", account, &json!(persist))?;
                Ok(
                    json!({"account_id":account,"authenticated":self.network.has_session(account),"persisted":persist,"verification":"local_credentials_only"}),
                )
            }
            "auth.logout" => {
                let account = required_string(&params, "account_id")?;
                let _guard = self.session_gate.lock().await;
                self.network.clear_session(account)?;
                self.store
                    .kv_set("core:session-policy", account, &json!(false))?;
                if self
                    .platform
                    .capabilities()
                    .contains(&"vault.delete".to_owned())
                {
                    self.platform
                        .call(
                            "vault.delete",
                            json!({"key":format!("http-sessions:{account}")}),
                        )
                        .await?;
                }
                Ok(json!({"account_id":account,"authenticated":false}))
            }
            "auth.requireLogin" => {
                let account = required_string(&params, "account_id")?;
                self.ensure_session_loaded(account).await?;
                if self.network.has_session(account) {
                    return Ok(
                        json!({"account_id":account,"authenticated":true,"verification":"local_credentials_only"}),
                    );
                }
                let _ = self.store.event(
                    "authentication_required",
                    &json!({"principal":principal.id,"account_id":account}),
                );
                Err(CoreError::new(
                    "AuthenticationRequired",
                    "complete authentication through the trusted platform adapter",
                ))
            }
            "http.request" => {
                let input: HttpRequest = serde_json::from_value(params)?;
                let account = input.account_id.clone();
                if let Some(account) = &account {
                    self.ensure_session_loaded(account).await?;
                }
                let response = Box::pin(self.network.request(principal, &grant, input)).await;
                if let Some(account) = &account {
                    self.refresh_saved_session(account).await;
                }
                Ok(serde_json::to_value(response?)?)
            }
            "storage.get" => self.store.kv_get(
                &format!("private:{}", principal.id),
                required_string(&params, "key")?,
            ),
            "storage.set" => {
                self.store.kv_set(
                    &format!("private:{}", principal.id),
                    required_string(&params, "key")?,
                    &params["value"],
                )?;
                Ok(Value::Null)
            }
            "storage.delete" => {
                self.store.kv_delete(
                    &format!("private:{}", principal.id),
                    required_string(&params, "key")?,
                )?;
                Ok(Value::Null)
            }
            "sources.upsert" => {
                let source = required_string(&params, "source_id")?;
                if principal.kind == PrincipalKind::Plugin {
                    let id = principal.id.trim_start_matches("plugin:");
                    if !source.starts_with(&format!("{id}.")) {
                        return Err(CoreError::new(
                            "PermissionDenied",
                            "plugin source must use its own id prefix",
                        ));
                    }
                }
                self.store.record_upsert(
                    &principal.id,
                    params["account_id"].as_str().unwrap_or(""),
                    source,
                    required_string(&params, "external_id")?,
                    required_string(&params, "kind")?,
                    &params["data"],
                )
            }
            "sources.query" => Ok(json!(self.store.records(principal, &grant, &params, None)?)),
            "search.query" => {
                let q = required_string(&params, "query")?.to_owned();
                if q.chars().count() > 200 {
                    return Err(CoreError::invalid("search query too long"));
                }
                crate::search::query(&self.store, principal, &grant, params, &q)
            }
            "events.poll" => {
                let events = self.store.events(params["after"].as_i64().unwrap_or(0))?;
                let cursor = events
                    .last()
                    .map(|e| e.sequence)
                    .unwrap_or(params["after"].as_i64().unwrap_or(0));
                let after = params["after"].as_i64().unwrap_or(0);
                let oldest = self.store.first_event_sequence()?;
                Ok(
                    json!({"cursor":cursor,"resync_required":after>0&&oldest>after+1,"events":events.into_iter().filter(|e|principal.is_owner()||e.data["principal"]==principal.id).collect::<Vec<_>>()}),
                )
            }
            "plugins.list" => {
                let mut p = self.store.plugins()?;
                for value in &mut p {
                    value.as_object_mut().unwrap().remove("path");
                }
                Ok(json!(p))
            }
            "plugins.install" => {
                owner(principal)?;
                let source = PathBuf::from(required_string(&params, "path")?);
                let root = self.store.directory.join("plugins");
                let installed = tokio::task::spawn_blocking(move || {
                    crate::plugins::install_local_package(&source, &root)
                })
                .await
                .map_err(|_| CoreError::new("InstallFailed", "plugin installer stopped"))?
                .map_err(plugin_error)?;
                let _ = self.store.plugin_enable(&installed.manifest.id, false);
                self.stop_plugin_runs(&installed.manifest.id).await?;
                self.store.plugin_save(
                    &installed.manifest.id,
                    &installed.package_dir,
                    &serde_json::to_value(&installed.manifest)?,
                )?;
                Ok(json!({"plugin_id":installed.manifest.id,"enabled":false}))
            }
            "plugins.enable" | "plugins.disable" => {
                owner(principal)?;
                let id = required_string(&params, "plugin_id")?;
                if method == "plugins.enable" {
                    let plugin = self
                        .store
                        .plugins()?
                        .into_iter()
                        .find(|p| p["id"] == id)
                        .ok_or_else(|| CoreError::new("NotFound", "plugin not found"))?;
                    let installed =
                        crate::plugins::installed_package(self.store.directory.join("plugins"), id)
                            .map_err(plugin_error)?;
                    if Path::new(required_string(&plugin, "path")?)
                        != installed.package_dir.as_path()
                        || plugin["manifest"] != serde_json::to_value(&installed.manifest)?
                    {
                        return Err(CoreError::new(
                            "PluginChanged",
                            "installed package and registry differ",
                        ));
                    }
                    if !plugin["verification"].is_null() {
                        let keys = self.trusted_publishers()?;
                        let publisher: crate::plugins::PluginPublisher =
                            serde_json::from_value(plugin["verification"]["publisher"].clone())?;
                        if !keys.iter().any(|key| key.publisher == publisher) {
                            return Err(CoreError::new(
                                "UntrustedPublisher",
                                "this installed publisher key is no longer trusted",
                            ));
                        }
                    }
                    // Failed migration leaves this installation disabled. Its
                    // previous data and version remain in the same transaction.
                    self.store.plugin_enable(id, false)?;
                    let storage = self.store.plugin_storage_enable(&installed.manifest)?;
                    return Ok(json!({"plugin_id":id,"enabled":true,"storage":storage}));
                }
                self.store.plugin_enable(id, method == "plugins.enable")?;
                if method == "plugins.disable" {
                    self.stop_plugin_runs(id).await?;
                }
                Ok(json!({"plugin_id":id,"enabled":method=="plugins.enable"}))
            }
            "plugins.storage.snapshots" | "plugins.storage.restore" | "plugins.storage.discard" => {
                owner(principal)?;
                let id = required_string(&params, "plugin_id")?;
                match method {
                    "plugins.storage.snapshots" => self.store.plugin_storage_snapshots(id),
                    "plugins.storage.restore" => self
                        .store
                        .plugin_storage_restore(id, required_string(&params, "snapshot_id")?),
                    _ => self
                        .store
                        .plugin_storage_discard(id, required_string(&params, "snapshot_id")?),
                }
            }
            "plugins.rollback" => {
                owner(principal)?;
                let id = required_string(&params, "plugin_id")?;
                let _ = self.store.plugin_enable(id, false);
                self.stop_plugin_runs(id).await?;
                let installed = crate::plugins::rollback_local_package(
                    self.store.directory.join("plugins"),
                    id,
                    params["generation"].as_str(),
                )
                .map_err(plugin_error)?;
                let verification = installed
                    .verification
                    .as_ref()
                    .map(serde_json::to_value)
                    .transpose()?;
                self.store.plugin_save_verified(
                    id,
                    &installed.package_dir,
                    &serde_json::to_value(&installed.manifest)?,
                    verification.as_ref(),
                )?;
                Ok(json!({"plugin_id":id,"version":installed.manifest.version,"enabled":false}))
            }
            "plugins.uninstall" => {
                owner(principal)?;
                let id = required_string(&params, "plugin_id")?;
                self.store.plugin_enable(id, false)?;
                self.stop_plugin_runs(id).await?;
                let receipt = crate::plugins::uninstall_local_package(
                    self.store.directory.join("plugins"),
                    id,
                )
                .map_err(plugin_error)?;
                self.store.plugin_remove(id)?;
                Ok(
                    json!({"plugin_id":id,"recovery_generation":receipt.recovery_generation,"data_retained":true}),
                )
            }
            "plugins.trust.set" => {
                owner(principal)?;
                let _guard = self.catalog_gate.lock().await;
                let keys: Vec<crate::plugins::TrustedPublisher> =
                    serde_json::from_value(params["publishers"].clone())?;
                if keys.len() > 128 {
                    return Err(CoreError::invalid("too many trusted publisher keys"));
                }
                let mut seen = std::collections::BTreeSet::new();
                for key in &keys {
                    let identity = input_hash(&serde_json::to_value(&key.publisher)?);
                    if !seen.insert(identity.clone()) {
                        return Err(CoreError::invalid("duplicate publisher key identity"));
                    }
                    let history = format!("key:{identity}");
                    let fingerprint = hex::encode(Sha256::digest(key.public_key));
                    let previous = self.store.kv_get("core:plugins", &history)?;
                    if !previous.is_null() && previous != json!(fingerprint) {
                        return Err(CoreError::invalid(
                            "key_id is immutable; use a new key_id when rotating publisher keys",
                        ));
                    }
                    self.store
                        .kv_set("core:plugins", &history, &json!(fingerprint))?;
                }
                self.store.kv_set(
                    "core:plugins",
                    "trusted_publishers",
                    &serde_json::to_value(&keys)?,
                )?;
                for plugin in self.store.plugins()? {
                    if !plugin["verification"].is_null() {
                        let publisher: crate::plugins::PluginPublisher =
                            serde_json::from_value(plugin["verification"]["publisher"].clone())?;
                        if !keys.iter().any(|key| key.publisher == publisher) {
                            let id = required_string(&plugin, "id")?;
                            self.store.plugin_enable(id, false)?;
                            self.stop_plugin_runs(id).await?;
                        }
                    }
                }
                Ok(json!({"updated":true}))
            }
            "plugins.catalog.verify" | "plugins.catalog.fetch" | "plugins.catalog.install" => {
                owner(principal)?;
                let _guard = self.catalog_gate.lock().await;
                let bytes = if method == "plugins.catalog.fetch" {
                    let url = required_string(&params, "url")?;
                    if !url.starts_with("https://") {
                        return Err(CoreError::invalid("plugin catalog requires HTTPS"));
                    }
                    let response = self
                        .network
                        .request(
                            principal,
                            &grant,
                            HttpRequest {
                                url: url.into(),
                                ..Default::default()
                            },
                        )
                        .await?;
                    if response.status != 200 {
                        return Err(CoreError::new(
                            "RemoteStatus",
                            "catalog request did not return HTTP 200",
                        ));
                    }
                    response.body.into_bytes()
                } else if let Some(id) = params["catalog_id"].as_str() {
                    self.store
                        .kv_get("core:catalogs", id)?
                        .as_str()
                        .ok_or_else(|| CoreError::new("NotFound", "cached catalog not found"))?
                        .as_bytes()
                        .to_vec()
                } else if let Some(raw) = params["catalog_json"].as_str() {
                    raw.as_bytes().to_vec()
                } else {
                    serde_json::to_vec(&params["catalog"])?
                };
                if bytes.len() > crate::plugins::MAX_CATALOG_BYTES {
                    return Err(CoreError::invalid("catalog exceeds size limit"));
                }
                let trusted = self.trusted_publishers()?;
                let parsed: Value = serde_json::from_slice(&bytes)?;
                let publisher = &parsed["catalog"]["publisher"];
                let floor_key = format!(
                    "sequence:{}:{}",
                    required_string(publisher, "id")?,
                    required_string(publisher, "key_id")?
                );
                let floor = self
                    .store
                    .kv_get("core:plugins", &floor_key)?
                    .as_u64()
                    .unwrap_or(0);
                let now = Utc::now().timestamp().max(0) as u64;
                let verified = crate::plugins::verify_catalog(&bytes, &trusted, now, floor)
                    .map_err(plugin_error)?;
                self.store.kv_set(
                    "core:plugins",
                    &floor_key,
                    &json!(verified.catalog().sequence),
                )?;
                let catalog_id = hex::encode(Sha256::digest(&bytes));
                self.store.kv_set(
                    "core:catalogs",
                    &catalog_id,
                    &json!(
                        String::from_utf8(bytes)
                            .map_err(|_| CoreError::invalid("catalog must be UTF-8"))?
                    ),
                )?;
                if method != "plugins.catalog.install" {
                    return Ok(json!({"catalog_id":catalog_id,"catalog":verified.catalog()}));
                }
                let source = if let Some(path) = params["path"].as_str() {
                    PathBuf::from(path)
                } else {
                    let id = required_string(&params, "plugin_id")?;
                    let version = required_string(&params, "version")?;
                    let entry = verified
                        .catalog()
                        .packages
                        .iter()
                        .find(|entry| entry.id == id && entry.version == version)
                        .ok_or_else(|| {
                            CoreError::new("NotFound", "package not found in signed catalog")
                        })?;
                    let url = entry.archive_url.as_ref().ok_or_else(|| {
                        CoreError::new(
                            "CapabilityUnavailable",
                            "catalog package has no archive URL; import a local package",
                        )
                    })?;
                    let download_root = self.store.directory.join("package-downloads");
                    std::fs::create_dir_all(&download_root)?;
                    let download_id = uuid::Uuid::new_v4().to_string();
                    let archive = download_root.join(format!("{download_id}.zip"));
                    self.network
                        .download(
                            principal,
                            &grant,
                            HttpRequest {
                                url: url.clone(),
                                ..Default::default()
                            },
                            archive.clone(),
                            16 * 1024 * 1024,
                            false,
                        )
                        .await?;
                    let destination = download_root.join(download_id);
                    let package = tokio::task::spawn_blocking(move || {
                        crate::plugins::extract_package_archive(archive, destination)
                    })
                    .await
                    .map_err(|_| CoreError::new("InstallFailed", "archive extractor stopped"))?
                    .map_err(plugin_error)?;
                    package.package_dir
                };
                let root = self.store.directory.join("plugins");
                let receipt = tokio::task::spawn_blocking(move || {
                    crate::plugins::install_catalog_package(source, root, &verified, now)
                })
                .await
                .map_err(|_| CoreError::new("InstallFailed", "catalog installer stopped"))?
                .map_err(plugin_error)?;
                let _ = self.store.plugin_enable(&receipt.manifest.id, false);
                self.stop_plugin_runs(&receipt.manifest.id).await?;
                let verification = receipt
                    .verification
                    .as_ref()
                    .map(serde_json::to_value)
                    .transpose()?;
                self.store.plugin_save_verified(
                    &receipt.manifest.id,
                    &receipt.package_dir,
                    &serde_json::to_value(&receipt.manifest)?,
                    verification.as_ref(),
                )?;
                Ok(
                    json!({"plugin_id":receipt.manifest.id,"version":receipt.manifest.version,"verified":true,"enabled":false,"permission_changes":receipt.permission_changes}),
                )
            }
            "plugins.run" => {
                let id = required_string(&params, "plugin_id")?.to_owned();
                let action = required_string(&params, "action")?.to_owned();
                let input = params.get("input").cloned().unwrap_or(json!({}));
                self.validate_plugin_action(principal, &id, &action, &input_hash(&input))?;
                let data = json!({"plugin_id":id,"action":action,"input":input});
                let (job_id, lease) = self.store.create_claimed_plugin_job(
                    principal,
                    &data,
                    &Utc::now().to_rfc3339(),
                )?;
                // Install the drop guard before the first await. Cancellation
                // while waiting for workflow/worker slots retains a durable lease
                // outcome instead of leaving a silently replayable invocation.
                let claimed = lease.map(|lease| JobGuard {
                    engine: Arc::downgrade(self),
                    id: job_id.clone(),
                    lease,
                });
                Box::pin(self.run_job_with_claim(&job_id, claimed))
                    .await
                    .map_err(|mut error| {
                        error.message = format!("{} (job_id={job_id})", error.message);
                        error
                    })
            }
            "actions.preview" => {
                let id = required_string(&params, "plugin_id")?;
                let action = required_string(&params, "action")?;
                let p = self.installed(id)?;
                let descriptor = p["manifest"]["actions"]
                    .get(action)
                    .ok_or_else(|| CoreError::new("ActionNotFound", "unknown plugin action"))?;
                let input = params.get("input").cloned().unwrap_or(json!({}));
                let fingerprint = input_hash(&input);
                Ok(
                    json!({"plugin_id":id,"action":action,"description":descriptor["description"],"mutating":descriptor["mutating"],"input":input,"input_sha256":fingerprint,"required_action_capability":format!("plugin:{id}:{action}"),"required_execution_capability":format!("execute:{id}:{action}"),"constraint_key":format!("{id}:{action}")}),
                )
            }
            "ui.publish" => {
                let component = &params["component"];
                if !matches!(
                    component["type"].as_str(),
                    Some("card" | "list" | "detail" | "form" | "action" | "settings")
                ) {
                    return Err(CoreError::invalid("unsupported declarative UI component"));
                }
                let id = required_string(&params, "id")?;
                self.store
                    .kv_set(&format!("ui:{}", principal.id), id, component)?;
                let sequence = self.store.event(
                    "ui_changed",
                    &json!({"principal":principal.id,"id":id,"component":component}),
                )?;
                Ok(json!({"sequence":sequence}))
            }
            "ui.get" => self.store.kv_get(
                &format!(
                    "ui:{}",
                    if principal.is_owner() {
                        params["principal"].as_str().unwrap_or(&principal.id)
                    } else {
                        &principal.id
                    }
                ),
                required_string(&params, "id")?,
            ),
            "jobs.schedule" => {
                match params["kind"].as_str() {
                    Some("service") => {
                        return self.schedule_native_job(principal, &grant, params).await;
                    }
                    None if params["kind"].is_null() => {}
                    Some("plugin") => {}
                    _ => return Err(CoreError::invalid("job kind must be plugin or service")),
                }
                grant.check_account(principal, params["input"]["account_id"].as_str())?;
                let run_at = params["run_at"]
                    .as_str()
                    .map(|s| DateTime::parse_from_rfc3339(s).map(|d| d.with_timezone(&Utc)))
                    .transpose()
                    .map_err(|_| CoreError::invalid("invalid run_at"))?
                    .unwrap_or_else(Utc::now);
                if let Some(s) = params["deadline_at"].as_str() {
                    let deadline = DateTime::parse_from_rfc3339(s)
                        .map_err(|_| CoreError::invalid("invalid deadline_at"))?;
                    if deadline <= run_at {
                        return Err(CoreError::invalid("deadline must follow scheduled time"));
                    }
                }
                if let Some(interval) = params["interval_seconds"].as_u64()
                    && !(15..=365 * 86400).contains(&interval)
                {
                    return Err(CoreError::invalid(
                        "interval must be 15 seconds to 365 days; platform wake-up may be coarser",
                    ));
                }
                let plugin = required_string(&params, "plugin_id")?;
                let action = required_string(&params, "action")?;
                self.validate_plugin_action(
                    principal,
                    plugin,
                    action,
                    &input_hash(&params.get("input").cloned().unwrap_or(json!({}))),
                )?;
                let mut stored = params.clone();
                let window = if let Some(deadline) = params["deadline_at"].as_str() {
                    (DateTime::parse_from_rfc3339(deadline)
                        .map_err(|_| CoreError::invalid("invalid deadline"))?
                        .with_timezone(&Utc)
                        - run_at)
                        .num_seconds()
                } else {
                    params["deadline_window_seconds"].as_i64().unwrap_or(60)
                };
                if !(1..=86400).contains(&window) {
                    return Err(CoreError::invalid(
                        "deadline window must be between 1 second and 24 hours",
                    ));
                }
                if stored["deadline_at"].is_null() {
                    stored["deadline_at"] = json!(
                        run_at
                            .checked_add_signed(chrono::Duration::seconds(window))
                            .ok_or_else(|| CoreError::invalid("deadline overflow"))?
                            .to_rfc3339()
                    );
                }
                if params["interval_seconds"].is_number() {
                    stored["_deadline_window_seconds"] = json!(window);
                }
                let id = self
                    .store
                    .create_job(principal, &stored, &run_at.to_rfc3339())?;
                let _ = self.store.event(
                    "job_scheduled",
                    &json!({"principal":principal.id,"job_id":id}),
                );
                let job = self.visible_job(principal, &id)?;
                let wake = self.schedule_wake(&job).await;
                Ok(json!({"job_id":id,"run_at":job["run_at"],"state":job["state"],"wake_up":wake}))
            }
            "jobs.status" => {
                if let Some(id) = params["job_id"].as_str() {
                    self.visible_job(principal, id)
                } else {
                    Ok(json!(self.visible_jobs(principal)?))
                }
            }
            "jobs.cancel" => {
                let id = required_string(&params, "job_id")?;
                let owned = self.owned_job(principal, id)?;
                if native_jobs::is_native(&owned) {
                    return self.cancel_native_job(&owned).await;
                }
                let previous = self.visible_job(principal, id)?;
                if previous["state"] == "needs_reconciliation" {
                    return Err(CoreError::new(
                        "NeedsReconciliation",
                        "an uncertain job must be reconciled before it can be dismissed",
                    ));
                }
                self.store.cancel_job(id)?;
                self.cancel_wake(&previous).await;
                if let Some((_, token)) = self
                    .running
                    .lock()
                    .map_err(|_| CoreError::new("InternalError", "runner lock failed"))?
                    .get(id)
                {
                    token.cancel();
                }
                Ok(
                    json!({"job_id":id,"state":self.store.job(id)?.map(|job|job["state"].clone()),"note":"already submitted remote actions are not undone; interrupted runs require reconciliation"}),
                )
            }
            "jobs.run" => {
                let id = required_string(&params, "job_id")?;
                self.visible_job(principal, id)?;
                Box::pin(self.run_job(id)).await
            }
            "jobs.reconcile" | "jobs.resume" => {
                let id = required_string(&params, "job_id")?;
                let job = self.visible_job(principal, id)?;
                if native_jobs::is_native(&job) {
                    if method == "jobs.reconcile" {
                        return Err(CoreError::invalid(
                            "read-only service jobs do not use write reconciliation",
                        ));
                    }
                    self.authorize_native_execution(&job)?;
                    self.store.resume_job(id)?;
                    let refreshed = self
                        .store
                        .job(id)?
                        .ok_or_else(|| CoreError::new("NotFound", "job not found"))?;
                    let _ = self.schedule_wake(&refreshed).await;
                    return Ok(json!({"job_id":id}));
                }
                if method == "jobs.reconcile" {
                    owner(principal)?;
                    if params["evidence"].is_null() {
                        return Err(CoreError::invalid(
                            "a trusted reconciliation record is required",
                        ));
                    }
                    self.store.reconcile_job(
                        id,
                        required_string(&params, "outcome")?,
                        &params["evidence"],
                    )?;
                } else {
                    self.store.resume_job(id)?;
                }
                Ok(json!({"job_id":id}))
            }
            "browser.open" | "browser.navigate" | "browser.login" | "browser.close"
            | "browser.request" | "browser.evaluate" | "notifications.show"
            | "jobs.wake.status" => {
                if !self.platform.capabilities().contains(&method.to_string()) {
                    return Err(CoreError::new(
                        "CapabilityUnavailable",
                        format!("platform does not provide {method}"),
                    ));
                }
                self.platform
                    .call(
                        method,
                        json!({"principal":principal,"grant":grant,"input":params}),
                    )
                    .await
            }
            "backup.create" => {
                owner(principal)?;
                let engine = self.clone();
                tokio::task::spawn_blocking(move || crate::backup::create(&engine.store))
                    .await
                    .map_err(|_| CoreError::new("BackupError", "snapshot worker stopped"))?
            }
            _ => Err(CoreError::new(
                "MethodNotFound",
                format!("unknown method: {method}"),
            )),
        }
    }

    async fn ensure_session_loaded(&self, account: &str) -> CoreResult<()> {
        let routes = self.store.kv_get("core:network-routes", account)?;
        if !routes.is_null() {
            self.network
                .set_routes(account, serde_json::from_value(routes)?)?;
        }
        if self.network.has_session(account) {
            return Ok(());
        }
        let _guard = self.session_gate.lock().await;
        if self.network.has_session(account)
            || self.store.kv_get("core:session-policy", account)? != json!(true)
        {
            return Ok(());
        }
        let value = self
            .platform
            .call(
                "vault.get",
                json!({"key":format!("http-sessions:{account}")}),
            )
            .await?;
        if !value["value"].is_null() {
            self.network.restore_sessions(account, &value["value"])?;
        }
        Ok(())
    }
    async fn refresh_saved_session(&self, account: &str) {
        let _guard = self.session_gate.lock().await;
        let result:CoreResult<()>=async{
   if self.store.kv_get("core:session-policy",account)?==json!(true){self.platform.call("vault.set",json!({"key":format!("http-sessions:{account}"),"value":self.network.export_sessions(account)?})).await?;}Ok(())
  }.await;
        if result.is_err() {
            let _ = self.store.event(
                "session_persistence_failed",
                &json!({"account_id":account,"principal":"owner"}),
            );
        }
    }

    fn visible_jobs(&self, principal: &Principal) -> CoreResult<Vec<Value>> {
        let mut visible = Vec::new();
        for job in self.store.jobs()? {
            if !principal.is_owner() && job["owner"]["id"] != principal.id {
                continue;
            }
            if native_jobs::is_native(&job)
                && self.authorize_native_visibility(principal, &job).is_err()
            {
                continue;
            }
            visible.push(job);
        }
        Ok(visible)
    }
    fn trusted_publishers(&self) -> CoreResult<Vec<crate::plugins::TrustedPublisher>> {
        let value = self.store.kv_get("core:plugins", "trusted_publishers")?;
        Ok(if value.is_null() {
            vec![]
        } else {
            serde_json::from_value(value)?
        })
    }
    fn visible_job(&self, principal: &Principal, id: &str) -> CoreResult<Value> {
        let job = self.owned_job(principal, id)?;
        if native_jobs::is_native(&job) {
            self.authorize_native_visibility(principal, &job)?;
        }
        Ok(job)
    }
    fn owned_job(&self, principal: &Principal, id: &str) -> CoreResult<Value> {
        self.store
            .job(id)?
            .filter(|j| principal.is_owner() || j["owner"]["id"] == principal.id)
            .ok_or_else(|| CoreError::new("NotFound", "job not found"))
    }
    async fn stop_plugin_runs(&self, id: &str) -> CoreResult<()> {
        for (plugin, token) in self
            .running
            .lock()
            .map_err(|_| CoreError::new("InternalError", "runner lock failed"))?
            .values()
        {
            if plugin == id {
                token.cancel();
            }
        }
        for job in self.store.jobs()? {
            if job["data"]["plugin_id"] == id {
                self.store.cancel_job(required_string(&job, "id")?)?;
                self.cancel_wake(&job).await;
            }
        }
        Ok(())
    }
    async fn schedule_wake(&self, job: &Value) -> Value {
        if !self
            .platform
            .capabilities()
            .contains(&"jobs.wake.schedule".to_owned())
        {
            return json!({"state":"host_must_remain_running"});
        }
        let result:CoreResult<Value>=async{
   let principal:Principal=serde_json::from_value(job["owner"].clone())?;let mut grant=self.store.grant(&principal.id)?;
   grant.check(&principal,"jobs.schedule")?;grant.capabilities.insert("jobs.wake.schedule".into());
   let run=DateTime::parse_from_rfc3339(required_string(job,"run_at")?).map_err(|_|CoreError::invalid("invalid stored run time"))?;
   let data=&job["data"];let deadline=data["deadline_at"].as_str().map(str::to_owned).unwrap_or_else(||(run+chrono::Duration::seconds(60)).to_rfc3339());
   self.platform.call("jobs.wake.schedule",json!({"principal":principal,"grant":grant,"input":{"job_id":job["id"],"run_at":job["run_at"],"prepare_at":data["prepare_at"].as_str().unwrap_or(required_string(job,"run_at")?),"deadline_at":deadline,"account_id":data["input"]["account_id"],"precision":data["wake_precision"].as_str().unwrap_or(if data["prepare_at"].is_string(){"exact"}else{"inexact"})}})).await
  }.await;
        match result {
            Ok(value) => value,
            Err(error) => json!({"state":"not_armed","error":error}),
        }
    }
    async fn cancel_wake(&self, job: &Value) {
        if self
            .platform
            .capabilities()
            .contains(&"jobs.wake.cancel".to_owned())
        {
            let _=self.platform.call("jobs.wake.cancel",json!({"principal":Principal::owner(),"grant":Grant::default(),"input":{"job_id":job["id"],"account_id":job["data"]["input"]["account_id"]}})).await;
        }
    }
    fn installed(&self, id: &str) -> CoreResult<Value> {
        self.store
            .plugins()?
            .into_iter()
            .find(|p| p["id"] == id && p["enabled"] == true)
            .ok_or_else(|| CoreError::new("PluginUnavailable", "plugin is missing or disabled"))
    }
    fn validate_plugin_action(
        &self,
        caller: &Principal,
        id: &str,
        action: &str,
        input_fingerprint: &str,
    ) -> CoreResult<(PathBuf, PluginManifest)> {
        let p = self.installed(id)?;
        let manifest: PluginManifest = serde_json::from_value(p["manifest"].clone())?;
        self.store.plugin_storage_ready(&manifest)?;
        let action_info = p["manifest"]["actions"]
            .get(action)
            .ok_or_else(|| CoreError::new("ActionNotFound", "unknown plugin action"))?;
        if !caller.is_owner() {
            let g = self.store.grant(&caller.id)?;
            let capability = format!("plugin:{id}:{action}");
            if !g.allows(&capability) {
                return Err(CoreError::new(
                    "PermissionDenied",
                    format!("missing action grant: {capability}"),
                ));
            }
            if action_info["mutating"].as_bool().unwrap_or(true)
                && !g.allows(&format!("execute:{id}:{action}"))
            {
                return Err(CoreError::new(
                    "ApprovalRequired",
                    "external mutation requires an explicit action execution grant",
                ));
            }
            if g.action_inputs
                .get(&format!("{id}:{action}"))
                .is_some_and(|expected| expected != input_fingerprint)
            {
                return Err(CoreError::new(
                    "ApprovalRequired",
                    "action parameters differ from the approved preview",
                ));
            }
        }
        Ok((PathBuf::from(required_string(&p, "path")?), manifest))
    }
    async fn run_plugin(
        self: &Arc<Self>,
        caller: &Principal,
        id: &str,
        action: &str,
        input: Value,
        job_id: Option<(String, String)>,
        immediate: bool,
    ) -> CoreResult<Value> {
        let bound_account = input["account_id"]
            .as_str()
            .filter(|a| !a.is_empty())
            .map(str::to_owned);
        self.store
            .grant(&caller.id)?
            .check_account(caller, bound_account.as_deref())?;
        let fingerprint = input_hash(&input);
        let lifecycle = self.plugin_lifecycle.read().await;
        let (path, manifest) = self.validate_plugin_action(caller, id, action, &fingerprint)?;
        let cancellation = PluginCancellation::new();
        let run_id = job_id
            .as_ref()
            .map(|(job, _)| job.clone())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        self.running
            .lock()
            .map_err(|_| CoreError::new("InternalError", "runner lock failed"))?
            .insert(run_id.clone(), (id.into(), cancellation.clone()));
        let _run_guard = RunGuard {
            engine: Arc::downgrade(self),
            id: run_id,
        };
        let host = Arc::new(RunHost {
            engine: self.clone(),
            plugin_id: id.into(),
            action: action.into(),
            input_fingerprint: fingerprint,
            bound_account,
            caller: caller.clone(),
            job_id: job_id.clone(),
            manifest: serde_json::to_value(&manifest)?,
            package_path: path.clone(),
            last_error: Mutex::new(None),
            uncertain: AtomicBool::new(false),
        });
        drop(lifecycle);
        let mut limits = PluginLimits::default();
        if immediate
            && caller.is_owner()
            && action == "visibleLogin"
            && manifest.actions.get(action).is_some_and(|a| !a.mutating)
            && manifest.capabilities.iter().any(|c| c == "browser.login")
        {
            // The platform's foreground identity dialog has its own 50 s timer.
            // Its cancellation and cookie cleanup must finish before an explicit retry.
            limits.interactive_login_timeout = Some(std::time::Duration::from_secs(55));
            limits.wall_timeout = std::time::Duration::from_secs(57);
        }
        let result = PluginRunner::run_with_cancellation(
            path,
            manifest,
            action.into(),
            input,
            host.clone(),
            limits,
            cancellation,
        )
        .await;
        if host.uncertain.load(Ordering::SeqCst) {
            return Err(CoreError::new(
                "NeedsReconciliation",
                "a plugin write did not produce a confirmed outcome",
            ));
        }
        if result.is_ok() {
            let _lifecycle = self.plugin_lifecycle.read().await;
            let current = self.installed(id)?;
            if current["manifest"] != host.manifest
                || Path::new(required_string(&current, "path")?) != host.package_path.as_path()
            {
                return Err(CoreError::new(
                    "PluginChanged",
                    "plugin generation changed during execution",
                ));
            }
        }
        result.map_err(|e| {
            host.last_error
                .lock()
                .ok()
                .and_then(|last| last.clone())
                .unwrap_or_else(|| plugin_error(e))
        })
    }
    async fn run_job(self: &Arc<Self>, id: &str) -> CoreResult<Value> {
        Box::pin(self.run_job_with_claim(id, None)).await
    }
    async fn run_job_with_claim(
        self: &Arc<Self>,
        id: &str,
        claimed: Option<JobGuard>,
    ) -> CoreResult<Value> {
        self.recover_native_jobs()?;
        let candidate = self
            .store
            .job(id)?
            .ok_or_else(|| CoreError::new("NotFound", "job not found"))?;
        if native_jobs::is_native(&candidate) {
            if claimed.is_some() {
                return Err(CoreError::new(
                    "JobDefinitionConflict",
                    "plugin invocation cannot claim a native service job",
                ));
            }
            return Box::pin(self.run_native_job(id)).await;
        }
        let key = input_hash(&json!([
            candidate["data"]["plugin_id"],
            candidate["data"]["input"]["account_id"],
            candidate["data"]["input"]["task_id"]
        ]));
        let workflow = {
            let mut locks = self
                .workflow_locks
                .lock()
                .map_err(|_| CoreError::new("InternalError", "workflow lock unavailable"))?;
            locks.retain(|_, weak| weak.strong_count() > 0);
            match locks.get(&key).and_then(std::sync::Weak::upgrade) {
                Some(lock) => lock,
                None => {
                    let lock = Arc::new(tokio::sync::Mutex::new(()));
                    locks.insert(key, Arc::downgrade(&lock));
                    lock
                }
            }
        };
        // Continuations wait until the prior stage has persisted its state.
        let _workflow = workflow.lock_owned().await;
        let _slot = self
            .plugin_slots
            .acquire()
            .await
            .map_err(|_| CoreError::new("Shutdown", "plugin execution is unavailable"))?;
        let job = self
            .store
            .job(id)?
            .ok_or_else(|| CoreError::new("NotFound", "job not found"))?;
        if job["state"] == "needs_reconciliation" {
            return Err(CoreError::new(
                "NeedsReconciliation",
                "this job has an unresolved outcome",
            ));
        }
        let job_guard = match claimed {
            Some(claimed) => {
                if !self.store.owns_job_lease(id, &claimed.lease)? {
                    return Err(CoreError::new(
                        "JobNotRunnable",
                        "invocation lease is no longer active",
                    ));
                }
                claimed
            }
            None => JobGuard {
                engine: Arc::downgrade(self),
                id: id.into(),
                lease: self.store.claim_job(id)?.ok_or_else(|| {
                    CoreError::new("JobNotRunnable", "job is not due or already claimed")
                })?,
            },
        };
        let lease = job_guard.lease.clone();
        let data = &job["data"];
        if let Some(s) = data["deadline_at"].as_str()
            && DateTime::parse_from_rfc3339(s).is_ok_and(|d| d <= Utc::now())
        {
            self.store
                .finish_job(id, &lease, "expired", &json!({}), None)?;
            return Ok(json!({"state":"expired"}));
        }
        let principal: Principal = serde_json::from_value(job["owner"].clone())?;
        let result = self
            .run_plugin(
                &principal,
                required_string(data, "plugin_id")?,
                required_string(data, "action")?,
                data.get("input").cloned().unwrap_or(json!({})),
                Some((id.into(), lease.clone())),
                data["deadline_at"].is_null(),
            )
            .await;
        let (state, body) = match &result {
            Ok(v) => ("succeeded", v.clone()),
            Err(e) => {
                let state = match e.code.as_str() {
                    "AuthenticationRequired" => "waiting_for_auth",
                    "ApprovalRequired" | "PermissionDenied" => "waiting_for_approval",
                    "NeedsReconciliation" => "needs_reconciliation",
                    _ => "failed",
                };
                (state, json!({"error":e}))
            }
        };
        let next = if result.is_ok() {
            data["interval_seconds"]
                .as_i64()
                .map(|s| (Utc::now() + chrono::Duration::seconds(s)).to_rfc3339())
        } else {
            None
        };
        self.store.finish_job(
            id,
            &lease,
            if next.is_some() { "scheduled" } else { state },
            &body,
            next.as_deref(),
        )?;
        if next.is_some()
            && let Some(job) = self.store.job(id)?
        {
            let _ = self.schedule_wake(&job).await;
        }
        let _ = self.store.event(
            "job_finished",
            &json!({"principal":principal.id,"job_id":id,"state":state}),
        );
        result
    }
    pub async fn tick(self: &Arc<Self>) -> CoreResult<usize> {
        self.publish_notifications().await?;
        self.recover_native_jobs()?;
        let jobs = self.store.due_jobs()?;
        let count = jobs.len();
        let futures = jobs.iter().map(|job| async move {
            if let Some(id) = job["id"].as_str() {
                let _ = self.run_job(id).await;
            }
        });
        futures_util::future::join_all(futures).await;
        Ok(count)
    }
    async fn publish_notifications(&self) -> CoreResult<()> {
        use crate::organizer::{self, DeliveryChannel, DeliveryOutcome, NotificationOptions};
        let batch = organizer::claim_due_notifications(
            &self.store,
            Utc::now(),
            NotificationOptions {
                include_platform: self
                    .platform
                    .capabilities()
                    .contains(&"notifications.show".to_owned()),
                ..Default::default()
            },
        )?;
        for claim in batch.claims {
            if !organizer::notification_claim_is_current(&self.store, &claim, Utc::now())? {
                continue;
            }
            let outcome=match claim.channel{
    DeliveryChannel::Event=>match self.store.event("activity_notification",&json!({"principal":claim.principal.id,"delivery_key":claim.delivery_key,"activity":claim.activity})){Ok(sequence)=>DeliveryOutcome::Delivered{event_sequence:Some(sequence)},Err(_)=>DeliveryOutcome::Retry{after_seconds:10}},
    DeliveryChannel::Platform=>{
     let grant=self.store.grant(&claim.principal.id)?;
     match tokio::time::timeout(std::time::Duration::from_secs(30),self.platform.call("notifications.show",json!({"principal":claim.principal,"grant":grant,"input":{"delivery_key":claim.delivery_key,"activity":claim.activity}}))).await{
      Ok(Ok(_))=>DeliveryOutcome::Delivered{event_sequence:None},Ok(Err(error))if matches!(error.code.as_str(),"CapabilityUnavailable"|"PermissionDenied")=>DeliveryOutcome::Retry{after_seconds:60},_=>DeliveryOutcome::Uncertain
     }
    }
   };
            let _ = organizer::finish_notification(&self.store, &claim, outcome, Utc::now());
        }
        Ok(())
    }
}

struct RunHost {
    package_path: PathBuf,
    engine: Arc<Engine>,
    plugin_id: String,
    action: String,
    input_fingerprint: String,
    bound_account: Option<String>,
    caller: Principal,
    job_id: Option<(String, String)>,
    manifest: Value,
    last_error: Mutex<Option<CoreError>>,
    uncertain: AtomicBool,
}
struct MutationGuard<'a> {
    host: &'a RunHost,
    armed: bool,
}
impl Drop for MutationGuard<'_> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        self.host.uncertain.store(true, Ordering::SeqCst);
        let error = CoreError::new(
            "NeedsReconciliation",
            "a write was interrupted before its outcome was confirmed",
        );
        if let Ok(mut last) = self.host.last_error.lock() {
            *last = Some(error.clone());
        }
        if let Some((id, lease)) = &self.host.job_id {
            let _ = self.host.engine.store.finish_job(
                id,
                lease,
                "needs_reconciliation",
                &json!({"error":error}),
                None,
            );
        }
        let _=self.host.engine.store.event("write_uncertain",&json!({"principal":self.host.caller.id,"plugin_id":self.host.plugin_id,"job_id":self.host.job_id.as_ref().map(|(id,_)|id)}));
    }
}
struct RunGuard {
    engine: std::sync::Weak<Engine>,
    id: String,
}
impl Drop for RunGuard {
    fn drop(&mut self) {
        if let Some(e) = self.engine.upgrade()
            && let Ok(mut running) = e.running.lock()
            && let Some((_, token)) = running.remove(&self.id)
        {
            token.cancel();
        }
    }
}
struct JobGuard {
    engine: std::sync::Weak<Engine>,
    id: String,
    lease: String,
}
impl Drop for JobGuard {
    fn drop(&mut self) {
        if let Some(e) = self.engine.upgrade() {
            let _=e.store.finish_job(&self.id,&self.lease,"needs_reconciliation",&json!({"error":{"code":"Interrupted","message":"execution stopped before its outcome was recorded"}}),None);
        }
    }
}
#[async_trait]
impl PluginHost for RunHost {
    async fn call(
        &self,
        plugin_id: &str,
        method: &str,
        mut params: Value,
    ) -> Result<Value, PluginError> {
        let lifecycle = self.engine.plugin_lifecycle.read().await;
        let remote_write = matches!(method, "mail.send" | "mail.set_flags")
            || ((method == "http.request" || method == "browser.request")
                && !matches!(
                    params["method"]
                        .as_str()
                        .unwrap_or("GET")
                        .to_ascii_uppercase()
                        .as_str(),
                    "GET" | "HEAD" | "OPTIONS"
                ));
        if remote_write && self.uncertain.load(Ordering::SeqCst) {
            return Err(PluginError::new(
                "NeedsReconciliation",
                "further writes are blocked until reconciliation",
            ));
        }
        let mut mutation = remote_write.then(|| MutationGuard {
            host: self,
            armed: true,
        });
        let result:CoreResult<Value>=async{
   if plugin_id!=self.plugin_id{return Err(CoreError::new("PermissionDenied","plugin identity mismatch"));}
   let current=self.engine.installed(plugin_id)?;
   if current["manifest"]!=self.manifest || Path::new(required_string(&current,"path")?)!=self.package_path.as_path(){return Err(CoreError::new("PluginChanged","plugin generation changed during execution"));}
   if let Some((id,_))=&self.job_id&& !self.engine.store.job_active(id)?&&!(self.uncertain.load(Ordering::SeqCst)&&!remote_write){return Err(CoreError::new("Cancelled","job is no longer running"));}
   let cap=self.engine.required_capability(method);
   let declared=self.manifest["capabilities"].as_array().is_some_and(|caps|caps.iter().any(|v|v.as_str()==Some(cap.as_str())));
   if method!="capabilities.has"&&!declared{return Err(CoreError::new("PermissionDenied",format!("plugin did not declare {cap}")));}
   let principal=Principal{id:format!("plugin:{plugin_id}"),kind:PrincipalKind::Plugin};
   let mut grant=self.engine.store.grant(&principal.id)?;
   grant.origins.retain(|origin|self.manifest["network"].as_array().is_some_and(|origins|origins.iter().any(|v|v.as_str()==Some(origin.as_str()))));
   if method!="capabilities.has" {grant.check(&principal,&cap)?;}
   if !self.caller.is_owner(){
    // Caller action grant delegates this plugin's approved capabilities, but account access is intersected.
    let caller_grant=self.engine.store.grant(&self.caller.id)?;
    caller_grant.check_account(&self.caller,params["account_id"].as_str())?;
    self.engine.validate_plugin_action(&self.caller,plugin_id,&self.action,&self.input_fingerprint)?;
    grant.capabilities=grant.capabilities.intersection(&caller_grant.capabilities).cloned().collect();
    grant.origins=grant.origins.intersection(&caller_grant.origins).cloned().collect();
    grant.allow_private_network&=caller_grant.allow_private_network;
    grant.account_ids=grant.account_ids.intersection(&caller_grant.account_ids).cloned().collect();
    grant.source_ids=grant.source_ids.intersection(&caller_grant.source_ids).cloned().collect();
   }
   if let Some(account)=&self.bound_account{
    grant.check_account(&principal,Some(account))?;
    grant.account_ids.retain(|a|a==account);
    if matches!(method,"sources.upsert"|"files.download")&&params["account_id"].as_str().is_none_or(str::is_empty){params["account_id"]=json!(account);}
   }
   if method!="capabilities.has"{grant.check(&principal,&cap)?;}
   if remote_write {
    let write_cap=match method{"http.request"=>"http.write","browser.request"=>"browser.write","mail.send"=>"mail.send",_=>"mail.write"};
    if !self.manifest["capabilities"].as_array().is_some_and(|caps|caps.iter().any(|v|v.as_str()==Some(write_cap))){return Err(CoreError::new("PermissionDenied","plugin did not declare the actual write capability"));}
    grant.check(&principal,write_cap)?;
    if !self.caller.is_owner()&&!self.engine.store.grant(&self.caller.id)?.allows(&format!("execute:{}:{}",self.plugin_id,self.action)){return Err(CoreError::new("ApprovalRequired","actual writes require an execution grant regardless of manifest labels"));}
    if self.engine.store.has_uncertain_job(plugin_id,params["account_id"].as_str().or(self.bound_account.as_deref()))?{return Err(CoreError::new("NeedsReconciliation","a previous write for this plugin/account remains uncertain"));}
   }
   if method=="sources.upsert"&&!grant.account_ids.is_empty()&&params["account_id"].as_str().is_none_or(str::is_empty){return Err(CoreError::invalid("account-scoped plugin records require account_id"));}
   if method=="sources.upsert"||method=="files.download"{
    let sensitive=grant.capabilities.iter().filter(|cap|cap.ends_with(".read")&&!matches!(cap.as_str(),"storage.read"|"sources.read")).cloned().collect();
    let source=params["source_id"].as_str().map(str::to_owned).unwrap_or_else(||format!("{plugin_id}.documents"));
    self.engine.store.require_source_capabilities(&principal.id,&source,&sensitive)?;
   }
   if matches!(method,"storage.get"|"storage.set"|"storage.delete"){
    grant.check_account(&principal,params["account_id"].as_str())?;
    let fingerprint=input_hash(&json!({"accounts":grant.account_ids,"capabilities":grant.capabilities,"origins":grant.origins,"private_network":grant.allow_private_network,"sources":grant.source_ids,"organizer_scope":grant.organizer_scope}));
    let namespace=format!("plugin-state:{plugin_id}:{fingerprint}");let key=required_string(&params,"key")?;
    return match method{"storage.get"=>self.engine.store.kv_get(&namespace,key),"storage.set"=>{self.engine.store.kv_set(&namespace,key,&params["value"])?;Ok(Value::Null)},_=>{self.engine.store.kv_delete(&namespace,key)?;Ok(Value::Null)}};
   }
   // The private storage operation above is atomic with lifecycle transitions.
   // Release before external awaits so disabling can cancel in-flight requests.
   drop(lifecycle);
   if method=="http.request" {
    let u=url::Url::parse(required_string(&params,"url")?).map_err(|_|CoreError::invalid("invalid URL"))?;
    if !self.manifest["network"].as_array().is_some_and(|origins|origins.iter().any(|v|v.as_str()==Some(&u.origin().ascii_serialization()))){return Err(CoreError::new("PermissionDenied","network origin not declared by plugin"));}
    grant.origins.retain(|origin|self.manifest["network"].as_array().is_some_and(|origins|origins.iter().any(|v|v.as_str()==Some(origin.as_str()))));
   }
   if method=="jobs.schedule"{
    if params["plugin_id"]!=self.plugin_id{return Err(CoreError::new("PermissionDenied","a plugin can schedule only its own actions"));}
    grant.check_account(&principal,params["input"]["account_id"].as_str())?;
    // Preserve the original UI/MCP authority across deferred execution. Storing
    // the plugin itself as owner would discard the caller's account constraints.
    let caller_grant=self.engine.store.grant(&self.caller.id)?;
    return Box::pin(self.engine.dispatch_with_grant(&self.caller,method,params,caller_grant)).await;
   }
   if method=="jobs.status"||method=="jobs.cancel"{
    let belongs=|job:&Value|job["data"]["plugin_id"]==self.plugin_id
      &&(self.caller.is_owner()||job["owner"]["id"]==self.caller.id)
      &&job["data"]["input"]["account_id"].as_str().is_none_or(|account|grant.account_ids.contains(account));
    if let Some(id)=params["job_id"].as_str(){
     if !self.engine.store.job(id)?.as_ref().is_some_and(belongs){return Err(CoreError::new("NotFound","job not found in this plugin invocation scope"));}
     let caller_grant=self.engine.store.grant(&self.caller.id)?;
     return Box::pin(self.engine.dispatch_with_grant(&self.caller,method,params,caller_grant)).await;
    }
    if method=="jobs.cancel"{return Err(CoreError::invalid("job_id is required"));}
    return Ok(json!(self.engine.store.jobs()?.into_iter().filter(belongs).collect::<Vec<_>>()));
   }
   self.engine.dispatch_with_grant(&principal,method,params,grant).await
  }.await;
        if (result.is_ok()
            || result.as_ref().err().is_some_and(|e| {
                matches!(
                    e.code.as_str(),
                    "PermissionDenied"
                        | "ApprovalRequired"
                        | "InvalidInput"
                        | "AuthenticationRequired"
                        | "CapabilityUnavailable"
                        | "Cancelled"
                )
            }))
            && let Some(guard) = &mut mutation
        {
            guard.armed = false;
        }
        drop(mutation);
        result.map_err(|e| {
            if e.code == "NeedsReconciliation"
                && let Some((id, lease)) = &self.job_id
            {
                let _ = self.engine.store.finish_job(
                    id,
                    lease,
                    "needs_reconciliation",
                    &json!({"error":e}),
                    None,
                );
            }
            if let Ok(mut last) = self.last_error.lock() {
                *last = Some(e.clone());
            }
            PluginError::new(e.code, e.message)
        })
    }
}
fn owner(principal: &Principal) -> CoreResult<()> {
    if principal.is_owner() {
        Ok(())
    } else {
        Err(CoreError::new(
            "PermissionDenied",
            "operation requires the trusted owner adapter",
        ))
    }
}
fn plugin_error(error: PluginError) -> CoreError {
    CoreError::new(&error.code, error.message)
}
fn input_hash(input: &Value) -> String {
    hex::encode(Sha256::digest(input.to_string().as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::UnavailablePlatform;
    #[tokio::test]
    async fn external_identity_cannot_be_forged_in_params() {
        let d = tempfile::tempdir().unwrap();
        let e = Engine::open(d.path(), Arc::new(UnavailablePlatform)).unwrap();
        let r=e.handle(Principal{id:"mcp:test".into(),kind:PrincipalKind::Mcp},Request{id:"1".into(),method:"permissions.set".into(),params:json!({"principal":"owner","subject":"attacker","grant":{"capabilities":["http.request"]}})}).await;
        assert_eq!(r.error.unwrap().code, "PermissionDenied");
    }
    #[tokio::test]
    async fn stored_account_has_no_credential_fields() {
        let d = tempfile::tempdir().unwrap();
        let e = Engine::open(d.path(), Arc::new(UnavailablePlatform)).unwrap();
        let r=e.handle(Principal::owner(),Request{id:"1".into(),method:"accounts.upsert".into(),params:json!({"account_id":"a","password":"never-store","bearer":"never-store"})}).await;
        assert!(!r.result.unwrap().to_string().contains("never-store"));
    }
}
