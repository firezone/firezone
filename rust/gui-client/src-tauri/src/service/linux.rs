use std::{path::PathBuf, time::Duration};

use anyhow::{Result, bail};
use bin_shared::{DnsControlMethod, signals};

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub fn run(log_dir: Option<PathBuf>, dns_control: DnsControlMethod) -> Result<()> {
    let (_handle, log_filter_reloader) = crate::logging::setup_tunnel(log_dir)?;
    if !elevation_check()? {
        bail!("Tunnel service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut signals = signals::Terminate::new()?;

    rt.block_on(super::ipc_listen(
        dns_control,
        &log_filter_reloader,
        &mut signals,
    ))
    .inspect_err(|e| tracing::error!("IPC service failed: {e:#}"))?;

    rt.shutdown_timeout(Duration::from_secs(1)); // Ensure we don't block forever on a task in the blocking pool.

    Ok(())
}

/// Returns true if the Tunnel service can run properly
// Fallible on Windows
#[expect(clippy::unnecessary_wraps)]
pub fn elevation_check() -> Result<bool> {
    Ok(nix::unistd::getuid().is_root())
}

pub fn install() -> Result<()> {
    bail!("`install_ipc_service` not implemented and not needed on Linux")
}
