//! macOS IPC implementation using Unix Domain Sockets.
//!
//! This is a minimal, *not* production-grade implementation, aimed primarily for
//! running controller tests on macOS. The production macOS client uses the
//! native Swift implementation in `swift/apple/`.

use super::{NotFound, SocketId};
use anyhow::{Context as _, Result};
use std::{io::ErrorKind, path::PathBuf};
use tokio::net::{UnixListener, UnixStream};

pub(crate) struct Server {
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

pub type ClientStream = UnixStream;
pub(crate) type ServerStream = UnixStream;

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

    tracing::debug!("Made an IPC connection to {}", path.display());

    Ok(stream)
}

impl Server {
    pub(crate) fn new(id: SocketId) -> Result<Self> {
        let sock_path = ipc_path(id)?;

        tracing::debug!(socket = %sock_path.display(), "Creating new IPC server");

        // Remove the socket if a previous run left it there
        std::fs::remove_file(&sock_path).ok();

        // Create the dir if needed
        let dir = sock_path
            .parent()
            .context("`sock_path` should always have a parent")?;
        std::fs::create_dir_all(dir).context("Failed to create socket parent directory")?;

        let listener = UnixListener::bind(&sock_path)
            .with_context(|| format!("Couldn't bind UDS `{}`", sock_path.display()))?;

        Ok(Self { listener, id })
    }

    pub(crate) async fn next_client(&mut self) -> Result<ServerStream> {
        let (stream, _) = self.listener.accept().await?;
        tracing::info!("Accepted an IPC connection");

        Ok(stream)
    }
}

fn ipc_path(id: SocketId) -> Result<PathBuf> {
    let runtime_dir = bin_shared::known_dirs::runtime().context("Failed to get runtime directory")?;

    Ok(match id {
        SocketId::Tunnel => runtime_dir.join("tunnel.sock"),
        SocketId::Gui => runtime_dir.join("gui.sock"),
        #[cfg(test)]
        SocketId::Test(id) => runtime_dir.join(format!("ipc_test_{id}.sock")),
    })
}
