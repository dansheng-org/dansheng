//! Isolated source-only JavaScript plugins and atomic local package installation.
//!
//! Required dependencies: `async-trait`, `serde` (derive), `serde_json`, `thiserror`,
//! `url`, `uuid` (v4), `tokio` (rt, time, sync, macros), and
//! `rquickjs = { version = "0.14", default-features = false,
//! features = ["std", "futures", "loader"] }`. Do not unify `rust-alloc` into
//! rquickjs: its custom allocator disables QuickJS's native heap accounting.
//! Signed catalogs additionally require `ed25519-dalek = "2"` (default features)
//! and `sha2 = "0.10"`; no random-number feature is needed for verification.
//! Archive extraction requires `zip = { version = "2", default-features = false,
//! features = ["deflate"] }` and performs no network requests.
//! Module-local tests additionally use `tempfile` and Tokio's test macros.
//!
//! Every ctx method accepts one JSON parameter (default `{}`) and returns a
//! Promise of JSON. All calls, including `capabilities.has`, go to PluginHost;
//! manifest declarations never confer authority. Host implementations must be
//! cancellation-safe, avoid blocking in Future::poll, and reconcile uncertain
//! external writes before any retry. This module never retries host calls.

mod archive;
mod catalog;
mod error;
mod manifest;
mod package;
mod runtime;
mod storage_schema;

pub use archive::extract_package_archive;
pub use catalog::{
    CatalogPackage, MAX_CATALOG_BYTES, PackageVerification, PluginCatalog, SignedPluginCatalog,
    TrustedPublisher, VerifiedCatalog, compute_package_integrity, install_catalog_package,
    verify_catalog,
};
pub use error::PluginError;
pub use manifest::{
    MAX_MANIFEST_BYTES, PackageIntegrity, PluginAction, PluginManifest, PluginPublisher,
};
pub use package::{
    InstalledPlugin, MANIFEST_FILE, PermissionChanges, PluginPackage, UninstalledPlugin,
    install_local_package, installed_package, rollback_local_package, uninstall_local_package,
    validate_package,
};
pub use runtime::{PluginCancellation, PluginHost, PluginLimits, PluginRunner};
pub use storage_schema::{PluginStorageMigration, PluginStorageOperation, PluginStorageSchema};

#[cfg(test)]
mod tests;

#[cfg(test)]
mod package_tests;

#[cfg(test)]
mod archive_tests;
