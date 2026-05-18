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

    #[allow(clippy::unused_self)]
    pub fn verify(&self, stream: UnixStream) -> Result<UnixStream, PeerRejected> {
        Ok(stream)
    }
}
