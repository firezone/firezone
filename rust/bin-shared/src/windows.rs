use anyhow::{Context as _, Result};
use known_folders::{get_known_folder_path, KnownFolder};
use ring::digest;
use std::{
    fs,
    io::Read as _,
    path::{Path, PathBuf},
};

/// Hides Powershell's console on Windows
///
/// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
/// Also used for self-elevation
pub const CREATE_NO_WINDOW: u32 = 0x08000000;

/// Returns e.g. `C:/Users/User/AppData/Local/dev.firezone.client
///
/// This is where we can save config, logs, crash dumps, etc.
/// It's per-user and doesn't roam across different PCs in the same domain.
/// It's read-write for non-elevated processes.
pub fn app_local_data_dir() -> Result<PathBuf> {
    let path = get_known_folder_path(KnownFolder::LocalAppData)
        .context("Can't find %LOCALAPPDATA% dir")?
        .join(crate::BUNDLE_ID);
    Ok(path)
}

/// Returns the absolute path for installing and loading `wintun.dll`
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
pub fn wintun_dll_path() -> Result<PathBuf> {
    let path = app_local_data_dir()?.join("data").join("wintun.dll");
    Ok(path)
}

/// Installs the DLL in %LOCALAPPDATA% and returns the DLL's absolute path
///
/// e.g. `C:\Users\User\AppData\Local\dev.firezone.client\data\wintun.dll`
/// Also verifies the SHA256 of the DLL on-disk with the expected bytes packed into the exe
pub fn ensure_dll() -> Result<PathBuf> {
    let dll_bytes = wintun_bytes();

    let path = wintun_dll_path().context("Can't compute wintun.dll path")?;
    // The DLL path should always have a parent
    let dir = path.parent().context("wintun.dll path invalid")?;
    std::fs::create_dir_all(dir).context("Can't create dirs for wintun.dll")?;

    tracing::debug!(?path, "wintun.dll path");

    // This hash check is not meant to protect against attacks. It only lets us skip redundant disk writes, and it updates the DLL if needed.
    // `tun_windows.rs` in connlib, and `elevation.rs`, rely on thia.
    if dll_already_exists(&path, &dll_bytes) {
        return Ok(path);
    }
    fs::write(&path, dll_bytes.bytes).context("Failed to write wintun.dll")?;
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

pub struct DllBytes {
    /// Bytes embedded in the client with `include_bytes`
    pub bytes: &'static [u8],
    /// Expected SHA256 hash
    pub expected_sha256: &'static str,
}

#[cfg(target_arch = "x86_64")]
pub fn wintun_bytes() -> DllBytes {
    DllBytes {
        bytes: include_bytes!("wintun/bin/amd64/wintun.dll"),
        expected_sha256: "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce",
    }
}

#[cfg(target_arch = "aarch64")]
pub fn wintun_bytes() -> DllBytes {
    DllBytes {
        bytes: include_bytes!("wintun/bin/arm64/wintun.dll"),
        expected_sha256: "f7ba89005544be9d85231a9e0d5f23b2d15b3311667e2dad0debd344918a3f80",
    }
}
