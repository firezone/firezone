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

use crate::{SecurityDescriptor, sid_to_string};
use anyhow::{Context as _, Result};
use std::{borrow::Cow, fmt};
use windows::{
    Win32::{
        Foundation::{HLOCAL, LocalFree},
        Security::Isolation::DeriveAppContainerSidFromAppContainerName,
    },
    core::{HSTRING, PCWSTR},
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

    /// SID for the given MSIX Package Family Name (`Name_publisherId`
    /// — the deterministic Crockford-base32 hash Windows derives from
    /// the cert Subject DN). Use this in pipe DACLs to pin access to
    /// processes the kernel activated from that package: the kernel
    /// attaches this SID to those processes' tokens, so an ACE
    /// granting access to it is effectively a cert-rooted access
    /// check (Windows enforces that the package's `Publisher` match
    /// the signing cert's Subject DN at registration time).
    ///
    /// The PFN is just a string; the caller owns picking the right
    /// one (typically a `pub const` next to the AppxManifest it
    /// originates from). This function doesn't verify the package is
    /// registered — it just runs the SID-derivation hash — so the
    /// returned SID is safe to bake into a DACL even when the
    /// package isn't yet provisioned (the ACE would simply match no
    /// process).
    pub fn from_package_family_name(pfn: &str) -> Result<Self> {
        let sid = derive_package_sid(pfn)?;
        Ok(Self(Cow::Owned(sid)))
    }

    /// Wraps a pre-computed SID string (typically a `pub const`
    /// emitted from `build.rs`). The caller owns ensuring the input
    /// is a well-formed SDDL SID like `S-1-5-32-544` or
    /// `S-1-15-2-…`; we just hand it through to the SDDL builder
    /// unchanged. Useful for baking AppContainer / Package SIDs at
    /// compile time and skipping the runtime kernel-API call.
    pub const fn from_sid_string(sid: &'static str) -> Self {
        Self(Cow::Borrowed(sid))
    }

    /// The string Windows expects for this trustee inside an SDDL
    /// ACE — `"SY"` for an alias, `"S-1-…"` for a SID.
    pub fn as_sddl_str(&self) -> &str {
        &self.0
    }
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

    /// `from_package_family_name` is a deterministic SID hash —
    /// always succeeds for any non-empty PFN, regardless of whether
    /// the package is registered on this machine. The exact SID is
    /// documented by Microsoft's
    /// [`8wekyb3d8bbwe`](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/appxmanifestschema/element-identity)
    /// example for `Microsoft.WindowsCalculator`.
    #[test]
    fn from_package_family_name_returns_sid() {
        let trustee =
            Trustee::from_package_family_name("Microsoft.WindowsCalculator_8wekyb3d8bbwe").unwrap();
        assert!(
            trustee.as_sddl_str().starts_with("S-1-15-2-"),
            "expected S-1-15-2-… SID, got `{}`",
            trustee.as_sddl_str()
        );
    }

    /// `from_sid_string` is an infallible wrapper -- the input flows
    /// straight to the SDDL builder. Test that it round-trips a
    /// build-time-baked SID through `PipeDacl::Display` unchanged.
    #[test]
    fn from_sid_string_round_trips_through_dacl() {
        const SID: &str = "S-1-15-2-1-2-3-4-5-6-7-8";
        let dacl = PipeDacl::new()
            .allow(FileRights::ReadWrite, Trustee::from_sid_string(SID))
            .to_string();
        assert_eq!(dacl, format!("D:P(A;;FRFW;;;{SID})"));
    }
}
