use anyhow::{Context as _, Result};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use std::{fs, io::Write, path::Path};

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
    // Make sure the dir exists, and fix its permissions so the GUI can write the
    // log filter file
    fs::create_dir_all(&dir).context("Failed to create dir for firezone-id")?;
    set_permissions(&dir).with_context(|| {
        format!(
            "Couldn't set permissions on IPC service config dir `{}`",
            dir.display()
        )
    })?;

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

    let content =
        serde_json::to_string(&j).context("Impossible: Failed to serialize firezone-id")?;

    let file = AtomicFile::new(&path, OverwriteBehavior::DisallowOverwrite);
    file.write(|f| f.write_all(content.as_bytes()))
        .context("Failed to write firezone-id file")?;

    let id = j.device_id();
    tracing::debug!(?id, "Saved device ID to disk");
    Ok(DeviceId { id })
}

#[cfg(target_os = "linux")]
fn set_permissions(dir: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    // user read/write, group read-write, others nothing
    // directories need `+x` to work of course
    let perms = fs::Permissions::from_mode(0o770);
    std::fs::set_permissions(dir, perms)?;
    Ok(())
}

/// Does nothing on non-Linux systems
#[cfg(not(target_os = "linux"))]
#[allow(clippy::unnecessary_wraps)]
fn set_permissions(_f: &fs::File) -> Result<()> {
    Ok(())
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
