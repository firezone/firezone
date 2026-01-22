use super::{NotFound, SocketId};
use anyhow::{Context as _, Result, bail};
use bin_shared::BUNDLE_ID;
use std::{ffi::c_void, io::ErrorKind, os::windows::io::AsRawHandle, time::Duration};
use tokio::net::windows::named_pipe;
use windows::Win32::{
    Foundation::HANDLE,
    Security as WinSec,
    System::Pipes::{GetNamedPipeClientProcessId, GetNamedPipeServerProcessId},
};

pub(crate) struct Server {
    pipe_path: String,
}

/// Alias for the client's half of a platform-specific IPC stream
pub type ClientStream = named_pipe::NamedPipeClient;

/// Alias for the server's half of a platform-specific IPC stream
pub(crate) type ServerStream = named_pipe::NamedPipeServer;

/// Connect to an IPC socket.
///
/// This is async on Linux
#[expect(clippy::unused_async)]
#[expect(clippy::wildcard_enum_match_arm)]
pub(crate) async fn connect_to_socket(id: SocketId) -> Result<ClientStream> {
    let path = ipc_path(id);
    let stream = named_pipe::ClientOptions::new()
        .open(&path)
        .map_err(|error| match error.kind() {
            ErrorKind::NotFound => anyhow::Error::new(NotFound(path)),
            _ => anyhow::Error::new(error),
        })
        .context("Couldn't connect to named pipe")?;
    let handle = HANDLE(stream.as_raw_handle());
    let mut server_pid: u32 = 0;
    // SAFETY: Windows doesn't store this pointer or handle, and we just got the handle
    // from Tokio, so it should be valid.
    unsafe { GetNamedPipeServerProcessId(handle, &mut server_pid) }
        .context("Couldn't get PID of named pipe server")?;

    tracing::debug!(?server_pid, "Made IPC connection");
    Ok(stream)
}

impl Server {
    /// Platform-specific setup
    #[expect(clippy::unnecessary_wraps, reason = "Linux impl is fallible")]
    pub(crate) fn new(id: SocketId) -> Result<Self> {
        let pipe_path = ipc_path(id);
        Ok(Self { pipe_path })
    }

    // `&mut self` needed to match the Linux signature
    pub(crate) async fn next_client(&mut self) -> Result<ServerStream> {
        // Fixes #5143. In the Tunnel service, if we close the pipe and immediately re-open
        // it, Tokio may not get a chance to clean up the pipe. Yielding seems to fix
        // this in tests, but `yield_now` doesn't make any such guarantees, so
        // we also do a loop.
        tokio::task::yield_now().await;

        let server = self
            .bind_to_pipe()
            .await
            .context("Couldn't bind to named pipe")?;
        // Note that Tokio has no `poll_connect`
        server
            .connect()
            .await
            .context("Couldn't accept IPC connection from GUI")?;
        let handle = HANDLE(server.as_raw_handle());
        let mut client_pid: u32 = 0;
        // SAFETY: Windows doesn't store this pointer or handle, and we just got the handle
        // from Tokio, so it should be valid.
        unsafe { GetNamedPipeClientProcessId(handle, &mut client_pid) }
            .context("Couldn't get PID of named pipe client")?;
        tracing::debug!(?client_pid, "Accepted IPC connection");
        Ok(server)
    }

    async fn bind_to_pipe(&self) -> Result<ServerStream> {
        const NUM_ITERS: usize = 10;
        // This loop is defense-in-depth. The `yield_now` in `next_client` is enough
        // to fix #5143, but Tokio doesn't guarantee any behavior when yielding, so
        // the loop will catch it even if yielding doesn't.
        for i in 0..NUM_ITERS {
            match create_pipe_server(&self.pipe_path) {
                Ok(server) => return Ok(server),
                Err(PipeError::AccessDenied) => {
                    tracing::debug!("PipeError::AccessDenied, sleeping... (loop {i})");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
                Err(error) => Err(error)?,
            }
        }
        bail!("Tried {NUM_ITERS} times to bind the pipe and failed");
    }
}

#[derive(Debug, thiserror::Error)]
enum PipeError {
    #[error("Access denied - Is another process using this pipe path?")]
    AccessDenied,
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

fn create_pipe_server(pipe_path: &str) -> Result<named_pipe::NamedPipeServer, PipeError> {
    let mut server_options = named_pipe::ServerOptions::new();
    server_options.first_pipe_instance(true);

    // This will allow non-admin clients to connect to us even though we're running with privilege
    let mut sd = WinSec::SECURITY_DESCRIPTOR::default();
    let psd = WinSec::PSECURITY_DESCRIPTOR(&mut sd as *mut _ as *mut c_void);
    // SAFETY: Unsafe needed to call Win32 API. There shouldn't be any threading or lifetime problems, because we only pass pointers to our local vars to Win32, and Win32 shouldn't sae them anywhere.
    unsafe {
        // ChatGPT pointed me to these functions
        WinSec::InitializeSecurityDescriptor(
            psd,
            windows::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION,
        )
        .context("InitializeSecurityDescriptor failed")?;
        WinSec::SetSecurityDescriptorDacl(psd, true, None, false)
            .context("SetSecurityDescriptorDacl failed")?;
    }

    let mut sa = WinSec::SECURITY_ATTRIBUTES {
        nLength: 0,
        lpSecurityDescriptor: psd.0,
        bInheritHandle: false.into(),
    };
    sa.nLength = std::mem::size_of_val(&sa)
        .try_into()
        .context("Size of SECURITY_ATTRIBUTES struct is not right")?;

    let sa_ptr = &mut sa as *mut _ as *mut c_void;
    // SAFETY: Unsafe needed to call Win32 API. We only pass pointers to local vars, and Win32 shouldn't store them, so there shouldn't be any threading of lifetime problems.
    match unsafe { server_options.create_with_security_attributes_raw(pipe_path, sa_ptr) } {
        Ok(x) => Ok(x),
        Err(err) => {
            if err.kind() == std::io::ErrorKind::PermissionDenied {
                Err(PipeError::AccessDenied)
            } else {
                Err(anyhow::Error::from(err).into())
            }
        }
    }
}

/// Named pipe for an IPC connection
fn ipc_path(id: SocketId) -> String {
    let name = match id {
        SocketId::Tunnel => format!("{BUNDLE_ID}_tunnel.ipc"),
        SocketId::Gui => format!("{BUNDLE_ID}_gui.ipc"),
        #[cfg(test)]
        SocketId::Test(id) => format!("{BUNDLE_ID}_test_{id}.ipc"),
    };
    named_pipe_path(&name)
}

/// Returns a valid name for a Windows named pipe
///
/// # Arguments
///
/// * `id` - BUNDLE_ID, e.g. `dev.firezone.client`
///
/// Public because the GUI Client reuses this for deep links. Eventually that code
/// will be de-duped into this code.
pub fn named_pipe_path(id: &str) -> String {
    format!(r"\\.\pipe\{id}")
}

#[cfg(test)]
mod tests {
    use super::{Server, SocketId};
    use anyhow::Context as _;
    use futures::StreamExt;

    #[test]
    fn named_pipe_path() {
        assert_eq!(
            super::named_pipe_path("dev.firezone.client"),
            r"\\.\pipe\dev.firezone.client"
        );
    }

    #[test]
    fn ipc_path() {
        assert!(super::ipc_path(SocketId::Tunnel).starts_with(r"\\.\pipe\"));
    }

    #[tokio::test]
    async fn single_instance() -> anyhow::Result<()> {
        let _guard = logging::test("trace");
        const ID: SocketId = SocketId::Test(0x1A6FE1F6);
        let mut server_1 = Server::new(ID)?;
        let pipe_path = server_1.pipe_path.clone();

        tokio::spawn(async move {
            let (mut rx, _tx) = server_1.next_client_split::<(), ()>().await?;
            rx.next().await;
            Ok::<_, anyhow::Error>(())
        });

        let (_rx, _tx) =
            crate::ipc::connect::<(), ()>(ID, crate::ipc::ConnectOptions::default()).await?;

        match super::create_pipe_server(&pipe_path) {
            Err(super::PipeError::AccessDenied) => {}
            Err(error) => {
                Err(error).context("Expected `PipeError::AccessDenied` but got another error")?
            }
            Ok(_) => anyhow::bail!("Expected `PipeError::AccessDenied` but got `Ok`"),
        }
        Ok(())
    }
}
