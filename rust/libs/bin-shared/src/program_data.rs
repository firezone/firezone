//! The Tunnel service directory in `C:\ProgramData`.

use anyhow::{Context as _, Result};
use std::path::PathBuf;
use windows_security::{SecurityDescriptor, secure_dir};

/// Full Access to `LocalSystem` and `BUILTIN\Administrators`, read access to
/// `BUILTIN\Users` (the GUI reads the Tunnel service logs). Users cannot
/// create or change anything.
const ROOT_SDDL: &str = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)";

/// Full Access to `LocalSystem` and `BUILTIN\Administrators` only.
const PRIVATE_SDDL: &str = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

/// Makes sure that only `LocalSystem` and administrators own and can change
/// `C:\ProgramData\dev.firezone.client`, its `config` and `flow_logs`
/// directories, and the entries in them.
///
/// Call this before anything reads from or writes to these directories.
///
/// Returns the paths that objects with an untrusted owner moved to.
pub fn secure() -> Result<Vec<PathBuf>> {
    let config = known_dirs::tunnel_service_config()
        .context("Failed to compute Tunnel service config dir")?;
    let root = config.parent().context("Config dir should have a parent")?;
    let mut quarantine = root.as_os_str().to_owned();
    quarantine.push(".untrusted");
    let quarantine = PathBuf::from(quarantine);

    let root_sd = SecurityDescriptor::from_sddl(ROOT_SDDL)?;
    let private_sd = SecurityDescriptor::from_sddl(PRIVATE_SDDL)?;

    let mut moved = secure_dir(root, &root_sd, &quarantine)?;
    moved.extend(secure_dir(&config, &private_sd, &quarantine)?);

    if let Some(flow_logs) = known_dirs::flow_logs() {
        moved.extend(secure_dir(&flow_logs, &private_sd, &quarantine)?);
    }

    Ok(moved)
}
