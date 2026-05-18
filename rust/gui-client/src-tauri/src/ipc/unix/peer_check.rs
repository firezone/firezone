//! Verify that the peer of a connected Unix Domain Socket is a Firezone
//! GUI binary installed at the canonical location.
//!
//! Linux 6.5+ exposes `SO_PEERPIDFD` on `AF_UNIX` sockets which yields a
//! `pidfd` pinned to a specific process incarnation. We resolve the peer's
//! `/proc/<pid>/exe` symlink against a compile-time path
//! (`/usr/bin/firezone-client-gui`) so even processes running as the same
//! UID as the GUI cannot impersonate it.
//!
//! On kernels (or platforms) lacking `SO_PEERPIDFD`, `verify` returns
//! `PeerRejected::Unverifiable`; the caller decides what to do (production
//! today accepts the connection and logs that enforcement is unavailable).

// macOS uses the Swift extension in production; the Rust path is test-only
// and `verify` always returns `Unverifiable`, so the non-Unverifiable
// variants and the `AllowedPeer::exe` field are never read there.
#![cfg_attr(target_os = "macos", allow(dead_code))]

use std::io;
use std::path::{Path, PathBuf};

#[cfg(target_os = "linux")]
#[path = "peer_check/linux.rs"]
mod linux;
#[cfg(target_os = "macos")]
#[path = "peer_check/macos.rs"]
mod macos;

/// The single binary the daemon is willing to accept as a peer.
#[derive(Debug)]
pub struct AllowedPeer {
    exe: PathBuf,
}

impl AllowedPeer {
    pub fn new(exe: PathBuf) -> Self {
        Self { exe }
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
    #[error("Peer's executable `{}` is not the expected GUI binary", exe.display())]
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
