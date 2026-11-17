//! Group integration suites into one executable to reduce Windows startup overhead.
//! Keep helpers module-local; each test owns its temporary profiles and loopback servers.

#[path = "suites/assets.rs"]
mod assets;
#[path = "suites/backup.rs"]
mod backup;
#[path = "suites/binary_http.rs"]
mod binary_http;
#[path = "suites/closed_loop.rs"]
mod closed_loop;
#[path = "suites/immediate_plugin_jobs.rs"]
mod immediate_plugin_jobs;
#[path = "suites/native_jobs.rs"]
mod native_jobs;
#[path = "suites/network_routes.rs"]
mod network_routes;
#[path = "suites/organizer.rs"]
mod organizer;
#[path = "suites/plugin_storage.rs"]
mod plugin_storage;
#[path = "suites/secret_headers.rs"]
mod secret_headers;
