use std::path::PathBuf;

use tokio::net::UnixStream;

use super::{Allowlist, PeerRejected};

pub fn load_default() -> Allowlist {
    Allowlist::default()
}

pub fn verify_peer(_stream: &UnixStream, _allowlist: &Allowlist) -> Result<PathBuf, PeerRejected> {
    Err(PeerRejected::Unverifiable)
}
