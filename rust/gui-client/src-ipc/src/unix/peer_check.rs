//! Verify that the peer of a connected Unix Domain Socket is a Firezone
//! GUI binary installed at the canonical location.
//!
//! Linux 6.5+ exposes `SO_PEERPIDFD` on `AF_UNIX` sockets which yields a
//! `pidfd` pinned to a specific process incarnation. We resolve the peer's
//! `/proc/<pid>/exe` symlink against a compile-time path
//! (`/usr/bin/firezone-client-gui`) so even processes running as the same
//! UID as the GUI cannot impersonate it.

#![cfg_attr(target_os = "macos", allow(dead_code))]

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
