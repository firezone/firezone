// Stub module: `verify` always accepts.
#![allow(dead_code, clippy::unused_self, clippy::unnecessary_wraps)]

use anyhow::Result;
use tokio::net::UnixStream;

/// Stub for macOS where production uses the Swift network extension and
/// the Rust path is exercised only by controller tests. `verify` is a
/// no-op that always accepts.
#[derive(Debug)]
pub struct AllowedPeer;

impl AllowedPeer {
    pub fn stub() -> Self {
        Self
    }

    pub fn verify(&self, stream: UnixStream) -> Result<UnixStream> {
        Ok(stream)
    }
}
