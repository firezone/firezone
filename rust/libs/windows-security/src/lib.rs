//! Safe wrappers around the Windows security descriptor APIs.
//!
//! The crate confines all unsafe FFI to a small set of types so that callers
//! get a Rust-y interface that upholds Windows' lifetime and ownership
//! requirements (e.g. `LocalFree` on the buffer returned by
//! `ConvertStringSecurityDescriptorToSecurityDescriptorW`).
//!
//! Windows-only: builds to an empty rlib on other platforms so cross-platform
//! callers can simply gate their use sites with `cfg(windows)`.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg(windows)]

pub mod pipe_dacl;

use anyhow::{Context as _, Result, bail, ensure};
use std::{
    ffi::{OsStr, c_void},
    os::windows::ffi::OsStrExt,
    path::Path,
    ptr,
};
use windows::{
    Win32::{
        Foundation::{ERROR_SUCCESS, HLOCAL, LocalFree},
        Security::{
            ACCESS_ALLOWED_ACE, ACE_HEADER, ACL,
            Authorization::{
                ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
                GetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT, SetNamedSecurityInfoW,
            },
            DACL_SECURITY_INFORMATION, GetAce, GetSecurityDescriptorDacl, INHERIT_ONLY_ACE,
            PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
        },
        System::SystemServices::{ACCESS_ALLOWED_ACE_TYPE, ACCESS_DENIED_ACE_TYPE},
    },
    core::{BOOL, PCWSTR, PWSTR},
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

/// Returns the SIDs (`S-1-…`) that the DACL of the named file or directory
/// grants access to.
///
/// Fails if the DACL is NULL, which grants unrestricted access, or contains an
/// ACE type other than plain allow or deny.
pub fn allowed_sids_for_path(path: &Path) -> Result<Vec<String>> {
    let path_wide = wide(path.as_os_str());
    let mut dacl: *mut ACL = ptr::null_mut();
    let mut descriptor = PSECURITY_DESCRIPTOR::default();

    // SAFETY: `path_wide` is null-terminated and the other arguments are valid
    // out-pointers to local variables. On success, `descriptor` is set to a
    // buffer that we release with `LocalFree` below and `dacl` points into it.
    let err = unsafe {
        GetNamedSecurityInfoW(
            PCWSTR(path_wide.as_ptr()),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(&mut dacl),
            None,
            &mut descriptor,
        )
    };

    if err != ERROR_SUCCESS {
        return Err(std::io::Error::from_raw_os_error(err.0 as i32))
            .with_context(|| format!("Failed to get Windows DACL of `{}`", path.display()));
    }

    // SAFETY: `dacl` is NULL or points into `descriptor`, which is still alive.
    let sids = unsafe { allowed_sids(dacl) }
        .with_context(|| format!("Failed to read Windows DACL of `{}`", path.display()));

    // SAFETY: `descriptor` was allocated by `GetNamedSecurityInfoW` and must be
    // released with `LocalFree`. After this call no pointer derived from it is
    // used.
    unsafe {
        LocalFree(Some(HLOCAL(descriptor.0)));
    }

    sids
}

/// # Safety
///
/// `dacl` must be NULL or point to a valid ACL.
unsafe fn allowed_sids(dacl: *const ACL) -> Result<Vec<String>> {
    ensure!(!dacl.is_null(), "DACL is NULL");

    // SAFETY: `dacl` is non-NULL and points to a valid ACL.
    let ace_count = unsafe { (*dacl).AceCount };
    let mut sids = Vec::new();

    for index in 0..u32::from(ace_count) {
        let mut ace: *mut c_void = ptr::null_mut();

        // SAFETY: `dacl` is a valid ACL and `index` is below its ACE count.
        unsafe { GetAce(dacl, index, &mut ace) }.context("Failed to get ACE")?;

        // SAFETY: Every ACE starts with an `ACE_HEADER`.
        let header = unsafe { *ace.cast::<ACE_HEADER>() };

        if u32::from(header.AceFlags) & INHERIT_ONLY_ACE.0 != 0 {
            continue;
        }

        match u32::from(header.AceType) {
            ACCESS_ALLOWED_ACE_TYPE => {
                // SAFETY: The header marks this as an `ACCESS_ALLOWED_ACE`, whose
                // SID starts at `SidStart`.
                let sid =
                    unsafe { ptr::addr_of_mut!((*ace.cast::<ACCESS_ALLOWED_ACE>()).SidStart) };

                sids.push(sid_to_string(PSID(sid.cast()))?);
            }
            ACCESS_DENIED_ACE_TYPE => {}
            other => bail!("Unsupported ACE type {other}"),
        }
    }

    Ok(sids)
}

fn wide(s: impl AsRef<OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}

/// Renders a `PSID` into its SDDL string form (`S-1-…`) by calling
/// `ConvertSidToStringSidW` and freeing the Windows-allocated buffer
/// with `LocalFree`.
pub(crate) fn sid_to_string(sid: PSID) -> Result<String> {
    let mut out = PWSTR(ptr::null_mut());
    // SAFETY: `sid` is a valid SID from a Windows API; `&mut out` is a valid
    // out-pointer. On success Windows allocates a wide string with
    // `LocalAlloc`, which we release with `LocalFree`.
    unsafe { ConvertSidToStringSidW(sid, &mut out) }.context("ConvertSidToStringSidW failed")?;
    ensure!(!out.0.is_null(), "ConvertSidToStringSidW returned NULL");

    // SAFETY: `out.0` points to a null-terminated wide string allocated by
    // Windows; we copy it into an owned `String` before freeing.
    let s = unsafe { out.to_string() }.context("ConvertSidToStringSidW returned invalid UTF-16")?;

    // SAFETY: `out` is the LocalAlloc-allocated buffer; release it.
    unsafe {
        let _ = LocalFree(Some(HLOCAL(out.0 as *mut _)));
    }

    Ok(s)
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
    fn allowed_sids_for_path_skips_deny_aces() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("token.txt");
        std::fs::write(&path, "").unwrap();

        SecurityDescriptor::from_sddl("D:(D;;FA;;;AN)(A;;FA;;;WD)")
            .unwrap()
            .apply_to_path(&path)
            .unwrap();

        assert_eq!(allowed_sids_for_path(&path).unwrap(), ["S-1-1-0"]);
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
