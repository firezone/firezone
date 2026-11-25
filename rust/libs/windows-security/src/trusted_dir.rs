//! Directories that a privileged process keeps under a parent that other
//! users can write to, such as `C:\ProgramData`.
//!
//! A DACL alone does not protect such a directory: its owner can always
//! change the DACL again. [`secure_dir`] therefore also makes sure that a
//! trusted principal owns the directory and every entry in it.

use crate::SecurityDescriptor;
use anyhow::{Context as _, Result, ensure};
use std::{
    fs, io,
    os::windows::{
        fs::{MetadataExt as _, OpenOptionsExt as _},
        io::AsRawHandle as _,
    },
    path::{Path, PathBuf},
};
use windows::{
    Win32::{
        Foundation::{HANDLE, HLOCAL, LocalFree},
        Security::{
            Authorization::{GetSecurityInfo, SE_FILE_OBJECT},
            EqualSid, GetTokenInformation, IsWellKnownSid, OWNER_SECURITY_INFORMATION,
            PSECURITY_DESCRIPTOR, PSID, TOKEN_QUERY, TOKEN_USER, TokenUser,
            WinBuiltinAdministratorsSid, WinLocalSystemSid,
        },
        Storage::FileSystem::{
            FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
            FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, READ_CONTROL,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    },
    core::Owned,
};

/// Makes `path` a directory that a trusted principal owns, applies the DACL
/// of `descriptor` to it, and moves out every entry in it that a trusted
/// principal does not own.
///
/// Trusted principals are `LocalSystem`, `BUILTIN\Administrators` and the
/// user of the current process. Reparse points are never trusted.
///
/// Untrusted objects move to `{quarantine}-{uuid}`. `quarantine` must be on
/// the same volume as `path` and outside of it.
///
/// Returns the new paths of the objects that moved.
pub fn secure_dir(
    path: &Path,
    descriptor: &SecurityDescriptor,
    quarantine: &Path,
) -> Result<Vec<PathBuf>> {
    let mut moved = Vec::new();

    match fs::create_dir(path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => {
            return Err(e).with_context(|| format!("Failed to create `{}`", path.display()));
        }
    }

    if !trusted_object(path)?.is_some_and(|object| object.is_dir) {
        moved.push(move_aside(path, quarantine)?);

        fs::create_dir(path).with_context(|| format!("Failed to create `{}`", path.display()))?;
        ensure!(
            trusted_object(path)?.is_some_and(|object| object.is_dir),
            "`{}` is not a directory that a trusted principal owns",
            path.display()
        );
    }

    descriptor.apply_to_path(path)?;

    for entry in
        fs::read_dir(path).with_context(|| format!("Failed to list `{}`", path.display()))?
    {
        let entry = entry
            .with_context(|| format!("Failed to list `{}`", path.display()))?
            .path();

        if trusted_object(&entry)?.is_none() {
            moved.push(move_aside(&entry, quarantine)?);
        }
    }

    Ok(moved)
}

struct TrustedObject {
    is_dir: bool,
}

/// Returns `None` if `path` is a reparse point, or if a trusted principal
/// does not own it, or if we cannot read its owner.
///
/// We open the object itself (not the target of a reparse point) and read
/// everything from that one handle.
fn trusted_object(path: &Path) -> Result<Option<TrustedObject>> {
    let file = match fs::OpenOptions::new()
        .access_mode(READ_CONTROL.0)
        .share_mode((FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE).0)
        .custom_flags((FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT).0)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => return Ok(None),
        Err(e) => return Err(e).with_context(|| format!("Failed to open `{}`", path.display())),
    };

    let metadata = file
        .metadata()
        .with_context(|| format!("Failed to read metadata of `{}`", path.display()))?;

    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
        return Ok(None);
    }

    if !has_trusted_owner(HANDLE(file.as_raw_handle()))
        .with_context(|| format!("Failed to read owner of `{}`", path.display()))?
    {
        return Ok(None);
    }

    Ok(Some(TrustedObject {
        is_dir: metadata.is_dir(),
    }))
}

fn has_trusted_owner(handle: HANDLE) -> Result<bool> {
    let mut owner = PSID::default();
    let mut descriptor = PSECURITY_DESCRIPTOR::default();

    // SAFETY: `handle` is a live file handle. The other arguments are
    // out-pointers to stack locals. On success Windows allocates
    // `descriptor` (which we release with `LocalFree`) and points `owner`
    // into it.
    let err = unsafe {
        GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            None,
            None,
            Some(&mut descriptor),
        )
    };
    if err.0 != 0 {
        return Err(io::Error::from_raw_os_error(err.0 as i32)).context("GetSecurityInfo failed");
    }

    let trusted = is_trusted_sid(owner);

    // SAFETY: `descriptor` was allocated by `GetSecurityInfo`. No pointer
    // derived from it is used after this.
    unsafe {
        let _ = LocalFree(Some(HLOCAL(descriptor.0)));
    }

    trusted
}

fn is_trusted_sid(sid: PSID) -> Result<bool> {
    // SAFETY: `sid` is a valid SID and Windows does not retain it.
    let well_known = unsafe {
        IsWellKnownSid(sid, WinLocalSystemSid).as_bool()
            || IsWellKnownSid(sid, WinBuiltinAdministratorsSid).as_bool()
    };
    if well_known {
        return Ok(true);
    }

    let mut token = HANDLE::default();
    // SAFETY: `GetCurrentProcess` returns a pseudo handle and `&mut token`
    // is a valid out-pointer.
    unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) }
        .context("OpenProcessToken failed")?;
    // SAFETY: `OpenProcessToken` succeeded, so we own `token`.
    let token = unsafe { Owned::new(token) };

    let mut len = 0u32;
    // SAFETY: With no buffer, Windows only writes the needed size to `len`.
    // This call fails with `ERROR_INSUFFICIENT_BUFFER` by design.
    let _ = unsafe { GetTokenInformation(*token, TokenUser, None, 0, &mut len) };

    // `u64` elements keep the buffer aligned for `TOKEN_USER`.
    let mut buffer = vec![0u64; (len as usize).div_ceil(size_of::<u64>())];
    // SAFETY: `buffer` has room for `len` bytes.
    unsafe {
        GetTokenInformation(
            *token,
            TokenUser,
            Some(buffer.as_mut_ptr().cast()),
            len,
            &mut len,
        )
    }
    .context("GetTokenInformation failed")?;

    // SAFETY: On success, `buffer` starts with a `TOKEN_USER` whose SID
    // points into `buffer`, which lives until the end of this function.
    let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };

    // SAFETY: Both SIDs are valid for this call.
    Ok(unsafe { EqualSid(sid, user.User.Sid) }.is_ok())
}

/// Moves `path` to `{quarantine}-{uuid}`.
///
/// This needs `DELETE` on `path` or `FILE_DELETE_CHILD` on its parent, so it
/// works whatever DACL the owner of `path` set on it.
fn move_aside(path: &Path, quarantine: &Path) -> Result<PathBuf> {
    let mut target = quarantine.as_os_str().to_owned();
    target.push(format!("-{}", uuid::Uuid::new_v4().simple()));
    let target = PathBuf::from(target);

    fs::rename(path, &target).with_context(|| {
        format!(
            "Failed to move untrusted `{}` to `{}`",
            path.display(),
            target.display()
        )
    })?;

    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    const SDDL: &str = "D:P(A;OICI;FA;;;WD)";

    #[test]
    fn creates_missing_dir() {
        let root = tempdir().unwrap();
        let dir = root.path().join("dir");
        let descriptor = SecurityDescriptor::from_sddl(SDDL).unwrap();

        let moved = secure_dir(&dir, &descriptor, &root.path().join("untrusted")).unwrap();

        assert!(moved.is_empty());
        assert!(dir.is_dir());
    }

    #[test]
    fn keeps_own_dir_and_entries() {
        let root = tempdir().unwrap();
        let dir = root.path().join("dir");
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("file.json"), "{}").unwrap();
        let descriptor = SecurityDescriptor::from_sddl(SDDL).unwrap();

        let moved = secure_dir(&dir, &descriptor, &root.path().join("untrusted")).unwrap();

        assert!(moved.is_empty());
        assert_eq!(fs::read_to_string(dir.join("file.json")).unwrap(), "{}");
    }

    #[test]
    fn replaces_file_at_dir_path() {
        let root = tempdir().unwrap();
        let dir = root.path().join("dir");
        fs::write(&dir, "").unwrap();
        let descriptor = SecurityDescriptor::from_sddl(SDDL).unwrap();

        let moved = secure_dir(&dir, &descriptor, &root.path().join("untrusted")).unwrap();

        assert_eq!(moved.len(), 1);
        assert!(moved[0].is_file());
        assert!(dir.is_dir());
    }

    #[test]
    fn moves_out_untrusted_entries() {
        let root = tempdir().unwrap();
        let dir = root.path().join("dir");
        fs::create_dir(&dir).unwrap();
        let file = dir.join("file.json");
        fs::write(&file, "{}").unwrap();
        // `Everyone` is never a trusted owner.
        if !set_owner(&file, "*S-1-1-0") {
            return;
        }
        let descriptor = SecurityDescriptor::from_sddl(SDDL).unwrap();

        let moved = secure_dir(&dir, &descriptor, &root.path().join("untrusted")).unwrap();

        assert_eq!(moved.len(), 1);
        assert!(!file.exists());
        assert_eq!(fs::read_to_string(&moved[0]).unwrap(), "{}");
    }

    /// Setting another owner needs `SeRestorePrivilege`, which only elevated
    /// processes have. Returns `false` when we cannot do that.
    fn set_owner(path: &Path, sid: &str) -> bool {
        std::process::Command::new("icacls")
            .arg(path)
            .arg("/setowner")
            .arg(sid)
            .status()
            .unwrap()
            .success()
    }
}
