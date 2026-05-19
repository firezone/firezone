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
// variants are never constructed there.
#![cfg_attr(target_os = "macos", allow(dead_code))]

use std::io;
use std::path::PathBuf;

#[cfg(target_os = "linux")]
#[path = "peer_check/linux.rs"]
mod linux;
#[cfg(target_os = "macos")]
#[path = "peer_check/macos.rs"]
mod macos;

#[cfg(target_os = "linux")]
pub use linux::AllowedPeer;
#[cfg(target_os = "macos")]
pub use macos::AllowedPeer;

#[derive(Debug, thiserror::Error)]
pub enum PeerRejected {
    #[error("Couldn't read peer's executable: {0}")]
    ExeUnreadable(#[source] io::Error),
    #[error("Peer's executable has been deleted: {0}")]
    ExeDeleted(PathBuf),
    #[error(
        "Peer's executable `{}` does not match the expected GUI binary `{}`",
        exe.display(),
        expected.display()
    )]
    NotAllowlisted { exe: PathBuf, expected: PathBuf },
}
