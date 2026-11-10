//! Token material is never logged. All token reads reject symlinks.
use dansheng_core::{CoreError, CoreResult};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
};

fn denied() -> CoreError {
    CoreError::new(
        "InsecurePermissions",
        "host files must be owned and accessible only by the current user",
    )
}

pub fn private_dir(path: &Path) -> CoreResult<()> {
    if path.exists() && fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(denied());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true).mode(0o700);
        builder.create(path)?;
    }
    #[cfg(not(unix))]
    fs::create_dir_all(path)?;
    restrict(path)?;
    Ok(())
}

pub fn restrict(path: &Path) -> CoreResult<()> {
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(denied());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let metadata = fs::metadata(path)?;
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(denied());
        }
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if metadata.is_dir() { 0o700 } else { 0o600 }),
        )?;
    }
    #[cfg(windows)]
    windows::restrict(path)?;
    Ok(())
}

fn new_private(path: &Path) -> std::io::Result<File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
    }
    #[cfg(windows)]
    {
        windows::new_private(path)
    }
    #[cfg(not(any(unix, windows)))]
    {
        OpenOptions::new().write(true).create_new(true).open(path)
    }
}

pub fn read_token(path: &Path) -> CoreResult<String> {
    restrict(path)?;
    if !fs::metadata(path)?.is_file() {
        return Err(denied());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
        use std::os::unix::fs::MetadataExt;
        if fs::metadata(path)?.nlink() != 1 {
            return Err(denied());
        }
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        return Err(denied());
    }
    let mut token = String::new();
    file.take(513).read_to_string(&mut token)?;
    let token = token.trim();
    if token.len() < 32 || token.len() > 512 || token.chars().any(char::is_whitespace) {
        return Err(CoreError::new(
            "InvalidTokenFile",
            "token file is malformed",
        ));
    }
    Ok(token.to_owned())
}

pub fn provision_token(path: &Path) -> CoreResult<String> {
    match new_private(path) {
        Ok(mut file) => {
            let token = format!(
                "{}{}",
                uuid::Uuid::new_v4().simple(),
                uuid::Uuid::new_v4().simple()
            );
            file.write_all(token.as_bytes())?;
            file.sync_all()?;
            Ok(token)
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => read_token(path),
        Err(e) => Err(e.into()),
    }
}

pub fn write_private_json(path: &Path, value: &impl serde::Serialize) -> CoreResult<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    match new_private(path) {
        Ok(mut file) => {
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            restrict(path)?;
            let mut file = OpenOptions::new().write(true).truncate(true).open(path)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        Err(e) => return Err(e.into()),
    }
    Ok(())
}

#[cfg(windows)]
pub mod windows {
    use super::*;
    use std::{
        os::windows::{ffi::OsStrExt, io::FromRawHandle},
        ptr,
    };
    use windows_sys::Win32::{
        Foundation::*,
        Security::{Authorization::*, *},
        Storage::FileSystem::*,
        System::Threading::*,
    };

    pub struct UserSecurity {
        descriptor: PSECURITY_DESCRIPTOR,
    }
    impl UserSecurity {
        pub fn new() -> std::io::Result<Self> {
            unsafe {
                let mut token = ptr::null_mut();
                if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let mut needed = 0;
                GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut needed);
                let mut storage = vec![0usize; (needed as usize).div_ceil(size_of::<usize>())];
                let success = GetTokenInformation(
                    token,
                    TokenUser,
                    storage.as_mut_ptr().cast(),
                    needed,
                    &mut needed,
                );
                CloseHandle(token);
                if success == 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let user = &*storage.as_ptr().cast::<TOKEN_USER>();
                let mut sid = ptr::null_mut();
                if ConvertSidToStringSidW(user.User.Sid, &mut sid) == 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let mut len = 0;
                while *sid.add(len) != 0 {
                    len += 1;
                }
                let sid_text = String::from_utf16_lossy(std::slice::from_raw_parts(sid, len));
                LocalFree(sid.cast());
                let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid_text})\0")
                    .encode_utf16()
                    .collect();
                let mut descriptor = ptr::null_mut();
                if ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    ptr::null_mut(),
                ) == 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(Self { descriptor })
            }
        }
        pub fn attributes(&self) -> SECURITY_ATTRIBUTES {
            SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: self.descriptor,
                bInheritHandle: 0,
            }
        }
    }
    impl Drop for UserSecurity {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.descriptor);
            }
        }
    }

    pub fn restrict(path: &Path) -> CoreResult<()> {
        let security = UserSecurity::new()?;
        let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        unsafe {
            if SetFileSecurityW(
                path.as_ptr(),
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                security.descriptor,
            ) == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        Ok(())
    }
    pub fn new_private(path: &Path) -> std::io::Result<File> {
        let security = UserSecurity::new()?;
        let attrs = security.attributes();
        let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        unsafe {
            let handle = CreateFileW(
                path.as_ptr(),
                GENERIC_WRITE,
                0,
                &attrs,
                CREATE_NEW,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                ptr::null_mut(),
            );
            if handle == INVALID_HANDLE_VALUE {
                return Err(std::io::Error::last_os_error());
            }
            Ok(File::from_raw_handle(handle))
        }
    }

    #[cfg(test)]
    pub(super) fn assert_current_user_only(path: &Path) {
        let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        unsafe {
            let mut needed = 0;
            GetFileSecurityW(
                path.as_ptr(),
                DACL_SECURITY_INFORMATION,
                ptr::null_mut(),
                0,
                &mut needed,
            );
            let mut descriptor = vec![0usize; (needed as usize).div_ceil(size_of::<usize>())];
            assert_ne!(
                GetFileSecurityW(
                    path.as_ptr(),
                    DACL_SECURITY_INFORMATION,
                    descriptor.as_mut_ptr().cast(),
                    needed,
                    &mut needed
                ),
                0
            );
            let mut control = 0;
            let mut revision = 0;
            assert_ne!(
                GetSecurityDescriptorControl(
                    descriptor.as_mut_ptr().cast(),
                    &mut control,
                    &mut revision
                ),
                0
            );
            assert_ne!(control & SE_DACL_PROTECTED, 0);
            let mut present = 0;
            let mut defaulted = 0;
            let mut actual = ptr::null_mut();
            assert_ne!(
                GetSecurityDescriptorDacl(
                    descriptor.as_mut_ptr().cast(),
                    &mut present,
                    &mut actual,
                    &mut defaulted
                ),
                0
            );
            assert_ne!(present, 0);
            assert!(!actual.is_null());
            assert_eq!((*actual).AceCount, 1);
            let expected_security = UserSecurity::new().unwrap();
            let mut expected = ptr::null_mut();
            assert_ne!(
                GetSecurityDescriptorDacl(
                    expected_security.descriptor,
                    &mut present,
                    &mut expected,
                    &mut defaulted
                ),
                0
            );
            let mut actual_ace = ptr::null_mut();
            let mut expected_ace = ptr::null_mut();
            assert_ne!(GetAce(actual, 0, &mut actual_ace), 0);
            assert_ne!(GetAce(expected, 0, &mut expected_ace), 0);
            let actual_ace = &*actual_ace.cast::<ACCESS_ALLOWED_ACE>();
            let expected_ace = &*expected_ace.cast::<ACCESS_ALLOWED_ACE>();
            assert_eq!(actual_ace.Header.AceType, expected_ace.Header.AceType);
            assert!(
                actual_ace.Mask & GENERIC_ALL != 0
                    || actual_ace.Mask & FILE_ALL_ACCESS == FILE_ALL_ACCESS
            );
            assert_ne!(
                EqualSid(
                    (&actual_ace.SidStart as *const u32).cast_mut().cast(),
                    (&expected_ace.SidStart as *const u32).cast_mut().cast()
                ),
                0
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_survives_restart_without_exporting_value() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().join("host");
        private_dir(&dir).unwrap();
        let path = dir.join("owner-token");
        assert!(provision_token(&path).unwrap() == provision_token(&path).unwrap());
        #[cfg(windows)]
        windows::assert_current_user_only(&path);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
}
