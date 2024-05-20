//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client;
use anyhow::Result;

#[derive(clap::Subcommand)]
pub enum Cmd {
    CheckForUpdates,
    Crash,
    DnsChanges,
    Hostname,
    NetworkChanges,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::CheckForUpdates => check_for_updates()?,
        Cmd::Crash => crash()?,
        Cmd::DnsChanges => client::network_changes::run_dns_debug()?,
        Cmd::Hostname => hostname(),
        Cmd::NetworkChanges => client::network_changes::run_debug()?,
    };

    Ok(())
}

fn check_for_updates() -> Result<()> {
    firezone_headless_client::debug_command_setup()?;

    let rt = tokio::runtime::Runtime::new().unwrap();
    let version = rt.block_on(client::updates::check())?;
    tracing::info!("{:?}", version);

    Ok(())
}

fn crash() -> Result<()> {
    // `_` doesn't seem to work here, the log files end up empty
    let _handles = client::logging::setup("debug")?;
    tracing::info!("started log (DebugCrash)");

    panic!("purposely crashing to see if it shows up in logs");
}

#[allow(clippy::print_stdout)]
fn hostname() {
    println!(
        "{:?}",
        hostname::get().ok().and_then(|x| x.into_string().ok())
    );
}
