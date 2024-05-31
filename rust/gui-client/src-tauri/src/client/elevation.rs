pub(crate) use imp::is_normal_user;

#[cfg(target_os = "linux")]
mod imp {
    use crate::client::gui::Error;
    use anyhow::Context;

    /// Returns true if we're running without root privileges
    ///
    /// Everything that needs root / admin powers happens in the IPC services,
    /// so for security and practicality reasons the GUIs must be non-root.
    /// (In Linux by default a root GUI app barely works at all)
    pub(crate) fn is_normal_user() -> anyhow::Result<bool, Error> {
        // Must use `eprintln` here because `tracing` won't be initialized yet.
        let user = std::env::var("USER").context("USER env var should be set")?;
        if user == "root" {
            return Ok(false);
        }

        let fz_gid = firezone_headless_client::platform::firezone_group()?.gid;
        let groups = nix::unistd::getgroups().context("`nix::unistd::getgroups`")?;
        if !groups.contains(&fz_gid) {
            return Err(Error::UserNotInFirezoneGroup);
        }

        Ok(true)
    }
}

// Stub only
#[cfg(target_os = "macos")]
mod imp {
    /// Placeholder for cargo check on macOS
    pub(crate) fn is_normal_user() -> anyhow::Result<bool, crate::client::gui::Error> {
        Ok(true)
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use crate::client::gui::Error;

    // Returns true on Windows
    ///
    /// On Windows, checking for elevation is complicated,
    /// so it just always returns true. The Windows GUI does work correctly even if
    /// elevated, so we should warn users that it doesn't need elevation, but it's
    /// not a show-stopper if they accidentally "Run as admin".
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn is_normal_user() -> anyhow::Result<bool, Error> {
        Ok(true)
    }
}
