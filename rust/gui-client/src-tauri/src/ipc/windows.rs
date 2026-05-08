use super::{NotFound, SocketId};
use anyhow::{Context as _, Result, bail};
use std::{ffi::c_void, io::ErrorKind, os::windows::io::AsRawHandle, time::Duration};
use tokio::net::windows::named_pipe;
use windows::Win32::{
    Foundation::HANDLE,
    Security::SECURITY_ATTRIBUTES,
    System::Pipes::{GetNamedPipeClientProcessId, GetNamedPipeServerProcessId},
};
use windows_security::SecurityDescriptor;

/// SDDL applied to every Firezone named pipe.
///
/// The Tunnel pipe is created by the LocalSystem-privileged tunnel service and
/// must be reachable by the user-mode GUI; the GUI pipe is created by the GUI
/// itself but uses the same DACL for uniformity.
///
/// - `D:P` — protected DACL (don't inherit ACEs).
/// - `(A;;FA;;;SY)` — Full Access for `LocalSystem` (the tunnel service).
/// - `(A;;FA;;;BA)` — Full Access for `BUILTIN\Administrators`.
/// - `(A;;FRFW;;;BU)` — `FILE_GENERIC_READ | FILE_GENERIC_WRITE | SYNCHRONIZE`
///   for `BUILTIN\Users`. This is the alias the non-admin GUI runs under and
///   excludes `NETWORK SERVICE`, `LOCAL SERVICE`, `ANONYMOUS LOGON`, IIS app
///   pool identities, and arbitrary new service accounts (unlike `AU`).
const PIPE_SDDL: &str = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFW;;;BU)";

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
        // Defense-in-depth around #5143: when an IPC handler panics or otherwise
        // tears down the pipe and we immediately re-bind, Windows can briefly
        // return `AccessDenied` because the previous instance hasn't been fully
        // released yet. Polling on a short cadence is plenty — this typically
        // clears in tens of milliseconds. The previous 1s sleep was long enough
        // to make the `panic_inside_handler_doesnt_interrupt_service` unit test
        // race the test-side reconnect window on the `windows-2025` CI runner.
        const NUM_ITERS: usize = 100;
        const RETRY_INTERVAL: Duration = Duration::from_millis(100);
        for i in 0..NUM_ITERS {
            match create_pipe_server(&self.pipe_path) {
                Ok(server) => return Ok(server),
                Err(PipeError::AccessDenied) => {
                    tracing::debug!("PipeError::AccessDenied, sleeping... (loop {i})");
                    tokio::time::sleep(RETRY_INTERVAL).await;
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

    // Build a `SECURITY_ATTRIBUTES` that grants the non-admin GUI (running as
    // `BUILTIN\Users`) read/write access to the pipe while keeping it shut to
    // `NETWORK SERVICE`, anonymous logons, and other unintended principals.
    let sd = SecurityDescriptor::from_sddl(PIPE_SDDL).map_err(PipeError::Other)?;
    let mut sa = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: sd.as_raw().0,
        bInheritHandle: false.into(),
    };

    let sa_ptr = &mut sa as *mut _ as *mut c_void;
    // SAFETY: `sa_ptr` is a valid pointer to a fully-initialised
    // `SECURITY_ATTRIBUTES`. The kernel copies the security descriptor during
    // `CreateNamedPipeW`, so `sd` may be dropped after the call returns.
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
        SocketId::Tunnel => format!("{}_tunnel.ipc", crate::BUNDLE_ID),
        SocketId::Gui => format!("{}_gui.ipc", crate::BUNDLE_ID),
        #[cfg(test)]
        SocketId::Test(id) => format!("{}_test_{id}.ipc", crate::BUNDLE_ID),
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
