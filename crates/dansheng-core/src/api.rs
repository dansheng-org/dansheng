use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Request {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Response {
    pub id: String,
    #[serde(
        default,
        deserialize_with = "present_result",
        skip_serializing_if = "Option::is_none"
    )]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<CoreError>,
}

// A successful null is still a result. Option<Value>'s default deserializer
// otherwise turns explicit JSON null into None, and a forwarding IPC/CLI/MCP
// adapter drops the result field when it serializes the response again.
fn present_result<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<Value>, D::Error> {
    Value::deserialize(deserializer).map(Some)
}

#[cfg(test)]
mod response_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn successful_null_survives_ipc_response_forwarding() {
        for value in [
            Value::Null,
            json!(false),
            json!(0),
            json!(""),
            json!([]),
            json!({}),
        ] {
            let wire = json!({"id":"fixture","result":value});
            let decoded: Response = serde_json::from_value(wire.clone()).unwrap();
            assert_eq!(decoded.result, Some(value));
            assert_eq!(serde_json::to_value(decoded).unwrap(), wire);
        }
        let error = json!({"id":"fixture","error":{"code":"Denied","message":"synthetic"}});
        let decoded: Response = serde_json::from_value(error.clone()).unwrap();
        assert_eq!(decoded.result, None);
        assert_eq!(serde_json::to_value(decoded).unwrap(), error);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, thiserror::Error)]
#[error("{code}: {message}")]
pub struct CoreError {
    pub code: String,
    pub message: String,
}

impl CoreError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new("InvalidInput", message)
    }
}

pub type CoreResult<T> = Result<T, CoreError>;

impl From<rusqlite::Error> for CoreError {
    fn from(_: rusqlite::Error) -> Self {
        Self::new("StorageError", "database operation failed")
    }
}
impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        Self::new("IoError", e.kind().to_string())
    }
}
impl From<serde_json::Error> for CoreError {
    fn from(_: serde_json::Error) -> Self {
        Self::invalid("invalid JSON payload")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Event {
    pub sequence: i64,
    pub kind: String,
    pub data: Value,
    pub at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PrincipalKind {
    Owner,
    Client,
    Mcp,
    Plugin,
}

/// Constructed only by trusted adapters, never deserialized from request params.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Principal {
    pub id: String,
    pub kind: PrincipalKind,
}
impl Principal {
    pub fn owner() -> Self {
        Self {
            id: "owner".into(),
            kind: PrincipalKind::Owner,
        }
    }
    pub fn is_owner(&self) -> bool {
        self.kind == PrincipalKind::Owner && self.id == "owner"
    }
}

pub fn required_string<'a>(params: &'a Value, name: &str) -> CoreResult<&'a str> {
    params
        .get(name)
        .and_then(Value::as_str)
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| CoreError::invalid(format!("missing or empty {name}")))
}
