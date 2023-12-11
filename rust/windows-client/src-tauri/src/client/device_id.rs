use ring::digest;
use tokio::fs;

/// Get the hashed device ID, generating it if it's not already on disk.
/// Per <https://github.com/firezone/firezone/issues/2697> and <https://github.com/firezone/firezone/issues/2711>,
/// clients must generate their own random IDs and persist them to disk, to handle situations like VMs where a hardware ID is not unique or not available.
///
/// Returns: The hexadecimal SHA256 of the UUID, suitable for sending directly to `connlib_client_shared::Session::connect`.
/// Errors: If the disk is unwritable when initially generating the ID, or unreadable when reading it back, or if the file is not valid JSON or doesn't match the expected schema
pub(crate) async fn hashed_device_id(
    app_local_data_dir: &crate::client::AppLocalDataDir,
) -> anyhow::Result<String> {
    let dir = app_local_data_dir.0.join("config");
    let path = dir.join("device_id.json");

    // Try to read it back from disk
    if let Some(j) = fs::read_to_string(&path)
        .await
        .ok()
        .and_then(|s| serde_json::from_str::<DeviceIdJson>(&s).ok())
    {
        tracing::debug!("device ID loaded from disk is {}", j.id.to_string());
        return Ok(j.hashed_device_id());
    }

    // Couldn't read, it's missing or invalid, generate a new one and save it.
    let id = uuid::Uuid::new_v4();
    let j = DeviceIdJson { id };
    // TODO: This file write has the same possible problems with power loss as described here https://github.com/firezone/firezone/pull/2757#discussion_r1416374516
    // Since the device ID is random, typically only written once in the device's lifetime, and the read will error out if it's corrupted, it's low-risk.
    fs::create_dir_all(&dir).await?;
    fs::write(&path, serde_json::to_string(&j)?).await?;

    tracing::debug!("device ID saved to disk is {}", j.id.to_string());
    Ok(j.hashed_device_id())
}

#[derive(serde::Deserialize, serde::Serialize)]
struct DeviceIdJson {
    id: uuid::Uuid,
}

impl DeviceIdJson {
    fn hashed_device_id(&self) -> String {
        hex::encode(digest::digest(&digest::SHA256, self.id.as_bytes()))
    }
}
