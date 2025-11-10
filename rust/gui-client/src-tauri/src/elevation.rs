pub use platform::gui_check;

#[cfg(target_os = "linux")]
mod platform {
    use crate::FIREZONE_CLIENT_GROUP;
    use anyhow::{Context as _, Result};

    /// Returns true if all permissions are correct for the GUI to run
    ///
    /// Everything that needs root / admin powers happens in the Tunnel services,
    /// so for security and practicality reasons the GUIs must be non-root.
    /// (In Linux by default a root GUI app barely works at all)
    pub fn gui_check() -> Result<bool, Error> {
        let user = std::env::var("USER").context("Unable to determine current user")?;
        if user == "root" {
            return Ok(false);
        }

        let fz_gid = crate::firezone_client_group()?.gid;
        let groups = nix::unistd::getgroups().context("Unable to read groups of current user")?;
        if !groups.contains(&fz_gid) {
            return Err(Error::UserNotInFirezoneGroup);
        }

        Ok(true)
    }

    #[derive(Debug, thiserror::Error)]
    pub enum Error {
        #[error("User is not part of {FIREZONE_CLIENT_GROUP} group")]
        UserNotInFirezoneGroup,
        #[error(transparent)]
        Other(#[from] anyhow::Error),
    }

    impl Error {
        pub fn user_friendly_msg(&self) -> String {
            match self {
                Error::UserNotInFirezoneGroup => {
                    format!(
                        "You are not a member of the group `{FIREZONE_CLIENT_GROUP}`. If you have just installed Firezone for the first time, you need to reboot your computer for membership changes to take effect."
                    )
                }
                Error::Other(e) => format!("Failed to determine group ownership: {e:#}"),
            }
        }
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use anyhow::Result;

    // Returns true on Windows
    ///
    /// On Windows, some users will run as admin, and the GUI does work correctly,
    /// unlike on Linux where most distros don't like to mix root GUI apps with X11 / Wayland.
    #[expect(clippy::unnecessary_wraps)]
    pub fn gui_check() -> Result<bool, Error> {
        Ok(true)
    }

    #[derive(Debug, Clone, Copy, thiserror::Error)]
    pub enum Error {}
}

#[cfg(target_os = "macos")]
mod platform {
    use anyhow::Result;

    #[expect(clippy::unnecessary_wraps)]
    pub fn gui_check() -> Result<bool, Error> {
        Ok(true)
    }

    #[derive(Debug, Clone, Copy, thiserror::Error)]
    pub enum Error {}
}

#[cfg(test)]
mod tests {
    // Make sure it doesn't panic
    #[test]
    fn gui_check_no_panic() {
        super::gui_check().ok();
    }
}
