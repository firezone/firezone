//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client::Cli;
use anyhow::Result;

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

pub fn wintun(_: Cli) -> Result<()> {
    tracing_subscriber::fmt::init();

    if crate::client::elevation::check()? {
        tracing::info!("Elevated");
    } else {
        tracing::warn!("Not elevated")
    }
    Ok(())
}
