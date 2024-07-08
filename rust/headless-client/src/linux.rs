//! Implementation, Linux-specific

use super::{SignalKind, TOKEN_ENV_KEY};
use anyhow::{bail, Result};
use futures::future::FutureExt as _;
use std::{
    path::{Path, PathBuf},
    pin::pin,
};
use tokio::signal::unix::{signal, Signal, SignalKind as TokioSignalKind};

// The Client currently must run as root to control DNS
// Root group and user are used to check file ownership on the token
const ROOT_GROUP: u32 = 0;
const ROOT_USER: u32 = 0;

pub(crate) struct Signals {
    /// For reloading settings in the standalone Client
    sighup: Signal,
    /// For Ctrl+C from a terminal
    sigint: Signal,
    /// For systemd service stopping
    sigterm: Signal,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sighup = signal(TokioSignalKind::hangup())?;
        let sigint = signal(TokioSignalKind::interrupt())?;
        let sigterm = signal(TokioSignalKind::terminate())?;

        Ok(Self {
            sighup,
            sigint,
            sigterm,
        })
    }

    pub(crate) async fn recv(&mut self) -> SignalKind {
        futures::select! {
            _ = pin!(self.sighup.recv().fuse()) => SignalKind::Hangup,
            _ = pin!(self.sigint.recv().fuse()) => SignalKind::Interrupt,
            _ = pin!(self.sigterm.recv().fuse()) => SignalKind::Terminate,
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
