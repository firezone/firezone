//! Unix IPC implementation using Unix Domain Sockets.
//!
//! Shared by Linux and macOS. The production macOS client uses the native
//! Swift implementation in `swift/apple/`; this enables running controller
//! tests on macOS.

#[path = "unix/peer_check.rs"]
mod peer_check;

use super::{NotFound, SocketId};
use anyhow::{Context as _, Result};
#[cfg(debug_assertions)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::{io::ErrorKind, os::unix::fs::PermissionsExt, path::PathBuf};
use tokio::net::{UnixListener, UnixStream};

/// Whether to skip verifying the peer's binary on the Tunnel socket.
#[cfg(debug_assertions)]
static SKIP_PEER_VERIFICATION: AtomicBool = AtomicBool::new(false);

/// Set [`SKIP_PEER_VERIFICATION`].
///
/// Call once at process startup, before any `Server::new(SocketId::Tunnel)` or `connect_to_socket`.
#[cfg(debug_assertions)]
pub fn skip_peer_verification() {
    SKIP_PEER_VERIFICATION.store(true, Ordering::Relaxed);
}

pub struct Server {
    listener: UnixListener,
    id: SocketId,
    allowed_peer: peer_check::AllowedPeer,
}

impl Drop for Server {
    fn drop(&mut self) {
        let Ok(path) = ipc_path(self.id) else {
            return;
        };

        if let Err(e) = std::fs::remove_file(&path) {
            tracing::debug!(path = %path.display(), "Failed to delete IPC socket: {e}");
        }
    }
}

/// Alias for the client's half of a platform-specific IPC stream
pub type ClientStream = UnixStream;

/// Alias for the server's half of a platform-specific IPC stream
///
/// On Windows `ClientStream` and `ServerStream` differ
pub(crate) type ServerStream = UnixStream;

/// Connect to the Tunnel service
#[expect(clippy::wildcard_enum_match_arm)]
pub async fn connect_to_socket(id: SocketId) -> Result<ClientStream> {
    let path = ipc_path(id)?;
    let stream = UnixStream::connect(&path)
        .await
        .map_err(|error| match error.kind() {
            ErrorKind::NotFound => anyhow::Error::new(NotFound(path.display().to_string())),
            _ => anyhow::Error::new(error),
        })
        .context("Couldn't connect to Unix domain socket")?;
    let cred = stream
        .peer_cred()
        .context("Couldn't get PID of UDS server")?;
    tracing::debug!(
        uid = cred.uid(),
        gid = cred.gid(),
        pid = cred.pid(),
        "Made an IPC connection"
    );
    Ok(stream)
}

impl Server {
    /// Platform-specific setup
    pub(crate) fn new(id: SocketId) -> Result<Self> {
        let sock_path = ipc_path(id)?;

        tracing::debug!(socket = %sock_path.display(), "Creating new IPC server");

        // Remove the socket if a previous run left it there
        std::fs::remove_file(&sock_path).ok();
        // Create the dir if possible, needed for test paths under `/run/user`
        let dir = sock_path
            .parent()
            .context("`sock_path` should always have a parent")?;
        std::fs::create_dir_all(dir).context("Failed to create socket parent directory")?;
        let listener = UnixListener::bind(&sock_path)
            .with_context(|| format!("Couldn't bind UDS `{}`", sock_path.display()))?;
        let perms = std::fs::Permissions::from_mode(0o660);
        std::fs::set_permissions(&sock_path, perms).context("Failed to set permissions on UDS")?;

        #[cfg(target_os = "linux")]
        {
            // TODO: Change this to `notify_service_controller` and put it in
            // the same place in the Tunnel service's main loop as in the Headless Client.
            sd_notify::notify(&[sd_notify::NotifyState::Ready])?;
        }

        let allowed_peer = cfg_select! {
            all(target_os = "linux", test) => peer_check::AllowedPeer::for_current_exe(),
            target_os = "linux" => peer_check::AllowedPeer::firezone_gui_client(),
            target_os = "macos" => peer_check::AllowedPeer::stub(),
        };

        Ok(Self {
            listener,
            id,
            allowed_peer,
        })
    }

    pub(crate) async fn next_client(&mut self) -> Result<(ServerStream, u32)> {
        loop {
            let (stream, _) = self.listener.accept().await?;
            let cred = stream.peer_cred()?;

            #[cfg(debug_assertions)]
            if SKIP_PEER_VERIFICATION.load(Ordering::Relaxed) {
                tracing::info!(
                    uid = cred.uid(),
                    gid = cred.gid(),
                    pid = cred.pid(),
                    "Accepted an IPC connection without peer verification"
                );
                let pid = cred.pid().context("No PID")?.try_into()?;

                return Ok((stream, pid));
            }

            match self.allowed_peer.verify(stream) {
                Ok(stream) => {
                    tracing::info!(
                        uid = cred.uid(),
                        gid = cred.gid(),
                        pid = cred.pid(),
                        "Accepted an IPC connection"
                    );
                    let pid = cred.pid().context("No PID")?.try_into()?;

                    return Ok((stream, pid));
                }
                Err(rejected) => {
                    tracing::info!(
                        uid = cred.uid(),
                        gid = cred.gid(),
                        pid = cred.pid(),
                        "Rejected an IPC connection: {rejected:#}"
                    );
                }
            }
        }
    }
}

/// The path for our Unix Domain Socket
///
/// Docker keeps theirs in `/run` and also appears to use filesystem permissions
/// for security, so we're following their lead. `/run` and `/var/run` are symlinked
/// on some systems, `/run` should be the newer version.
///
/// Also systemd can create this dir with the `RuntimeDir=` directive which is nice.
///
/// Test sockets live in e.g. `/run/user/1000/dev.firezone.client/data/`
fn ipc_path(id: SocketId) -> Result<PathBuf> {
    Ok(match id {
        SocketId::Tunnel => known_dirs::root_runtime()
            .context("Failed to get root runtime directory")?
            .join("tunnel.sock"),
        SocketId::Gui => known_dirs::user_runtime()
            .context("Failed to get user runtime directory")?
            .join("gui.sock"),
        #[cfg(test)]
        SocketId::Test(id) => known_dirs::user_runtime()
            .context("Failed to get user runtime directory")?
            .join(format!("ipc_test_{id}.sock")),
    })
}
