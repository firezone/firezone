use anyhow::{Context as _, Result};
use firezone_headless_client::platform::sock_path;
use tokio::net::UnixStream;

/// A type alias to abstract over the Windows and Unix IPC primitives
pub(crate) type IpcStream = UnixStream;

/// Connect to the IPC service
pub(crate) async fn connect_to_service() -> Result<IpcStream> {
    let stream = UnixStream::connect(sock_path())
        .await
        .context("Couldn't connect to Unix domain socket")?;
    Ok(stream)
}
