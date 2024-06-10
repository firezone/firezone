use anyhow::{Context, Result};
use std::fs;
use std::io::Write;

pub(crate) struct DeviceId {
    pub(crate) id: String,
}

/// Returns the device ID, generating it and saving it to disk if needed.
///
/// Per <https://github.com/firezone/firezone/issues/2697> and <https://github.com/firezone/firezone/issues/2711>,
/// clients must generate their own random IDs and persist them to disk, to handle situations like VMs where a hardware ID is not unique or not available.
///
/// Returns: The UUID as a String, suitable for sending verbatim to `connlib_client_shared::Session::connect`.
///
/// Errors: If the disk is unwritable when initially generating the ID, or unwritable when re-generating an invalid ID.
pub(crate) fn get_or_create() -> Result<DeviceId> {
    let dir = crate::known_dirs::ipc_service_config()
        .context("Failed to compute path for firezone-id file")?;
    let path = dir.join("firezone-id.json");

    // Try to read it from the disk
    if let Some(j) = fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<DeviceIdJson>(&s).ok())
    {
        let id = j.device_id();
        tracing::debug!(?id, "Loaded device ID from disk");
        return Ok(DeviceId { id });
    }

    // Couldn't read, it's missing or invalid, generate a new one and save it.
    let id = uuid::Uuid::new_v4();
    let j = DeviceIdJson { id };
    // TODO: This file write has the same possible problems with power loss as described here https://github.com/firezone/firezone/pull/2757#discussion_r1416374516
    // Since the device ID is random, typically only written once in the device's lifetime, and the read will error out if it's corrupted, it's low-risk.
    fs::create_dir_all(&dir).context("Failed to create dir for firezone-id")?;

    let content =
        serde_json::to_string(&j).context("Impossible: Failed to serialize firezone-id")?;

    let file =
        atomicwrites::AtomicFile::new(&path, atomicwrites::OverwriteBehavior::DisallowOverwrite);
    file.write(|f| f.write_all(content.as_bytes()))
        .context("Failed to write firezone-id file")?;

    let id = j.device_id();
    tracing::debug!(?id, "Saved device ID to disk");
    Ok(DeviceId { id })
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
