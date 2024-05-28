use anyhow::{Context as _, Result};
use firezone_headless_client::platform::sock_path;
use tokio::net::UnixStream;

/// A type alias to abstract over the Windows and Unix IPC primitives
pub(crate) type IpcStream = UnixStream;

/// Connect to the IPC service
pub(crate) async fn connect_to_service() -> Result<IpcStream> {
    let path = sock_path();
    let stream = UnixStream::connect(&path).await.with_context(|| {
        format!(
            "Couldn't connect to Unix domain socket at `{}`",
            path.display()
        )
    })?;
    Ok(stream)
}
