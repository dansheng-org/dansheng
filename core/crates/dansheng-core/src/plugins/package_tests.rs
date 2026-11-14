use std::{fs, path::Path};

use ed25519_dalek::{Signer, SigningKey};
use serde_json::json;
use tempfile::TempDir;

use super::*;

fn fixture(version: &str) -> (TempDir, PluginManifest) {
    let directory = tempfile::tempdir().unwrap();
    let manifest: PluginManifest = serde_json::from_value(json!({
        "id": "example.catalog", "version": version, "api_version": 1,
        "entry": "main.js", "name": "Synthetic catalog fixture",
        "capabilities": ["storage.read"], "network": ["https://fixture.invalid"],
        "actions": {"run": {"description": "Synthetic action", "mutating": false}}
    }))
    .unwrap();
    fs::write(
        directory.path().join("main.js"),
        "export function run() { return {fixture:true}; }",
    )
    .unwrap();
    write_manifest(directory.path(), &manifest);
    (directory, manifest)
}

fn write_manifest(directory: &Path, manifest: &PluginManifest) {
    fs::write(
        directory.join(MANIFEST_FILE),
        serde_json::to_vec(manifest).unwrap(),
    )
    .unwrap();
}

fn generation(path: &Path) -> &str {
    path.file_name().unwrap().to_str().unwrap()
}

// These are public synthetic test seeds, never user keys or production fixtures.
fn signing_key() -> SigningKey {
    SigningKey::from_bytes(&[0x42; 32])
}

fn publisher() -> PluginPublisher {
    PluginPublisher {
        id: "example.publisher".into(),
        key_id: "release-one".into(),
    }
}

fn sign(catalog: PluginCatalog, key: &SigningKey) -> SignedPluginCatalog {
    let signature = key.sign(&catalog.signing_bytes().unwrap());
    SignedPluginCatalog {
        catalog,
        signature: signature
            .to_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
    }
}

fn publish(
    directory: &Path,
    manifest: &mut PluginManifest,
    sequence: u64,
) -> (SignedPluginCatalog, TrustedPublisher) {
    manifest.publisher = Some(publisher());
    // Compute on the current manifest before writing the new paired fields.
    manifest.integrity = Some(compute_package_integrity(directory).unwrap());
    write_manifest(directory, manifest);
    let key = signing_key();
    let catalog = PluginCatalog {
        catalog_version: 1,
        publisher: publisher(),
        sequence,
        expires_at: 1000,
        packages: vec![CatalogPackage::from_local_package(directory).unwrap()],
    };
    (
        sign(catalog, &key),
        TrustedPublisher {
            publisher: publisher(),
            public_key: key.verifying_key().to_bytes(),
        },
    )
}

fn verified(signed: &SignedPluginCatalog, trusted: &TrustedPublisher) -> VerifiedCatalog {
    verify_catalog(
        &serde_json::to_vec(signed).unwrap(),
        std::slice::from_ref(trusted),
        100,
        1,
    )
    .unwrap()
}

#[test]
fn local_rollback_uninstall_and_restore_are_atomic_disabled_and_recoverable() {
    let (source, mut manifest) = fixture("1.0.0");
    let destination = tempfile::tempdir().unwrap();
    let first = install_local_package(source.path(), destination.path()).unwrap();
    assert!(!first.enabled);
    assert!(first.requires_approval);
    manifest.version = "2.0.0".into();
    write_manifest(source.path(), &manifest);
    let second = install_local_package(source.path(), destination.path()).unwrap();
    assert!(!second.enabled);
    assert!(!second.requires_approval);
    let rollback = rollback_local_package(destination.path(), &manifest.id, None).unwrap();
    assert_eq!(rollback.package_dir, first.package_dir);
    assert_eq!(
        rollback.previous_package_dir,
        Some(second.package_dir.clone())
    );
    assert!(!rollback.enabled);
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap()
            .manifest
            .version,
        "1.0.0"
    );
    // A separate host data directory survives uninstall unchanged.
    let host_data = destination.path().join("host-data.json");
    fs::write(&host_data, "{\"synthetic\":true}").unwrap();
    let removed = uninstall_local_package(destination.path(), &manifest.id).unwrap();
    assert_eq!(removed.recovery_generation, generation(&first.package_dir));
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap_err()
            .code,
        "PLUGIN_NOT_INSTALLED"
    );
    assert!(first.package_dir.join(MANIFEST_FILE).exists());
    assert!(second.package_dir.join(MANIFEST_FILE).exists());
    assert_eq!(
        fs::read_to_string(host_data).unwrap(),
        "{\"synthetic\":true}"
    );
    let restored = rollback_local_package(
        destination.path(),
        &manifest.id,
        Some(&removed.recovery_generation),
    )
    .unwrap();
    assert_eq!(restored.package_dir, first.package_dir);
    assert!(!restored.enabled);
    assert!(restored.requires_approval);
}

#[test]
fn permission_expansion_and_rollback_never_reuse_enablement_or_approval() {
    let (source, mut manifest) = fixture("1.0.0");
    let destination = tempfile::tempdir().unwrap();
    let first = install_local_package(source.path(), destination.path()).unwrap();
    manifest.version = "2.0.0".into();
    manifest.capabilities.push("storage.write".into());
    manifest.network.push("https://second.invalid".into());
    manifest.actions.get_mut("run").unwrap().mutating = true;
    manifest.actions.insert(
        "added".into(),
        PluginAction {
            description: "New action".into(),
            mutating: false,
            input_schema: None,
        },
    );
    write_manifest(source.path(), &manifest);
    let upgraded = install_local_package(source.path(), destination.path()).unwrap();
    assert!(!upgraded.enabled);
    assert!(upgraded.requires_approval);
    assert_eq!(
        upgraded.permission_changes.added_capabilities,
        ["storage.write"]
    );
    assert_eq!(
        upgraded.permission_changes.added_network_origins,
        ["https://second.invalid"]
    );
    assert_eq!(upgraded.permission_changes.added_actions, ["added"]);
    assert_eq!(upgraded.permission_changes.newly_mutating_actions, ["run"]);
    rollback_local_package(
        destination.path(),
        &manifest.id,
        Some(generation(&first.package_dir)),
    )
    .unwrap();
    let restored_upgrade = rollback_local_package(
        destination.path(),
        &manifest.id,
        Some(generation(&upgraded.package_dir)),
    )
    .unwrap();
    assert!(!restored_upgrade.enabled);
    assert!(restored_upgrade.requires_approval);
}

#[test]
fn rollback_rejects_escape_and_corrupt_retained_bytes_without_switching_pointer() {
    let (source, mut manifest) = fixture("1.0.0");
    let destination = tempfile::tempdir().unwrap();
    let first = install_local_package(source.path(), destination.path()).unwrap();
    manifest.version = "2.0.0".into();
    write_manifest(source.path(), &manifest);
    let current = install_local_package(source.path(), destination.path()).unwrap();
    for escape in ["../outside", "..", "C:\\outside", "versions/other"] {
        assert_eq!(
            rollback_local_package(destination.path(), &manifest.id, Some(escape))
                .unwrap_err()
                .code,
            "PATH_ESCAPE"
        );
    }
    fs::write(
        first.package_dir.join("main.js"),
        "export function run() { return 'altered'; }",
    )
    .unwrap();
    assert_eq!(
        rollback_local_package(
            destination.path(),
            &manifest.id,
            Some(generation(&first.package_dir))
        )
        .unwrap_err()
        .code,
        "INTEGRITY_MISMATCH"
    );
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap()
            .package_dir,
        current.package_dir
    );
    // Corrupt packages must still be removable: uninstall does not execute or
    // require the compromised generation to validate successfully.
    fs::write(current.package_dir.join("main.js"), "altered").unwrap();
    assert!(uninstall_local_package(destination.path(), &manifest.id).is_ok());
}

#[test]
fn rollback_recovers_a_corrupt_current_package_without_inheriting_approval() {
    let (source, mut manifest) = fixture("1.0.0");
    let destination = tempfile::tempdir().unwrap();
    let first = install_local_package(source.path(), destination.path()).unwrap();
    manifest.version = "2.0.0".into();
    write_manifest(source.path(), &manifest);
    let broken = install_local_package(source.path(), destination.path()).unwrap();
    fs::write(broken.package_dir.join("main.js"), "corrupt current bytes").unwrap();
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap_err()
            .code,
        "INTEGRITY_MISMATCH"
    );
    let restored = rollback_local_package(destination.path(), &manifest.id, None).unwrap();
    assert_eq!(restored.package_dir, first.package_dir);
    assert_eq!(restored.previous_package_dir, Some(broken.package_dir));
    assert!(!restored.enabled);
    assert!(restored.requires_approval);
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap()
            .manifest
            .version,
        "1.0.0"
    );
}

#[test]
fn verified_catalog_installs_only_bound_publisher_manifest_and_payload() {
    let (source, mut manifest) = fixture("1.0.0");
    let (signed, trusted) = publish(source.path(), &mut manifest, 7);
    let catalog = verified(&signed, &trusted);
    assert_eq!(catalog.catalog().sequence, 7);
    let destination = tempfile::tempdir().unwrap();
    assert_eq!(
        install_local_package(source.path(), destination.path())
            .unwrap_err()
            .code,
        "CATALOG_REQUIRED"
    );
    let installed =
        install_catalog_package(source.path(), destination.path(), &catalog, 100).unwrap();
    assert!(!installed.enabled);
    assert_eq!(
        installed.verification.as_ref().unwrap().publisher,
        publisher()
    );
    assert_eq!(installed.verification.as_ref().unwrap().catalog_sequence, 7);
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap()
            .manifest,
        manifest
    );
    // Installed metadata binds manifest bytes too, so permissions cannot be
    // changed locally without invalidating a retained generation.
    manifest.capabilities.push("browser.evaluate".into());
    write_manifest(&installed.package_dir, &manifest);
    assert_eq!(
        installed_package(destination.path(), &manifest.id)
            .unwrap_err()
            .code,
        "INTEGRITY_MISMATCH"
    );
}

#[test]
fn catalog_rejects_unknown_wrong_weak_and_ambiguous_keys_and_forged_signature() {
    let (source, mut manifest) = fixture("1.0.0");
    let (signed, trusted) = publish(source.path(), &mut manifest, 1);
    let bytes = serde_json::to_vec(&signed).unwrap();
    assert_eq!(
        verify_catalog(&bytes, &[], 100, 1).unwrap_err().code,
        "UNTRUSTED_PUBLISHER"
    );
    let mut wrong_key = trusted.clone();
    wrong_key.public_key = SigningKey::from_bytes(&[0x24; 32])
        .verifying_key()
        .to_bytes();
    assert_eq!(
        verify_catalog(&bytes, &[wrong_key], 100, 1)
            .unwrap_err()
            .code,
        "INVALID_SIGNATURE"
    );
    let mut weak_key = trusted.clone();
    weak_key.public_key = [0; 32];
    weak_key.public_key[0] = 1;
    assert_eq!(
        verify_catalog(&bytes, &[weak_key], 100, 1)
            .unwrap_err()
            .code,
        "INVALID_SIGNATURE"
    );
    assert_eq!(
        verify_catalog(&bytes, &[trusted.clone(), trusted.clone()], 100, 1)
            .unwrap_err()
            .code,
        "INVALID_TRUST_STORE"
    );
    let mut forged = signed.clone();
    forged.signature.replace_range(
        0..2,
        if &forged.signature[..2] == "00" {
            "01"
        } else {
            "00"
        },
    );
    assert_eq!(
        verify_catalog(
            &serde_json::to_vec(&forged).unwrap(),
            std::slice::from_ref(&trusted),
            100,
            1
        )
        .unwrap_err()
        .code,
        "INVALID_SIGNATURE"
    );
    let mut altered = signed;
    altered.catalog.packages[0].version = "2.0.0".into();
    assert_eq!(
        verify_catalog(&serde_json::to_vec(&altered).unwrap(), &[trusted], 100, 1)
            .unwrap_err()
            .code,
        "INVALID_SIGNATURE"
    );
}

#[test]
fn signed_catalog_enforces_expiry_monotonic_floor_and_freshness_at_install() {
    let (source, mut manifest) = fixture("1.0.0");
    let (signed, trusted) = publish(source.path(), &mut manifest, 4);
    let bytes = serde_json::to_vec(&signed).unwrap();
    assert_eq!(
        verify_catalog(&bytes, std::slice::from_ref(&trusted), 1000, 1)
            .unwrap_err()
            .code,
        "CATALOG_EXPIRED"
    );
    assert_eq!(
        verify_catalog(&bytes, std::slice::from_ref(&trusted), 100, 5)
            .unwrap_err()
            .code,
        "CATALOG_ROLLBACK"
    );
    let catalog = verified(&signed, &trusted);
    let destination = tempfile::tempdir().unwrap();
    assert_eq!(
        install_catalog_package(source.path(), destination.path(), &catalog, 1000)
            .unwrap_err()
            .code,
        "CATALOG_EXPIRED"
    );
    assert!(!destination.path().join(&manifest.id).exists());
}

#[test]
fn source_asset_manifest_and_publisher_substitution_are_rejected_before_activation() {
    for mutation in [
        "source",
        "asset",
        "permissions",
        "publisher",
        "manifest-whitespace",
    ] {
        let (source, mut manifest) = fixture("1.0.0");
        let (signed, trusted) = publish(source.path(), &mut manifest, 1);
        let catalog = verified(&signed, &trusted);
        match mutation {
            "source" => fs::write(
                source.path().join("main.js"),
                "export function run() { return 99; }",
            )
            .unwrap(),
            "asset" => fs::write(source.path().join("extra.json"), "{}").unwrap(),
            "permissions" => {
                manifest.capabilities.push("browser.evaluate".into());
                write_manifest(source.path(), &manifest);
            }
            "publisher" => {
                manifest.publisher.as_mut().unwrap().id = "another.publisher".into();
                write_manifest(source.path(), &manifest);
            }
            _ => fs::write(
                source.path().join(MANIFEST_FILE),
                serde_json::to_string_pretty(&manifest).unwrap(),
            )
            .unwrap(),
        }
        let destination = tempfile::tempdir().unwrap();
        let error =
            install_catalog_package(source.path(), destination.path(), &catalog, 100).unwrap_err();
        assert_eq!(
            error.code,
            if mutation == "publisher" {
                "PUBLISHER_MISMATCH"
            } else {
                "INTEGRITY_MISMATCH"
            },
            "{mutation}"
        );
        assert!(!destination.path().join(&manifest.id).exists());
    }
}

#[test]
fn malformed_duplicate_and_oversized_catalogs_are_rejected() {
    let (source, mut manifest) = fixture("1.0.0");
    let (signed, trusted) = publish(source.path(), &mut manifest, 1);
    let text = serde_json::to_string(&signed).unwrap();
    let duplicate = text.replace("\"sequence\":1", "\"sequence\":1,\"sequence\":1");
    assert_eq!(
        verify_catalog(duplicate.as_bytes(), std::slice::from_ref(&trusted), 100, 1)
            .unwrap_err()
            .code,
        "INVALID_CATALOG"
    );
    assert_eq!(
        verify_catalog(
            &vec![b' '; MAX_CATALOG_BYTES + 1],
            std::slice::from_ref(&trusted),
            100,
            1
        )
        .unwrap_err()
        .code,
        "INVALID_CATALOG"
    );
    let mut malformed = signed.clone();
    malformed.signature = "zz".repeat(64);
    assert_eq!(
        verify_catalog(
            &serde_json::to_vec(&malformed).unwrap(),
            std::slice::from_ref(&trusted),
            100,
            1
        )
        .unwrap_err()
        .code,
        "INVALID_SIGNATURE"
    );
    let mut duplicate_entry = signed;
    duplicate_entry
        .catalog
        .packages
        .push(duplicate_entry.catalog.packages[0].clone());
    assert_eq!(
        verify_catalog(
            &serde_json::to_vec(&duplicate_entry).unwrap(),
            &[trusted],
            100,
            1
        )
        .unwrap_err()
        .code,
        "INVALID_CATALOG"
    );
}

#[test]
fn optional_https_archive_url_is_signed_and_old_catalog_wire_bytes_stay_compatible() {
    let (source, mut manifest) = fixture("1.0.0");
    let (old, trusted) = publish(source.path(), &mut manifest, 1);
    let old_json = serde_json::to_string(&old).unwrap();
    assert!(!old_json.contains("archive_url"));
    assert!(
        verified(&old, &trusted).catalog().packages[0]
            .archive_url
            .is_none()
    );
    let mut catalog = old.catalog;
    catalog.packages[0].archive_url =
        Some("HTTPS://fixtures.invalid/package.zip?label=user@example.invalid".into());
    let signed = sign(catalog, &signing_key());
    assert_eq!(
        verified(&signed, &trusted).catalog().packages[0].archive_url,
        signed.catalog.packages[0].archive_url
    );
    let mut tampered = signed;
    tampered.catalog.packages[0].archive_url = Some("https://second.invalid/replaced.zip".into());
    assert_eq!(
        verify_catalog(&serde_json::to_vec(&tampered).unwrap(), &[trusted], 100, 1)
            .unwrap_err()
            .code,
        "INVALID_SIGNATURE"
    );
}

#[test]
fn archive_urls_reject_insecure_schemes_embedded_credentials_and_malformed_addresses() {
    let (source, mut manifest) = fixture("1.0.0");
    let (signed, trusted) = publish(source.path(), &mut manifest, 1);
    for url in [
        "http://fixtures.invalid/package.zip",
        "file:///package.zip",
        "https://user:password@fixtures.invalid/p.zip",
        "https://user@fixtures.invalid/p.zip",
        "https://@fixtures.invalid/p.zip",
        "https://fixtures.invalid/p.zip#fragment",
        "https://fixtures.invalid/p.zip\n",
        "https://",
        "https:\\fixtures.invalid\\p.zip",
    ] {
        let mut invalid = signed.clone();
        invalid.catalog.packages[0].archive_url = Some(url.into());
        assert_eq!(
            verify_catalog(
                &serde_json::to_vec(&invalid).unwrap(),
                std::slice::from_ref(&trusted),
                100,
                1
            )
            .unwrap_err()
            .code,
            "INVALID_CATALOG"
        );
    }
}

#[test]
fn manifest_pairing_and_file_hash_framing_are_unambiguous() {
    let (source, mut manifest) = fixture("1.0.0");
    manifest.publisher = Some(publisher());
    assert_eq!(manifest.validate().unwrap_err().code, "INVALID_MANIFEST");
    manifest.publisher = None;
    manifest.integrity = Some(PackageIntegrity {
        sha256: "0".repeat(64),
    });
    assert_eq!(manifest.validate().unwrap_err().code, "INVALID_MANIFEST");
    fs::write(source.path().join("a"), b"bc").unwrap();
    let first = compute_package_integrity(source.path()).unwrap();
    fs::remove_file(source.path().join("a")).unwrap();
    fs::write(source.path().join("ab"), b"c").unwrap();
    assert_ne!(first, compute_package_integrity(source.path()).unwrap());
}

#[test]
fn signed_upgrade_and_rollback_retain_provenance_and_require_new_permission_approval() {
    let (source, mut manifest) = fixture("1.0.0");
    let (signed, trusted) = publish(source.path(), &mut manifest, 1);
    let destination = tempfile::tempdir().unwrap();
    let first = install_catalog_package(
        source.path(),
        destination.path(),
        &verified(&signed, &trusted),
        100,
    )
    .unwrap();
    manifest.version = "2.0.0".into();
    manifest.capabilities.push("browser.request".into());
    write_manifest(source.path(), &manifest);
    let (signed, trusted) = publish(source.path(), &mut manifest, 2);
    let upgraded = install_catalog_package(
        source.path(),
        destination.path(),
        &verified(&signed, &trusted),
        100,
    )
    .unwrap();
    assert!(!upgraded.enabled);
    assert!(upgraded.requires_approval);
    assert_eq!(
        upgraded.permission_changes.added_capabilities,
        ["browser.request"]
    );
    let rolled = rollback_local_package(destination.path(), &manifest.id, None).unwrap();
    assert_eq!(rolled.package_dir, first.package_dir);
    assert!(!rolled.enabled);
    assert_eq!(rolled.verification.unwrap().catalog_sequence, 1);
    let mut changed_key = manifest.clone();
    changed_key.publisher.as_mut().unwrap().key_id = "release-two".into();
    assert!(PermissionChanges::between(Some(&manifest), &changed_key).publisher_changed);
}
