use super::SocketId;
use anyhow::{Result, bail};
use tokio::net::UnixStream;

pub(crate) struct Server {}

pub type ClientStream = UnixStream;
pub(crate) type ServerStream = UnixStream;

#[expect(
    clippy::unused_async,
    reason = "Signture must match other operating systems"
)]
pub async fn connect_to_socket(_id: SocketId) -> Result<ClientStream> {
    bail!("not implemented")
}

impl Server {
    pub(crate) fn new(_id: SocketId) -> Result<Self> {
        bail!("not implemented")
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub(crate) async fn next_client(&mut self) -> Result<ServerStream> {
        bail!("not implemented")
    }
}
