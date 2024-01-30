//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client;
use anyhow::Result;

#[derive(clap::Subcommand)]
pub enum Cmd {
    Crash,
    Hostname,
    NetworkChanges,
    TestIpc {
        #[command(subcommand)]
        cmd: Option<client::ipc::Subcommand>,
    },
    Wintun,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::Crash => crash(),
        Cmd::Hostname => hostname(),
        Cmd::NetworkChanges => client::network_changes::run_debug(),
        Cmd::TestIpc { cmd } => client::ipc::test_subcommand(cmd),
        Cmd::Wintun => wintun(),
    }
}

fn crash() -> Result<()> {
    // `_` doesn't seem to work here, the log files end up empty
    let _handles = client::logging::setup("debug")?;
    tracing::info!("started log (DebugCrash)");

    panic!("purposely crashing to see if it shows up in logs");
}

fn hostname() -> Result<()> {
    println!(
        "{:?}",
        hostname::get().ok().and_then(|x| x.into_string().ok())
    );
    Ok(())
}

/// Try to load wintun.dll and throw an error if it's not in the right place
fn wintun() -> Result<()> {
    tracing_subscriber::fmt::init();
    let path = crate::client::wintun_install::dll_path()?;
    unsafe { wintun::load_from_path(&path) }?;
    tracing::info!(?path, "Loaded wintun.dll");

    Ok(())
}
