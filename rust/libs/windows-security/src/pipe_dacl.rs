//! Type-safe builder for the SDDL flavours Firezone applies to its
//! named pipes.
//!
//! The full SDDL grammar (MS-DTYP §2.5.1) is sprawling — ACE types,
//! flag sets, generic vs specific access masks, four kinds of
//! conditional expression, on and on. This module deliberately
//! exposes only the small dialect our pipe DACLs need: an optional
//! `O:<owner>` prefix, a protected DACL, plain-allow ACEs, and the
//! file-access rights `FA` / `FRFW`. Everything else is
//! unrepresentable, so a typo or shape error can't make it to
//! runtime.

use crate::SecurityDescriptor;
use anyhow::{Context as _, Result, anyhow, ensure};
use std::{borrow::Cow, fmt, ptr};
use windows::{
    Win32::{
        Foundation::{
            APPMODEL_ERROR_NO_PACKAGE, ERROR_INSUFFICIENT_BUFFER, HLOCAL, LocalFree, WIN32_ERROR,
        },
        Security::{
            Authorization::ConvertSidToStringSidW,
            Isolation::DeriveAppContainerSidFromAppContainerName,
            PSID,
        },
        Storage::Packaging::Appx::GetCurrentPackageFamilyName,
    },
    core::{HSTRING, PCWSTR, PWSTR},
};

/// File-system rights expressible in a Firezone pipe ACE. Encoded
/// SDDL strings: `FA` (full access) and `FRFW` (file generic read +
/// file generic write).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileRights {
    /// `FA` — full access.
    FullAccess,
    /// `FRFW` — generic read + generic write.
    ReadWrite,
}

impl FileRights {
    fn as_sddl(self) -> &'static str {
        match self {
            FileRights::FullAccess => "FA",
            FileRights::ReadWrite => "FRFW",
        }
    }
}

/// A trustee — either a fixed two-letter SDDL alias (`SY`, `BA`,
/// `BU`) or a process-derived SID string like `S-1-15-2-…`. There is
/// no public string-based constructor; the SID variants come from
/// Windows APIs that read kernel state.
#[derive(Debug, Clone)]
pub struct Trustee(Cow<'static, str>);

impl Trustee {
    /// `SY` — the LocalSystem account.
    pub const fn local_system() -> Self {
        Self(Cow::Borrowed("SY"))
    }

    /// `BA` — the `BUILTIN\Administrators` group.
    pub const fn builtin_administrators() -> Self {
        Self(Cow::Borrowed("BA"))
    }

    /// `BU` — the `BUILTIN\Users` group.
    pub const fn builtin_users() -> Self {
        Self(Cow::Borrowed("BU"))
    }

    /// SID for the current process's MSIX package identity, computed
    /// by Windows from the kernel-attached Package Family Name.
    ///
    /// Use this in pipe DACLs to pin access to processes launched
    /// from the Firezone MSIX package: the kernel attaches this SID
    /// to those processes' tokens, so an ACE granting access to it
    /// is effectively a cert-rooted access check (the package SID is
    /// a hash of `Name + Publisher`, and Windows enforces that
    /// `Publisher` match the signing cert's Subject DN).
    ///
    /// Defense-in-depth: the PFN must start with
    /// `Firezone.Client.GUI_`, otherwise the caller is somehow
    /// executing inside someone else's package, and we'd rather fail
    /// than pin a foreign SID into our DACL.
    ///
    /// Returns an error in contexts without package identity (the
    /// MSI install canary covers the supported-Windows positive
    /// case; pre-21H2 / hardened images fall through here so callers
    /// can choose a fallback).
    pub fn current_package() -> Result<Self> {
        let pfn = current_package_family_name()?;
        ensure!(
            pfn.starts_with("Firezone.Client.GUI_"),
            "current package family name `{pfn}` is not Firezone's"
        );
        let sid = derive_package_sid(&pfn)?;
        Ok(Self(Cow::Owned(sid)))
    }

    /// The string Windows expects for this trustee inside an SDDL
    /// ACE — `"SY"` for an alias, `"S-1-…"` for a SID.
    pub fn as_sddl_str(&self) -> &str {
        &self.0
    }
}

/// Reads the Package Family Name the kernel has attached to the
/// current process. Returns `Err` (with a "no package identity"
/// hint) when the process has no package identity.
fn current_package_family_name() -> Result<String> {
    // First call probes the required buffer size; the documented
    // pattern is to pass a 0 length and rely on the returned size.
    let mut len: u32 = 0;
    // SAFETY: NULL buffer + 0 length is the documented sizing call;
    // Windows writes only to `len`.
    let rc: WIN32_ERROR = unsafe { GetCurrentPackageFamilyName(&mut len, None) };
    if rc == APPMODEL_ERROR_NO_PACKAGE {
        return Err(anyhow!(
            "current process has no MSIX package identity (rc={:#x})",
            rc.0
        ));
    }
    // Per docs, "first call" returns `ERROR_INSUFFICIENT_BUFFER` (122)
    // when there *is* a name but the buffer was too small. Anything
    // else here is unexpected.
    ensure!(
        rc == ERROR_INSUFFICIENT_BUFFER,
        "GetCurrentPackageFamilyName sizing call returned unexpected rc={:#x}",
        rc.0
    );

    let mut buf = vec![0u16; len as usize];
    // SAFETY: `buf` has `len` u16 capacity; Windows writes up to that.
    let rc: WIN32_ERROR =
        unsafe { GetCurrentPackageFamilyName(&mut len, Some(PWSTR(buf.as_mut_ptr()))) };
    ensure!(
        rc.0 == 0,
        "GetCurrentPackageFamilyName retrieval call returned rc={:#x}",
        rc.0
    );

    // `len` includes the null terminator; trim it before converting.
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16(&buf[..end]).context("GetCurrentPackageFamilyName returned invalid UTF-16")
}

/// Wraps `DeriveAppContainerSidFromAppContainerName` and
/// `ConvertSidToStringSidW` to turn a Package Family Name into the
/// SDDL string form (`S-1-15-2-…`) Windows uses for that package's
/// AppContainer SID.
fn derive_package_sid(pfn: &str) -> Result<String> {
    let pfn_wide = HSTRING::from(pfn);
    // SAFETY: `pfn_wide` is null-terminated by HSTRING. On success Windows
    // allocates a SID we must release with `LocalFree`.
    let sid = unsafe { DeriveAppContainerSidFromAppContainerName(PCWSTR(pfn_wide.as_ptr())) }
        .context("DeriveAppContainerSidFromAppContainerName failed")?;

    let sid_string = sid_to_string(sid);

    // SAFETY: `sid` came from `DeriveAppContainerSidFromAppContainerName`
    // (LocalAlloc-allocated). Free it now; the SDDL string is on the
    // Rust heap and survives.
    unsafe {
        let _ = LocalFree(Some(HLOCAL(sid.0)));
    }

    sid_string
}

fn sid_to_string(sid: PSID) -> Result<String> {
    let mut out = PWSTR(ptr::null_mut());
    // SAFETY: `sid` is a valid SID from a Windows API; `&mut out` is a valid
    // out-pointer. On success Windows allocates a wide string with
    // `LocalAlloc`, which we release with `LocalFree`.
    unsafe { ConvertSidToStringSidW(sid, &mut out) }.context("ConvertSidToStringSidW failed")?;
    ensure!(!out.0.is_null(), "ConvertSidToStringSidW returned NULL");

    // SAFETY: `out.0` points to a null-terminated wide string allocated by
    // Windows; we copy it into an owned `String` before freeing.
    let s = unsafe { out.to_string() }
        .context("ConvertSidToStringSidW returned invalid UTF-16")?;

    // SAFETY: `out` is the LocalAlloc-allocated buffer; release it.
    unsafe {
        let _ = LocalFree(Some(HLOCAL(out.0 as *mut _)));
    }

    Ok(s)
}

/// A security descriptor for a Firezone named pipe: an optional
/// `O:<owner>` clause followed by a protected DACL containing only
/// plain-allow (`A`) ACEs.
#[derive(Debug, Default)]
pub struct PipeDacl {
    owner: Option<Trustee>,
    aces: Vec<PipeAce>,
}

#[derive(Debug)]
struct PipeAce {
    rights: FileRights,
    trustee: Trustee,
}

impl PipeDacl {
    pub fn new() -> Self {
        Self::default()
    }

    /// Pin the security descriptor's `Owner` to `trustee`. Renders as
    /// an `O:<trustee>` prefix on the SDDL.
    pub fn owner(mut self, trustee: Trustee) -> Self {
        self.owner = Some(trustee);
        self
    }

    /// Plain `(A;;<rights>;;;<trustee>)` ACE.
    pub fn allow(mut self, rights: FileRights, trustee: Trustee) -> Self {
        self.aces.push(PipeAce { rights, trustee });
        self
    }

    /// Parse the rendered SDDL into a [`SecurityDescriptor`].
    ///
    /// The SDDL is syntactically valid by construction — every field
    /// comes from a typed primitive — so any error from this call is
    /// either a kernel-level rejection or an out-of-memory condition.
    pub fn build(&self) -> Result<SecurityDescriptor> {
        SecurityDescriptor::from_sddl(&self.to_string())
    }
}

/// Renders as `[O:<sid>]D:P(A;;<rights>;;;<trustee>)…`. Useful for
/// tests, `tracing` payloads, and [`PipeDacl::build`].
impl fmt::Display for PipeDacl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(owner) = &self.owner {
            write!(f, "O:{}", owner.as_sddl_str())?;
        }
        f.write_str("D:P")?;
        for ace in &self.aces {
            write!(
                f,
                "(A;;{};;;{})",
                ace.rights.as_sddl(),
                ace.trustee.as_sddl_str(),
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_dacl_renders_protected_only() {
        assert_eq!(PipeDacl::new().to_string(), "D:P");
    }

    #[test]
    fn allow_renders_plain_ace() {
        let s = PipeDacl::new()
            .allow(FileRights::FullAccess, Trustee::local_system())
            .allow(FileRights::ReadWrite, Trustee::builtin_users())
            .to_string();
        assert_eq!(s, "D:P(A;;FA;;;SY)(A;;FRFW;;;BU)");
    }

    #[test]
    fn owner_renders_as_prefix() {
        let s = PipeDacl::new().owner(Trustee::local_system()).to_string();
        assert_eq!(s, "O:SYD:P");
    }

    /// Exact shape Firezone's Tunnel pipe uses.
    #[test]
    fn tunnel_pipe_sddl() {
        let s = PipeDacl::new()
            .owner(Trustee::local_system())
            .allow(FileRights::FullAccess, Trustee::local_system())
            .allow(FileRights::FullAccess, Trustee::builtin_administrators())
            .allow(FileRights::ReadWrite, Trustee::builtin_users())
            .to_string();
        assert_eq!(s, "O:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFW;;;BU)");
    }

    /// Exact shape Firezone's GUI pipe uses (no owner clause).
    #[test]
    fn gui_pipe_sddl() {
        let s = PipeDacl::new()
            .allow(FileRights::FullAccess, Trustee::local_system())
            .allow(FileRights::FullAccess, Trustee::builtin_administrators())
            .allow(FileRights::ReadWrite, Trustee::builtin_users())
            .to_string();
        assert_eq!(s, "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFW;;;BU)");
    }

    /// Round-trip both pipe shapes through `from_sddl` to confirm the
    /// kernel accepts every shape this builder can emit.
    #[test]
    fn round_trips_through_security_descriptor() {
        PipeDacl::new()
            .owner(Trustee::local_system())
            .allow(FileRights::FullAccess, Trustee::local_system())
            .allow(FileRights::FullAccess, Trustee::builtin_administrators())
            .allow(FileRights::ReadWrite, Trustee::builtin_users())
            .build()
            .expect("kernel should accept Tunnel-shape SDDL");

        PipeDacl::new()
            .allow(FileRights::FullAccess, Trustee::local_system())
            .allow(FileRights::FullAccess, Trustee::builtin_administrators())
            .allow(FileRights::ReadWrite, Trustee::builtin_users())
            .build()
            .expect("kernel should accept GUI-shape SDDL");
    }

    /// `current_package` requires a registered Firezone MSIX in the
    /// caller's process token — which CI's `cargo test` doesn't have
    /// (the test binary isn't itself MSIX-activated). Assert only
    /// that the call returns `Err` here; the install canary covers
    /// the positive case end-to-end.
    #[test]
    fn current_package_errors_without_package_identity() {
        let result = Trustee::current_package();
        assert!(
            result.is_err(),
            "expected `Err` outside MSIX, got: {:?}",
            result.map(|t| t.as_sddl_str().to_owned())
        );
    }
}
