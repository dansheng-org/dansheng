//! System credential store; these capabilities are internal engine ports, not wire methods.
use async_trait::async_trait;
use dansheng_core::{CoreError, CoreResult, PlatformPort};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

const VAULT_CAPABILITIES: &[&str] = &["vault.set", "vault.get", "vault.delete"];
pub struct DesktopPlatform {
    namespace: String,
    directory: PathBuf,
    gate: Arc<tokio::sync::Semaphore>,
}
impl DesktopPlatform {
    pub fn new(data_dir: &Path) -> Self {
        let path = data_dir
            .canonicalize()
            .unwrap_or_else(|_| data_dir.to_owned());
        let path = path.to_string_lossy().into_owned();
        #[cfg(windows)]
        let path = path.to_lowercase();
        Self {
            namespace: format!("dansheng-core/{}", digest(path.as_bytes())),
            directory: data_dir.join("vault"),
            gate: Arc::new(tokio::sync::Semaphore::new(1)),
        }
    }
}
fn digest(value: &[u8]) -> String {
    Sha256::digest(value)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn unavailable() -> CoreError {
    CoreError::new(
        "CapabilityUnavailable",
        "system credential store is unavailable or locked; no plaintext fallback is provided",
    )
}

#[async_trait]
impl PlatformPort for DesktopPlatform {
    fn capabilities(&self) -> Vec<String> {
        VAULT_CAPABILITIES.iter().map(|v| (*v).to_owned()).collect()
    }
    async fn call(&self, capability: &str, input: Value) -> CoreResult<Value> {
        if !VAULT_CAPABILITIES.contains(&capability) {
            return Err(CoreError::new(
                "CapabilityUnavailable",
                "desktop platform capability is not provided",
            ));
        }
        let key = input
            .get("key")
            .and_then(Value::as_str)
            .filter(|key| !key.trim().is_empty() && key.len() <= 1024 && !key.contains('\0'))
            .ok_or_else(|| CoreError::invalid("credential key is missing or invalid"))?;
        let value = if capability == "vault.set" {
            let value = input
                .get("value")
                .ok_or_else(|| CoreError::invalid("credential value is missing"))?;
            let encoded = serde_json::to_string(value)?;
            if encoded.len() > 1024 * 1024 {
                return Err(CoreError::invalid("credential exceeds the input limit"));
            }
            Some(encoded)
        } else {
            None
        };
        let key = digest(key.as_bytes());
        let namespace = self.namespace.clone();
        let directory = self.directory.clone();
        let operation = capability.to_owned();
        let permit = self
            .gate
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| unavailable())?;
        // Native keyring calls run outside Tokio I/O workers. The permit remains with
        // actual native work even if a caller stops waiting; no write is retried.
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            native_call(&directory, &namespace, &key, &operation, value)
        })
        .await
        .map_err(|_| CoreError::new("VaultError", "system credential operation failed"))?
    }
}

#[cfg(target_os = "linux")]
fn native_call(
    _directory: &Path,
    namespace: &str,
    key: &str,
    operation: &str,
    value: Option<String>,
) -> CoreResult<Value> {
    // Only Windows Credential Manager or Secret Service features are compiled;
    // neither a mock store, kernel-only keyutils store nor file fallback is selected.
    let entry = keyring::Entry::new(namespace, key).map_err(safe_error)?;
    match operation {
        "vault.set" => {
            entry
                .set_secret(value.as_deref().unwrap_or_default().as_bytes())
                .map_err(safe_error)?;
            Ok(json!({"ok":true}))
        }
        "vault.get" => match entry.get_secret() {
            Ok(bytes) => {
                let value: Value = serde_json::from_slice(&bytes).map_err(|_| {
                    CoreError::new("VaultError", "stored credential has an invalid format")
                })?;
                Ok(json!({"value":value}))
            }
            Err(keyring::Error::NoEntry) => Ok(json!({"value":null})),
            Err(error) => Err(safe_error(error)),
        },
        "vault.delete" => match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(json!({"ok":true})),
            Err(error) => Err(safe_error(error)),
        },
        _ => Err(unavailable()),
    }
}
#[cfg(target_os = "linux")]
fn safe_error(error: keyring::Error) -> CoreError {
    match error {
        keyring::Error::TooLong(..) => {
            CoreError::invalid("credential exceeds the system credential store limit")
        }
        keyring::Error::Invalid(..) => {
            CoreError::invalid("system credential attributes are invalid")
        }
        _ => unavailable(),
    }
}
#[cfg(not(any(windows, target_os = "linux")))]
fn native_call(_: &Path, _: &str, _: &str, _: &str, _: Option<String>) -> CoreResult<Value> {
    Err(unavailable())
}

#[cfg(windows)]
fn native_call(
    directory: &Path,
    namespace: &str,
    key: &str,
    operation: &str,
    value: Option<String>,
) -> CoreResult<Value> {
    use std::io::Write;
    crate::security::private_dir(directory)?;
    let path = directory.join(format!("{key}.dpapi"));
    if path.try_exists()? {
        let metadata = std::fs::symlink_metadata(&path)?;
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || metadata.len() > 2 * 1024 * 1024
        {
            return Err(CoreError::new(
                "VaultError",
                "invalid encrypted credential file",
            ));
        }
        crate::security::restrict(&path)?;
    }
    let entropy = format!("{namespace}:{key}");
    match operation {
        "vault.set" => {
            let sealed = dpapi(
                value.as_deref().unwrap_or_default().as_bytes(),
                entropy.as_bytes(),
                true,
            )?;
            let temporary = directory.join(format!("{}.tmp", uuid::Uuid::new_v4()));
            let mut file = crate::security::windows::new_private(&temporary)?;
            file.write_all(&sealed)?;
            file.sync_all()?;
            drop(file);
            if let Err(error) = std::fs::rename(&temporary, &path) {
                let _ = std::fs::remove_file(&temporary);
                return Err(error.into());
            }
            Ok(json!({"ok":true}))
        }
        "vault.get" => {
            if !path.try_exists()? {
                return Ok(json!({"value":null}));
            }
            let sealed = std::fs::read(&path)?;
            let clear = dpapi(&sealed, entropy.as_bytes(), false)?;
            let value: Value = serde_json::from_slice(&clear)
                .map_err(|_| CoreError::new("VaultError", "invalid decrypted credential"))?;
            Ok(json!({"value":value}))
        }
        "vault.delete" => {
            if path.try_exists()? {
                std::fs::remove_file(path)?;
            }
            Ok(json!({"ok":true}))
        }
        _ => Err(unavailable()),
    }
}

#[cfg(windows)]
fn dpapi(input: &[u8], entropy: &[u8], protect: bool) -> CoreResult<Vec<u8>> {
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
        },
    };
    let data = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(input.len())
            .map_err(|_| CoreError::invalid("credential too large"))?,
        pbData: input.as_ptr().cast_mut(),
    };
    let entropy = CRYPT_INTEGER_BLOB {
        cbData: entropy.len() as u32,
        pbData: entropy.as_ptr().cast_mut(),
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // DPAPI reads the input buffers for the duration of the call and allocates
    // output with LocalAlloc. No UI is permitted; identity is the current user.
    let ok = unsafe {
        if protect {
            CryptProtectData(
                &data,
                std::ptr::null(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &data,
                std::ptr::null_mut(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        }
    };
    if ok == 0 {
        return Err(CoreError::new(
            "VaultError",
            "Windows credential encryption or decryption failed",
        ));
    }
    let result = if output.cbData > 2 * 1024 * 1024 || output.pbData.is_null() {
        Err(CoreError::new(
            "VaultError",
            "invalid Windows credential result",
        ))
    } else {
        Ok(unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec())
    };
    unsafe {
        LocalFree(output.pbData.cast());
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn vault_validation_and_unavailable_browser_are_explicit() {
        let temp = tempfile::tempdir().unwrap();
        let platform = DesktopPlatform::new(temp.path());
        assert_eq!(
            platform
                .call("browser.request", json!({}))
                .await
                .unwrap_err()
                .code,
            "CapabilityUnavailable"
        );
        assert_eq!(
            platform
                .call("vault.set", json!({"key":""}))
                .await
                .unwrap_err()
                .code,
            "InvalidInput"
        );
        assert_eq!(
            platform
                .call("vault.set", json!({"key":"offline"}))
                .await
                .unwrap_err()
                .code,
            "InvalidInput"
        );
    }
    #[cfg(windows)]
    #[tokio::test]
    async fn actual_windows_dpapi_large_session_survives_provider_restart() {
        let temp = tempfile::tempdir().unwrap();
        let first = DesktopPlatform::new(temp.path());
        let key = format!("contract-fixture-{}", uuid::Uuid::new_v4());
        let value = json!({"fixture":"synthetic local credential test".repeat(4096),"marker":uuid::Uuid::new_v4().to_string()});
        assert!(
            first
                .call("vault.set", json!({"key":key,"value":value}))
                .await
                .is_ok()
        );
        let sealed = std::fs::read(
            first
                .directory
                .join(format!("{}.dpapi", digest(key.as_bytes()))),
        )
        .unwrap();
        assert!(
            !sealed
                .windows(32)
                .any(|window| window == &value["marker"].as_str().unwrap().as_bytes()[..32])
        );
        drop(first);
        let second = DesktopPlatform::new(temp.path());
        let read = second.call("vault.get", json!({"key":key})).await.unwrap();
        assert!(read["value"] == value);
        assert_eq!(
            second
                .call("vault.delete", json!({"key":key}))
                .await
                .unwrap()["ok"],
            true
        );
        assert!(second.call("vault.get", json!({"key":key})).await.unwrap()["value"].is_null());
    }
}
