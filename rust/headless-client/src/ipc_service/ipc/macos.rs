use super::ServiceId;
use anyhow::{Result, bail};
use tokio::net::UnixStream;

pub(crate) struct Server {}

/// Alias for the client's half of a platform-specific IPC stream
pub type ClientStream = UnixStream;

/// Alias for the server's half of a platform-specific IPC stream
///
/// On Windows `ClientStream` and `ServerStream` differ
pub(crate) type ServerStream = UnixStream;

/// Connect to the IPC service
#[expect(clippy::wildcard_enum_match_arm)]
pub async fn connect_to_service(_id: ServiceId) -> Result<ClientStream> {
    bail!("not implemented")
}

impl Server {
    /// Platform-specific setup
    pub(crate) async fn new(_id: ServiceId) -> Result<Self> {
        bail!("not implemented")
    }

    pub(crate) async fn next_client(&mut self) -> Result<ServerStream> {
        bail!("not implemented")
    }
}
