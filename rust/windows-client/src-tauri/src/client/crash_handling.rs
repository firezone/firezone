//! A module for handling crashes and writing minidump files
//!
//! Mostly copied from <https://github.com/EmbarkStudios/crash-handling/blob/main/minidumper/examples/diskwrite.rs>
//!
//! TODO: Capture crash dumps on panic.

use anyhow::{anyhow, bail, Context};
use known_folders::{get_known_folder_path, KnownFolder};
use std::{fs::File, io::Write, path::PathBuf};

const SOCKET_NAME: &str = "dev.firezone.client.crash_handler";

/// Attaches a crash handler to the client process
///
/// Returns a CrashHandler that must be kept alive until the program exits.
/// Dropping the handler will detach it.
///
/// If you need this on non-Windows, re-visit
/// <https://github.com/EmbarkStudios/crash-handling/blob/main/minidumper/examples/diskwrite.rs>
/// Linux has a special `set_ptracer` call that is handy
/// MacOS needs a special `ping` call to flush messages inside the crash handler
#[cfg(all(debug_assertions, target_os = "windows"))]
pub(crate) fn attach_handler() -> anyhow::Result<crash_handler::CrashHandler> {
    // Attempt to connect to the server
    let (client, _server) = start_server_and_connect()?;

    // SAFETY: Unsafe is required here because this will run after the program
    // has crashed. We should try to do as little as possible, basically just
    // tell the crash handler process to get our minidump and then return.
    // https://docs.rs/crash-handler/0.6.0/crash_handler/trait.CrashEvent.html#safety
    let handler = crash_handler::CrashHandler::attach(unsafe {
        crash_handler::make_crash_event(move |crash_context| {
            crash_handler::CrashEventResult::Handled(client.request_dump(crash_context).is_ok())
        })
    })
    .context("failed to attach signal handler")?;

    Ok(handler)
}

#[cfg(not(debug_assertions))]
pub(crate) fn attach_handler() -> anyhow::Result<crash_handler::CrashHandler> {
    bail!("crash handling is disabled in release builds for now");
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
    let mut server = minidumper::Server::with_name(SOCKET_NAME)?;
    let ab = std::sync::atomic::AtomicBool::new(false);
    server.run(Box::new(Handler), &ab, None)?;
    Ok(())
}

fn start_server_and_connect() -> anyhow::Result<(minidumper::Client, std::process::Child)> {
    let exe = std::env::current_exe().context("unable to find our own exe path")?;
    let mut server = None;

    for _ in 0..10 {
        // Create the crash client first so we can error out if another instance of
        // the Firezone client is already using this socket for crash handling.
        if let Ok(client) = minidumper::Client::with_name(SOCKET_NAME) {
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

/// Crash handler that runs inside the crash handler process.
///
/// The minidumper docs call this the "server" process because it's an IPC server,
/// not to be confused with network servers for Firezone itself.
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

    fn on_client_disconnected(&self, num_clients: usize) -> minidumper::LoopAction {
        if num_clients == 0 {
            minidumper::LoopAction::Exit
        } else {
            minidumper::LoopAction::Continue
        }
    }
}
