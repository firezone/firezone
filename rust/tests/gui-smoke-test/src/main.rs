// Invoke with `cargo run --bin gui-smoke-test`
//
// Starts up the IPC service and GUI app and lets them run for a bit

use anyhow::{Context as _, Result, bail};
use clap::Parser;
use std::path::{Path, PathBuf};
use subprocess::Exec;

#[cfg(target_os = "linux")]
const FZ_GROUP: &str = "firezone-client";

const GUI_NAME: &str = "firezone-gui-client";
const IPC_NAME: &str = "firezone-client-ipc";

#[cfg(target_os = "linux")]
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

    // Run normal smoke test
    let mut ipc_service = ipc_service_command().arg("run-smoke-test").popen()?;
    let mut gui = app
        .gui_command(&["smoke-test"])? // Disable deep links because they don't work in the headless CI environment
        .popen()?;

    gui.wait()?.fz_exit_ok().context("GUI process")?;

    ipc_service.wait()?.fz_exit_ok().context("IPC service")?;

    // Force the GUI to crash
    let mut ipc_service = ipc_service_command().arg("run-smoke-test").popen()?;
    let mut gui = app.gui_command(&["--crash"])?.popen()?;

    // Ignore exit status here since we asked the GUI to crash on purpose
    gui.wait()?;
    ipc_service.wait()?.fz_exit_ok().context("IPC service")?;

    if cli.manual_tests {
        manual_tests(&app)?;
    }

    Ok(())
}

fn manual_tests(app: &App) -> Result<()> {
    // Replicate #6791
    app.gui_command(&["debug", "replicate6791"])?
        .popen()?
        .wait()?;

    let mut ipc_service = ipc_service_command().arg("run-smoke-test").popen()?;
    let mut gui = app.gui_command(&["--quit-after", "10"])?.popen()?;

    // Expect exit codes of 0
    gui.wait()?.fz_exit_ok().context("GUI process")?;
    ipc_service.wait()?.fz_exit_ok().context("IPC service")?;

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
            .args(&[
                "groupadd", "--force", // Exit with success if the group already exists
                FZ_GROUP,
            ])
            .join()?
            .fz_exit_ok()?;

        // Add ourself to the firezone group
        Exec::cmd("sudo")
            .args(&["usermod", "--append", "--groups", FZ_GROUP, &username])
            .join()?
            .fz_exit_ok()?;

        Ok(Self { username })
    }

    // `args` can't just be appended because of the `xvfb-run` wrapper
    fn gui_command(&self, args: &[&str]) -> Result<Exec> {
        let gui_path = gui_path().canonicalize()?;
        let args: Vec<_> = [
            "--auto-servernum",
            gui_path
                .to_str()
                .context("Should be able to convert Path to &str")?, // For some reason `xvfb-run` doesn't just use our current working dir
            "--no-deep-links",
        ]
        .into_iter()
        .chain(args.iter().copied())
        .collect();
        let xvfb = Exec::cmd("xvfb-run").args(&args).to_cmdline_lossy();

        tracing::debug!(?xvfb);

        let cmd = Exec::cmd("sudo") // We need `sudo` to run `su`
            .args(&[
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

#[cfg(target_os = "windows")]
impl App {
    fn new() -> Result<Self> {
        Ok(Self {})
    }

    // Strange signature needed to match Linux
    fn gui_command(&self, args: &[&str]) -> Result<Exec> {
        Ok(Exec::cmd(gui_path()).arg("--no-deep-links").args(args))
    }
}

#[cfg(target_os = "linux")]
fn ipc_service_command() -> Exec {
    Exec::cmd("sudo").args(&[
        "--preserve-env",
        "runuser", // The `runuser` looks redundant but CI will complain if we use `sudo` directly, not sure why
        "-u",
        "root",
        "--group",
        "firezone-client",
        "--whitelist-environment=RUST_LOG",
        ipc_path()
            .to_str()
            .expect("IPC binary path should be valid Unicode"),
    ])
}

#[cfg(target_os = "windows")]
fn ipc_service_command() -> Exec {
    Exec::cmd(ipc_path())
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

fn ipc_path() -> PathBuf {
    Path::new("target")
        .join("debug")
        .join(IPC_NAME)
        .with_extension(EXE_EXTENSION)
}
