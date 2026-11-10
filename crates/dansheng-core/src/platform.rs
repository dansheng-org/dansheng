use crate::api::{CoreError, CoreResult};
use async_trait::async_trait;
use serde_json::Value;

/// UI/platform operations are provided by the embedding app or a desktop broker.
#[async_trait]
pub trait PlatformPort: Send + Sync {
    fn capabilities(&self) -> Vec<String>;
    async fn call(&self, capability: &str, input: Value) -> CoreResult<Value>;
}

#[derive(Default)]
pub struct UnavailablePlatform;
#[async_trait]
impl PlatformPort for UnavailablePlatform {
    fn capabilities(&self) -> Vec<String> {
        vec![]
    }
    async fn call(&self, capability: &str, _: Value) -> CoreResult<Value> {
        Err(CoreError::new(
            "CapabilityUnavailable",
            format!("platform does not provide {capability}"),
        ))
    }
}
