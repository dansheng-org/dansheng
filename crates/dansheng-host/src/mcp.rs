//! MCP is a client adapter, never a database owner or an authority escalation path.
use crate::{Client, ClientConfig};
use dansheng_core::{CoreError, CoreResult, PrincipalKind, Response};
use rmcp::{ErrorData, RoleServer, ServerHandler, ServiceExt, model::*, service::RequestContext};
use serde_json::{Value, json};
use std::sync::LazyLock;

const BASE_METHODS: &[&str] = &[
    "core.info",
    "capabilities.has",
    "sources.query",
    "search.query",
    "accounts.list",
    "auth.status",
    "plugins.list",
    "plugins.run",
    "jobs.status",
    "jobs.schedule",
    "jobs.cancel",
    "jobs.run",
    "jobs.resume",
    "events.poll",
    "ui.get",
    "actions.preview",
    "todo.list",
    "todo.get",
    "todo.create",
    "todo.update",
    "todo.complete",
    "todo.delete",
    "todo.link",
    "calendar.list",
    "calendar.get",
    "calendar.conflicts",
    "calendar.export_ics",
    "calendar.create",
    "calendar.update",
    "calendar.delete",
    "calendar.link",
    "activity.list",
    "activity.sync",
    "activity.read",
    "activity.archive",
    "activity.notifications",
    "reminders.list",
    "reminders.schedule",
    "reminders.cancel",
    "reminders.due",
    "files.list",
    "files.read",
    "files.index",
    "files.download",
];
#[cfg(feature = "services")]
const MAIL_METHODS: &[&str] = &[
    "mail.status",
    "mail.sync",
    "mail.folders",
    "mail.list",
    "mail.read",
    "mail.attachment.read",
    "mail.draft.save",
    "mail.draft.list",
    "mail.send",
    "mail.set_flags",
];
#[cfg(feature = "services")]
fn campus_query(method: &str, capability: &str) -> bool {
    (method.starts_with("fudan.")
        || method.starts_with("canvas.")
        || method.starts_with("community."))
        && capability.ends_with(".read")
        && !method.ends_with(".configure")
}
static METHODS: LazyLock<Vec<&'static str>> = LazyLock::new(|| {
    let mut methods = BASE_METHODS.to_vec();
    #[cfg(feature = "services")]
    {
        use dansheng_core::services::CoreService;
        methods.extend(MAIL_METHODS);
        methods.extend(
            dansheng_connectors::core_adapter::CampusService
                .methods()
                .into_iter()
                .filter(|(method, capability)| campus_query(method, capability))
                .map(|(method, _)| method),
        );
    }
    methods.sort_unstable();
    methods.dedup();
    methods
});
const RESOURCES: &[(&str, &str, &str)] = &[
    ("dansheng://sources", "Sources", "sources.query"),
    ("dansheng://jobs", "Jobs", "jobs.status"),
    ("dansheng://plugins", "Plugins", "plugins.list"),
    ("dansheng://events", "Events", "events.poll"),
    ("dansheng://todos", "Todos", "todo.list"),
    ("dansheng://calendar", "Calendar", "calendar.list"),
    ("dansheng://activity", "Activity", "activity.list"),
    ("dansheng://reminders", "Reminders", "reminders.list"),
    ("dansheng://files", "Managed files", "files.list"),
];
fn mail_resource(uri: &str) -> Option<(&'static str, Value)> {
    let (account, resource) = uri.strip_prefix("dansheng://mail/")?.split_once('/')?;
    if account.is_empty()
        || account.len() > 80
        || !account
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return None;
    }
    let method = match resource {
        "folders" => "mail.folders",
        "messages" => "mail.list",
        "drafts" => "mail.draft.list",
        _ => return None,
    };
    Some((method, json!({"account_id":account})))
}

#[derive(Clone)]
pub struct McpAdapter {
    client: Client,
}
impl McpAdapter {
    pub async fn connect(config: &ClientConfig) -> CoreResult<Self> {
        let client = Client::connect(config).await?;
        if client.principal.kind != PrincipalKind::Mcp {
            return Err(CoreError::new(
                "PermissionDenied",
                "MCP requires its dedicated MCP client token",
            ));
        }
        Ok(Self { client })
    }
    pub async fn dispatch(&self, method: &str, params: Value) -> CoreResult<Response> {
        if !METHODS.contains(&method) {
            return Err(CoreError::new(
                "PermissionDenied",
                "method is not exposed through MCP",
            ));
        }
        self.client.invoke(method, params).await
    }
}

fn model<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, ErrorData> {
    serde_json::from_value(value)
        .map_err(|_| ErrorData::internal_error("MCP model construction failed", None))
}
fn tools() -> Vec<Value> {
    let query = json!({"type":"object", "properties":{}, "additionalProperties":true});
    vec![
        json!({"name":"sources_query", "description":"Query local records within explicit account/source grants. sources.read alone does not grant global anonymous records.", "inputSchema":query}),
        json!({"name":"search_query", "description":"Search local campus data within explicit account/source grants.", "inputSchema":query}),
        json!({"name":"jobs_list", "description":"Inspect persisted jobs within this client's grants.", "inputSchema":query}),
        json!({"name":"events_list", "description":"Read local events within this client's grants.", "inputSchema":query}),
        json!({"name":"core_call", "description":"Controlled core calls: action previews, organizer, managed files, mail, plugin runs and scheduling. Each operation requires core grants. Mail sends require an exact preview grant or explicit full-send authority. Reconcile uncertain write outcomes before retrying.",
            "inputSchema":{"type":"object", "properties":{"method":{"type":"string","enum":METHODS.as_slice()}, "params":{"type":"object"}}, "required":["method"], "additionalProperties":false}}),
    ]
}
impl ServerHandler for McpAdapter {
    fn get_info(&self) -> ServerConfig {
        let mut config = ServerConfig::new(ServerCapabilities::builder().enable_tools().enable_resources().build())
            .with_instructions("Local dansheng service. Every request uses a dedicated MCP principal and core grants. External write timeouts are uncertain; reconcile before retrying.");
        config.server_info = Implementation::new("dansheng-host", env!("CARGO_PKG_VERSION"));
        config
    }
    async fn list_tools(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        model(json!({"tools":tools()}))
    }
    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let params = Value::Object(request.arguments.unwrap_or_default());
        let (method, params) = match request.name.as_ref() {
            "sources_query" => ("sources.query", params),
            "search_query" => ("search.query", params),
            "jobs_list" => ("jobs.status", params),
            "events_list" => ("events.poll", params),
            "core_call" => {
                let method = params
                    .get("method")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ErrorData::invalid_params("method is required", None))?
                    .to_owned();
                let input = params.get("params").cloned().unwrap_or_else(|| json!({}));
                if !input.is_object() {
                    return Err(ErrorData::invalid_params("params must be an object", None));
                }
                return Ok(tool_result(self.dispatch(&method, input).await).into());
            }
            _ => return Err(ErrorData::invalid_params("unknown tool", None)),
        };
        Ok(tool_result(self.dispatch(method, params).await).into())
    }
    async fn list_resources(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, ErrorData> {
        let mut resources: Vec<Value> = RESOURCES
            .iter()
            .map(|(uri, name, _)| json!({"uri":uri,"name":name,"mimeType":"application/json"}))
            .collect();
        resources.push(json!({"uri":"dansheng://schema","name":"Core request and response schema","mimeType":"application/json"}));
        model(json!({"resources":resources}))
    }
    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, ErrorData> {
        let uri = request.uri.as_str();
        let text = if uri == "dansheng://schema" {
            crate::schema().to_string()
        } else {
            let (method, params) = RESOURCES
                .iter()
                .find(|(resource, _, _)| *resource == uri)
                .map(|(_, _, method)| (*method, json!({})))
                .or_else(|| mail_resource(uri))
                .ok_or_else(|| ErrorData::invalid_params("unknown resource", None))?;
            match self.dispatch(method, params).await {
                Ok(response) => serde_json::to_string(&response).unwrap_or_default(),
                Err(_) => {
                    return Err(ErrorData::internal_error(
                        "local service unavailable; reconcile any pending requests",
                        None,
                    ));
                }
            }
        };
        let result: ReadResourceResult =
            model(json!({"contents":[{"uri":uri,"mimeType":"application/json","text":text}]}))?;
        Ok(result.into())
    }
    async fn list_resource_templates(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListResourceTemplatesResult, ErrorData> {
        model(json!({"resourceTemplates":[
            {"uriTemplate":"dansheng://mail/{account_id}/folders","name":"Cached mailbox folders","mimeType":"application/json"},
            {"uriTemplate":"dansheng://mail/{account_id}/messages","name":"Cached INBOX metadata","mimeType":"application/json"},
            {"uriTemplate":"dansheng://mail/{account_id}/drafts","name":"Local draft summaries","mimeType":"application/json"}
        ]}))
    }
}
fn tool_result(result: CoreResult<Response>) -> CallToolResult {
    match result {
        Ok(response) => {
            let failed = response.error.is_some();
            let content = vec![ContentBlock::text(
                serde_json::to_string(&response).unwrap_or_default(),
            )];
            if failed {
                CallToolResult::error(content)
            } else {
                CallToolResult::success(content)
            }
        }
        Err(error) => {
            CallToolResult::error(vec![ContentBlock::text(json!({"error":error}).to_string())])
        }
    }
}
pub async fn serve_stdio(config: &ClientConfig) -> CoreResult<()> {
    let adapter = McpAdapter::connect(config).await?;
    let service = adapter
        .serve(rmcp::transport::stdio())
        .await
        .map_err(|_| CoreError::new("McpError", "MCP stdio initialization failed"))?;
    service
        .waiting()
        .await
        .map_err(|_| CoreError::new("McpError", "MCP stdio service failed"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn schemas_construct_and_no_privilege_tools_are_exposed() {
        for tool in tools() {
            model::<Tool>(tool).unwrap();
        }
        for method in [
            "permissions.grant",
            "grants.set",
            "clients.register",
            "auth.session.set",
            "plugins.install",
            "permissions.set",
            "permissions.get",
            "jobs.reconcile",
            "vault.get",
            "vault.set",
            "vault.delete",
            "mail.configure",
            "canvas.configure",
            "files.export",
            "files.open_path",
            "backup.restore",
        ] {
            assert!(!METHODS.contains(&method));
        }
    }
    #[test]
    fn organizer_and_bounded_mail_file_operations_are_exposed() {
        for method in METHODS.iter().filter(|method| {
            method.starts_with("todo.")
                || method.starts_with("calendar.")
                || method.starts_with("activity.")
                || method.starts_with("reminders.")
        }) {
            assert!(dansheng_core::organizer::required_capability(method).is_some());
        }
        for method in [
            "actions.preview",
            "jobs.resume",
            "todo.link",
            "calendar.conflicts",
            "calendar.export_ics",
            "reminders.due",
            "files.list",
            "files.read",
            "files.index",
            "files.download",
        ] {
            assert!(METHODS.contains(&method));
        }
        #[cfg(feature = "services")]
        for method in [
            "mail.send",
            "mail.draft.save",
            "mail.status",
            "fudan.semesters",
            "canvas.courses.sync",
        ] {
            assert!(METHODS.contains(&method));
        }
    }
    #[test]
    fn mail_resources_are_read_only_scoped_and_protocol_traces_are_disabled() {
        assert_eq!(
            mail_resource("dansheng://mail/campus/messages").unwrap().0,
            "mail.list"
        );
        for uri in [
            "dansheng://mail/campus/send",
            "dansheng://mail/campus/vault.get",
            "dansheng://mail/campus/messages/extra",
            "dansheng://mail/%2fcampus/messages",
        ] {
            assert!(mail_resource(uri).is_none());
        }
        #[cfg(feature = "services")]
        assert!(log::STATIC_MAX_LEVEL <= log::LevelFilter::Info);
    }
    #[cfg(feature = "services")]
    #[test]
    fn registered_service_surface_excludes_configuration_and_credential_presentation() {
        use dansheng_core::services::CoreService;
        for (method, capability) in dansheng_connectors::core_adapter::CampusService.methods() {
            let is_query = !matches!(method, "canvas.configure" | "fudan.qr.present");
            if is_query {
                assert!(
                    capability.ends_with(".read"),
                    "campus query has a non-read capability: {method}"
                );
            }
            assert_eq!(
                METHODS.contains(&method),
                is_query,
                "campus method surface mismatch: {method}"
            );
        }
        for (method, _) in dansheng_connectors::mail::MailService::default().methods() {
            assert_eq!(
                METHODS.contains(&method),
                method != "mail.configure",
                "mail method surface mismatch: {method}"
            );
        }
    }
    #[cfg(feature = "services")]
    #[test]
    fn dynamic_campus_catalog_exposes_only_source_queries() {
        assert!(campus_query("fudan.new_named_query", "fudan.academic.read"));
        for (method, capability) in [
            ("canvas.configure", "canvas.read"),
            ("fudan.update", "fudan.write"),
            ("vault.get", "vault.read"),
            ("permissions.get", "permissions.read"),
            ("jobs.reconcile", "jobs.read"),
        ] {
            assert!(!campus_query(method, capability));
        }
        let core_call = tools()
            .into_iter()
            .find(|tool| tool["name"] == "core_call")
            .unwrap();
        let values = core_call["inputSchema"]["properties"]["method"]["enum"]
            .as_array()
            .unwrap();
        for method in METHODS.iter() {
            assert!(values.iter().any(|value| value == method));
        }
    }
}
