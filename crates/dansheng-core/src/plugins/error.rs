use serde::{Deserialize, Serialize};

/// A stable, serializable boundary error. Host implementations must supply safe
/// messages: never include credentials, request bodies, or remote error bodies.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, thiserror::Error)]
#[error("{code}: {message}")]
pub struct PluginError {
    pub code: String,
    pub message: String,
}

impl PluginError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub(super) fn manifest(message: &'static str) -> Self {
        Self::new("INVALID_MANIFEST", message)
    }

    pub(super) fn package(message: &'static str) -> Self {
        Self::new("INVALID_PACKAGE", message)
    }

    pub(super) fn path() -> Self {
        Self::new("PATH_ESCAPE", "Module paths must remain inside the package")
    }

    pub(super) fn io() -> Self {
        // std::io::Error may contain absolute user paths. Keep it out of the wire.
        Self::new("PLUGIN_IO", "Local plugin package I/O failed")
    }

    pub(super) fn timeout() -> Self {
        Self::new("PLUGIN_TIMEOUT", "Plugin wall deadline exceeded")
    }

    pub(super) fn cancelled() -> Self {
        Self::new("PLUGIN_CANCELLED", "Plugin execution was cancelled")
    }

    pub(super) fn quota() -> Self {
        Self::new("HOST_QUOTA", "Plugin host I/O quota exceeded")
    }
}
