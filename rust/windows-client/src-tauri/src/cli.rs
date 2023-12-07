use clap::Parser;
use firezone_cli_utils::CommonArgs;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<CliCommands>,
    #[arg(long, hide = true)]
    pub inject_faults: bool,
}

#[derive(clap::Subcommand)]
pub enum CliCommands {
    Debug,
    DebugConnlib {
        #[command(flatten)]
        common: CommonArgs,
    },
    DebugDeviceId,
    DebugToken,
    DebugWintun,
}
