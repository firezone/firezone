//! Implementation of headless Client and Tunnel service for Windows
//!
//! Try not to panic in the Tunnel service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use anyhow::{Context as _, Result, bail};
use std::path::Path;

/// Protected DACL granting Full Access to `LocalSystem` and
/// `BUILTIN\Administrators` only.
const TOKEN_SDDL: &str = "D:P(A;;FA;;;SY)(A;;FA;;;BA)";

pub(crate) fn check_token_permissions(path: &Path) -> Result<()> {
    let sddl = windows_security::dacl_sddl_for_path(path)?;

    if sorted_aces(&sddl) != sorted_aces(TOKEN_SDDL) {
        bail!(
            "Token file `{}` should only be accessible by SYSTEM and Administrators but has DACL `{sddl}`",
            path.display()
        );
    }

    Ok(())
}

pub(crate) fn set_token_permissions(path: &Path) -> Result<()> {
    windows_security::SecurityDescriptor::from_sddl(TOKEN_SDDL)?.apply_to_path(path)
}

/// The ACEs of a DACL in SDDL form, ignoring the DACL flags.
fn sorted_aces(sddl: &str) -> Vec<&str> {
    let mut aces = sddl
        .split(['(', ')'])
        .filter(|part| !part.is_empty())
        .skip(1)
        .collect::<Vec<_>>();
    aces.sort_unstable();

    aces
}

/// Writes a token to the specified path.
/// Creates the parent directory if needed and restricts the file to SYSTEM and
/// Administrators before writing the token.
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

    set_token_permissions(path)?;

    file.write_all(token.as_bytes())
        .context("Failed to write token to file")?;

    Ok(())
}

// Does nothing on Windows. On Linux this notifies systemd that we're ready.
// When we eventually have a system service for the Windows Headless Client,
// this could notify the Windows service controller too.
#[expect(clippy::unnecessary_wraps)]
pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(())
}
