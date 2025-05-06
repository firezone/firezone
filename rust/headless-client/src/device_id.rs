use anyhow::{Context as _, Result};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

pub struct DeviceId {
    pub id: String,
}

/// Returns the path of the randomly-generated Firezone device ID
///
/// e.g. `C:\ProgramData\dev.firezone.client/firezone-id.json` or
/// `/var/lib/dev.firezone.client/config/firezone-id.json`.
pub(crate) fn path() -> Result<PathBuf> {
    let path = firezone_bin_shared::known_dirs::ipc_service_config()
        .context("Failed to compute path for firezone-id file")?
        .join("firezone-id.json");
    Ok(path)
}

/// Returns the device ID without generating it
pub fn get() -> Result<DeviceId> {
    let path = path()?;
    let content = fs::read_to_string(&path).context("Failed to read file")?;
    let device_id_json = serde_json::from_str::<DeviceIdJson>(&content)
        .context("Failed to deserialize content as JSON")?;

    Ok(DeviceId {
        id: device_id_json.device_id(),
    })
}

/// Returns the device ID, generating it and saving it to disk if needed.
///
/// Per <https://github.com/firezone/firezone/issues/2697> and <https://github.com/firezone/firezone/issues/2711>,
/// clients must generate their own random IDs and persist them to disk, to handle situations like VMs where a hardware ID is not unique or not available.
///
/// Returns: The UUID as a String, suitable for sending verbatim to `connlib_client_shared::Session::connect`.
///
/// Errors: If the disk is unwritable when initially generating the ID, or unwritable when re-generating an invalid ID.
pub fn get_or_create() -> Result<DeviceId> {
    let path = path()?;
    let dir = path
        .parent()
        .context("Device ID path should always have a parent")?;
    // Make sure the dir exists, and fix its permissions so the GUI can write the
    // log filter file
    fs::create_dir_all(dir).context("Failed to create dir for firezone-id")?;
    set_dir_permissions(dir).with_context(|| {
        format!(
            "Couldn't set permissions on IPC service config dir `{}`",
            dir.display()
        )
    })?;

    // Try to read it from the disk
    if let Some(j) = fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<DeviceIdJson>(&s).ok())
    {
        let id = j.device_id();
        tracing::debug!(?id, "Loaded device ID from disk");
        // Correct permissions for #6989
        set_id_permissions(&path).context("Couldn't set permissions on Firezone ID file")?;
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
    set_id_permissions(&path).context("Couldn't set permissions on Firezone ID file")?;
    Ok(DeviceId { id })
}

#[cfg(target_os = "linux")]
fn set_dir_permissions(dir: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    // user read/write, group read/write, others nothing
    // directories need `+x` to work of course
    let perms = fs::Permissions::from_mode(0o770);
    std::fs::set_permissions(dir, perms)?;
    Ok(())
}

/// Does nothing on non-Linux systems
#[cfg(not(target_os = "linux"))]
#[expect(clippy::unnecessary_wraps)]
fn set_dir_permissions(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn set_id_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    // user read/write, group read, others nothing
    let perms = fs::Permissions::from_mode(0o640);
    std::fs::set_permissions(path, perms)?;
    Ok(())
}

/// Does nothing on non-Linux systems
#[cfg(not(target_os = "linux"))]
#[expect(clippy::unnecessary_wraps)]
fn set_id_permissions(_: &Path) -> Result<()> {
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
