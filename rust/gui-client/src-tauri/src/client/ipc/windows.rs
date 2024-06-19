use anyhow::{Context as _, Result};
use firezone_headless_client::ipc;
use std::os::windows::io::AsRawHandle;
use tokio::net::windows::named_pipe;
use windows::Win32::{Foundation::HANDLE, System::Pipes::GetNamedPipeServerProcessId};

/// A type alias to abstract over the Windows and Unix IPC primitives
pub(crate) type IpcStream = named_pipe::NamedPipeClient;

/// Connect to the IPC service
///
/// This is async on Linux
#[allow(clippy::unused_async)]
pub(crate) async fn connect_to_service() -> Result<IpcStream> {
    let path = ipc::platform::pipe_path(ipc::ServiceId::Prod);
    let stream = named_pipe::ClientOptions::new()
        .open(path)
        .with_context(|| "Couldn't connect to named pipe server at `{path}`")?;
    let handle = HANDLE(stream.as_raw_handle() as isize);
    let mut server_pid: u32 = 0;
    // SAFETY: Windows doesn't store this pointer or handle, and we just got the handle
    // from Tokio, so it should be valid.
    unsafe { GetNamedPipeServerProcessId(handle, &mut server_pid) }
        .context("Couldn't get PID of named pipe server")?;
    tracing::info!(?server_pid, "Made IPC connection");
    Ok(stream)
}
