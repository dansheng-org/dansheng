use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::PluginError;

/// Declarative migrations for private ctx.storage only, never other host data.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PluginStorageSchema {
    pub version: u32,
    #[serde(default)]
    pub migrations: Vec<PluginStorageMigration>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PluginStorageMigration {
    pub from: u32,
    pub to: u32,
    pub operations: Vec<PluginStorageOperation>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum PluginStorageOperation {
    RenameKey {
        from: String,
        to: String,
    },
    DeleteKey {
        key: String,
    },
    SetDefault {
        key: String,
        value: Value,
    },
    PatchObject {
        key: String,
        #[serde(default)]
        rename_fields: BTreeMap<String, String>,
        #[serde(default)]
        defaults: BTreeMap<String, Value>,
        #[serde(default)]
        remove_fields: Vec<String>,
    },
}

impl PluginStorageSchema {
    pub(super) fn validate(&self) -> Result<(), PluginError> {
        let invalid = || PluginError::manifest("Invalid private storage migration declaration");
        if self.version == 0 || self.version > 1_000_000 || self.migrations.len() > 128 {
            return Err(invalid());
        }
        let mut previous = None;
        let mut operations = 0;
        for step in &self.migrations {
            if step.from.checked_add(1) != Some(step.to)
                || step.to > self.version
                || previous.is_some_and(|from| from >= step.from)
            {
                return Err(invalid());
            }
            previous = Some(step.from);
            operations += step.operations.len();
            if operations > 256 {
                return Err(invalid());
            }
            for operation in &step.operations {
                let good = match operation {
                    PluginStorageOperation::RenameKey { from, to } => {
                        valid_key(from) && valid_key(to) && from != to
                    }
                    PluginStorageOperation::DeleteKey { key }
                    | PluginStorageOperation::SetDefault { key, .. } => valid_key(key),
                    PluginStorageOperation::PatchObject {
                        key,
                        rename_fields,
                        defaults,
                        remove_fields,
                    } => {
                        let count = rename_fields.len() + defaults.len() + remove_fields.len();
                        valid_key(key)
                            && (1..=128).contains(&count)
                            && rename_fields
                                .iter()
                                .all(|(a, b)| valid_key(a) && valid_key(b) && a != b)
                            && defaults.keys().all(|key| valid_key(key))
                            && remove_fields.iter().all(|key| valid_key(key))
                    }
                };
                if !good {
                    return Err(invalid());
                }
            }
        }
        Ok(())
    }
}

fn valid_key(key: &str) -> bool {
    !key.is_empty() && key.len() <= 256 && !key.chars().any(char::is_control)
}
