use super::CliCommon;
use anyhow::{Result, bail};

pub(crate) fn run_ipc_service(cli: CliCommon) -> Result<()> {
    // We call this here to avoid a dead-code warning.
    let (_handle, _log_filter_reloader) = super::setup_logging(cli.log_dir)?;

    bail!("not implemented")
}

pub(crate) fn elevation_check() -> Result<bool> {
    bail!("not implemented")
}

pub(crate) fn install_ipc_service() -> Result<()> {
    bail!("not implemented")
}
