//! A module for handling crashes and writing minidump files
//!
//! Mostly copied from <https://github.com/EmbarkStudios/crash-handling/blob/main/minidumper/examples/diskwrite.rs>

use anyhow::{anyhow, bail, Context};
use known_folders::{get_known_folder_path, KnownFolder};
use std::{fs::File, io::Write, path::PathBuf};

const SOCKET_NAME: &str = "dev.firezone.client.crash_handler";

use minidumper::{Client, Server};

/// Attaches a crash handler to the client process
///
/// Returns a CrashHandler that must be kept alive until the program exits.
/// Dropping the handler will detach it.
#[cfg(debug_assertions)]
pub(crate) fn attach_handler() -> anyhow::Result<crash_handler::CrashHandler> {
    attach_handler_inner()
}

#[cfg(not(debug_assertions))]
pub(crate) fn attach_handler() -> anyhow::Result<crash_handler::CrashHandler> {
    // Prevent cargo from complaining
    if false {
        return attach_handler_inner();
    }
    bail!("crash handling is disabled in release builds for now");
}

fn attach_handler_inner() -> anyhow::Result<crash_handler::CrashHandler> {
    // Attempt to connect to the server
    let (client, _server) = connect()?;

    // Not sure what this does, but the sample code has it.
    client.send_message(1, "mistakes will be made")?;

    #[allow(unsafe_code)]
    let handler = crash_handler::CrashHandler::attach(unsafe {
        crash_handler::make_crash_event(move |crash_context: &crash_handler::CrashContext| {
            // Before we request the crash, send a message to the server
            client.send_message(2, "mistakes were made").unwrap();

            // Send a ping to the server, this ensures that all messages that have been sent
            // are "flushed" before the crash event is sent. This is only really useful
            // on macos where messages and crash events are sent via different, unsynchronized,
            // methods which can result in the crash event closing the server before
            // the non-crash messages are received/processed
            client.ping().unwrap();

            crash_handler::CrashEventResult::Handled(client.request_dump(crash_context).is_ok())
        })
    })
    .context("failed to attach signal handler")?;

    // On linux we can explicitly allow only the server process to inspect the
    // process we are monitoring (this one) for crashes
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        handler.set_ptracer(Some(_server.id()));
    }

    Ok(handler)
}

fn connect() -> anyhow::Result<(Client, std::process::Child)> {
    let exe = std::env::current_exe().context("unable to find our own exe path")?;
    let mut server = None;

    for _ in 0..10 {
        // Create the crash client first so we can error out if another instance of
        // the Firezone client is already using this socket for crash handling.
        if let Ok(client) = Client::with_name(SOCKET_NAME) {
            return Ok((
                client,
                server.ok_or_else(|| {
                    anyhow!(
                        "should be impossible to make a client if we didn't make the server yet"
                    )
                })?,
            ));
        }

        server = Some(
            std::process::Command::new(&exe)
                .arg("crash-handler-server")
                .spawn()
                .context("unable to spawn server process")?,
        );

        // Give it time to start
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    bail!("Couldn't set up crash handler server")
}

/// Main function for the server process, for out-of-process crash handling.
///
/// The server process seems to be the preferred method,
/// since it's hard to run complex code in a process
/// that's already crashed and likely suffered memory corruption.
///
/// <https://jake-shadle.github.io/crash-reporting/#implementation>
/// <https://chromium.googlesource.com/breakpad/breakpad/+/master/docs/getting_started_with_breakpad.md#terminology>
pub(crate) fn server() -> anyhow::Result<()> {
    let mut server = Server::with_name(SOCKET_NAME)?;

    let ab = std::sync::atomic::AtomicBool::new(false);

    struct Handler;

    impl minidumper::ServerHandler for Handler {
        /// Called when a crash has been received and a backing file needs to be
        /// created to store it.
        fn create_minidump_file(&self) -> Result<(File, PathBuf), std::io::Error> {
            let dump_path = get_known_folder_path(KnownFolder::ProgramData)
                .expect("should be able to find C:/ProgramData")
                .join(crate::client::gui::BUNDLE_ID)
                .join("dumps")
                .join("last_crash.dmp");

            if let Some(dir) = dump_path.parent() {
                if !dir.try_exists()? {
                    std::fs::create_dir_all(dir)?;
                }
            }
            let file = File::create(&dump_path)?;
            Ok((file, dump_path))
        }

        /// Called when a crash has been fully written as a minidump to the provided
        /// file. Also returns the full heap buffer as well.
        fn on_minidump_created(
            &self,
            result: Result<minidumper::MinidumpBinary, minidumper::Error>,
        ) -> minidumper::LoopAction {
            match result {
                Ok(mut md_bin) => {
                    let _ = md_bin.file.flush();
                    tracing::info!("wrote minidump to disk");
                }
                Err(e) => {
                    tracing::error!("failed to write minidump: {:#}", e);
                }
            }

            // Tells the server to exit, which will in turn exit the process
            minidumper::LoopAction::Exit
        }

        fn on_message(&self, kind: u32, buffer: Vec<u8>) {
            tracing::info!(
                "kind: {kind}, message: {}",
                String::from_utf8(buffer).expect("message should be valid UTF-8")
            );
        }
    }

    server.run(Box::new(Handler), &ab, None)?;
    Ok(())
}
