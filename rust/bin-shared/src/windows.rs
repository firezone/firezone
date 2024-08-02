use anyhow::{Context as _, Result};
use known_folders::{get_known_folder_path, KnownFolder};
use std::path::PathBuf;

/// Hides Powershell's console on Windows
///
/// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
/// Also used for self-elevation
pub const CREATE_NO_WINDOW: u32 = 0x08000000;

#[derive(Clone, Copy, Debug)]
pub enum DnsControlMethod {
    /// Explicitly disable DNS control.
    ///
    /// We don't use an `Option<Method>` because leaving out the CLI arg should
    /// use NRPT, not disable DNS control.
    Disabled,
    /// NRPT, the only DNS control method we use on Windows.
    Nrpt,
}

impl Default for DnsControlMethod {
    fn default() -> Self {
        Self::Nrpt
    }
}

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Result<PathBuf> {
    let path = get_known_folder_path(KnownFolder::LocalAppData)
        .context("Can't find %LOCALAPPDATA% dir")?
        .join(crate::BUNDLE_ID);
    Ok(path)
}
