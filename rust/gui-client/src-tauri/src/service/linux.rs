use std::path::PathBuf;

use anyhow::{Result, bail};
use firezone_bin_shared::{DnsControlMethod, signals};

use firezone_telemetry::Telemetry;

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
    let mut telemetry = Telemetry::default();

    rt.block_on(super::ipc_listen(
        dns_control,
        &log_filter_reloader,
        &mut signals,
        &mut telemetry,
    ))
    .inspect(|_| rt.block_on(telemetry.stop()))
    .inspect_err(|e| {
        tracing::error!("Tunnel service failed: {e:#}");

        rt.block_on(telemetry.stop_on_crash())
    })
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
