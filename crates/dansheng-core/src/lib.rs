//! Local-first, UI-independent campus data and automation engine.
pub mod api;
pub mod assets;
pub mod backup;
pub mod engine;
pub mod network;
pub mod network_routes;
pub mod organizer;
pub mod platform;
mod plugin_storage;
pub mod plugins;
pub mod policy;
mod search;
pub mod services;
pub mod store;
pub use api::{CoreError, CoreResult, Principal, PrincipalKind, Request, Response};
pub use engine::Engine;
pub use platform::{PlatformPort, UnavailablePlatform};
