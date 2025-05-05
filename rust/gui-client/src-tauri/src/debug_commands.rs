//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use anyhow::Result;

#[derive(clap::Subcommand)]
pub(crate) enum Cmd {
    Replicate6791,
    SetAutostart(SetAutostartArgs),
}

#[derive(clap::Parser)]
pub(crate) struct SetAutostartArgs {
    #[clap(action=clap::ArgAction::Set)]
    enabled: bool,
}

#[derive(clap::Parser)]
pub(crate) struct CheckTokenArgs {
    token: String,
}

#[derive(clap::Parser)]
pub(crate) struct StoreTokenArgs {
    token: String,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::Replicate6791 => crate::auth::replicate_6791(),
        Cmd::SetAutostart(SetAutostartArgs { enabled }) => set_autostart(enabled),
    }
}

fn set_autostart(enabled: bool) -> Result<()> {
    firezone_headless_client::setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(crate::gui::set_autostart(enabled))?;
    Ok(())
}
