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

use anyhow::{Context as _, Result, ensure};
use std::ffi::c_void;
use std::{ffi::OsStr, os::windows::ffi::OsStrExt, path::Path, ptr};
use windows::{
    Win32::{
        Foundation::{CloseHandle, ERROR_SUCCESS, HANDLE, HLOCAL, LocalFree},
        Security::{
            ACL,
            Authorization::{
                ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
                SDDL_REVISION_1, SE_FILE_OBJECT, SetNamedSecurityInfoW,
            },
            DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl, GetTokenInformation,
            PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SID_AND_ATTRIBUTES,
            TOKEN_GROUPS, TOKEN_INFORMATION_CLASS, TOKEN_QUERY, TOKEN_USER, TokenLogonSid,
            TokenUser,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
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

fn wide(s: impl AsRef<OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}

/// RAII wrapper around a `HANDLE` opened by `OpenProcessToken` (or
/// similar). Unlike the `GetCurrentProcess` pseudo-handle, real token
/// handles must be released with `CloseHandle` — without this wrapper
/// each call to `current_user_sid_string` leaks a kernel handle.
struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            // SAFETY: `self.0` was produced by `OpenProcessToken`; the
            // wrapper is the sole owner.
            let _ = unsafe { CloseHandle(self.0) };
        }
    }
}

fn open_current_process_token() -> Result<OwnedHandle> {
    let mut token = HANDLE::default();
    // SAFETY: `GetCurrentProcess` returns a pseudo-handle that doesn't need
    // closing; `OpenProcessToken` writes the real handle into `token`.
    unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) }
        .context("OpenProcessToken failed")?;
    Ok(OwnedHandle(token))
}

/// Allocates a buffer sized for the requested token-information class
/// and fills it via `GetTokenInformation`. The two-call sizing pattern
/// is the documented way to discover the length of variable-sized
/// token info (`TokenUser`, `TokenLogonSid`, ...).
fn read_token_information(token: &OwnedHandle, class: TOKEN_INFORMATION_CLASS) -> Result<Vec<u8>> {
    let mut needed: u32 = 0;
    // SAFETY: A zero-sized buffer with `None` info is the documented
    // pattern for sizing. The error return is expected.
    let _ = unsafe { GetTokenInformation(token.0, class, None, 0, &mut needed) };

    let mut buf = vec![0u8; needed as usize];
    // SAFETY: `buf` has length `needed`; the API writes the structure
    // for `class` into it.
    unsafe {
        GetTokenInformation(
            token.0,
            class,
            Some(buf.as_mut_ptr() as *mut c_void),
            needed,
            &mut needed,
        )
    }
    .with_context(|| format!("GetTokenInformation({class:?}) failed"))?;
    Ok(buf)
}

/// Returns the calling process's primary-user SID in SDDL string form
/// (e.g. `"S-1-5-21-..."`).
///
/// Built on `OpenProcessToken` + `GetTokenInformation(TokenUser)` +
/// `ConvertSidToStringSidW`. The token handle is closed via
/// [`OwnedHandle`]; the `LocalFree` on the SID buffer is handled
/// internally so callers don't have to think about Windows lifetime
/// rules.
pub fn current_user_sid_string() -> Result<String> {
    let token = open_current_process_token()?;
    let buf = read_token_information(&token, TokenUser)?;

    // SAFETY: `buf` holds at least one `TOKEN_USER`; the cast yields a
    // reference whose lifetime is bounded by the `buf` borrow.
    let token_user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    sid_to_string(token_user.User.Sid)
}

/// Returns the calling process's *logon-session* SID in SDDL string
/// form (e.g. `"S-1-5-5-X-Y"`). Distinct from the user SID — this one
/// changes per interactive logon / RDP session, which is exactly the
/// boundary you want for "this user's running GUI process" rather than
/// "any process from this user account anywhere on the box".
///
/// Returns an error in service contexts that don't have a logon-SID
/// entry (background services, scheduled tasks running as `LocalSystem`,
/// some sandboxed processes). Callers that need to gracefully degrade
/// should fall back to [`current_user_sid_string`] on error.
pub fn current_logon_sid_string() -> Result<String> {
    let token = open_current_process_token()?;
    let buf = read_token_information(&token, TokenLogonSid)?;

    // SAFETY: `buf` starts with a `TOKEN_GROUPS` (GroupCount + flexible
    // array of `SID_AND_ATTRIBUTES`); the second cast walks one entry
    // past the GroupCount, which is in-bounds when `GroupCount >= 1`.
    let groups = unsafe { &*(buf.as_ptr() as *const TOKEN_GROUPS) };
    ensure!(
        groups.GroupCount >= 1,
        "Process token has no logon-session SID (likely a service / non-interactive context)"
    );
    let first = unsafe { &*(groups.Groups.as_ptr() as *const SID_AND_ATTRIBUTES) };
    sid_to_string(first.Sid)
}

fn sid_to_string(sid: PSID) -> Result<String> {
    let mut wide_ptr: PWSTR = PWSTR::null();
    // SAFETY: `ConvertSidToStringSidW` writes a fresh allocation to
    // `wide_ptr` that we own and must release via `LocalFree`.
    unsafe { ConvertSidToStringSidW(sid, &mut wide_ptr) }
        .context("ConvertSidToStringSidW failed")?;

    // SAFETY: `wide_ptr` is a non-null pointer to a NUL-terminated UTF-16
    // string Windows allocated; `to_string` walks until the NUL.
    let s = unsafe { wide_ptr.to_string() }.context("SID buffer was not valid UTF-16")?;

    // SAFETY: We own `wide_ptr` and must release it with `LocalFree`; after
    // this call no pointer derived from it is used.
    unsafe { LocalFree(Some(HLOCAL(wide_ptr.0 as *mut c_void))) };
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

    /// SDDL with a conditional `XA` (callback-allow) ACE plus a long
    /// `S-1-15-2-...` package SID and a `Member_of` predicate referencing
    /// a per-user SID. This is the exact shape of the GUI-pipe DACL the
    /// Firezone IPC layer constructs at runtime; if the kernel's SDDL
    /// parser refuses it, the GUI's pipe-creation will fail closed and
    /// the second-instance/deeplink flow breaks. We pin it here to
    /// catch any regression in the underlying Win32 surface.
    const CONDITIONAL_PACKAGE_SDDL: &str = concat!(
        "D:P(A;;FA;;;SY)(A;;FA;;;BA)",
        "(XA;;FRFW;;;",
        "S-1-15-2-1112396765-125922509-3270321643-1953995960-1208983976",
        ";(Member_of {SID(S-1-5-21-1-2-3-1001)}))",
    );

    #[test]
    fn parse_dacl_only_sddl_does_not_crash() {
        // Exercises `ConvertStringSecurityDescriptorToSecurityDescriptorW`
        // and the `Drop` impl that calls `LocalFree`.
        SecurityDescriptor::from_sddl(DACL_ONLY_SDDL).unwrap();
    }

    #[test]
    fn parse_conditional_package_sddl_does_not_crash() {
        // The Firezone GUI pipe DACL combines a `S-1-15-2-...` package SID
        // and a per-user `Member_of` predicate. Both are revision-2 SDDL
        // features; the test guards against future `windows` crate or
        // OS-side regressions removing support for them.
        SecurityDescriptor::from_sddl(CONDITIONAL_PACKAGE_SDDL).unwrap();
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

    #[test]
    fn current_user_sid_string_has_user_prefix() {
        // Domain / local accounts both fall under `S-1-5-21-`; the test
        // runner won't be one of the well-known SIDs that share the
        // `S-1-5-` prefix without a `-21-` subauthority (e.g. SYSTEM
        // is `S-1-5-18`). Asserting the longer prefix catches the case
        // where `ConvertSidToStringSidW` returns a non-user SID.
        let sid = current_user_sid_string().unwrap();
        assert!(
            sid.starts_with("S-1-5-21-") || sid.starts_with("S-1-12-"),
            "got SID: {sid}"
        );
    }
}
