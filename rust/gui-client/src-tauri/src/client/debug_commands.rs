//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client;
use anyhow::Result;

#[derive(clap::Subcommand)]
pub enum Cmd {
    CheckForUpdates,
    Crash,
    DnsChanges,
    NetworkChanges,
    Wintun,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::CheckForUpdates => check_for_updates(),
        Cmd::Crash => crash(),
        Cmd::DnsChanges => client::network_changes::run_dns_debug(),
        Cmd::NetworkChanges => client::network_changes::run_debug(),
        Cmd::Wintun => wintun(),
    }
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

    panic!("purposely panicking to see if it shows up in logs");
}

/// Wintun stress test to shake out issue #4765
///
/// Should work on other platforms but won't do anything useful
fn wintun() -> Result<()> {
    firezone_headless_client::debug_command_setup()?;

    let iters = 10;
    for i in 0..iters {
        tracing::info!(?i, "Loop");
        {
            let _tunnel = firezone_tunnel::device_channel::Tun::new()?;
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    for i in 0..iters {
        tracing::info!(?i, "Loop");
        {
            let _tunnel = firezone_tunnel::device_channel::Tun::new()?;
        }
    }
    Ok(())
}
