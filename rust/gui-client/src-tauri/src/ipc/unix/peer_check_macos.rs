//! Stub of `peer_check` for macOS. The production macOS client uses the
//! Swift network extension; this Rust path is only used by controller
//! tests, which the caller treats as `Unverifiable` (accept without
//! binary identity check).

use std::io;
use std::path::{Path, PathBuf};

use tokio::net::UnixStream;

#[derive(Debug, Default)]
pub struct Allowlist;

impl Allowlist {
    pub fn load_default() -> Self {
        Self
    }
}

/// Mirrors the Linux variants so `unix.rs` can match the same arms on both
/// targets. macOS only ever constructs `Unverifiable`.
#[derive(Debug, thiserror::Error)]
#[allow(dead_code)]
pub enum PeerRejected {
    #[error("Peer binary cannot be verified on this platform")]
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

pub fn verify_peer(_stream: &UnixStream, _allowlist: &Allowlist) -> Result<PathBuf, PeerRejected> {
    Err(PeerRejected::Unverifiable)
}
