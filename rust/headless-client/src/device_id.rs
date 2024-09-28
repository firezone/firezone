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
    let path = crate::known_dirs::ipc_service_config()
        .context("Failed to compute path for firezone-id file")?
        .join("firezone-id.json");
    Ok(path)
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
    if let Ok(data) = smbioslib::table_load_from_device() {
        if let Some(id) = data.find_map(|sys_info: smbioslib::SMBiosSystemInformation| {
            sys_info.serial_number().to_utf8_lossy()
        }) {
            // Some systems such as system76(https://github.com/system76/firmware-open/issues/432) might have the default serial nubmer
            // set to smbios which is 123456789 due to limitations with coreboot.
            if id != "123456789" {
                return Ok(DeviceId { id });
            }
        }
    }

    let path = path()?;
    let dir = path
        .parent()
        .context("Device ID path should always have a parent")?;
    // Make sure the dir exists, and fix its permissions so the GUI can write the
    // log filter file
    fs::create_dir_all(dir).context("Failed to create dir for firezone-id")?;
    set_permissions(dir).with_context(|| {
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
#[expect(clippy::unnecessary_wraps)]
fn set_permissions(_: &Path) -> Result<()> {
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
