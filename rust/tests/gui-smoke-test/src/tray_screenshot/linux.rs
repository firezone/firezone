use anyhow::{Context as _, Result, ensure};
use std::path::Path;
use subprocess::Exec;

/// Photographs the native GNOME AppIndicator menu in an isolated desktop session.
pub(crate) fn capture(submenu: &str, output: &Path) -> Result<()> {
    let gui = crate::gui_path()
        .canonicalize()
        .context("Failed to locate the built GUI client")?;

    // The driver is embedded so the smoke-test binary does not depend on a source checkout.
    let status = Exec::cmd("dbus-run-session")
        .args(["--", "/usr/bin/python3", "-c", include_str!("linux.py")])
        .arg("--client")
        .arg(gui)
        .arg("--submenu")
        .arg(submenu)
        .arg("--output")
        .arg(output)
        .arg("--diagnostics")
        .arg("target/gui-smoke-test/gnome-tray")
        .join()
        .context("Failed to run the GNOME tray screenshot driver")?;
    ensure!(status.success(), "GNOME tray screenshot failed: {status:?}");

    Ok(())
}
