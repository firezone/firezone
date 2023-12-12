use clap::Parser;

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
    DebugToken,
    DebugWintun,
}
