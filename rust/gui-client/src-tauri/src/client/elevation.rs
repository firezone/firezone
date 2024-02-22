#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[cfg(target_os = "windows")]
    #[error("couldn't install wintun.dll")]
    DllInstall(#[from] wintun_install::Error),
    #[cfg(target_os = "windows")]
    #[error("couldn't load wintun.dll")]
    DllLoad,
    #[error("UUID parse error - This should be impossible since the UUID is hard-coded")]
    Uuid,
}

pub(crate) use imp::{check, elevate};

#[cfg(target_os = "linux")]
mod imp {
    use super::Error;

    pub(crate) fn check() -> Result<bool, Error> {
        // TODO
        Ok(true)
    }

    pub(crate) fn elevate() -> Result<(), Error> {
        todo!()
    }
}

/// Creates a bogus wintun tunnel to check whether we have permissions to create wintun tunnels.
/// Extracts wintun.dll if needed.
///
/// Returns true if already elevated, false if not elevated, error if we can't be sure
#[cfg(target_os = "windows")]
mod imp {
    use crate::client::wintun_install;
    use std::str::FromStr;
    use super::Error;

    pub(crate) fn check() -> Result<bool, Error> {
        // Almost the same as the code in tun_windows.rs in connlib
        const TUNNEL_UUID: &str = "72228ef4-cb84-4ca5-a4e6-3f8636e75757";
        const TUNNEL_NAME: &str = "Firezone Elevation Check";

        let path = match wintun_install::ensure_dll() {
            Ok(x) => x,
            Err(wintun_install::Error::PermissionDenied) => return Ok(false),
            Err(e) => return Err(Error::DllInstall(e)),
        };

        // SAFETY: Unsafe needed because we're loading a DLL from disk and it has arbitrary C code in it.
        // `wintun_install::ensure_dll` checks the hash before we get here. This protects against accidental corruption, but not against attacks. (Because of TOCTOU)
        let wintun = unsafe { wintun::load_from_path(path) }.map_err(|_| Error::DllLoad)?;
        let uuid = uuid::Uuid::from_str(TUNNEL_UUID).map_err(|_| Error::Uuid)?;

        // Wintun hides the exact Windows error, so let's assume the only way Adapter::create can fail is if we're not elevated.
        if wintun::Adapter::create(&wintun, "Firezone", TUNNEL_NAME, Some(uuid.as_u128())).is_err() {
            return Ok(false);
        }
        Ok(true)
    }

    pub(crate) fn elevate() -> Result<(), Error> {
        let current_exe = tauri_utils::platform::current_exe()?;
        if current_exe.display().to_string().contains('\"') {
            anyhow::bail!("The exe path must not contain double quotes, it makes it hard to elevate with Powershell");
        }
        std::proces::Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("-Command")
            .arg("Start-Process")
            .arg("-FilePath")
            .arg(format!(r#""{}""#, current_exe.display()))
            .arg("-Verb")
            .arg("RunAs")
            .arg("-ArgumentList")
            .arg("elevated")
            .spawn()?;
        Ok(())
    }
}
