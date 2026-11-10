use crate::api::{CoreError, CoreResult, Principal};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Grant {
    #[serde(default)]
    pub capabilities: BTreeSet<String>,
    #[serde(default)]
    pub origins: BTreeSet<String>,
    #[serde(default)]
    pub account_ids: BTreeSet<String>,
    #[serde(default)]
    pub source_ids: BTreeSet<String>,
    /// Optional exact input SHA256 bindings for `plugin_id:action`. Missing entry
    /// means the owner deliberately granted the whole named action.
    #[serde(default)]
    pub action_inputs: BTreeMap<String, String>,
    /// Plugins remain private unless the profile owner explicitly grants sharing.
    #[serde(default)]
    pub organizer_scope: Option<String>,
    #[serde(default)]
    pub allow_private_network: bool,
    /// Owner-only HTTPS origins that may resolve to campus LAN / VPN addresses.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub private_network_origins: BTreeSet<String>,
    #[serde(default)]
    pub expires_at: Option<String>,
}

impl Grant {
    pub fn allows(&self, capability: &str) -> bool {
        let active = match &self.expires_at {
            None => true,
            Some(s) => chrono::DateTime::parse_from_rfc3339(s)
                .map(|d| d > chrono::Utc::now())
                .unwrap_or(false),
        };
        active && self.capabilities.contains(capability)
    }
    pub fn check(&self, principal: &Principal, capability: &str) -> CoreResult<()> {
        if principal.is_owner() || self.allows(capability) {
            Ok(())
        } else {
            Err(CoreError::new(
                "PermissionDenied",
                format!("missing capability: {capability}"),
            ))
        }
    }
    pub fn check_account(&self, principal: &Principal, account: Option<&str>) -> CoreResult<()> {
        if !principal.is_owner()
            && self.expires_at.as_ref().is_some_and(|s| {
                chrono::DateTime::parse_from_rfc3339(s)
                    .map(|d| d <= chrono::Utc::now())
                    .unwrap_or(true)
            })
        {
            return Err(CoreError::new("PermissionDenied", "grant has expired"));
        }
        if let Some(account) = account
            && !principal.is_owner()
            && !self.account_ids.contains(account)
        {
            return Err(CoreError::new(
                "PermissionDenied",
                "account is outside the grant",
            ));
        }
        Ok(())
    }
}

pub fn capability_for(method: &str) -> &str {
    if let Some(cap) = crate::organizer::required_capability(method) {
        return cap;
    }
    match method {
        "storage.get" => "storage.read",
        "storage.set" | "storage.delete" => "storage.write",
        "sources.query" | "search.query" => "sources.read",
        "sources.upsert" => "sources.write",
        "accounts.list" | "auth.status" => "auth.status",
        "jobs.wake.status" => "jobs.status",
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn expired_account_grants_are_rejected() {
        let p = Principal {
            id: "client".into(),
            kind: crate::PrincipalKind::Client,
        };
        let mut g = Grant::default();
        g.account_ids.insert("a".into());
        g.capabilities.insert("auth.status".into());
        g.expires_at = Some("2000-01-01T00:00:00Z".into());
        assert!(!g.allows("auth.status"));
        assert!(g.check_account(&p, Some("a")).is_err());
    }
}
