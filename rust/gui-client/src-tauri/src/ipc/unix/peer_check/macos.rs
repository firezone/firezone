// Stub module: `verify` always accepts, so no `PeerRejected` variants are
// ever constructed and the per-variant methods are dead on this target.
#![allow(dead_code, clippy::unused_self)]

use tokio::net::UnixStream;

use super::PeerRejected;

/// Stub for macOS where production uses the Swift network extension and
/// the Rust path is exercised only by controller tests. `verify` is a
/// no-op that always accepts.
#[derive(Debug)]
pub struct AllowedPeer;

impl AllowedPeer {
    pub fn load_default() -> Self {
        Self
    }

    pub fn verify(&self, stream: UnixStream) -> Result<UnixStream, PeerRejected> {
        Ok(stream)
    }
}
