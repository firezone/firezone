//! Implementation, Linux-specific

use super::{CliCommon, SignalKind, FIREZONE_GROUP, TOKEN_ENV_KEY};
use anyhow::{bail, Context as _, Result};
use connlib_client_shared::file_logger;
use firezone_cli_utils::setup_global_subscriber;
use futures::future::{select, Either};
use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    pin::pin,
};
use tokio::{
    net::{UnixListener, UnixStream},
    signal::unix::{signal, Signal, SignalKind as TokioSignalKind},
};

// The Client currently must run as root to control DNS
// Root group and user are used to check file ownership on the token
const ROOT_GROUP: u32 = 0;
const ROOT_USER: u32 = 0;

pub(crate) struct Signals {
    sighup: Signal,
    sigint: Signal,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sighup = signal(TokioSignalKind::hangup())?;
        let sigint = signal(TokioSignalKind::interrupt())?;

        Ok(Self { sighup, sigint })
    }

    pub(crate) async fn recv(&mut self) -> SignalKind {
        match select(pin!(self.sighup.recv()), pin!(self.sigint.recv())).await {
            Either::Left((_, _)) => SignalKind::Hangup,
            Either::Right((_, _)) => SignalKind::Interrupt,
        }
    }
}

pub(crate) fn default_token_path() -> PathBuf {
    PathBuf::from("/etc")
        .join(connlib_shared::BUNDLE_ID)
        .join("token")
}

pub(crate) fn check_token_permissions(path: &Path) -> Result<()> {
    let Ok(stat) = nix::sys::stat::fstatat(None, path, nix::fcntl::AtFlags::empty()) else {
        // File doesn't exist or can't be read
        tracing::info!(
            ?path,
            ?TOKEN_ENV_KEY,
            "No token found in env var or on disk"
        );
        bail!("Token file doesn't exist");
    };
    if stat.st_uid != ROOT_USER {
        bail!(
            "Token file `{}` should be owned by root user",
            path.display()
        );
    }
    if stat.st_gid != ROOT_GROUP {
        bail!(
            "Token file `{}` should be owned by root group",
            path.display()
        );
    }
    if stat.st_mode & 0o177 != 0 {
        bail!(
            "Token file `{}` should have mode 0o400 or 0x600",
            path.display()
        );
    }
    Ok(())
}

/// The path for our Unix Domain Socket
///
/// Docker keeps theirs in `/run` and also appears to use filesystem permissions
/// for security, so we're following their lead. `/run` and `/var/run` are symlinked
/// on some systems, `/run` should be the newer version.
///
/// Also systemd can create this dir with the `RuntimeDir=` directive which is nice.
pub fn sock_path() -> PathBuf {
    PathBuf::from("/run")
        .join(connlib_shared::BUNDLE_ID)
        .join("ipc.sock")
}

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(cli: CliCommon) -> Result<()> {
    tracing::info!("run_ipc_service");
    // systemd supplies this but maybe we should hard-code a better default
    let (layer, _handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);
    tracing::info!(git_version = crate::GIT_VERSION);

    if !nix::unistd::getuid().is_root() {
        anyhow::bail!("This is the IPC service binary, it's not meant to run interactively.");
    }
    let rt = tokio::runtime::Runtime::new()?;
    rt.spawn(crate::heartbeat::heartbeat());
    if let Err(error) = rt.block_on(crate::ipc_listen()) {
        tracing::error!(?error, "`ipc_listen` failed");
    }
    Ok(())
}

pub(crate) fn run_wintun() -> Result<()> {
    anyhow::bail!("`debug wintun` is only implemented on Windows");
}

pub fn firezone_group() -> Result<nix::unistd::Group> {
    let group = nix::unistd::Group::from_name(FIREZONE_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_GROUP}` group must exist on the system"))?;
    Ok(group)
}

pub(crate) struct IpcServer {
    listener: UnixListener,
}

/// Opaque wrapper around platform-specific IPC stream
pub(crate) type IpcStream = UnixStream;

impl IpcServer {
    /// Platform-specific setup
    pub(crate) async fn new() -> Result<Self> {
        Self::new_with_path(&sock_path()).await
    }

    /// Uses a test path instead of what prod uses
    ///
    /// The test path doesn't need admin powers and won't conflict with the prod
    /// IPC service on a dev machine.
    #[cfg(test)]
    pub(crate) async fn new_for_test() -> Result<Self> {
        let dir = crate::known_dirs::runtime().context("Can't find runtime dir")?;
        // On a CI runner, the dir might not exist yet
        tokio::fs::create_dir_all(&dir).await?;
        let sock_path = dir.join("ipc_test.sock");
        Self::new_with_path(&sock_path).await
    }

    async fn new_with_path(sock_path: &Path) -> Result<Self> {
        // Remove the socket if a previous run left it there
        tokio::fs::remove_file(sock_path).await.ok();
        let listener = UnixListener::bind(sock_path).context("Couldn't bind UDS")?;
        let perms = std::fs::Permissions::from_mode(0o660);
        tokio::fs::set_permissions(sock_path, perms).await?;
        sd_notify::notify(true, &[sd_notify::NotifyState::Ready])?;
        Ok(Self { listener })
    }

    pub(crate) async fn next_client(&mut self) -> Result<IpcStream> {
        tracing::info!("Listening for GUI to connect over IPC...");
        let (stream, _) = self.listener.accept().await?;
        let cred = stream.peer_cred()?;
        tracing::info!(
            uid = cred.uid(),
            gid = cred.gid(),
            pid = cred.pid(),
            "Accepted an IPC connection"
        );
        Ok(stream)
    }
}

pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(sd_notify::notify(true, &[sd_notify::NotifyState::Ready])?)
}

/// Platform-specific setup needed for connlib
///
/// On Linux this does nothing
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn setup_before_connlib() -> Result<()> {
    Ok(())
}
