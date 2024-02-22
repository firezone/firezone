//! "Installs" wintun.dll at runtime by copying it into whatever folder the exe is in

use connlib_shared::windows::wintun_dll_path;
use ring::digest;
use std::{
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
};

struct DllBytes {
    /// Bytes embedded in the client with `include_bytes`
    bytes: &'static [u8],
    /// Expected SHA256 hash
    expected_sha256: &'static str,
}

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("Can't compute path where wintun.dll should be installed")]
    CantComputeWintunPath,
    #[error("create_dir_all failed")]
    CreateDirAll,
    #[error("Computed DLL path is invalid")]
    DllPathInvalid,
    #[error("permission denied")]
    PermissionDenied,
    #[error("platform not supported")]
    PlatformNotSupported,
    #[error("write failed: `{0:?}`")]
    WriteFailed(io::Error),
}

/// Installs the DLL in %LOCALAPPDATA% and returns the DLL's absolute path
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
/// Also verifies the SHA256 of the DLL on-disk with the expected bytes packed into the exe
pub(crate) fn ensure_dll() -> Result<PathBuf, Error> {
    let dll_bytes = get_dll_bytes().ok_or(Error::PlatformNotSupported)?;

    let path = wintun_dll_path().map_err(|_| Error::CantComputeWintunPath)?;
    // The DLL path should always have a parent
    let dir = path.parent().ok_or(Error::DllPathInvalid)?;
    std::fs::create_dir_all(dir).map_err(|_| Error::CreateDirAll)?;

    // TODO: This log never shows up because `tracing` isn't started when we install wintun.dll
    tracing::info!(?path, "wintun.dll path");

    // This hash check is not meant to protect against attacks. It only lets us skip redundant disk writes, and it updates the DLL if needed.
    // `tun_windows.rs` in connlib, and `elevation.rs`, rely on thia.
    if !dll_already_exists(&path, &dll_bytes) {
        fs::write(&path, dll_bytes.bytes).map_err(|e| match e.kind() {
            io::ErrorKind::PermissionDenied => Error::PermissionDenied,
            _ => Error::WriteFailed(e),
        })?;
    }
    Ok(path)
}

fn dll_already_exists(path: &Path, dll_bytes: &DllBytes) -> bool {
    let mut f = match fs::File::open(path) {
        Err(_) => return false,
        Ok(x) => x,
    };

    let actual_len = usize::try_from(f.metadata().unwrap().len()).unwrap();
    let expected_len = dll_bytes.bytes.len();
    // If the dll is 100 MB instead of 0.5 MB, this allows us to skip a 100 MB read
    if actual_len != expected_len {
        return false;
    }

    let mut buf = vec![0u8; expected_len];
    if f.read_exact(&mut buf).is_err() {
        return false;
    }

    let expected = ring::test::from_hex(dll_bytes.expected_sha256).unwrap();
    let actual = digest::digest(&digest::SHA256, &buf);
    expected == actual.as_ref()
}

/// Returns the platform-specific bytes of wintun.dll, or None if we don't support the compiled platform.
fn get_dll_bytes() -> Option<DllBytes> {
    get_platform_dll_bytes()
}

#[cfg(target_arch = "x86_64")]
fn get_platform_dll_bytes() -> Option<DllBytes> {
    Some(DllBytes {
        bytes: include_bytes!("../../../wintun/bin/amd64/wintun.dll"),
        expected_sha256: "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce",
    })
}

#[cfg(target_arch = "aarch64")]
fn get_platform_dll_bytes() -> Option<DllBytes> {
    Some(DllBytes {
        bytes: include_bytes!("../../../wintun/bin/arm64/wintun.dll"),
        expected_sha256: "f7ba89005544be9d85231a9e0d5f23b2d15b3311667e2dad0debd344918a3f80",
    })
}
