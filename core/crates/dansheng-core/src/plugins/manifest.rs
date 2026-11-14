use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use url::Url;

use super::PluginError;

pub const MAX_MANIFEST_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PluginPublisher {
    pub id: String,
    pub key_id: String,
}

impl PluginPublisher {
    pub(super) fn validate(&self) -> Result<(), PluginError> {
        if !valid_id(&self.id) || !valid_id(&self.key_id) {
            return Err(PluginError::manifest("Invalid publisher or signing key id"));
        }
        Ok(())
    }
}

/// SHA-256 over the v1 framed package files, excluding manifest.json to avoid
/// a circular hash. The signed catalog separately binds the exact manifest bytes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackageIntegrity {
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PluginAction {
    pub description: String,
    pub mutating: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_schema: Option<Value>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PluginManifest {
    pub id: String,
    pub version: String,
    pub api_version: u32,
    pub entry: String,
    pub name: String,
    pub capabilities: Vec<String>,
    pub network: Vec<String>,
    pub actions: BTreeMap<String, PluginAction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui: Option<Vec<Map<String, Value>>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publisher: Option<PluginPublisher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub integrity: Option<PackageIntegrity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub storage_schema: Option<super::PluginStorageSchema>,
}

impl PluginManifest {
    /// Parse a bounded v1 manifest. Unknown fields, wrong types, duplicate JSON
    /// keys, unsupported versions and ambiguous identifiers are rejected.
    pub fn from_slice(bytes: &[u8]) -> Result<Self, PluginError> {
        if bytes.is_empty() || bytes.len() > MAX_MANIFEST_BYTES {
            return Err(PluginError::manifest("Manifest exceeds its size limit"));
        }
        // serde_json normally accepts duplicate object keys (including action
        // ids). Reject them before deserializing the public wire types.
        let manifest: Self = parse_unique_json(bytes)
            .map_err(|_| PluginError::manifest("Manifest fields do not match v1"))?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> Result<(), PluginError> {
        if !valid_id(&self.id) {
            return Err(PluginError::manifest("Invalid plugin id"));
        }
        if self.api_version != 1 {
            return Err(PluginError::manifest("Unsupported plugin API version"));
        }
        if !valid_version(&self.version) {
            return Err(PluginError::manifest("Invalid plugin version"));
        }
        match (&self.publisher, &self.integrity) {
            (None, None) => {}
            (Some(publisher), Some(integrity)) => {
                publisher.validate()?;
                if !valid_sha256(&integrity.sha256) {
                    return Err(PluginError::manifest("Invalid package SHA-256"));
                }
            }
            _ => {
                return Err(PluginError::manifest(
                    "Publisher and integrity must be declared together",
                ));
            }
        }
        if let Some(schema) = &self.storage_schema {
            schema.validate()?;
        }
        if self.name.trim().is_empty()
            || self.name.len() > 256
            || self.name.chars().any(char::is_control)
        {
            return Err(PluginError::manifest("Invalid plugin name"));
        }
        validate_entry(&self.entry)?;
        if self.capabilities.len() > 128 || self.network.len() > 64 {
            return Err(PluginError::manifest(
                "Too many capabilities or network origins",
            ));
        }
        let mut capabilities = BTreeSet::new();
        for capability in &self.capabilities {
            if capability.is_empty()
                || capability.len() > 128
                || !capability.bytes().all(|b| b.is_ascii_graphic())
                || !capabilities.insert(capability)
            {
                return Err(PluginError::manifest("Invalid or duplicate capability"));
            }
        }
        let mut origins = BTreeSet::new();
        for origin in &self.network {
            let url =
                Url::parse(origin).map_err(|_| PluginError::manifest("Invalid network origin"))?;
            if origin.len() > 2048
                || !matches!(url.scheme(), "http" | "https")
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.path() != "/"
                || url.query().is_some()
                || url.fragment().is_some()
                || url.origin().ascii_serialization() != *origin
                || !origins.insert(url.origin().ascii_serialization())
            {
                return Err(PluginError::manifest(
                    "Network declarations must be unique canonical HTTP origins",
                ));
            }
        }
        if self.actions.is_empty() || self.actions.len() > 128 {
            return Err(PluginError::manifest(
                "Manifest must declare 1 to 128 actions",
            ));
        }
        for (id, action) in &self.actions {
            if !valid_action(id)
                || action.description.len() > 2048
                || action
                    .description
                    .chars()
                    .any(|c| c.is_control() && c != '\n' && c != '\t')
                || action
                    .input_schema
                    .as_ref()
                    .is_some_and(|s| !s.is_object() && !s.is_boolean())
            {
                return Err(PluginError::manifest("Invalid action declaration"));
            }
        }
        if self.ui.as_ref().is_some_and(|ui| ui.len() > 64) {
            return Err(PluginError::manifest("Too many UI descriptions"));
        }
        super::package::bounded_json(self, MAX_MANIFEST_BYTES)
            .map_err(|_| PluginError::manifest("Manifest exceeds its size limit"))?;
        Ok(())
    }
}

pub(super) fn valid_version(version: &str) -> bool {
    !version.is_empty()
        && version.len() <= 64
        && version.as_bytes()[0].is_ascii_digit()
        && version
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b))
        && !version.contains("..")
        && !version.ends_with('.')
}

pub(super) fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(super) fn parse_unique_json<T: serde::de::DeserializeOwned>(
    bytes: &[u8],
) -> Result<T, serde_json::Error> {
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let unique = UniqueJson::deserialize(&mut deserializer)?;
    deserializer.end()?;
    serde_json::from_value(unique.0)
}

pub(super) fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.as_bytes()[0].is_ascii_lowercase()
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
        && id.as_bytes()[id.len() - 1].is_ascii_alphanumeric()
        && !id.contains("..")
        && !reserved_windows_name(id)
}

fn valid_action(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && (id.as_bytes()[0].is_ascii_alphabetic() || b"_$".contains(&id.as_bytes()[0]))
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_$".contains(&b))
        && id != "default"
}

pub(super) fn reserved_windows_name(name: &str) -> bool {
    let stem = name
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end_matches(' ')
        .to_ascii_uppercase();
    matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$" | "CLOCK$"
    ) || (stem.len() == 4
        && (stem.starts_with("COM") || stem.starts_with("LPT"))
        && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        || ["COM", "LPT"].iter().any(|prefix| {
            stem.strip_prefix(prefix)
                .is_some_and(|suffix| matches!(suffix, "¹" | "²" | "³"))
        })
}

pub(super) fn validate_entry(entry: &str) -> Result<(), PluginError> {
    let path = entry.strip_prefix("./").unwrap_or(entry);
    if path.is_empty()
        || path.len() > 512
        || path.split('/').any(|s| !portable_segment(s))
        || !is_js(path)
    {
        return Err(PluginError::manifest(
            "Entry must be a relative .js or .mjs source path",
        ));
    }
    Ok(())
}

pub(super) fn portable_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && segment.len() <= 255
        && !segment.ends_with('.')
        && !segment.ends_with(' ')
        && !segment
            .chars()
            .any(|c| c.is_control() || "\\/:*?\"<>|%#".contains(c))
        && !reserved_windows_name(segment)
}

pub(super) fn is_js(path: &str) -> bool {
    path.ends_with(".js") || path.ends_with(".mjs")
}

struct UniqueJson(Value);

impl<'de> Deserialize<'de> for UniqueJson {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = UniqueJson;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("JSON without duplicate keys")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut a: A,
            ) -> Result<Self::Value, A::Error> {
                let mut map = Map::new();
                while let Some((key, value)) = a.next_entry::<String, UniqueJson>()? {
                    if map.insert(key, value.0).is_some() {
                        return Err(serde::de::Error::custom("duplicate key"));
                    }
                }
                Ok(UniqueJson(Value::Object(map)))
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut a: A,
            ) -> Result<Self::Value, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = a.next_element::<UniqueJson>()? {
                    values.push(value.0);
                }
                Ok(UniqueJson(Value::Array(values)))
            }
            fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<Self::Value, E> {
                Ok(UniqueJson(v.into()))
            }
            fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<Self::Value, E> {
                Ok(UniqueJson(v.into()))
            }
            fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<Self::Value, E> {
                Ok(UniqueJson(v.into()))
            }
            fn visit_f64<E: serde::de::Error>(self, v: f64) -> Result<Self::Value, E> {
                serde_json::Number::from_f64(v)
                    .map(|n| UniqueJson(Value::Number(n)))
                    .ok_or_else(|| E::custom("non-finite number"))
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(UniqueJson(v.into()))
            }
            fn visit_string<E: serde::de::Error>(self, v: String) -> Result<Self::Value, E> {
                Ok(UniqueJson(v.into()))
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
                Ok(UniqueJson(Value::Null))
            }
            fn visit_none<E: serde::de::Error>(self) -> Result<Self::Value, E> {
                self.visit_unit()
            }
        }
        deserializer.deserialize_any(Visitor)
    }
}
