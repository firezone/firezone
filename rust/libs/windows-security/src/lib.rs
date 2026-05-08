//! Safe wrappers around the Windows security descriptor APIs.
//!
//! The crate confines all unsafe FFI to a small set of types so that callers
//! get a Rust-y interface that upholds Windows' lifetime and ownership
//! requirements (e.g. `LocalFree` on the buffer returned by
//! `ConvertStringSecurityDescriptorToSecurityDescriptorW`).
//!
//! Windows-only: builds to an empty rlib on other platforms so cross-platform
//! callers can simply gate their use sites with `cfg(windows)`.

#![cfg(windows)]

use anyhow::{Context as _, Result, ensure};
use std::{ffi::OsStr, os::windows::ffi::OsStrExt, path::Path, ptr};
use windows::{
    Win32::{
        Foundation::{ERROR_SUCCESS, HLOCAL, LocalFree},
        Security::{
            ACL,
            Authorization::{
                ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
                SE_FILE_OBJECT, SetNamedSecurityInfoW,
            },
            DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl,
            PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
        },
    },
    core::{BOOL, PCWSTR},
};

/// Owned wrapper around a `PSECURITY_DESCRIPTOR` allocated by
/// `ConvertStringSecurityDescriptorToSecurityDescriptorW`.
///
/// The only constructor, [`Self::from_sddl`], guarantees that the inner
/// pointer was returned by that API. This upholds the safety invariant of the
/// [`Drop`] impl, which calls `LocalFree`.
pub struct SecurityDescriptor(PSECURITY_DESCRIPTOR);

impl SecurityDescriptor {
    /// Parses an SDDL string into an owned security descriptor.
    ///
    /// See [SDDL for Conditional ACEs](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptor-string-format).
    pub fn from_sddl(sddl: &str) -> Result<Self> {
        let sddl = wide(sddl);
        let mut descriptor = PSECURITY_DESCRIPTOR::default();

        // SAFETY: `sddl` is null-terminated by `wide` and `&mut descriptor` is
        // a valid out-pointer to a stack-allocated value. On success,
        // `descriptor` is set to a buffer that we own and that will be released
        // by our `Drop` impl.
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                PCWSTR(sddl.as_ptr()),
                SDDL_REVISION_1,
                &mut descriptor,
                None,
            )
        }
        .context("Failed to build Windows security descriptor from SDDL")?;

        Ok(Self(descriptor))
    }

    /// Applies this security descriptor's DACL to the named file or directory,
    /// replacing any inherited ACEs.
    pub fn apply_to_path(&self, path: &Path) -> Result<()> {
        let dacl = self.dacl()?;
        let path_wide = wide(path.as_os_str());
        let security_info = DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION;

        // SAFETY: `path_wide` is null-terminated, `dacl` borrows from `self`'s
        // buffer (which lives for this call), and Windows does not retain any
        // of these pointers after the call returns.
        let err = unsafe {
            SetNamedSecurityInfoW(
                PCWSTR(path_wide.as_ptr()),
                SE_FILE_OBJECT,
                security_info,
                None,
                None,
                Some(dacl),
                None,
            )
        };

        if err != ERROR_SUCCESS {
            return Err(std::io::Error::from_raw_os_error(err.0 as i32))
                .with_context(|| format!("Failed to set Windows DACL on `{}`", path.display()));
        }

        Ok(())
    }

    /// Returns the raw `PSECURITY_DESCRIPTOR` for use in
    /// `SECURITY_ATTRIBUTES::lpSecurityDescriptor` when creating a kernel
    /// object (named pipe, mutex, file, ...).
    ///
    /// The kernel copies the descriptor when the kernel object is created, so
    /// `self` may be dropped after the syscall returns.
    pub fn as_raw(&self) -> PSECURITY_DESCRIPTOR {
        self.0
    }

    fn dacl(&self) -> Result<*const ACL> {
        let mut dacl_present = BOOL::default();
        let mut dacl_defaulted = BOOL::default();
        let mut dacl: *mut ACL = ptr::null_mut();

        // SAFETY: `self.0` is a valid security descriptor (only constructed
        // via `from_sddl`). The other arguments are valid out-pointers into
        // local variables.
        unsafe {
            GetSecurityDescriptorDacl(self.0, &mut dacl_present, &mut dacl, &mut dacl_defaulted)
        }
        .context("Failed to get DACL from Windows security descriptor")?;

        ensure!(
            dacl_present.as_bool(),
            "Windows security descriptor has no DACL"
        );
        // A `NULL` DACL with `dacl_present == TRUE` semantically means
        // "unrestricted access" — distinct from "no DACL set". We never
        // want to propagate that to `SetNamedSecurityInfoW`.
        ensure!(
            !dacl.is_null(),
            "Windows security descriptor has a NULL DACL"
        );

        Ok(dacl)
    }
}

impl Drop for SecurityDescriptor {
    fn drop(&mut self) {
        // SAFETY: `self.0` was allocated by
        // `ConvertStringSecurityDescriptorToSecurityDescriptorW` (the only
        // constructor of `Self`) and must be released with `LocalFree`.
        unsafe {
            LocalFree(Some(HLOCAL(self.0.0)));
        }
    }
}

fn wide(s: impl AsRef<OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    /// SDDL with both protected DACL ACEs we want round-tripped through
    /// `from_sddl` -> `Drop`.
    const DACL_ONLY_SDDL: &str = "D:P(A;;FA;;;SY)(A;;FA;;;BA)";

    /// Permissive DACL we use in tests that need to actually apply a security
    /// descriptor. Granting Full Access to `WD` (Everyone) keeps the temp
    /// dir/file deletable by the test process during cleanup, regardless of
    /// whether tests run as Administrator.
    const PERMISSIVE_SDDL: &str = "D:(A;;FA;;;WD)";

    #[test]
    fn parse_dacl_only_sddl_does_not_crash() {
        // Exercises `ConvertStringSecurityDescriptorToSecurityDescriptorW`
        // and the `Drop` impl that calls `LocalFree`.
        SecurityDescriptor::from_sddl(DACL_ONLY_SDDL).unwrap();
    }

    #[test]
    fn parse_invalid_sddl_returns_err() {
        // Empty strings *do* parse successfully on Windows (they yield a
        // descriptor with no DACL/SACL set), so we only assert on garbage.
        assert!(SecurityDescriptor::from_sddl("not a valid SDDL").is_err());
    }

    #[test]
    fn apply_dacl_to_temp_dir() {
        let dir = tempdir().unwrap();

        SecurityDescriptor::from_sddl(PERMISSIVE_SDDL)
            .unwrap()
            .apply_to_path(dir.path())
            .unwrap();
    }

    #[test]
    fn apply_dacl_to_temp_file() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("firezone-id");
        std::fs::write(&path, "{}").unwrap();

        SecurityDescriptor::from_sddl(PERMISSIVE_SDDL)
            .unwrap()
            .apply_to_path(&path)
            .unwrap();
    }

    #[test]
    fn apply_dacl_to_missing_path_returns_err() {
        let dir = tempdir().unwrap();
        let missing = dir.path().join("does-not-exist");

        let result = SecurityDescriptor::from_sddl(PERMISSIVE_SDDL)
            .unwrap()
            .apply_to_path(&missing);
        assert!(result.is_err());
    }

    #[test]
    fn dropping_many_security_descriptors_does_not_crash() {
        // Hammer `Drop` to surface any double-free or use-after-free.
        for _ in 0..1024 {
            let _ = SecurityDescriptor::from_sddl(DACL_ONLY_SDDL).unwrap();
        }
    }

    #[test]
    fn as_raw_returns_descriptor_with_dacl() {
        let sd = SecurityDescriptor::from_sddl(DACL_ONLY_SDDL).unwrap();

        let raw = sd.as_raw();
        assert!(!raw.0.is_null());

        let mut dacl_present = BOOL::default();
        let mut dacl_defaulted = BOOL::default();
        let mut dacl: *mut ACL = ptr::null_mut();
        // SAFETY: `raw` came from a live `SecurityDescriptor`; the out-pointers
        // are valid and Windows does not retain them.
        unsafe {
            GetSecurityDescriptorDacl(raw, &mut dacl_present, &mut dacl, &mut dacl_defaulted)
        }
        .unwrap();

        assert!(dacl_present.as_bool());
        assert!(!dacl.is_null());
    }
}
