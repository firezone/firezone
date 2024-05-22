use anyhow::{Context as _, Result};
use tokio::net::windows::named_pipe;

/// A type alias to abstract over the Windows and Unix IPC primitives
pub(crate) type IpcStream = named_pipe::NamedPipeClient;

/// Connect to the IPC service
///
/// This is async on Linux
#[allow(clippy::unused_async)]
pub(crate) async fn connect_to_service() -> Result<IpcStream> {
    let stream = named_pipe::ClientOptions::new()
        .open(firezone_headless_client::windows::pipe_path())
        .context("Couldn't connect to named pipe server")?;
    Ok(stream)
}
