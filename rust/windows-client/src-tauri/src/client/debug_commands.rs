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

pub use details::{open_deep_link, pipe_server, register_deep_link, wintun};

#[cfg(target_family = "unix")]
mod details {
    use super::*;

    pub fn open_deep_link(_: &url::Url) -> Result<()> {
        unimplemented!()
    }

    pub fn pipe_server(_: Cli) -> Result<()> {
        unimplemented!()
    }

    pub fn register_deep_link(_: Cli) -> Result<()> {
        unimplemented!()
    }

    pub fn wintun(_: Cli) -> Result<()> {
        unimplemented!()
    }
}

#[cfg(target_os = "windows")]
mod details {
    use super::*;
    use std::sync::Arc;

    pub fn open_deep_link(path: &url::Url) -> Result<()> {
        let subscriber = tracing_subscriber::FmtSubscriber::builder()
            .with_max_level(tracing::Level::TRACE)
            .finish();
        tracing::subscriber::set_global_default(subscriber)
            .expect("setting default subscriber failed");

        let rt = Runtime::new()?;
        rt.block_on(crate::client::deep_link::open(PIPE_NAME, path))?;
        Ok(())
    }

    // Copied the named pipe idea from `interprocess` and `tauri-plugin-deep-link`,
    // although I believe it's considered best practice on Windows to use named pipes for
    // single-instance apps.
    pub fn pipe_server() -> Result<()> {
        let subscriber = tracing_subscriber::FmtSubscriber::builder()
            .with_max_level(tracing::Level::TRACE)
            .finish();
        tracing::subscriber::set_global_default(subscriber)
            .expect("setting default subscriber failed");

        let rt = Runtime::new()?;
        rt.block_on(async {
            loop {
                crate::client::deep_link::accept(PIPE_NAME).await?;
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
        for _ in 0..3 {
            println!("Creating adapter...");
            test_wintun_once()?;
        }
        Ok(())
    }

    fn test_wintun_once() -> Result<()> {
        //Must be run as Administrator because we create network adapters
        //Load the wintun dll file so that we can call the underlying C functions
        //Unsafe because we are loading an arbitrary dll file
        let wintun = unsafe { wintun::load_from_path("./wintun.dll") }?;

        //Try to open an adapter with the name "Demo"
        let adapter = match wintun::Adapter::open(&wintun, "Demo") {
            Ok(a) => a,
            Err(_) => {
                //If loading failed (most likely it didn't exist), create a new one
                wintun::Adapter::create(&wintun, "Demo", "Example manor hatch stash", None)?
            }
        };
        //Specify the size of the ring buffer the wintun driver should use.
        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);

        //Get a 20 byte packet from the ring buffer
        let mut packet = session.allocate_send_packet(20)?;
        let bytes: &mut [u8] = packet.bytes_mut();
        //Write IPV4 version and header length
        bytes[0] = 0x40;

        //Finish writing IP header
        bytes[9] = 0x69;
        bytes[10] = 0x04;
        bytes[11] = 0x20;
        //...

        //Send the packet to wintun virtual adapter for processing by the system
        session.send_packet(packet);

        // Sleep for a few seconds in case we want to confirm the adapter shows up in Device Manager.
        std::thread::sleep(std::time::Duration::from_secs(5));

        //Stop any readers blocking for data on other threads
        //Only needed when a blocking reader is preventing shutdown Ie. it holds an Arc to the
        //session, blocking it from being dropped
        session.shutdown()?;

        //the session is stopped on drop
        //drop(session);

        //drop(adapter)
        //And the adapter closes its resources when dropped

        Ok(())
    }
}
