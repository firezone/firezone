use clap::{Args, Parser};

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
    DebugHostname,
    DebugPipeServer,
    DebugWintun,
    Elevated,
    OpenDeepLink(DeepLink),
    RegisterDeepLink,
}

#[derive(Args)]
pub struct DeepLink {
    pub url: url::Url,
}
