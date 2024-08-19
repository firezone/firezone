pub(crate) use platform::gui_check;

#[cfg(target_os = "linux")]
mod platform {
    use crate::client::gui::Error;
    use anyhow::{Context as _, Result};
    use firezone_headless_client::FIREZONE_GROUP;

    /// Returns true if all permissions are correct for the GUI to run
    ///
    /// Everything that needs root / admin powers happens in the IPC services,
    /// so for security and practicality reasons the GUIs must be non-root.
    /// (In Linux by default a root GUI app barely works at all)
    pub(crate) fn gui_check() -> Result<bool, Error> {
        let user = std::env::var("USER").context("USER env var should be set")?;
        if user == "root" {
            return Ok(false);
        }

        let fz_gid = firezone_group()?.gid;
        let groups = nix::unistd::getgroups().context("`nix::unistd::getgroups`")?;
        if !groups.contains(&fz_gid) {
            return Err(Error::UserNotInFirezoneGroup);
        }

        Ok(true)
    }

    fn firezone_group() -> Result<nix::unistd::Group> {
        let group = nix::unistd::Group::from_name(FIREZONE_GROUP)
            .context("can't get group by name")?
            .with_context(|| format!("`{FIREZONE_GROUP}` group must exist on the system"))?;
        Ok(group)
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use crate::client::gui::Error;
    use anyhow::Result;

    // Returns true on Windows
    ///
    /// On Windows, some users will run as admin, and the GUI does work correctly,
    /// unlike on Linux where most distros don't like to mix root GUI apps with X11 / Wayland.
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn gui_check() -> Result<bool, Error> {
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    // Make sure it doesn't panic
    #[test]
    fn gui_check_no_panic() {
        super::gui_check().ok();
    }
}
