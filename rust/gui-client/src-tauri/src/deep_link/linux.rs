use anyhow::{Context, Result, bail};
use std::{io::ErrorKind, path::PathBuf, process::Command};

/// Register a URI scheme so that browser can deep link into our app for auth
///
/// Performs blocking I/O (Waits on `xdg-desktop-menu` subprocess)
pub fn register(exe: PathBuf) -> Result<()> {
    // Write `$HOME/.local/share/applications/firezone-client.desktop`
    // According to <https://wiki.archlinux.org/title/Desktop_entries>, that's the place to put
    // per-user desktop entries.
    let dir = dirs::data_local_dir()
        .context("can't figure out where to put our desktop entry")?
        .join("applications");
    std::fs::create_dir_all(&dir)?;

    // Don't use atomic writes here - If we lose power, we'll just rewrite this file on
    // the next boot anyway.
    let path = dir.join("firezone-client.desktop");
    let content = format!(
        "[Desktop Entry]
Version=1.0
Name=Firezone
Comment=Firezone GUI Client
Exec={} open-deep-link %U
Terminal=false
Type=Application
MimeType=x-scheme-handler/{}
Categories=Network;
NoDisplay=true
",
        exe.display(),
        super::FZ_SCHEME
    );
    std::fs::write(&path, content).context("failed to write desktop entry file")?;

    // Run `xdg-desktop-menu install` with that desktop file
    let xdg_desktop_menu = "xdg-desktop-menu";
    let status = Command::new(xdg_desktop_menu)
        .arg("install")
        .arg(&path)
        .status()
        .with_context(|| format!("failed to run `{xdg_desktop_menu}`"))?;
    if !status.success() {
        bail!("{xdg_desktop_menu} returned failure exit code");
    }

    // Needed for Ubuntu 22.04, see issue #4880
    let update_desktop_database = "update-desktop-database";
    match Command::new(update_desktop_database).arg(&dir).status() {
        Ok(status) => {
            if !status.success() {
                bail!("{update_desktop_database} returned failure exit code");
            }
        }
        Err(e) if e.kind() == ErrorKind::NotFound => {
            // This is not an Ubuntu machine, so this executable won't exist.
            tracing::debug!("Could not find {update_desktop_database} command, ignoring");
        }
        Err(e) => {
            return Err(e).with_context(|| format!("failed to run `{update_desktop_database}`"));
        }
    }

    Ok(())
}
