//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client::cli::Cli;
use anyhow::Result;
use interprocess::local_socket;
use keyring::Entry;
use std::{ffi::c_void, io::Write};
use tokio::{io::AsyncReadExt, net::windows::named_pipe, runtime::Runtime};
use windows::Win32::Security as WinSec;

const PIPE_NAME: &str = "dev.firezone.client";

// This gets a `Error: Access is denied. (os error 5)`
// if the server is running as admin and the client is not admin
pub fn pipe_client() -> Result<()> {
    println!("Client is connecting...");
    let mut stream = local_socket::LocalSocketStream::connect(PIPE_NAME)?;
    println!("Client is connected");
    stream.write_all("firezone://example.com".as_bytes())?;
    println!("Client wrote");
    Ok(())
}

pub fn pipe_server() -> Result<()> {
    let rt = Runtime::new()?;
    rt.block_on(async {
        for _ in 0..20 {
            // This isn't air-tight - We recreate the whole server on each loop,
            // rather than binding 1 socket and accepting many streams like a normal socket API.
            // I can only assume Tokio is following Windows' underlying API.

            // We could instead pick an ephemeral TCP port and write that to a file,
            // akin to how Unix processes will write their PID to a file to manage long-running instances
            // But this doesn't require us to listen on TCP.

            let mut server_options = named_pipe::ServerOptions::new();
            server_options.first_pipe_instance(true);

            let path = format!(r"\\.\pipe\{}", PIPE_NAME);

            // This will allow non-admin clients to connect to us even if we're running as admin
            let mut sd = WinSec::SECURITY_DESCRIPTOR::default();
            let psd = WinSec::PSECURITY_DESCRIPTOR(&mut sd as *mut _ as *mut c_void);
            unsafe {
                WinSec::InitializeSecurityDescriptor(
                    psd,
                    windows::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION,
                )?;
                WinSec::SetSecurityDescriptorDacl(psd, true, None, false)?;
            }

            let mut sa = WinSec::SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<WinSec::SECURITY_ATTRIBUTES>()
                    .try_into()
                    .unwrap(),
                lpSecurityDescriptor: psd.0,
                bInheritHandle: false.into(),
            };
            let mut server = unsafe {
                server_options
                    .create_with_security_attributes_raw(path, &mut sa as *mut _ as *mut c_void)
            }?;

            println!("Server is bound");
            server.connect().await?;
            println!("Server got connection");

            let mut req = vec![];
            server.read_to_end(&mut req).await?;

            server.disconnect().ok();

            println!("Server read");
            let req = String::from_utf8(req)?;
            println!("{}", req);
        }

        Ok::<_, anyhow::Error>(())
    })?;

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
