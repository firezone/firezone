//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use anyhow::Result;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

#[derive(clap::Subcommand)]
pub enum Cmd {
    Crash,
    Hostname,
    NetworkChanges,
    Test {
        #[command(subcommand)]
        command: Test,
    },
    Wintun,
}

#[derive(clap::Subcommand)]
pub enum Test {
    Ipc,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::Crash => crash(),
        Cmd::Hostname => hostname(),
        Cmd::NetworkChanges => network_changes(),
        Cmd::Test { command } => run_test(command),
        Cmd::Wintun => wintun(),
    }
}

fn run_test(cmd: Test) -> Result<()> {
    match cmd {
        Test::Ipc => test_ipc(),
    }
}

fn crash() -> Result<()> {
    // `_` doesn't seem to work here, the log files end up empty
    let _handles = crate::client::logging::setup("debug")?;
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

/// Listen for network change events from Windows
fn network_changes() -> Result<()> {
    tracing_subscriber::fmt::init();

    // Must be called for each thread that will do COM stuff
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }?;

    {
        let _listener = crate::client::network_changes::Listener::new()?;
        println!("Listening for network events for 1 minute");
        std::thread::sleep(std::time::Duration::from_secs(60));
    }

    unsafe {
        // Required, per CoInitializeEx docs
        // Safety: Make sure all the COM objects are dropped before we call
        // CoUninitialize or the program might segfault.
        CoUninitialize();
    }
    Ok(())
}

fn test_ipc() -> Result<()> {
    // TODO: Add multi-process IPC test here. This would be difficult to implement
    // idiomatically with `cargo test` alone.
    Ok(())
}

fn wintun() -> Result<()> {
    tracing_subscriber::fmt::init();

    if crate::client::elevation::check()? {
        tracing::info!("Elevated");
    } else {
        tracing::warn!("Not elevated")
    }
    Ok(())
}
