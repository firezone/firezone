//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::cli::Cli;
use anyhow::Result;
use connlib_client_shared::{file_logger, Callbacks, Error, ResourceDescription, Session};
use firezone_cli_utils::{block_on_ctrl_c, setup_global_subscriber, CommonArgs};
use keyring::Entry;
use secrecy::SecretString;
use smbioslib::SMBiosSystemInformation as SysInfo;
use std::path::PathBuf;

/// Test connlib and its callbacks.
pub fn connlib(common_args: CommonArgs) -> Result<()> {
    #[derive(Clone)]
    struct CallbackHandler {
        handle: Option<file_logger::Handle>,
    }

    impl Callbacks for CallbackHandler {
        type Error = std::convert::Infallible;

        fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
            tracing::error!("on_disconnect not implemented. Error: {error:?}");
            Ok(())
        }

        fn on_error(&self, error: &Error) -> Result<(), Self::Error> {
            tracing::error!("on_error not implemented. Error: {error}");
            Ok(())
        }

        fn on_update_resources(
            &self,
            _resource_list: Vec<ResourceDescription>,
        ) -> Result<(), Self::Error> {
            tracing::error!("on_update_resources not implemented");
            Ok(())
        }

        fn roll_log_file(&self) -> Option<PathBuf> {
            self.handle
                .as_ref()?
                .roll_to_new_file()
                .unwrap_or_else(|e| {
                    tracing::debug!("Failed to roll over to new file: {e}");
                    let _ = self.on_error(&Error::LogFileRollError(e));

                    None
                })
        }
    }

    let (layer, handle) = file_logger::layer(std::path::Path::new("."));
    setup_global_subscriber(layer);

    let device_id = crate::device_id::get();

    let mut session = Session::connect(
        common_args.api_url,
        SecretString::from(common_args.token),
        device_id,
        CallbackHandler {
            handle: Some(handle),
        },
    )
    .unwrap();

    tracing::info!("new_session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
}

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

/// Test generating a device ID from the BIOS or MAC address. This should survive OS re-installs and uniquely identify a device.
pub fn device_id() -> Result<()> {
    let data = smbioslib::table_load_from_device()?;
    if let Some(uuid) = data.find_map(|sys_info: SysInfo| sys_info.uuid()) {
        println!("SMBios uuid: {uuid}");
    } else {
        println!("SMBios couldn't find uuid");
    }

    Ok(())
}

pub use details::wintun;

#[cfg(target_family = "unix")]
mod details {
    use super::*;

    pub fn wintun(_: Cli) -> Result<()> {
        panic!("Wintun not implemented for Linux.");
    }
}

#[cfg(target_os = "windows")]
mod details {
    use super::*;
    use std::sync::Arc;

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
