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
use anyhow::Result;
use std::fmt;

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

/// A trustee — the SID alias an ACE refers to. Currently only the
/// three two-letter aliases Firezone uses are exposed.
#[derive(Debug, Clone, Copy)]
pub struct Trustee(&'static str);

impl Trustee {
    /// `SY` — the LocalSystem account.
    pub fn local_system() -> Self {
        Self("SY")
    }

    /// `BA` — the `BUILTIN\Administrators` group.
    pub fn builtin_administrators() -> Self {
        Self("BA")
    }

    /// `BU` — the `BUILTIN\Users` group.
    pub fn builtin_users() -> Self {
        Self("BU")
    }

    /// The string Windows expects for this trustee inside an SDDL
    /// ACE, e.g. `"SY"`.
    pub fn as_sddl_str(&self) -> &'static str {
        self.0
    }
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
}
