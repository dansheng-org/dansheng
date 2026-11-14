use std::{
    fs,
    io::{Cursor, Write},
    path::Path,
};

use ed25519_dalek::{Signer, SigningKey};
use serde_json::{Value, json};
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

use super::*;

fn manifest_value() -> Value {
    json!({"id":"example.archive", "version":"1.0.0", "api_version":1,
        "entry":"src/main.js", "name":"Synthetic ZIP fixture", "capabilities":[], "network":[],
        "actions":{"run":{"description":"Synthetic action", "mutating":false}}})
}

fn entries() -> Vec<(String, Vec<u8>)> {
    vec![
        (
            MANIFEST_FILE.into(),
            serde_json::to_vec(&manifest_value()).unwrap(),
        ),
        ("src/".into(), vec![]),
        (
            "src/main.js".into(),
            b"import {value} from './helper.mjs'; export function run() { return value; }".to_vec(),
        ),
        ("src/helper.mjs".into(), b"export const value = 7;".to_vec()),
        ("data/".into(), vec![]),
        (
            "data/介绍.txt".into(),
            "Synthetic UTF-8 内容".as_bytes().to_vec(),
        ),
    ]
}

fn zip_bytes(entries: &[(String, Vec<u8>)], compression: CompressionMethod) -> Vec<u8> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(compression);
    let options = if compression == CompressionMethod::Deflated {
        options.compression_level(Some(1))
    } else {
        options
    };
    for (name, data) in entries {
        if name.ends_with('/') {
            writer.add_directory(name, options).unwrap();
        } else {
            writer.start_file(name, options).unwrap();
            writer.write_all(data).unwrap();
        }
    }
    writer.finish().unwrap().into_inner()
}

fn zip_file(root: &Path, bytes: &[u8]) -> std::path::PathBuf {
    let archive = root.join("fixture.zip");
    fs::write(&archive, bytes).unwrap();
    archive
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap())
}
fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn put16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}
fn put32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

fn central(bytes: &[u8]) -> Vec<usize> {
    let end = bytes.len() - 22;
    assert_eq!(&bytes[end..end + 4], b"PK\x05\x06");
    let mut offset = u32_at(bytes, end + 16) as usize;
    let mut entries = Vec::new();
    while offset < end {
        assert_eq!(&bytes[offset..offset + 4], b"PK\x01\x02");
        entries.push(offset);
        offset += 46
            + u16_at(bytes, offset + 28) as usize
            + u16_at(bytes, offset + 30) as usize
            + u16_at(bytes, offset + 32) as usize;
    }
    entries
}

fn rejects_without_writing(bytes: &[u8], expected: &str) {
    let root = tempfile::tempdir().unwrap();
    let archive = zip_file(root.path(), bytes);
    let destination = root.path().join("output");
    let error = extract_package_archive(archive, &destination).unwrap_err();
    assert_eq!(error.code, expected);
    assert!(!destination.exists());
    assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
}

#[test]
fn stored_and_deflated_unix_and_windows_archives_extract_portable_utf8_packages() {
    for compression in [CompressionMethod::Stored, CompressionMethod::Deflated] {
        for windows_metadata in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let mut bytes = zip_bytes(&entries(), compression);
            if windows_metadata {
                for offset in central(&bytes) {
                    let name_end = offset + 46 + u16_at(&bytes, offset + 28) as usize;
                    let directory = bytes[name_end - 1] == b'/';
                    put16(&mut bytes, offset + 4, 20); // DOS creator, no Unix type bits.
                    put32(&mut bytes, offset + 38, if directory { 0x10 } else { 0x20 });
                }
            }
            let archive = zip_file(root.path(), &bytes);
            let destination = root.path().join("output");
            // Support both a new destination and a caller-created empty tempdir.
            if windows_metadata {
                fs::create_dir(&destination).unwrap();
            }
            let package = extract_package_archive(archive, &destination).unwrap();
            assert_eq!(package.manifest.id, "example.archive");
            assert_eq!(
                fs::read(destination.join("data/介绍.txt")).unwrap(),
                "Synthetic UTF-8 内容".as_bytes()
            );
            assert_eq!(package.manifest.entry, "src/main.js");
            assert!(package.package_dir.join("src/helper.mjs").is_file());
            assert_eq!(
                validate_package(&destination).unwrap().manifest,
                package.manifest
            );
        }
    }
}

#[test]
fn zip_slip_ads_device_names_and_platform_aliases_are_rejected_before_any_write() {
    for path in [
        "../outside.txt",
        "/absolute.txt",
        "C:/escape.txt",
        "a/../../escape",
        "a\\..\\escape",
        "main.js:ads",
        "CON.txt",
        "CON .txt",
        "CONIN$",
        "CONOUT$",
        "NUL",
        "COM1.txt",
        "LPT¹.txt",
        "a//b",
        "./main.js",
        "a./b",
        "a /b",
    ] {
        let mut files = entries();
        files.push(("safe-before-danger.txt".into(), b"must not appear".to_vec()));
        files.push((path.into(), b"unsafe".to_vec()));
        rejects_without_writing(&zip_bytes(&files, CompressionMethod::Stored), "PATH_ESCAPE");
    }
}

#[test]
fn duplicate_casefold_paths_and_file_directory_conflicts_are_rejected() {
    for (first, second) in [
        ("dup.js", "DUP.js"),
        ("Assets/a.txt", "assets/b.txt"),
        ("conflict", "conflict/nested.txt"),
        ("Straße.txt", "STRASSE.txt"),
    ] {
        let mut files = entries();
        files.push((first.into(), b"first".to_vec()));
        files.push((second.into(), b"second".to_vec()));
        rejects_without_writing(
            &zip_bytes(&files, CompressionMethod::Stored),
            "ARCHIVE_DUPLICATE_PATH",
        );
    }
    // Force an exact duplicate which ZipArchive's filename index would hide.
    let mut files = entries();
    files.push(("duplicate-a".into(), vec![]));
    files.push(("duplicate-b".into(), vec![]));
    let mut bytes = zip_bytes(&files, CompressionMethod::Stored);
    let offsets = central(&bytes);
    let first = offsets[offsets.len() - 2];
    let last = offsets[offsets.len() - 1];
    let name_size = u16_at(&bytes, first + 28) as usize;
    let replacement = bytes[first + 46..first + 46 + name_size].to_vec();
    bytes[last + 46..last + 46 + name_size].copy_from_slice(&replacement);
    let local = u32_at(&bytes, last + 42) as usize;
    bytes[local + 30..local + 30 + name_size].copy_from_slice(&replacement);
    rejects_without_writing(&bytes, "ARCHIVE_DUPLICATE_PATH");
}

#[test]
fn symlinks_devices_and_reparse_metadata_are_rejected() {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    writer
        .add_symlink("link.js", "../../outside.js", options)
        .unwrap();
    rejects_without_writing(&writer.finish().unwrap().into_inner(), "ARCHIVE_ENTRY_TYPE");
    for attributes in [
        (0o020600u32 << 16),
        (0o060600u32 << 16),
        (0o010600u32 << 16),
        0x400,
        0x40,
    ] {
        let mut bytes = zip_bytes(&entries(), CompressionMethod::Stored);
        let offset = central(&bytes)[0];
        put32(&mut bytes, offset + 38, attributes);
        rejects_without_writing(&bytes, "ARCHIVE_ENTRY_TYPE");
    }
}

#[test]
fn advertised_zip_bombs_entry_counts_and_per_file_limits_fail_before_decompression() {
    for (name, declared) in [
        (MANIFEST_FILE, MAX_MANIFEST_BYTES as u32 + 1),
        ("src/main.js", 1024 * 1024 + 1),
        ("bomb.bin", 16 * 1024 * 1024 + 1),
    ] {
        let mut files = entries();
        files.push(("bomb.bin".into(), b"tiny".to_vec()));
        let mut bytes = zip_bytes(&files, CompressionMethod::Deflated);
        for offset in central(&bytes) {
            let size = u16_at(&bytes, offset + 28) as usize;
            if &bytes[offset + 46..offset + 46 + size] == name.as_bytes() {
                put32(&mut bytes, offset + 24, declared);
            }
        }
        rejects_without_writing(&bytes, "ARCHIVE_LIMIT");
    }
    let mut bytes = zip_bytes(&entries(), CompressionMethod::Stored);
    let end = bytes.len() - 22;
    put16(&mut bytes, end + 8, 1025);
    put16(&mut bytes, end + 10, 1025);
    rejects_without_writing(&bytes, "ARCHIVE_LIMIT");
    let mut files = entries();
    files.extend([("one.bin".into(), vec![]), ("two.bin".into(), vec![])]);
    let mut bytes = zip_bytes(&files, CompressionMethod::Deflated);
    for offset in central(&bytes).into_iter().rev().take(2) {
        let local = u32_at(&bytes, offset + 42) as usize;
        put32(&mut bytes, offset + 24, 9 * 1024 * 1024);
        put32(&mut bytes, local + 22, 9 * 1024 * 1024);
    }
    rejects_without_writing(&bytes, "ARCHIVE_LIMIT");
}

#[test]
fn understated_output_crc_damage_and_invalid_manifest_never_reach_disk() {
    let mut files = entries();
    files.push(("understated.bin".into(), vec![b'x'; 64 * 1024]));
    let mut bytes = zip_bytes(&files, CompressionMethod::Deflated);
    let last = *central(&bytes).last().unwrap();
    let local = u32_at(&bytes, last + 42) as usize;
    put32(&mut bytes, last + 24, 1);
    put32(&mut bytes, local + 22, 1);
    // The reader can reject the inconsistent length itself, or the independent
    // output bound can observe the extra byte; neither may create files.
    let root = tempfile::tempdir().unwrap();
    let archive = zip_file(root.path(), &bytes);
    let destination = root.path().join("output");
    let error = extract_package_archive(archive, &destination).unwrap_err();
    assert!(matches!(
        error.code.as_str(),
        "ARCHIVE_INVALID" | "ARCHIVE_LIMIT"
    ));
    assert!(!destination.exists());
    let mut bytes = zip_bytes(&entries(), CompressionMethod::Stored);
    let first = central(&bytes)[0];
    let local = u32_at(&bytes, first + 42) as usize;
    let data =
        local + 30 + u16_at(&bytes, local + 26) as usize + u16_at(&bytes, local + 28) as usize;
    bytes[data] ^= 1;
    rejects_without_writing(&bytes, "ARCHIVE_INVALID");
    let mut files = entries();
    files[0].1 = b"{malformed}".to_vec();
    rejects_without_writing(
        &zip_bytes(&files, CompressionMethod::Stored),
        "INVALID_MANIFEST",
    );
}

#[test]
fn unsupported_compression_encryption_and_link_extra_fields_are_rejected() {
    for encrypted in [false, true] {
        let mut bytes = zip_bytes(&entries(), CompressionMethod::Stored);
        let first = central(&bytes)[0];
        let local = u32_at(&bytes, first + 42) as usize;
        if encrypted {
            put16(&mut bytes, first + 8, 1);
            put16(&mut bytes, local + 6, 1);
        } else {
            put16(&mut bytes, first + 10, 12);
            put16(&mut bytes, local + 8, 12);
        }
        rejects_without_writing(&bytes, "ARCHIVE_UNSUPPORTED");
    }
    let mut bytes = zip_bytes(&entries(), CompressionMethod::Stored);
    let first = central(&bytes)[0];
    let extra_start = first + 46 + u16_at(&bytes, first + 28) as usize;
    let old_extra = u16_at(&bytes, first + 30);
    bytes.splice(
        extra_start..extra_start,
        [0x99, 0x99, 0, 0, 0x6e, 0x75, 0, 0],
    );
    put16(&mut bytes, first + 30, old_extra + 8);
    let end = bytes.len() - 22;
    let central_size = u32_at(&bytes, end + 12);
    put32(&mut bytes, end + 12, central_size + 8);
    rejects_without_writing(&bytes, "ARCHIVE_UNSUPPORTED");
}

#[test]
fn extraction_never_overwrites_existing_data_or_follows_destination_links() {
    let root = tempfile::tempdir().unwrap();
    let archive = zip_file(
        root.path(),
        &zip_bytes(&entries(), CompressionMethod::Stored),
    );
    let destination = root.path().join("output");
    fs::create_dir(&destination).unwrap();
    fs::write(destination.join("keep.txt"), "existing synthetic data").unwrap();
    assert_eq!(
        extract_package_archive(&archive, &destination)
            .unwrap_err()
            .code,
        "ARCHIVE_DESTINATION"
    );
    assert_eq!(
        fs::read_to_string(destination.join("keep.txt")).unwrap(),
        "existing synthetic data"
    );
    let outside = tempfile::tempdir().unwrap();
    let link = root.path().join("linked-destination");
    #[cfg(unix)]
    std::os::unix::fs::symlink(outside.path(), &link).unwrap();
    #[cfg(windows)]
    assert!(
        std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(&link)
            .arg(outside.path())
            .output()
            .unwrap()
            .status
            .success()
    );
    assert_eq!(
        extract_package_archive(archive, &link).unwrap_err().code,
        "PATH_ESCAPE"
    );
    assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 0);
}

#[test]
fn oversized_archive_input_is_rejected_without_reading_or_creating_output() {
    let root = tempfile::tempdir().unwrap();
    let archive = root.path().join("large.zip");
    fs::File::create(&archive)
        .unwrap()
        .set_len(32 * 1024 * 1024 + 1)
        .unwrap();
    let destination = root.path().join("output");
    assert_eq!(
        extract_package_archive(archive, &destination)
            .unwrap_err()
            .code,
        "ARCHIVE_LIMIT"
    );
    assert!(!destination.exists());
}

#[test]
fn extracted_published_packages_still_require_verified_catalog_install_and_disabled_receipts() {
    let source = tempfile::tempdir().unwrap();
    let mut files = entries();
    for (name, data) in &files {
        let target = source.path().join(name);
        if name.ends_with('/') {
            fs::create_dir_all(target).unwrap();
        } else {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(target, data).unwrap();
        }
    }
    let mut manifest: PluginManifest = serde_json::from_value(manifest_value()).unwrap();
    manifest.publisher = Some(PluginPublisher {
        id: "example.publisher".into(),
        key_id: "archive-key".into(),
    });
    manifest.integrity = Some(compute_package_integrity(source.path()).unwrap());
    files[0].1 = serde_json::to_vec(&manifest).unwrap();
    fs::write(source.path().join(MANIFEST_FILE), &files[0].1).unwrap();
    let key = SigningKey::from_bytes(&[0x53; 32]); // Public synthetic fixture seed.
    let mut entry = CatalogPackage::from_local_package(source.path()).unwrap();
    entry.archive_url = Some("https://fixtures.invalid/package.zip".into());
    let catalog = PluginCatalog {
        catalog_version: 1,
        publisher: manifest.publisher.clone().unwrap(),
        sequence: 1,
        expires_at: 1000,
        packages: vec![entry],
    };
    let signature = key
        .sign(&catalog.signing_bytes().unwrap())
        .to_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let signed = SignedPluginCatalog { catalog, signature };
    let trusted = TrustedPublisher {
        publisher: manifest.publisher.clone().unwrap(),
        public_key: key.verifying_key().to_bytes(),
    };
    let verified =
        verify_catalog(&serde_json::to_vec(&signed).unwrap(), &[trusted], 100, 0).unwrap();
    let root = tempfile::tempdir().unwrap();
    let archive = zip_file(root.path(), &zip_bytes(&files, CompressionMethod::Deflated));
    let extracted = extract_package_archive(archive, root.path().join("extracted")).unwrap();
    let installed_root = root.path().join("installed");
    assert_eq!(
        install_local_package(&extracted.package_dir, &installed_root)
            .unwrap_err()
            .code,
        "CATALOG_REQUIRED"
    );
    let installed =
        install_catalog_package(&extracted.package_dir, installed_root, &verified, 100).unwrap();
    assert!(!installed.enabled);
    assert!(installed.requires_approval);
    assert_eq!(
        installed.verification.unwrap().publisher,
        manifest.publisher.unwrap()
    );
}
