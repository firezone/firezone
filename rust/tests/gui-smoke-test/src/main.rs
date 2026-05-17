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

/// The tunnel daemon allowlists peers by canonical executable path, and the
/// path must live on a root-owned, non-user-writable filesystem (`target_safe`
/// in `peer_check.rs` walks every ancestor). `/usr/local/*` is `0o775
/// root:staff` on Ubuntu runners and fails the check; `/usr/bin` is the
/// canonical `0o755 root:root` directory. The `-smoke` suffix avoids
/// clashing with any deb-installed firezone-client-gui on dev machines.
#[cfg(target_os = "linux")]
const INSTALLED_GUI_PATH: &str = "/usr/bin/firezone-client-gui-smoke";
#[cfg(target_os = "linux")]
const ALLOWLIST_PATH: &str = "/etc/firezone/allowed-clients.conf";

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

    // Launch-lock hand-off smoke test. No tunnel service or display
    // server required — the subcommand only drives the lock + GUI IPC
    // pipe.
    single_instance_test(&app)?;

    if cli.manual_tests {
        manual_tests(&app)?;
    }

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

        install_gui_for_allowlist()?;

        Ok(Self { username })
    }

    // `args` can't just be appended because of the `xvfb-run` wrapper
    fn gui_command(&self, args: &[&str]) -> Result<Exec> {
        let args: Vec<_> = [
            "--auto-servernum",
            // Launch the root-installed copy so `/proc/<pid>/exe` matches
            // the allowlisted path the tunnel daemon enforces.
            INSTALLED_GUI_PATH,
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

/// Copy the cargo-built GUI binary to a root-owned location and write the
/// peer-allowlist file the tunnel daemon reads.
///
/// Both files must be owned by `root:root` and have no group/world-writable
/// ancestors — see `target_safe` in `peer_check.rs`. Logs every step so a
/// CI failure here is debuggable without re-running.
#[cfg(target_os = "linux")]
fn install_gui_for_allowlist() -> Result<()> {
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
        .context("Failed to install GUI binary for allowlist")?;

    let tempdir = tempfile::tempdir().context("Couldn't create tempdir")?;
    let staged_allowlist = tempdir.path().join("allowed-clients.conf");
    std::fs::write(&staged_allowlist, format!("{INSTALLED_GUI_PATH}\n"))
        .context("Couldn't write staged allowlist")?;
    let staged_str = staged_allowlist
        .to_str()
        .context("Staged allowlist path is not valid UTF-8")?;
    tracing::info!(
        src = staged_str,
        dst = ALLOWLIST_PATH,
        "Installing allowlist"
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
            "0644",
            staged_str,
            ALLOWLIST_PATH,
        ])
        .join()?
        .fz_exit_ok()
        .context("Failed to install allowlist file")?;

    // Diagnostic: print mode/ownership of the installed path and each
    // ancestor so CI logs show whether `target_safe` will accept the entry.
    for path in [
        INSTALLED_GUI_PATH,
        "/usr/bin",
        "/usr",
        "/",
        ALLOWLIST_PATH,
        "/etc/firezone",
        "/etc",
    ] {
        Exec::cmd("stat")
            .args(["-c", "%a %U:%G %n", path])
            .join()?
            .fz_exit_ok()
            .with_context(|| format!("stat {path}"))?;
    }

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
