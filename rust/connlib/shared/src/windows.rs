//! Windows-specific things like the well-known appdata path, bundle ID, etc.

use crate::Error;
use known_folders::{get_known_folder_path, KnownFolder};
use std::path::PathBuf;

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Result<PathBuf, Error> {
    let path = get_known_folder_path(KnownFolder::LocalAppData)
        .ok_or(Error::CantFindLocalAppDataFolder)?
        .join(crate::BUNDLE_ID);
    Ok(path)
}

pub mod dns {
    //! Gives Firezone DNS privilege over other DNS resolvers on the system
    //!
    //! This uses NRPT and claims all domains, similar to the `systemd-resolved` control method
    //! on Linux.
    //! This allows us to "shadow" DNS resolvers that are configured by the user or DHCP on
    //! physical interfaces, as long as they don't have any NRPT rules that outrank us.
    //!
    //! If Firezone crashes, restarting Firezone and closing it gracefully will resume
    //! normal DNS operation. The Powershell command to remove the NRPT rule can also be run
    //! by hand.
    //!
    //! The system default resolvers don't need to be reverted because they're never deleted.
    //!
    //! <https://superuser.com/a/1752670>

    use anyhow::Result;
    use std::{
        os::windows::process::CommandExt,
        process::Command,
    };

    /// Hides Powershell's console on Windows
    ///
    /// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
    /// Also used for self-elevation
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    // Unique magic number that we can use to delete our well-known NRPT rule.
    // Copied from the deep link schema
    const FZ_MAGIC: &str = "firezone-fd0020211111";

    /// Tells Windows to send all DNS queries to our sentinels
    ///
    /// Parameters:
    /// - `dns_config_string`: Comma-separated IP addresses of DNS servers, e.g. "1.1.1.1,8.8.8.8"
    pub fn activate(dns_config_string: &str) -> Result<()> {
        tracing::info!("Activating DNS control");
        Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .args([
                "-Command",
                "Add-DnsClientNrptRule",
                "-Namespace",
                ".",
                "-Comment",
                FZ_MAGIC,
                "-NameServers",
                dns_config_string,
            ])
            .status()?;
        Ok(())
    }

    /// Tells Windows to send all DNS queries to this new set of sentinels
    ///
    /// Currently implemented as just removing the rule and re-adding it, which
    /// creates a gap but doesn't require us to parse Powershell output to figure
    /// out the rule's UUID.
    ///
    /// Parameters:
    /// - `dns_config_string` - Passed verbatim to [`activate`]
    pub fn change(dns_config_string: &str) -> Result<()> {
        deactivate()?;
        activate(dns_config_string)?;
        Ok(())
    }

    pub fn deactivate() -> Result<()> {
        tracing::info!("Deactivating DNS control");
        Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .args([
                "-Command",
                "Get-DnsClientNrptRule",
                "|",
                "where",
                "Comment",
                "-eq",
                FZ_MAGIC,
                "|",
                "foreach",
                "{",
                "Remove-DnsClientNrptRule",
                "-Name",
                "$_.Name",
                "-Force",
                "}",
            ])
            .status()?;
        Ok(())
    }

    /// Flush Windows' system-wide DNS cache
    pub fn flush() -> Result<()> {
        tracing::info!("Flushing Windows DNS cache");
        Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .args([
                "-Command",
                "Clear-DnsClientCache",
            ])
            .status()?;
        Ok(())
    }
}

/// Returns the absolute path for installing and loading `wintun.dll`
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
pub fn wintun_dll_path() -> Result<PathBuf, Error> {
    let path = app_local_data_dir()?.join("data").join("wintun.dll");
    Ok(path)
}
