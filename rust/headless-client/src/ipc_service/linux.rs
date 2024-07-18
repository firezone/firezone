use crate::known_dirs;
use anyhow::Context as _;
use anyhow::{bail, Result};

/// Cross-platform entry point for systemd / Windows services
pub(crate) fn run_ipc_service() -> Result<()> {
    let _handle = super::setup_logging(
        &known_dirs::ipc_service_logs().context("Couldn't compute IPC service logs dir")?,
    )?;
    if !nix::unistd::getuid().is_root() {
        anyhow::bail!("This is the IPC service binary, it's not meant to run interactively.");
    }
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(super::ipc_listen())
}

pub(crate) fn install_ipc_service() -> Result<()> {
    bail!("`install_ipc_service` not implemented and not needed on Linux")
}
