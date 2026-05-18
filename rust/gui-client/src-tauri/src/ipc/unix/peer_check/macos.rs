use std::path::PathBuf;

use tokio::net::UnixStream;

use super::{AllowedPeer, PeerRejected};

impl AllowedPeer {
    pub fn load_default() -> Self {
        Self::new(PathBuf::new())
    }

    pub fn verify(&self, _stream: &UnixStream) -> Result<PathBuf, PeerRejected> {
        Err(PeerRejected::Unverifiable)
    }
}
