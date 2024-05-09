pub(crate) use imp::{check, elevate};

pub(crate) const FIREZONE_GROUP: &str = "firezone-client";

#[cfg(target_os = "linux")]
mod imp {
    use crate::client::gui::Error;
    use anyhow::{Context, Result};

    #[allow(clippy::print_stderr)]
    pub(crate) fn check() -> Result<bool, Error> {
        // Must use `eprintln` here because `tracing` won't be initialized yet.
        let user = std::env::var("USER").context("USER env var should be set")?;
        if user == "root" {
            eprintln!("Firezone must run as a normal user, not with `sudo` or as root");
            return Ok(false);
        }

        let fz_gid = firezone_group()?.gid;
        let groups = nix::unistd::getgroups().context("`nix::unistd::getgroups`")?;
        if !groups.contains(&fz_gid) {
            return Err(Error::UserNotInFirezoneGroup);
        }

        Ok(true)
    }

    pub(crate) fn elevate() -> Result<()> {
        anyhow::bail!("Firezone must not elevate on Linux.");
    }

    fn firezone_group() -> Result<nix::unistd::Group> {
        let group = nix::unistd::Group::from_name(super::FIREZONE_GROUP)
            .context("can't get group by name")?
            .context("`{FIREZONE_GROUP}` group must exist on the system")?;
        Ok(group)
    }
}

// Stub only
#[cfg(target_os = "macos")]
mod imp {
    use anyhow::Result;

    pub(crate) fn check() -> Result<bool, crate::client::gui::Error> {
        Ok(true)
    }

    pub(crate) fn elevate() -> Result<()> {
        unimplemented!()
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use crate::client::{gui::Error, wintun_install};
    use anyhow::{Context, Result};
    use std::{os::windows::process::CommandExt, str::FromStr};

    /// Check if we have elevated privileges, extract wintun.dll if needed.
    ///
    /// Returns true if already elevated, false if not elevated, error if we can't be sure
    pub(crate) fn check() -> Result<bool, Error> {
        // Almost the same as the code in tun_windows.rs in connlib
        const TUNNEL_UUID: &str = "72228ef4-cb84-4ca5-a4e6-3f8636e75757";
        const TUNNEL_NAME: &str = "Firezone Elevation Check";

        let path = match wintun_install::ensure_dll() {
            Ok(x) => x,
            Err(wintun_install::Error::PermissionDenied) => return Ok(false),
            Err(e) => {
                return Err(e)
                    .context("Failed to ensure wintun.dll is installed")
                    .map_err(Error::Other)
            }
        };

        // SAFETY: Unsafe needed because we're loading a DLL from disk and it has arbitrary C code in it.
        // `wintun_install::ensure_dll` checks the hash before we get here. This protects against accidental corruption, but not against attacks. (Because of TOCTOU)
        let wintun =
            unsafe { wintun::load_from_path(path) }.context("Failed to load wintun.dll")?;
        let uuid =
            uuid::Uuid::from_str(TUNNEL_UUID).context("Impossible: Hard-coded UUID is invalid")?;

        // Wintun hides the exact Windows error, so let's assume the only way Adapter::create can fail is if we're not elevated.
        if wintun::Adapter::create(&wintun, "Firezone", TUNNEL_NAME, Some(uuid.as_u128())).is_err()
        {
            return Ok(false);
        }
        Ok(true)
    }

    pub(crate) fn elevate() -> Result<()> {
        /// Hides Powershell's console on Windows
        ///
        /// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
        const CREATE_NO_WINDOW: u32 = 0x08000000;

        let current_exe = tauri_utils::platform::current_exe()?;
        if current_exe.display().to_string().contains('\"') {
            anyhow::bail!("The exe path must not contain double quotes, it makes it hard to elevate with Powershell");
        }
        std::process::Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("-Command")
            .arg("Start-Process")
            .arg("-FilePath")
            .arg(format!(r#""{}""#, current_exe.display()))
            .arg("-Verb")
            .arg("RunAs")
            .arg("-ArgumentList")
            .arg("elevated")
            .spawn()
            .context("Failed to elevate ourselves with `RunAs`")?;
        Ok(())
    }
}
