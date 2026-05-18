use std::path::PathBuf;

use tokio::net::UnixStream;

use super::{Allowlist, PeerRejected};

impl Allowlist {
    pub fn load_default() -> Self {
        Allowlist::default()
    }

    pub fn verify_peer(&self, _stream: &UnixStream) -> Result<PathBuf, PeerRejected> {
        Err(PeerRejected::Unverifiable)
    }
}
