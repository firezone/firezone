//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client::cli::Cli;
use anyhow::Result;
use tokio::runtime::Runtime;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

// TODO: In tauri-plugin-deep-link, this is the identifier in tauri.conf.json
const PIPE_NAME: &str = "dev.firezone.client";

pub fn crash() -> Result<()> {
    // `_` doesn't seem to work here, the log files end up empty
    let _handles = crate::client::logging::setup("debug")?;
    tracing::info!("started log (DebugCrash)");

    panic!("purposely crashing to see if it shows up in logs");
}

pub fn hostname() -> Result<()> {
    println!(
        "{:?}",
        hostname::get().ok().and_then(|x| x.into_string().ok())
    );
    Ok(())
}

/// Listen for network change events from Windows
pub fn network_changes() -> Result<()> {
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

pub fn open_deep_link(path: &url::Url) -> Result<()> {
    tracing_subscriber::fmt::init();

    let rt = Runtime::new()?;
    rt.block_on(crate::client::deep_link::open(PIPE_NAME, path))?;
    Ok(())
}

// Copied the named pipe idea from `interprocess` and `tauri-plugin-deep-link`,
// although I believe it's considered best practice on Windows to use named pipes for
// single-instance apps.
pub fn pipe_server() -> Result<()> {
    tracing_subscriber::fmt::init();

    let rt = Runtime::new()?;
    rt.block_on(async {
        loop {
            let server = crate::client::deep_link::Server::new(PIPE_NAME)?;
            server.accept().await?;
        }
    })
}

// This is copied almost verbatim from tauri-plugin-deep-link's `register` fn, with an improvement
// that we send the deep link to a subcommand so the URL won't confuse `clap`
pub fn register_deep_link() -> Result<()> {
    crate::client::deep_link::register(PIPE_NAME)?;
    Ok(())
}

pub fn wintun(_: Cli) -> Result<()> {
    tracing_subscriber::fmt::init();

    if crate::client::elevation::check()? {
        tracing::info!("Elevated");
    } else {
        tracing::warn!("Not elevated")
    }
    Ok(())
}
