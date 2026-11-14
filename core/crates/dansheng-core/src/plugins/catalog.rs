//! Static, publisher-scoped Ed25519 catalogs. Trust anchors and the monotonic
//! sequence floor come from the embedding application's trusted configuration.
//! This module performs no network access or automatic key discovery.

use std::{collections::BTreeSet, path::Path};

use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;

use super::{
    InstalledPlugin, PackageIntegrity, PluginError, PluginPublisher,
    manifest::{parse_unique_json, valid_id, valid_sha256, valid_version},
    package::{MANIFEST_FILE, PackageSnapshot, bounded_json, install_snapshot},
};

pub const MAX_CATALOG_BYTES: usize = 256 * 1024;
const SIGNING_DOMAIN: &[u8] = b"dansheng-core:plugin-catalog:v1\0";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogPackage {
    pub id: String,
    pub version: String,
    pub manifest_sha256: String,
    pub package_sha256: String,
    /// Optional transport location; it is included in the catalog signature.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive_url: Option<String>,
}

impl CatalogPackage {
    /// Prepare an entry for an authoring/signing tool, not a verification proof.
    pub fn from_local_package(package_dir: impl AsRef<Path>) -> Result<Self, PluginError> {
        let snapshot = PackageSnapshot::read(package_dir.as_ref())?;
        let manifest = snapshot.manifest()?;
        snapshot.check_entry(&manifest)?;
        if manifest.publisher.is_none() {
            return Err(catalog_error(
                "Catalog packages must declare publisher and integrity",
            ));
        }
        Ok(Self {
            id: manifest.id,
            version: manifest.version,
            manifest_sha256: snapshot.manifest_digest()?,
            package_sha256: snapshot.content_digest(),
            archive_url: None,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PluginCatalog {
    pub catalog_version: u32,
    pub publisher: PluginPublisher,
    pub sequence: u64,
    pub expires_at: u64,
    pub packages: Vec<CatalogPackage>,
}

impl PluginCatalog {
    /// The v1 wire signing format is the domain prefix followed by compact serde
    /// JSON of this typed struct in declaration order. Package array order is
    /// significant. It is deliberately not a general-purpose JSON canonicalizer.
    /// Signatures use ordinary Ed25519 over these bytes, not Ed25519ph.
    pub fn signing_bytes(&self) -> Result<Vec<u8>, PluginError> {
        self.validate()?;
        let json = bounded_json(self, MAX_CATALOG_BYTES)
            .map_err(|_| catalog_error("Catalog exceeds its size limit"))?;
        let mut bytes = SIGNING_DOMAIN.to_vec();
        bytes.extend_from_slice(json.as_bytes());
        Ok(bytes)
    }

    fn validate(&self) -> Result<(), PluginError> {
        if self.catalog_version != 1 || self.sequence == 0 || self.packages.len() > 256 {
            return Err(catalog_error(
                "Invalid catalog version, sequence or package count",
            ));
        }
        self.publisher
            .validate()
            .map_err(|_| catalog_error("Invalid catalog publisher"))?;
        let mut identities = BTreeSet::new();
        for package in &self.packages {
            if !valid_id(&package.id)
                || !valid_version(&package.version)
                || !valid_sha256(&package.manifest_sha256)
                || !valid_sha256(&package.package_sha256)
                || package
                    .archive_url
                    .as_ref()
                    .is_some_and(|url| !valid_archive_url(url))
                || !identities.insert((&package.id, &package.version))
            {
                return Err(catalog_error("Invalid or duplicate catalog package"));
            }
        }
        Ok(())
    }
}

fn valid_archive_url(value: &str) -> bool {
    if value.is_empty()
        || value.len() > 4096
        || value.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return false;
    }
    let Ok(url) = Url::parse(value) else {
        return false;
    };
    url.scheme() == "https"
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none()
        && url.fragment().is_none()
        && value.split_once("://").is_some_and(|(_, rest)| {
            !rest
                .split(['/', '?', '#'])
                .next()
                .unwrap_or("")
                .contains('@')
        })
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignedPluginCatalog {
    pub catalog: PluginCatalog,
    /// Exactly 128 lowercase hex characters encoding an Ed25519 signature.
    pub signature: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TrustedPublisher {
    pub publisher: PluginPublisher,
    pub public_key: [u8; 32],
}

/// Only verify_catalog can construct this proof; it has no Deserialize impl.
/// Re-check trust and sequence floors when the host changes its trust policy.
#[derive(Clone, Debug)]
pub struct VerifiedCatalog {
    catalog: PluginCatalog,
}

impl VerifiedCatalog {
    pub fn catalog(&self) -> &PluginCatalog {
        &self.catalog
    }

    fn verify_snapshot(&self, snapshot: &PackageSnapshot, now: u64) -> Result<(), PluginError> {
        if self.catalog.expires_at <= now {
            return Err(PluginError::new(
                "CATALOG_EXPIRED",
                "Signed plugin catalog has expired",
            ));
        }
        let manifest = snapshot.manifest()?;
        snapshot.check_entry(&manifest)?;
        if manifest.publisher.as_ref() != Some(&self.catalog.publisher) {
            return Err(PluginError::new(
                "PUBLISHER_MISMATCH",
                "Package publisher does not match catalog signer",
            ));
        }
        let entry = self
            .catalog
            .packages
            .iter()
            .find(|entry| entry.id == manifest.id && entry.version == manifest.version)
            .ok_or_else(|| {
                PluginError::new(
                    "CATALOG_PACKAGE_MISSING",
                    "Package version is not in the verified catalog",
                )
            })?;
        if snapshot.manifest_digest()? != entry.manifest_sha256
            || snapshot.content_digest() != entry.package_sha256
            || manifest
                .integrity
                .as_ref()
                .map(|integrity| &integrity.sha256)
                != Some(&entry.package_sha256)
        {
            return Err(integrity_error());
        }
        Ok(())
    }
}

/// The caller supplies trusted public keys, trusted time and its persisted
/// highest accepted sequence for this publisher. Never obtain trust anchors or
/// the sequence floor from plugin request parameters. Persist the verified
/// sequence in the host so an older signed catalog cannot silently be replayed.
pub fn verify_catalog(
    bytes: &[u8],
    trusted_keys: &[TrustedPublisher],
    now_unix_seconds: u64,
    minimum_sequence: u64,
) -> Result<VerifiedCatalog, PluginError> {
    if bytes.is_empty() || bytes.len() > MAX_CATALOG_BYTES || trusted_keys.len() > 128 {
        return Err(catalog_error(
            "Catalog or trust store exceeds its size limit",
        ));
    }
    let signed: SignedPluginCatalog =
        parse_unique_json(bytes).map_err(|_| catalog_error("Malformed signed catalog"))?;
    signed.catalog.validate()?;
    let mut matching = trusted_keys
        .iter()
        .filter(|key| key.publisher == signed.catalog.publisher);
    let trusted = matching.next().ok_or_else(|| {
        PluginError::new(
            "UNTRUSTED_PUBLISHER",
            "Catalog publisher key is not trusted",
        )
    })?;
    if matching.next().is_some() {
        return Err(PluginError::new(
            "INVALID_TRUST_STORE",
            "Publisher key identity is ambiguous",
        ));
    }
    let key = VerifyingKey::from_bytes(&trusted.public_key).map_err(|_| signature_error())?;
    let signature = Signature::from_bytes(&decode_hex::<64>(&signed.signature)?);
    key.verify_strict(&signed.catalog.signing_bytes()?, &signature)
        .map_err(|_| signature_error())?;
    if signed.catalog.expires_at <= now_unix_seconds {
        return Err(PluginError::new(
            "CATALOG_EXPIRED",
            "Signed plugin catalog has expired",
        ));
    }
    if signed.catalog.sequence < minimum_sequence {
        return Err(PluginError::new(
            "CATALOG_ROLLBACK",
            "Catalog sequence is older than the trusted floor",
        ));
    }
    Ok(VerifiedCatalog {
        catalog: signed.catalog,
    })
}

/// Verify and install the same bounded byte snapshot, with no verify/copy race.
/// As with all local installs, the returned generation is always disabled.
pub fn install_catalog_package(
    source_dir: impl AsRef<Path>,
    install_root: impl AsRef<Path>,
    catalog: &VerifiedCatalog,
    now_unix_seconds: u64,
) -> Result<InstalledPlugin, PluginError> {
    let snapshot = PackageSnapshot::read(source_dir.as_ref())?;
    catalog.verify_snapshot(&snapshot, now_unix_seconds)?;
    let verification = PackageVerification {
        publisher: catalog.catalog.publisher.clone(),
        catalog_sequence: catalog.catalog.sequence,
    };
    install_snapshot(snapshot, install_root.as_ref(), Some(verification))
}

/// Public, non-secret provenance for a successfully verified installed package.
/// This is a receipt, not a constructible authorization token accepted by APIs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackageVerification {
    pub publisher: PluginPublisher,
    pub catalog_sequence: u64,
}

pub fn compute_package_integrity(
    package_dir: impl AsRef<Path>,
) -> Result<PackageIntegrity, PluginError> {
    let snapshot = PackageSnapshot::read(package_dir.as_ref())?;
    snapshot.manifest()?;
    Ok(PackageIntegrity {
        sha256: snapshot.content_digest(),
    })
}

impl PackageSnapshot {
    pub(super) fn content_digest(&self) -> String {
        let mut hash = Sha256::new();
        hash.update(b"dansheng-core:package-files:v1\0");
        for (name, bytes) in &self.files {
            if name == MANIFEST_FILE {
                continue;
            }
            hash.update((name.len() as u64).to_be_bytes());
            hash.update(name.as_bytes());
            hash.update((bytes.len() as u64).to_be_bytes());
            hash.update(bytes);
        }
        encode_hex(&hash.finalize())
    }

    pub(super) fn manifest_digest(&self) -> Result<String, PluginError> {
        let bytes = self
            .files
            .get(MANIFEST_FILE)
            .ok_or_else(|| PluginError::manifest("Package is missing manifest.json"))?;
        Ok(encode_hex(&Sha256::digest(bytes)))
    }
}

fn encode_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        encoded.push(DIGITS[(byte >> 4) as usize] as char);
        encoded.push(DIGITS[(byte & 15) as usize] as char);
    }
    encoded
}

fn decode_hex<const N: usize>(encoded: &str) -> Result<[u8; N], PluginError> {
    if encoded.len() != N * 2
        || !encoded
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(signature_error());
    }
    let mut bytes = [0; N];
    for (i, value) in bytes.iter_mut().enumerate() {
        *value =
            u8::from_str_radix(&encoded[i * 2..i * 2 + 2], 16).map_err(|_| signature_error())?;
    }
    Ok(bytes)
}

pub(super) fn integrity_error() -> PluginError {
    PluginError::new(
        "INTEGRITY_MISMATCH",
        "Package bytes do not match their integrity binding",
    )
}
fn signature_error() -> PluginError {
    PluginError::new("INVALID_SIGNATURE", "Catalog signature verification failed")
}
fn catalog_error(message: &'static str) -> PluginError {
    PluginError::new("INVALID_CATALOG", message)
}
