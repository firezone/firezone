//! Unix IPC implementation using Unix Domain Sockets.
//!
//! Shared by Linux and macOS. The production macOS client uses the native
//! Swift implementation in `swift/apple/`; this enables running controller
//! tests on macOS.

use super::{NotFound, SocketId};
use anyhow::{Context as _, Result};
use std::{io::ErrorKind, os::unix::fs::PermissionsExt, path::PathBuf};
use tokio::net::{UnixListener, UnixStream};

pub struct Server {
    listener: UnixListener,
    id: SocketId,
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

        Ok(Self { listener, id })
    }

    pub(crate) async fn next_client(&mut self) -> Result<ServerStream> {
        let (stream, _) = self.listener.accept().await?;
        let cred = stream.peer_cred()?;
        let pid = cred.pid();
        tracing::info!(
            uid = cred.uid(),
            gid = cred.gid(),
            pid = pid,
            "Accepted an IPC connection"
        );
        if let Some(pid) = pid {
            authorize_peer(pid).inspect_err(|error| {
                tracing::warn!(pid, "Rejecting IPC peer: {error:#}");
            })?;
        }
        Ok(stream)
    }
}

/// Authorize an IPC peer using its AppArmor label.
///
/// When the Tunnel service itself is confined by the `firezone-client-tunnel`
/// AppArmor profile (the deb/rpm packaging loads one at install time), the
/// peer's process must be confined by the matching `firezone-client-gui`
/// profile. This is checked here in userspace rather than via an AppArmor
/// `peer=(label=...)` rule because AppArmor unix peer mediation for
/// path-based sockets is unreliable on upstream kernels older than 6.17
/// (see Launchpad bug #1208988).
///
/// In every other case - AppArmor not active, profile failed to load, the
/// tunnel started before the profile was installed, the label is "kernel"
/// or "unconfined" - the peer check is skipped and POSIX permissions on the
/// socket (`root:firezone-client 0660`) remain the only gate. This preserves
/// behaviour on distros without AppArmor and on systems where the install
/// hasn't completed yet.
#[cfg(target_os = "linux")]
fn authorize_peer(pid: i32) -> Result<()> {
    const TUNNEL_LABEL: &str = "firezone-client-tunnel";
    const GUI_LABEL: &str = "firezone-client-gui";

    let our_label = read_apparmor_label(std::process::id() as i32);
    if our_label.as_deref() != Some(TUNNEL_LABEL) {
        return Ok(());
    }

    let peer_label =
        read_apparmor_label(pid).context("Failed to read peer's AppArmor label")?;
    anyhow::ensure!(
        peer_label == GUI_LABEL,
        "Peer AppArmor label {peer_label:?} is not {GUI_LABEL:?}",
    );
    Ok(())
}

#[cfg(target_os = "macos")]
fn authorize_peer(_pid: i32) -> Result<()> {
    // macOS doesn't have AppArmor; the production macOS client uses the
    // native Swift implementation in `swift/apple/` and this code path only
    // runs from controller tests.
    Ok(())
}

/// Read a process's AppArmor label from `/proc/<pid>/attr/current`.
///
/// Returns `None` when the file isn't readable - which happens when the
/// kernel was built without LSM support, or the peer process exited before
/// we could read its attribute.
///
/// Format of the file (newline- and sometimes null-terminated):
///  - `unconfined\n` - no profile attached
///  - `kernel\0` - kernel-internal label (e.g. in containers without AppArmor)
///  - `<profile-name>\n` - profile attached in enforce mode
///  - `<profile-name> (mode)\n` - profile attached in complain/etc. mode
#[cfg(target_os = "linux")]
fn read_apparmor_label(pid: i32) -> Option<String> {
    let raw = std::fs::read_to_string(format!("/proc/{pid}/attr/current")).ok()?;
    let cleaned = raw
        .trim_matches(|c: char| c.is_whitespace() || c == '\0')
        .split(' ')
        .next()
        .unwrap_or("");
    Some(cleaned.to_string())
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
