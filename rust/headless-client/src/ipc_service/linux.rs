use super::{CliCommon, SignalKind, TOKEN_ENV_KEY};
use anyhow::{bail, Result};
use futures::future::{select, Either};
use std::{
    path::{Path, PathBuf},
    pin::pin,
};
use tokio::signal::unix::{signal, Signal, SignalKind as TokioSignalKind};

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(cli: CliCommon) -> Result<()> {
    let _handle = crate::setup_ipc_service_logging(cli.log_dir)?;
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

pub(crate) fn install_ipc_service() -> Result<()> {
    bail!("`install_ipc_service` not implemented and not needed on Linux")
}
