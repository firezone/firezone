use crate::prelude::*;
use clap::Parser;

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
    DebugWintun,
    Tauri {
        // Common args are optional for the GUI because most of the time it'll be launched with useful args or env vars
        #[command(flatten)]
        common: Option<CommonArgs>,
    },
}
