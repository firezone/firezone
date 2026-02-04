//! Implementation of headless Client and Tunnel service for Windows
//!
//! Try not to panic in the Tunnel service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use anyhow::{Context as _, Result};
use bin_shared::BUNDLE_ID;
use known_folders::{KnownFolder, get_known_folder_path};
use std::path::{Path, PathBuf};

// The return value is useful on Linux
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    // TODO: Verify that the token file has the correct ACLs
    // https://github.com/firezone/firezone/issues/XXXXX
    Ok(())
}

// The return value is useful on Linux
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn set_token_permissions(_path: &Path) -> Result<()> {
    // TODO: Restrict token file access to SYSTEM and Administrators on Windows
    // https://github.com/firezone/firezone/issues/XXXXX
    Ok(())
}

/// Writes a token to the specified path.
/// Creates the parent directory if needed.
pub(crate) fn write_token(path: &Path, token: &str) -> Result<()> {
    use std::io::Write;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("Failed to create token directory")?;
    }

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(path)
        .context("Failed to create token file")?;

    file.write_all(token.as_bytes())
        .context("Failed to write token to file")?;

    set_token_permissions(path)?;

    Ok(())
}

pub(crate) fn default_token_path() -> PathBuf {
    get_known_folder_path(KnownFolder::ProgramData)
        .expect("ProgramData folder not found. Is %PROGRAMDATA% set?")
        .join(BUNDLE_ID)
        .join("token.txt")
}

// Does nothing on Windows. On Linux this notifies systemd that we're ready.
// When we eventually have a system service for the Windows Headless Client,
// this could notify the Windows service controller too.
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(())
}
