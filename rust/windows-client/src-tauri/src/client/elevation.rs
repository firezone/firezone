use crate::client::wintun_install;
use std::str::FromStr;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("couldn't install wintun.dll")]
    DllInstall(#[from] wintun_install::Error),
    #[error("couldn't load wintun.dll")]
    DllLoad,
    #[error("UUID parse error - This should be impossible since the UUID is hard-coded")]
    Uuid,
}

/// Creates a bogus wintun tunnel to check whether we have permissions to create wintun tunnels.
/// Extracts wintun.dll if needed.
///
/// Returns true if already elevated, false if not elevated, error if we can't be sure
#[tracing::instrument]
pub(crate) fn check() -> Result<bool, Error> {
    // Almost the same as the code in tun_windows.rs in connlib
    const TUNNEL_UUID: &str = "72228ef4-cb84-4ca5-a4e6-3f8636e75757";
    const TUNNEL_NAME: &str = "Firezone Elevation Check";

    let path = match wintun_install::ensure_dll() {
        Ok(x) => x,
        Err(wintun_install::Error::PermissionDenied) => return Ok(false),
        Err(e) => return Err(Error::DllInstall(e)),
    };
    tracing::info!(?path, "wintun.dll path");

    // The unsafe is here because we're loading a DLL from disk and it has arbitrary C code in it.
    // TODO: As a defense, we could verify the hash before loading it. This would protect against accidental corruption, but not against attacks. (Because of TOCTOU)
    let wintun = unsafe { wintun::load_from_path(r".\wintun.dll") }.map_err(|_| Error::DllLoad)?;
    let uuid = uuid::Uuid::from_str(TUNNEL_UUID).map_err(|_| Error::Uuid)?;

    // Wintun hides the exact Windows error, so let's assume the only way Adapter::create can fail is if we're not elevated.
    if wintun::Adapter::create(&wintun, "Firezone", TUNNEL_NAME, Some(uuid.as_u128())).is_err() {
        return Ok(false);
    }
    Ok(true)
}
