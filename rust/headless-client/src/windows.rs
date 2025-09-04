//! Implementation of headless Client and Tunnel service for Windows
//!
//! Try not to panic in the Tunnel service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use anyhow::Result;
use std::path::Path;

// The return value is useful on Linux
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    // TODO: For Headless Client, make sure the token is only readable by admin / our service user on Windows
    Ok(())
}

// Does nothing on Windows. On Linux this notifies systemd that we're ready.
// When we eventually have a system service for the Windows Headless Client,
// this could notify the Windows service controller too.
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(())
}
