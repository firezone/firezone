//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client::cli::Cli;
use anyhow::Result;
use keyring::Entry;
use tokio::runtime::Runtime;

// TODO: In tauri-plugin-deep-link, this is the identifier in tauri.conf.json
const PIPE_NAME: &str = "dev.firezone.client";

/// Test encrypted credential storage
pub fn token() -> Result<()> {
    // TODO: Remove placeholder email
    let entry = Entry::new_with_target("token", "firezone_windows_client", "username@example.com")?;
    match entry.get_password() {
        Ok(password) => {
            println!("Placeholder password is '{password}'");

            println!("Deleting password");
            entry.delete_password()?;
        }
        Err(keyring::Error::NoEntry) => {
            println!("No password in credential manager");

            let new_password = "top_secret_password";
            println!("Setting password to {new_password}");
            entry.set_password(new_password)?;
        }
        Err(e) => return Err(e.into()),
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
