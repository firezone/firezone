use anyhow::Result;
use clap::Parser;
use firezone_cli_utils::CommonArgs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<CliCommands>,
}

#[derive(clap::Subcommand)]
pub enum CliCommands {
    Debug,
    DebugConnlib {
        #[command(flatten)]
        common: CommonArgs,
    },
    DebugCredentials,
    DebugDeviceId,
    DebugHome,
    DebugWintun,
    Tauri {
        // Common args are optional for the GUI because most of the time it'll be launched with useful args or env vars
        #[command(flatten)]
        common: Option<CommonArgs>,
    },
}

pub(crate) fn get_windows_home() -> Result<PathBuf> {
    if let Some(home) = std::env::var_os("USERPROFILE") {
        // $USERPROFILE returns "C:\Users\User" for me in Cygywin.
        // Cygwin uses its own $HOME, so this is for compatibility with my dev system - ReactorScram
        // On Powershell on my dev system it is blank or not set
        if !home.is_empty() {
            return Ok(PathBuf::from(home));
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        // $HOME is "C:\Users\User" for me in Powershell.
        if !home.is_empty() {
            return Ok(PathBuf::from(home));
        }
    }

    anyhow::bail!("can't find user's home dir in $USERPROFILE or $HOME");
}

/// Compute well-known paths for the app's files, e.g. configs go in AppData on Windows and `~/.config` on Linux.
pub fn get_project_dirs() -> Result<directories::ProjectDirs> {
    directories::ProjectDirs::from("", "Firezone", "Client")
        .ok_or_else(|| anyhow::anyhow!("Can't compute project dirs"))
}
