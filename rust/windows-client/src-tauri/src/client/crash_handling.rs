//! A module for handling crashes and writing minidump files
//!
//! Mostly copied from <https://github.com/EmbarkStudios/crash-handling/blob/main/minidumper/examples/diskwrite.rs>
//!
//! TODO: Capture crash dumps on panic.

use crate::client::{logging, BUNDLE_ID};
use anyhow::{anyhow, bail, Context, Result};
use known_folders::{get_known_folder_path, KnownFolder};
use parking_lot::Mutex;
use std::{fs::File, io::Write, path::PathBuf};

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
pub(crate) fn attach_handler(crash_dump_name: &str) -> Result<crash_handler::CrashHandler> {
    // Can't have any slashes at all, apparently.
    let pipe_id = format!(r"{BUNDLE_ID}.crash.{}", crash_dump_name);
    // Attempt to connect to the server
    let (client, _server) = start_server_and_connect(&pipe_id)?;

    client.send_message(KIND_SET_FILENAME, crash_dump_name.as_bytes())?;

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
pub(crate) fn attach_handler(_crash_dump_name: &str) -> Result<crash_handler::CrashHandler> {
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
pub(crate) fn server(pipe_id: &str) -> Result<()> {
    // We don't have a place to log things from the crash handler, but at least
    // in debug mode they can go to the parent's stderr/stdout
    tracing_subscriber::fmt::try_init().ok();
    tracing::info!(?pipe_id, "crash_handling::server");

    let mut server = minidumper::Server::with_name(pipe_id)?;
    let ab = std::sync::atomic::AtomicBool::new(false);
    server.run(Box::<Handler>::default(), &ab, None)?;
    Ok(())
}

fn start_server_and_connect(
    pipe_id: &str,
) -> anyhow::Result<(minidumper::Client, std::process::Child)> {
    tracing::info!(?pipe_id, "crash_handling::start_server_and_connect");

    let exe = std::env::current_exe().context("unable to find our own exe path")?;
    let mut server = None;

    // I don't understand why there's a loop here. The original was an infinite loop,
    // so I reduced it to 10 and it still worked.
    // <https://github.com/EmbarkStudios/crash-handling/blob/16c2545f2a46b6b21d1e401cfeaf0d5b9a130b08/minidumper/examples/diskwrite.rs#L72>
    for _ in 0..10 {
        // Create the crash client first so we can error out if another instance of
        // the Firezone client is already using this socket for crash handling.
        if let Ok(client) = minidumper::Client::with_name(pipe_id) {
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
                .arg(pipe_id)
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
struct Handler {
    crash_dump_name: Mutex<String>,
}

impl Default for Handler {
    fn default() -> Self {
        Self {
            crash_dump_name: Mutex::new(logging::UNKNOWN_CRASH_DUMP.into()),
        }
    }
}

impl minidumper::ServerHandler for Handler {
    /// Called when a crash has been received and a backing file needs to be
    /// created to store it.
    fn create_minidump_file(&self) -> Result<(File, PathBuf), std::io::Error> {
        let crash_dump_name = self.crash_dump_name.lock().clone();

        let dump_path = get_known_folder_path(KnownFolder::LocalAppData)
            .expect("should be able to find AppData/Local")
            .join(BUNDLE_ID)
            .join("data")
            .join(crash_dump_name);

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
        let message = String::from_utf8(buffer).expect("message should be valid UTF-8");
        tracing::info!(?kind, ?message, "on_message");

        if kind == KIND_SET_FILENAME {
            *self.crash_dump_name.lock() = message;
        }
    }

    fn on_client_disconnected(&self, num_clients: usize) -> minidumper::LoopAction {
        if num_clients == 0 {
            minidumper::LoopAction::Exit
        } else {
            minidumper::LoopAction::Continue
        }
    }
}

const KIND_SET_FILENAME: u32 = 0;
