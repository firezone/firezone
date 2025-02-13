use super::CliCommon;
use crate::signals;
use anyhow::{bail, Result};

use firezone_telemetry::Telemetry;

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(cli: CliCommon) -> Result<()> {
    let (_handle, log_filter_reloader) = super::setup_logging(cli.log_dir)?;
    if !elevation_check()? {
        bail!("IPC service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut signals = signals::Terminate::new()?;
    let mut telemetry = Telemetry::default();

    rt.block_on(super::ipc_listen(
        cli.dns_control,
        &log_filter_reloader,
        &mut signals,
        &mut telemetry,
    ))
    .inspect(|_| rt.block_on(telemetry.stop()))
    .inspect_err(|e| {
        tracing::error!("IPC service failed: {e:#}");

        rt.block_on(telemetry.stop_on_crash())
    })
}

/// Returns true if the IPC service can run properly
// Fallible on Windows
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn elevation_check() -> Result<bool> {
    Ok(nix::unistd::getuid().is_root())
}

pub(crate) fn install_ipc_service() -> Result<()> {
    bail!("`install_ipc_service` not implemented and not needed on Linux")
}
