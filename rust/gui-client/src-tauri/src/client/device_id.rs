use std::fs;

#[derive(thiserror::Error, Debug)]
pub(crate) enum Error {
    #[error("Couldn't create app-specific dir in `ProgramData`: {0}")]
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
pub(crate) fn device_id() -> Result<String, Error> {
    let dir = crate::client::known_dirs::device_id().ok_or(Error::KnownFolder)?;
    let path = dir.join("device_id.json");

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
