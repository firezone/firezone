use crate::client::wintun_install;
use std::str::FromStr;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("couldn't install wintun.dll")]
    DllInstall(#[from] wintun_install::Error),
    #[error("couldn't load wintun.dll")]
    DllLoad,
    #[error("not elevated to admin privilege")]
    NotElevated,
    #[error("UUID parse error - This should be impossible since the UUID is hard-coded")]
    Uuid,
}

/// Creates a bogus wintun tunnel to check whether we have permissions to create wintun tunnels.
/// Extracts wintun.dll if needed.
pub(crate) fn check() -> Result<(), Error> {
    // Almost the same as the code in tun_windows.rs in connlib
    const TUNNEL_UUID: &str = "72228ef4-cb84-4ca5-a4e6-3f8636e75757";
    const TUNNEL_NAME: &str = "Firezone Elevation Check";

    wintun_install::ensure_dll().map_err(|e| {
        if let wintun_install::Error::PermissionDenied = e {
            Error::NotElevated
        } else {
            Error::DllInstall(e)
        }
    })?;

    // The unsafe is here because we're loading a DLL from disk and it has arbitrary C code in it.
    // TODO: As a defense, we could verify the hash before loading it. This would protect against accidental corruption, but not against attacks. (Because of TOCTOU)
    let wintun = unsafe { wintun::load_from_path("./wintun.dll") }.map_err(|_| Error::DllLoad)?;
    let uuid = uuid::Uuid::from_str(TUNNEL_UUID).map_err(|_| Error::Uuid)?;

    // Wintun hides the exact Windows error, so let's assume the only way Adapter::create can fail is if we're not elevated.
    wintun::Adapter::create(&wintun, "Firezone", TUNNEL_NAME, Some(uuid.as_u128()))
        .map_err(|_| Error::NotElevated)?;
    Ok(())
}
