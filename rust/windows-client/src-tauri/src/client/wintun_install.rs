//! "Installs" wintun.dll at runtime by copying it into whatever folder the exe is in

use std::{fs, io};

pub(crate) struct DllBytes {
    /// Bytes embedded in the client with `include_bytes`
    bytes: &'static [u8],
    /// Expected SHA256 hash
    _expected_sha256: &'static str,
}

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("current exe path unknown")]
    CurrentExePathUnknown,
    #[error("permission denied")]
    PermissionDenied,
    #[error("platform not supported")]
    PlatformNotSupported,
    #[error("write failed: `{0:?}`")]
    WriteFailed(io::Error),
}

/// Installs the DLL alongside the current exe, if needed
/// The reason not to do it in the current working dir is that deep links may launch
/// with a current working dir of `C:\Windows\System32`
/// The reason not to do it in AppData is that learning our AppData path before Tauri
/// setup is difficult.
/// The reason not to do it in `C:\Program Files` is that running in portable mode
/// is useful for development, even though it's not supported for production.
pub(crate) fn ensure_dll() -> Result<(), Error> {
    let path = tauri_utils::platform::current_exe()
        .map_err(|_| Error::CurrentExePathUnknown)?
        .with_file_name("wintun.dll");
    tracing::debug!("wintun.dll path = {path:?}");

    let dll_bytes = get_dll_bytes().ok_or(Error::PlatformNotSupported)?;

    // TODO: Check the hash and don't just overwrite the file every time
    fs::write(&path, dll_bytes.bytes).map_err(|e| match e.kind() {
        io::ErrorKind::PermissionDenied => Error::PermissionDenied,
        _ => Error::WriteFailed(e),
    })?;
    Ok(())
}

/// Returns the platform-specific bytes of wintun.dll, or None if we don't support the compiled platform.
pub(crate) fn get_dll_bytes() -> Option<DllBytes> {
    get_platform_dll_bytes()
}

#[cfg(target_arch = "x86_64")]
fn get_platform_dll_bytes() -> Option<DllBytes> {
    Some(DllBytes {
        bytes: include_bytes!("../../../wintun/bin/amd64/wintun.dll"),
        _expected_sha256: "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce",
    })
}

#[cfg(target_arch = "aarch64")]
fn get_platform_dll_bytes() -> Option<DllBytes> {
    // wintun supports aarch64 but it's not in the Firezone repo yet
    None
}
