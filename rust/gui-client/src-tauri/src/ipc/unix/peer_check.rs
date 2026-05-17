//! Verify that the peer of a connected Unix Domain Socket is one of the
//! binaries on a root-managed allowlist.
//!
//! Linux 6.5+ exposes `SO_PEERPIDFD` on `AF_UNIX` sockets which yields a
//! `pidfd` pinned to a specific process incarnation. Combined with the
//! `/proc/<pid>/exe` symlink and a canonicalised path allowlist, the daemon
//! can refuse calls from any process whose binary is not a Firezone-published
//! binary, even processes running as the same UID.
//!
//! On kernels (or platforms) lacking `SO_PEERPIDFD`, `verify_peer` returns
//! `PeerRejected::Unverifiable`; the caller decides what to do (production
//! today accepts the connection and logs that enforcement is unavailable).

use std::io;
use std::path::{Path, PathBuf};

#[cfg(target_os = "linux")]
#[path = "peer_check/linux.rs"]
mod linux;
#[cfg(target_os = "macos")]
#[path = "peer_check/macos.rs"]
mod macos;

#[cfg(target_os = "linux")]
use linux as imp;
#[cfg(target_os = "macos")]
use macos as imp;

pub use imp::verify_peer;

#[derive(Debug, Default)]
pub struct Allowlist {
    paths: Vec<PathBuf>,
}

impl Allowlist {
    /// Load the platform-appropriate allowlist. On Linux this reads
    /// `/etc/firezone/allowed-clients.conf`; on macOS it returns an empty
    /// allowlist because the Rust path is only used by tests there.
    pub fn load_default() -> Self {
        imp::load_default()
    }

    pub fn contains(&self, exe: &Path) -> bool {
        self.paths.iter().any(|allowed| allowed == exe)
    }

    pub(super) fn with_paths(paths: Vec<PathBuf>) -> Self {
        Self { paths }
    }

    #[cfg(test)]
    pub fn from_paths(paths: Vec<PathBuf>) -> Self {
        Self::with_paths(paths)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PeerRejected {
    /// The kernel (or platform) does not support `SO_PEERPIDFD`, so the
    /// daemon cannot identify the peer's executable. Not a verification
    /// failure — the caller decides whether to accept anyway.
    #[error("Peer binary cannot be verified on this kernel/platform")]
    Unverifiable,
    #[error("Couldn't read peer's executable: {0}")]
    ExeUnreadable(#[source] io::Error),
    #[error("Peer's executable has been deleted: {0}")]
    ExeDeleted(PathBuf),
    #[error("Peer's executable `{}` is not on the allowlist", exe.display())]
    NotAllowlisted { exe: PathBuf },
}

impl PeerRejected {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::Unverifiable => "unverifiable",
            Self::ExeUnreadable(_) => "exe_unreadable",
            Self::ExeDeleted(_) => "exe_deleted",
            Self::NotAllowlisted { .. } => "not_allowlisted",
        }
    }

    pub fn exe(&self) -> Option<&Path> {
        match self {
            Self::Unverifiable | Self::ExeUnreadable(_) => None,
            Self::ExeDeleted(path) | Self::NotAllowlisted { exe: path } => Some(path),
        }
    }
}
