// Invoke with `cargo run --bin gui-smoke-test`

use anyhow::{bail, Context as _, Result};
use std::{env, path::Path, process};
use subprocess::Exec;

#[cfg(target_os = "linux")]
const FZ_GROUP: &str = "firezone-client";

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let app = App::new()?;

    build_binary("firezone-gui-client")?;
    build_binary("firezone-client-ipc")?;

    let mut ipc_service = ipc_service_command().arg("run-smoke-test").spawn()?;

    let mut gui = app.gui_command()?.popen()?;

    gui.wait()?;
    ipc_service.wait()?;
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
        let username = env::var("USER")?;

        // Create the firezone group if needed
        process::Command::new("sudo")
            .args([
                "groupadd", "--force", // Exit with success if the group already exists
                FZ_GROUP,
            ])
            .status()?
            .fz_exit_ok()?;

        // Add ourself to the firezone group
        process::Command::new("sudo")
            .args(["usermod", "--append", "--groups", FZ_GROUP, &username])
            .status()?
            .fz_exit_ok()?;

        Ok(Self { username })
    }
}

#[cfg(target_os = "windows")]
impl App {
    fn new() -> Result<Self> {
        Ok(Self {})
    }
}

// `ExitStatus::exit_ok` is nightly, so we add an equivalent here
trait ExitStatusExt {
    fn fz_exit_ok(&self) -> Result<()>;
}

impl ExitStatusExt for process::ExitStatus {
    fn fz_exit_ok(&self) -> Result<()> {
        if !self.success() {
            bail!("Subprocess should exit with success");
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
impl App {
    fn gui_command(&self) -> Result<Exec> {
        let xvfb = Exec::cmd("xvfb-run")
            .args(&[
                "--auto-servernum",
                Path::new("target/debug/firezone-gui-client")
                    .canonicalize()?
                    .to_str()
                    .context("Should be able to convert Path to &str")?, // For some reason `xvfb-run` doesn't just use our current working dir
                "--no-deep-links", // Disable deep links since the headless CI won't allow them
                "smoke-test",
            ])
            .to_cmdline_lossy();

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
    fn gui_command(&self) -> Result<Exec> {
        Ok(Exec::cmd("target/debug/firezone-gui-client"))
    }
}

fn build_binary(name: &str) -> Result<()> {
    process::Command::new("cargo")
        .args(["build", "--bin", name])
        .status()?
        .fz_exit_ok()?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn ipc_service_command() -> process::Command {
    let mut cmd = process::Command::new("sudo");
    cmd.args(["--preserve-env", "target/debug/firezone-client-ipc"]);
    cmd
}

#[cfg(target_os = "windows")]
fn ipc_service_command() -> process::Command {
    process::Command::build("target/debug/firezone-client-ipc")
}
