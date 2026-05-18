use std::path::PathBuf;

use tokio::net::UnixStream;

use super::{Allowlist, PeerRejected};

impl Allowlist {
    pub fn load_default() -> Self {
        Alowlist::default()
    }
}

pub fn verify_peer(_stream: &UnixStream, _allowlist: &Allowlist) -> Result<PathBuf, PeerRejected> {
    Err(PeerRejected::Unverifiable)
}
