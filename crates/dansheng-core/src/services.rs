//! Trusted, statically linked services extend the core without school coupling.
use crate::{
    api::{CoreResult, Principal},
    network::Network,
    platform::PlatformPort,
    policy::Grant,
    store::Store,
};
use async_trait::async_trait;
use serde_json::Value;

pub struct ServiceContext<'a> {
    pub store: &'a Store,
    pub network: &'a Network,
    pub platform: &'a dyn PlatformPort,
}

#[async_trait]
pub trait CoreService: Send + Sync {
    /// Stable wire method names and the capability checked before invocation.
    fn methods(&self) -> Vec<(&'static str, &'static str)>;
    async fn call(
        &self,
        context: ServiceContext<'_>,
        principal: &Principal,
        grant: &Grant,
        method: &str,
        params: Value,
    ) -> CoreResult<Value>;
}
