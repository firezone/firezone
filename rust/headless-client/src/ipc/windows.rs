use super::ServiceId;
use anyhow::{bail, Context as _, Result};
use connlib_shared::BUNDLE_ID;
use std::{ffi::c_void, os::windows::io::AsRawHandle, time::Duration};
use tokio::net::windows::named_pipe;
use windows::Win32::{
    Foundation::HANDLE, Security as WinSec, System::Pipes::GetNamedPipeClientProcessId,
};

pub(crate) struct Server {
    pipe_path: String,
}

/// Opaque wrapper around platform-specific IPC stream
pub(crate) type Stream = named_pipe::NamedPipeServer;

impl Server {
    /// Platform-specific setup
    ///
    /// This is async on Linux
    #[allow(clippy::unused_async)]
    pub(crate) async fn new(id: ServiceId) -> Result<Self> {
        crate::platform::setup_before_connlib()?;
        let pipe_path = pipe_path(id);
        Ok(Self { pipe_path })
    }

    // `&mut self` needed to match the Linux signature
    pub(crate) async fn next_client(&mut self) -> Result<Stream> {
        // Fixes #5143. In the IPC service, if we close the pipe and immediately re-open
        // it, Tokio may not get a chance to clean up the pipe. Yielding seems to fix
        // this in tests, but `yield_now` doesn't make any such guarantees, so
        // we also do a loop.
        tokio::task::yield_now().await;

        let server = self
            .bind_to_pipe()
            .await
            .context("Couldn't bind to named pipe")?;
        tracing::info!(
            server_pid = std::process::id(),
            "Listening for GUI to connect over IPC..."
        );
        server
            .connect()
            .await
            .context("Couldn't accept IPC connection from GUI")?;
        let handle = HANDLE(server.as_raw_handle() as isize);
        let mut client_pid: u32 = 0;
        // SAFETY: Windows doesn't store this pointer or handle, and we just got the handle
        // from Tokio, so it should be valid.
        unsafe { GetNamedPipeClientProcessId(handle, &mut client_pid) }
            .context("Couldn't get PID of named pipe client")?;
        tracing::info!(?client_pid, "Accepted IPC connection");
        Ok(server)
    }

    async fn bind_to_pipe(&self) -> Result<Stream> {
        const NUM_ITERS: usize = 10;
        // This loop is defense-in-depth. The `yield_now` in `next_client` is enough
        // to fix #5143, but Tokio doesn't guarantee any behavior when yielding, so
        // the loop will catch it even if yielding doesn't.
        for i in 0..NUM_ITERS {
            match create_pipe_server(&self.pipe_path) {
                Ok(server) => return Ok(server),
                Err(PipeError::AccessDenied) => {
                    tracing::warn!("PipeError::AccessDenied, sleeping... (loop {i})");
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
                tracing::warn!(?pipe_path, "Named pipe `PermissionDenied`");
                Err(PipeError::AccessDenied)
            } else {
                Err(anyhow::Error::from(err).into())
            }
        }
    }
}

/// Named pipe for IPC between GUI client and IPC service
pub fn pipe_path(id: ServiceId) -> String {
    let name = match id {
        ServiceId::Prod => format!("{BUNDLE_ID}.ipc_service"),
        ServiceId::Test(id) => format!("{BUNDLE_ID}_test_{id}.ipc_service"),
    };
    named_pipe_path(&name)
}

/// Returns a valid name for a Windows named pipe
///
/// # Arguments
///
/// * `id` - BUNDLE_ID, e.g. `dev.firezone.client`
pub fn named_pipe_path(id: &str) -> String {
    format!(r"\\.\pipe\{}", id)
}

#[cfg(test)]
mod tests {
    #[test]
    fn named_pipe_path() {
        assert_eq!(
            super::named_pipe_path("dev.firezone.client"),
            r"\\.\pipe\dev.firezone.client"
        );
    }

    #[test]
    fn pipe_path() {
        assert!(super::pipe_path(super::ServiceId::Prod).starts_with(r"\\.\pipe\"));
    }
}
