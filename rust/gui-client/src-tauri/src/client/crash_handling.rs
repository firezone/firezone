//! A module for handling crashes and writing minidump files
//!
//! Mostly copied from <https://github.com/EmbarkStudios/crash-handling/blob/main/minidumper/examples/diskwrite.rs>
//!
//! TODO: Capture crash dumps on panic. <https://github.com/firezone/firezone/issues/3520>
//!
//! To get human-usable stack traces out of a dump, do this:
//! (Copied from <https://github.com/firezone/firezone/issues/3111#issuecomment-1887975171>)
//!
//! - Get the pdb corresponding to the client exe
//! - `cargo install dump_syms`
//! - Use dump_syms to convert the pdb to a syms file
//! - Compile `minidump-stackwalk` with PR 891 merged
//! - `minidump-stackwalker --symbols-path firezone.syms crash.dmp`

use crate::client::known_dirs;
use anyhow::{anyhow, bail, Context, Result};
use crash_handler::CrashHandler;
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
pub(crate) fn attach_handler() -> Result<CrashHandler> {
    // Attempt to connect to the server
    let (client, _server) = start_server_and_connect()?;

    // SAFETY: Unsafe is required here because this will run after the program
    // has crashed. We should try to do as little as possible, basically just
    // tell the crash handler process to get our minidump and then return.
    // https://docs.rs/crash-handler/0.6.0/crash_handler/trait.CrashEvent.html#safety
    let handler = CrashHandler::attach(unsafe {
        crash_handler::make_crash_event(move |crash_context| {
            let handled = client.request_dump(crash_context).is_ok();
            tracing::error!("Firezone crashed and wrote a crash dump.");
            crash_handler::CrashEventResult::Handled(handled)
        })
    })
    .context("failed to attach signal handler")?;

    Ok(handler)
}

/// Main function for the server process, for out-of-process crash handling.
///
/// The server process seems to be the preferred method,
/// since it's hard to run complex code in a process
/// that's already crashed and likely suffered memory corruption.
///
/// <https://jake-shadle.github.io/crash-reporting/#implementation>
/// <https://chromium.googlesource.com/breakpad/breakpad/+/master/docs/getting_started_with_breakpad.md#terminology>
pub(crate) fn server(socket_path: PathBuf) -> Result<()> {
    let mut server = minidumper::Server::with_name(&*socket_path)?;
    let ab = std::sync::atomic::AtomicBool::new(false);
    server.run(Box::new(Handler), &ab, None)?;
    Ok(())
}

fn start_server_and_connect() -> Result<(minidumper::Client, std::process::Child)> {
    let exe = std::env::current_exe().context("unable to find our own exe path")?;
    // Path of a Unix domain socket for IPC with the crash handler server
    // <https://github.com/EmbarkStudios/crash-handling/issues/10>
    let socket_path = known_dirs::runtime()
        .context("`known_dirs::runtime` failed")?
        .join("crash_handler_pipe");
    std::fs::create_dir_all(
        socket_path
            .parent()
            .context("`known_dirs::runtime` should have a parent")?,
    )
    .context("Failed to create dir for crash_handler_pipe")?;

    let mut server = None;

    // I don't understand why there's a loop here. The original was an infinite loop,
    // so I reduced it to 10 and it still worked.
    // <https://github.com/EmbarkStudios/crash-handling/blob/16c2545f2a46b6b21d1e401cfeaf0d5b9a130b08/minidumper/examples/diskwrite.rs#L72>
    for _ in 0..10 {
        // Create the crash client first so we can error out if another instance of
        // the Firezone client is already using this socket for crash handling.
        if let Ok(client) = minidumper::Client::with_name(&*socket_path) {
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
                .arg(&socket_path)
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
        let dump_path = known_dirs::logs()
            .expect("Should be able to find logs dir to put crash dump in")
            .join("last_crash.dmp");

        // `tracing` is unlikely to work inside the crash handler subprocess, so
        // just print to stderr and it may show up on the terminal. This helps in CI / local dev.
        eprintln!("Creating minidump at {}", dump_path.display());
        let Some(dir) = dump_path.parent() else {
            return Err(std::io::ErrorKind::NotFound.into());
        };
        std::fs::create_dir_all(dir)?;
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
