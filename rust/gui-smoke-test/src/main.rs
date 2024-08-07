// Invoke with `cargo run --bin gui-smoke-test`
//
// Starts up the IPC service and GUI app and lets them run for a bit

use anyhow::{bail, Context as _, Result};
use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
};
use subprocess::Exec;

#[cfg(target_os = "linux")]
const FZ_GROUP: &str = "firezone-client";

const GUI_NAME: &str = "firezone-gui-client";
const IPC_NAME: &str = "firezone-client-ipc";

#[cfg(target_os = "linux")]
const EXE_EXTENSION: &str = "";

#[cfg(target_os = "windows")]
const EXE_EXTENSION: &str = "exe";

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let app = App::new()?;

    dump_syms()?;

    // Run normal smoke test
    let mut ipc_service = ipc_service_command().arg("run-smoke-test").popen()?;
    let mut gui = app
        .gui_command(&["smoke-test"])? // Disable deep links because they don't work in the headless CI environment
        .popen()?;

    gui.wait()?.fz_exit_ok().context("GUI process")?;
    ipc_service.wait()?.fz_exit_ok().context("IPC service")?;

    // Force the GUI to crash and then try to read the crash dump
    let mut ipc_service = ipc_service_command().arg("run-smoke-test").popen()?;
    let mut gui = app.gui_command(&["--crash"])?.popen()?;

    // Ignore exit status here since we asked the GUI to crash on purpose
    gui.wait()?;
    ipc_service.wait()?.fz_exit_ok().context("IPC service")?;

    app.check_crash_dump()?;

    Ok(())
}

struct App {
    #[cfg(target_os = "linux")]
    username: String,
}

impl App {
    fn check_crash_dump(&self) -> Result<()> {
        Exec::cmd("minidump-stackwalk")
            .args(&[
                OsStr::new("--symbols-path"),
                syms_path().as_os_str(),
                self.crash_dump_path().as_os_str(),
            ])
            .join()?
            .fz_exit_ok()?;
        Ok(())
    }
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

    fn crash_dump_path(&self) -> PathBuf {
        Path::new("/home")
            .join(&self.username)
            .join(".cache/dev.firezone.client/data/logs/last_crash.dmp")
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

    fn crash_dump_path(&self) -> PathBuf {
        let app_data = std::env::var("LOCALAPPDATA").expect("$LOCALAPPDATA should be set");
        PathBuf::from(app_data)
            .join("dev.firezone.client/data/logs")
            .join("last_crash.dmp")
    }

    // Strange signature needed to match Linux
    fn gui_command(&self, args: &[&str]) -> Result<Exec> {
        Ok(Exec::cmd(gui_path()).arg("--no-deep-links").args(args))
    }
}

// Get debug symbols from the exe / pdb
fn dump_syms() -> Result<()> {
    Exec::cmd("dump_syms")
        .args(&[
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

#[cfg(target_os = "windows")]
fn debug_db_path() -> PathBuf {
    Path::new("target")
        .join("debug")
        .join("firezone_gui_client.pdb")
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

fn syms_path() -> PathBuf {
    gui_path().with_extension("syms")
}
