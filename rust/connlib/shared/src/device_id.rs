use std::fs;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("Couldn't create app-specific dir in `ProgramData` or `/var/lib`: {0}")]
    CreateProgramDataDir(std::io::Error),
    #[error("Can't find well-known folder")]
    KnownFolder,
    #[error("Couldn't write device ID file: {0}")]
    WriteDeviceIdFile(std::io::Error),
}

/// Returns the device ID, generating it and saving it to disk if needed.
///
/// Per <https://github.com/firezone/firezone/issues/2697> and <https://github.com/firezone/firezone/issues/2711>,
/// clients must generate their own random IDs and persist them to disk, to handle situations like VMs where a hardware ID is not unique or not available.
///
/// Returns: The UUID as a String, suitable for sending verbatim to `connlib_client_shared::Session::connect`.
///
/// Errors: If the disk is unwritable when initially generating the ID, or unwritable when re-generating an invalid ID.
pub fn get() -> Result<String, Error> {
    let dir = imp::path().ok_or(Error::KnownFolder)?;
    let path = dir.join("firezone-id.json");

    // Try to read it from the disk
    if let Some(j) = fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<DeviceIdJson>(&s).ok())
    {
        let device_id = j.device_id();
        tracing::debug!(?device_id, "Loaded device ID from disk");
        return Ok(device_id);
    }

    // Couldn't read, it's missing or invalid, generate a new one and save it.
    let id = uuid::Uuid::new_v4();
    let j = DeviceIdJson { id };
    // TODO: This file write has the same possible problems with power loss as described here https://github.com/firezone/firezone/pull/2757#discussion_r1416374516
    // Since the device ID is random, typically only written once in the device's lifetime, and the read will error out if it's corrupted, it's low-risk.
    fs::create_dir_all(&dir).map_err(Error::CreateProgramDataDir)?;
    fs::write(
        &path,
        serde_json::to_string(&j).expect("Device ID should always be serializable"),
    )
    .map_err(Error::WriteDeviceIdFile)?;

    let device_id = j.device_id();
    tracing::debug!(?device_id, "Saved device ID to disk");
    Ok(j.device_id())
}

#[derive(serde::Deserialize, serde::Serialize)]
struct DeviceIdJson {
    id: uuid::Uuid,
}

impl DeviceIdJson {
    fn device_id(&self) -> String {
        self.id.to_string()
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
mod imp {
    pub(crate) fn path() -> Option<std::path::PathBuf> {
        panic!("This function is only implemented on Linux and Windows since those have pure-Rust clients")
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use std::path::PathBuf;
    /// `/var/lib/$BUNDLE_ID/config/firezone-id`
    ///
    /// `/var/lib` because this is the correct place to put state data not meant for users
    /// to touch, which is specific to one host and persists across reboots
    /// <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch05s08.html>
    ///
    /// `BUNDLE_ID` because we need our own subdir
    ///
    /// `config` to make how Windows has `config` and `data` both under `AppData/Local/$BUNDLE_ID`
    pub(crate) fn path() -> Option<PathBuf> {
        Some(
            PathBuf::from("/var/lib")
                .join(crate::BUNDLE_ID)
                .join("config"),
        )
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use known_folders::{get_known_folder_path, KnownFolder};

    /// e.g. `C:\ProgramData\dev.firezone.client\config`
    ///
    /// Device ID is stored here until <https://github.com/firezone/firezone/issues/3712> lands
    pub(crate) fn path() -> Option<std::path::PathBuf> {
        Some(
            get_known_folder_path(KnownFolder::ProgramData)?
                .join(crate::BUNDLE_ID)
                .join("config"),
        )
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn smoke() {
        let dir = super::imp::path().expect("should have gotten Some(path)");
        assert!(dir
            .components()
            .any(|x| x == std::path::Component::Normal("dev.firezone.client".as_ref())));
    }
}
