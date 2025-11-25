use anyhow::{Result, bail};
use bin_shared::DnsControlMethod;
use std::path::PathBuf;

pub fn run(log_dir: Option<PathBuf>, _dns_control: DnsControlMethod) -> Result<()> {
    // We call this here to avoid a dead-code warning.
    let (_handle, _log_filter_reloader) = crate::logging::setup_tunnel(log_dir)?;

    bail!("not implemented")
}

pub fn elevation_check() -> Result<bool> {
    bail!("not implemented")
}

pub fn install() -> Result<()> {
    bail!("not implemented")
}
