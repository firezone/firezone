// Invoke with `cargo run --bin gui-smoke-test`
//
// Starts up the Tunnel service and GUI app and lets them run for a bit

use anyhow::{Context as _, Result, bail};
use clap::Parser;
use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
    time::Duration,
};
use subprocess::Exec;

#[cfg(target_os = "linux")]
const FZ_GROUP: &str = "firezone-client";

const GUI_NAME: &str = "firezone-gui-client";
const TUNNEL_NAME: &str = "firezone-client-tunnel";

/// The tunnel daemon only accepts peers whose `/proc/<pid>/exe` resolves
/// to this hardcoded path. The deb/rpm package installs the GUI there;
/// the smoke test installs the cargo-built GUI to the same location so
/// the kernel reports a matching exe.
#[cfg(target_os = "linux")]
const INSTALLED_GUI_PATH: &str = "/usr/bin/firezone-client-gui";

#[cfg(target_os = "linux")]
const EXE_EXTENSION: &str = "";

#[cfg(target_os = "macos")]
const EXE_EXTENSION: &str = "";

#[cfg(target_os = "windows")]
const EXE_EXTENSION: &str = "exe";

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// Run tests that can't run in CI, like tests that need access to the staging network.
    #[arg(long)]
    manual_tests: bool,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    tracing::info!("Started logging");
    let cli = Cli::try_parse()?;

    let app = App::new()?;

    dump_syms().context("Failed to run `dump_syms`")?;

    // Run normal smoke test
    let ipc_service = tunnel_service_command().arg("run-smoke-test").start()?;
    std::thread::sleep(Duration::from_millis(500)); // Wait for tunnel service to boot to write firezone-id.json

    let gui = app
        .gui_command(&["smoke-test"])? // Disable deep links because they don't work in the headless CI environment
        .start()?;

    gui.wait()?.fz_exit_ok().context("GUI process")?;

    ipc_service.wait()?.fz_exit_ok().context("Tunnel service")?;

    // Force the GUI to crash
    let ipc_service = tunnel_service_command().arg("run-smoke-test").start()?;
    let gui = app.gui_command(&["--crash"])?.start()?;

    // Ignore exit status here since we asked the GUI to crash on purpose
    gui.wait()?;
    ipc_service.wait()?.fz_exit_ok().context("Tunnel service")?;

    // Confirm a GUI launched from a non-allowlisted path is rejected.
    #[cfg(target_os = "linux")]
    binary_allowlist_rejection_test(&app)?;

    // Launch-lock hand-off smoke test. No tunnel service or display
    // server required — the subcommand only drives the lock + GUI IPC
    // pipe.
    single_instance_test(&app)?;

    if cli.manual_tests {
        manual_tests(&app)?;
    }

    Ok(())
}

/// Launch the GUI from its cargo-built `target/debug/` path (not the
/// allowlisted `/usr/bin/firezone-client-gui`) and assert that the tunnel
/// daemon rejects the connection. The GUI exits non-zero after its first
/// read returns EOF.
#[cfg(target_os = "linux")]
fn binary_allowlist_rejection_test(app: &App) -> Result<()> {
    tracing::info!("Running peer-binary allowlist rejection smoke test");

    let ipc_service = tunnel_service_command().arg("run-smoke-test").start()?;
    std::thread::sleep(Duration::from_millis(500));

    let built_gui = gui_path()
        .canonicalize()
        .context("Couldn't canonicalize built GUI binary path")?;
    let built_gui_str = built_gui
        .to_str()
        .context("Built GUI path is not valid UTF-8")?;

    let gui = app
        .gui_command_from(built_gui_str, &["smoke-test"])?
        .start()?;
    let exit_status = gui.wait()?;
    if exit_status.success() {
        bail!(
            "GUI launched from non-allowlisted path `{}` exited 0; expected non-zero (connection rejected)",
            built_gui_str
        );
    }
    tracing::info!(
        path = built_gui_str,
        "Confirmed: tunnel rejected GUI from non-allowlisted path"
    );

    // The tunnel never accepted a valid peer, so `run-smoke-test` is
    // still in its accept loop. Kill it so the next test can bind the
    // socket.
    ipc_service
        .kill()
        .context("Failed to kill tunnel service")?;
    let _ = ipc_service.wait();

    Ok(())
}

/// Spawn two `debug single-instance` invocations back-to-back and
/// assert that:
///
/// - The first acquires the launch lock and binds the GUI IPC pipe.
/// - The second observes the lock held, connects to the pipe, sends
///   `NewInstance`, awaits `Ack`, and exits 0.
/// - The first then exits 0 after acking the second.
///
/// Both subprocesses pipe their stdout so we can also assert each
/// one identified itself with the right role marker, and a 10-second
/// `capture_timeout` keeps a hang in either side from stalling CI.
fn single_instance_test(app: &App) -> Result<()> {
    tracing::info!("Running launch-lock single-instance smoke test");

    let first = app
        .gui_command(&["debug", "single-instance"])?
        .stdout(subprocess::Redirection::Pipe)
        .start()?;

    // Give the first process a moment to acquire the lock and bind the
    // pipe before we race a second invocation against it.
    std::thread::sleep(Duration::from_millis(500));

    let second = app
        .gui_command(&["debug", "single-instance"])?
        .stdout(subprocess::Redirection::Pipe)
        .start()?;
    let second_capture = second
        .capture_timeout(Duration::from_secs(10))
        .context("Second instance timed out")?;
    second_capture
        .exit_status
        .fz_exit_ok()
        .context("Second instance")?;
    let second_stdout = second_capture.stdout_str();
    if !second_stdout.contains("second-instance:") {
        bail!(
            "second instance did not identify itself; stdout was:\n{}",
            second_stdout
        );
    }

    let first_capture = first
        .capture_timeout(Duration::from_secs(10))
        .context("First instance timed out")?;
    first_capture
        .exit_status
        .fz_exit_ok()
        .context("First instance")?;
    let first_stdout = first_capture.stdout_str();
    if !first_stdout.contains("first-instance:") {
        bail!(
            "first instance did not identify itself; stdout was:\n{}",
            first_stdout
        );
    }

    Ok(())
}

fn manual_tests(app: &App) -> Result<()> {
    // Replicate #6791
    app.gui_command(&["debug", "replicate6791"])?
        .start()?
        .wait()?;

    let ipc_service = tunnel_service_command().arg("run-smoke-test").start()?;
    let gui = app.gui_command(&["--quit-after", "10"])?.start()?;

    // Expect exit codes of 0
    gui.wait()?.fz_exit_ok().context("GUI process")?;
    ipc_service.wait()?.fz_exit_ok().context("Tunnel service")?;

    Ok(())
}

struct App {
    #[cfg(target_os = "linux")]
    username: String,
}

#[cfg(target_os = "linux")]
impl App {
    fn new() -> Result<Self> {
        // Needed to manipulate the group membership inside CI
        let username = std::env::var("USER")?;

        // Create the firezone group if needed
        Exec::cmd("sudo")
            .args([
                "groupadd", "--force", // Exit with success if the group already exists
                FZ_GROUP,
            ])
            .join()?
            .fz_exit_ok()?;

        // Add ourself to the firezone group
        Exec::cmd("sudo")
            .args(["usermod", "--append", "--groups", FZ_GROUP, &username])
            .join()?
            .fz_exit_ok()?;

        install_gui_at_canonical_path()?;

        Ok(Self { username })
    }

    // `args` can't just be appended because of the `xvfb-run` wrapper
    fn gui_command(&self, args: &[&str]) -> Result<Exec> {
        // Launch the root-installed copy so `/proc/<pid>/exe` matches the
        // allowlisted path the tunnel daemon enforces.
        self.gui_command_from(INSTALLED_GUI_PATH, args)
    }

    fn gui_command_from(&self, gui_path: &str, args: &[&str]) -> Result<Exec> {
        let args: Vec<_> = [
            "--auto-servernum",
            gui_path,
            "--no-deep-links",
            "--no-elevation-check",
        ]
        .into_iter()
        .chain(args.iter().copied())
        .collect();
        let xvfb = Exec::cmd("xvfb-run").args(&args).to_cmdline_lossy();

        tracing::debug!(?xvfb);

        let cmd = Exec::cmd("sudo") // We need `sudo` to run `su`
            .args([
                "--preserve-env",
                "su",      // We need `su` to get a login shell as ourself
                "--login", // And we need a login shell so that the group membership will take effect immediately
                "--whitelist-environment=XDG_RUNTIME_DIR",
                &self.username,
                "--command",
                &xvfb,
            ])
            .env("WEBKIT_DISABLE_COMPOSITING_MODE", "1"); // Might help with CI
        Ok(cmd)
    }
}

/// Copy the cargo-built GUI binary to the canonical `/usr/bin` path the
/// tunnel daemon expects. Without this, `/proc/<gui-pid>/exe` would point
/// at `target/debug/...` and the daemon would reject the connection.
#[cfg(target_os = "linux")]
fn install_gui_at_canonical_path() -> Result<()> {
    let built_gui = gui_path()
        .canonicalize()
        .context("Couldn't canonicalize built GUI binary path")?;
    let built_gui_str = built_gui
        .to_str()
        .context("Built GUI path is not valid UTF-8")?;
    tracing::info!(
        src = built_gui_str,
        dst = INSTALLED_GUI_PATH,
        "Installing GUI binary"
    );

    Exec::cmd("sudo")
        .args([
            "install",
            "-D",
            "-o",
            "root",
            "-g",
            "root",
            "-m",
            "0755",
            built_gui_str,
            INSTALLED_GUI_PATH,
        ])
        .join()?
        .fz_exit_ok()
        .context("Failed to install GUI binary")?;

    Ok(())
}

#[cfg(target_os = "macos")]
impl App {
    fn new() -> Result<Self> {
        Ok(Self {})
    }

    fn gui_command(&self, args: &[&str]) -> Result<Exec> {
        Ok(Exec::cmd(gui_path())
            .arg("--no-deep-links")
            .arg("--no-elevation-check")
            .args(args))
    }
}

#[cfg(target_os = "windows")]
impl App {
    fn new() -> Result<Self> {
        Ok(Self {})
    }

    // Strange signature needed to match Linux
    fn gui_command(&self, args: &[&str]) -> Result<Exec> {
        Ok(Exec::cmd(gui_path())
            .arg("--no-deep-links")
            .arg("--no-elevation-check")
            .args(args))
    }
}

// Get debug symbols from the exe / pdb
fn dump_syms() -> Result<()> {
    Exec::cmd("dump_syms")
        .args([
            debug_db_path().as_os_str(),
            gui_path().as_os_str(),
            OsStr::new("--output"),
            syms_path().as_os_str(),
        ])
        .join()?
        .fz_exit_ok()?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn debug_db_path() -> PathBuf {
    Path::new("target").join("debug").join(GUI_NAME)
}

#[cfg(target_os = "macos")]
fn debug_db_path() -> PathBuf {
    Path::new("target").join("debug").join(GUI_NAME)
}

#[cfg(target_os = "windows")]
fn debug_db_path() -> PathBuf {
    Path::new("target")
        .join("debug")
        .join("firezone_gui_client.pdb")
}

#[cfg(target_os = "linux")]
fn tunnel_service_command() -> Exec {
    Exec::cmd("sudo").args([
        "--preserve-env",
        "runuser", // The `runuser` looks redundant but CI will complain if we use `sudo` directly, not sure why
        "-u",
        "root",
        "--group",
        "firezone-client",
        "--whitelist-environment=RUST_LOG",
        tunnel_path()
            .to_str()
            .expect("IPC binary path should be valid Unicode"),
    ])
}

#[cfg(target_os = "macos")]
fn tunnel_service_command() -> Exec {
    Exec::cmd("sudo").arg(tunnel_path())
}

#[cfg(target_os = "windows")]
fn tunnel_service_command() -> Exec {
    Exec::cmd(tunnel_path())
}

// `ExitStatus::exit_ok` is nightly, so we add an equivalent here
trait ExitStatusExt {
    fn fz_exit_ok(&self) -> Result<()>;
}

impl ExitStatusExt for subprocess::ExitStatus {
    fn fz_exit_ok(&self) -> Result<()> {
        if !self.success() {
            bail!("Subprocess should exit with success");
        }
        Ok(())
    }
}

fn gui_path() -> PathBuf {
    Path::new("target")
        .join("debug")
        .join(GUI_NAME)
        .with_extension(EXE_EXTENSION)
}

fn tunnel_path() -> PathBuf {
    Path::new("target")
        .join("debug")
        .join(TUNNEL_NAME)
        .with_extension(EXE_EXTENSION)
}

fn syms_path() -> PathBuf {
    gui_path().with_extension("syms")
}
