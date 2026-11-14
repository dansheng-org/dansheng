# Implementation contract v0.1

This is the integration contract for parallel contributors; the public product name is dansheng-core.

## Ownership

Main integration owns workspace manifests except the connectors crate, core library/API/store/policy/network/jobs/platform modules, desktop host, FFI and integration tests.
The plugin worker owns `crates/dansheng-core/src/plugins/` and its module-local tests only. The connectors worker owns `crates/dansheng-connectors/` and official plugin examples. A documentation worker may own README/docs/SDK/schema artifacts as explicitly assigned.

## Wire boundary

Requests use `{ "id": "opaque string", "method": "namespace.operation", "params": {} }`. Responses use `{ "id": "...", "result": ... }` or `{ "id": "...", "error": { "code": "...", "message": "..." } }`. Callers do not supply trusted principal identity or grant authority in request parameters. Adapters bind principal identity.

Core events have `sequence`, `kind`, `data` and `at` fields. Long running calls return a persistent job id. Data objects retain account/source/external identifiers, timestamps, and source-specific typed payloads.

## Plugin worker interface

Expose a self-contained `plugins` module with manifest/package validation, local install and execution. Do not modify core `lib.rs` or Cargo.toml.

`PluginHost: Send + Sync` has an async `call(&self, plugin_id: &str, method: &str, params: serde_json::Value) -> Result<serde_json::Value, PluginError>` (use async_trait). The parent provides the implementation.

`PluginRunner::run(package_dir: PathBuf, manifest: PluginManifest, action: String, input: Value, host: Arc<dyn PluginHost>, limits: PluginLimits) -> Result<Value, PluginError>` is async. Implement deterministic cancellation/time/memory bounds. Run isolated QuickJS runtimes on dedicated execution threads, not the Tokio I/O workers. Compile JS ES modules from source; never accept serialized bytecode or native extensions. No Node/browser APIs.

Plugin manifest v1: `id`, `version`, `api_version` (1), `entry`, `name`, `capabilities` (array of strings), `network` (array of URL origins), `actions` (map action id to `{ description, mutating, input_schema? }`), optional `ui` (array of objects). Every action is a named export `(ctx, input)`. ctx offers `http.request`, `auth.status`, `auth.requireLogin`, `storage.get/set/delete`, `sources.upsert/query`, `jobs.schedule/cancel/status`, `ui.publish`, `notifications.show`, `browser.request`, `browser.evaluate`, `capabilities.has`; each delegates to host call with that method. Host independently enforces grants and namespace ownership.

Plugin limits default: 32 MiB VM heap, 512 KiB stack, 30 seconds wall deadline. Host I/O has independent bounded quotas. Async waits must not defeat the deadline. Module imports are package-relative only and cannot escape the package via symlinks or traversal. Validate manifest size and ids. Install into a staging folder, validate, then promote atomically; previous version remains recoverable.

## Connector worker interface

The connectors crate is independent from core. It owns serde domain types, source parsing and service definitions with school URLs. Use async_trait `ConnectorTransport` with an owned `ConnectorRequest` (method, url, headers, optional body) and `ConnectorResponse` (status, final_url, headers, body bytes); provide typed errors. Parent implements transport via mediated HTTP/browser capability. Secrets must never appear in models or logs.

Implement useful reference-derived connectors/parsers for Fudan undergrad/postgrad timetable and generic Canvas; keep response parsing separate from transport. Authentication emits an explicit challenge or uses a host session; never invent a successful login. Fixtures must be synthetic or properly redacted. Official JS examples exercise HTTP, persistent storage, UI descriptions and timed actions.

## Platform and MCP

Android embeds core via C ABI; desktop clients use local IPC. MCP stdio is an adapter to the same service. Credentials, browser contexts and wake-up are platform ports. Missing platform capability returns an explicit error. Sports plugin is a follow-up milestone, Android first, and retains page-context fetch/XHR.
