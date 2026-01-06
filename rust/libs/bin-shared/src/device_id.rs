//! Generate a persistent device ID, stores it to disk, and reads it back.

use anyhow::{Context as _, Result};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use sha2::Digest;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

/// Randomly generated, hex-encoded 128bit identifier for Clients.
///
/// Together with a unique hardware ID, like `/etc/machine-id`, this can be used to deterministically compute a device ID.
const CLIENT_APP_ID: &str = "e1e465ce763e4759945c650ac334501f";

/// Randomly generated, hex-encoded 128bit identifier for Gateways.
///
/// Together with a unique hardware ID, like `/etc/machine-id`, this can be used to deterministically compute a device ID.
const GATEWAY_APP_ID: &str = "753b38f9f96947ef8083802d5909a372";

#[derive(Debug, Clone, PartialEq)]
pub struct DeviceId {
    pub id: String,
    pub source: Source,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    Disk,
    HardwareId,
}

/// Returns the path of the randomly-generated Firezone device ID
///
/// e.g. `C:\ProgramData\dev.firezone.client/firezone-id.json` or
/// `/var/lib/dev.firezone.client/config/firezone-id.json`.
pub fn client_path() -> Result<PathBuf> {
    let path = crate::known_dirs::tunnel_service_config()
        .context("Failed to compute path for firezone-id file")?
        .join("firezone-id.json");
    Ok(path)
}

/// Returns the device ID without generating it
pub fn get_client() -> Result<DeviceId> {
    let path = client_path()?;
    let id = get_at_or_compute(&path, CLIENT_APP_ID)?;

    Ok(id)
}

/// Returns the device ID, generating it and saving it to disk if needed.
///
/// Per <https://github.com/firezone/firezone/issues/2697> and <https://github.com/firezone/firezone/issues/2711>,
/// clients must generate their own random IDs and persist them to disk, to handle situations like VMs where a hardware ID is not unique or not available.
///
/// Returns: The UUID as a String, suitable for sending verbatim to `client_shared::Session::connect`.
///
/// Errors: If the disk is unwritable when initially generating the ID, or unwritable when re-generating an invalid ID.
pub fn get_or_create_client() -> Result<DeviceId> {
    let path = client_path()?;
    let id = get_or_create_at(&path, CLIENT_APP_ID)?;

    Ok(id)
}

pub fn get_or_create_gateway() -> Result<DeviceId> {
    const ID_PATH: &str = "/var/lib/firezone/gateway_id";

    let id = get_or_create_at(Path::new(ID_PATH), GATEWAY_APP_ID)?;

    Ok(id)
}

fn get_or_create_at(path: &Path, app_id: &str) -> Result<DeviceId> {
    let dir = path
        .parent()
        .context("Device ID path should always have a parent")?;
    // Make sure the dir exists, and fix its permissions so the GUI can write the
    // log filter file
    fs::create_dir_all(dir).context("Failed to create dir for firezone-id")?;
    set_dir_permissions(dir).with_context(|| {
        format!(
            "Couldn't set permissions on Tunnel service config dir `{}`",
            dir.display()
        )
    })?;

    // Try to read it from the disk
    if let Ok(id) = get_at_or_compute(path, app_id) {
        return Ok(id);
    }

    // Couldn't read, it's missing or invalid, generate a new one and save it.
    let id = hex::encode(sha2::Sha256::digest(uuid::Uuid::new_v4().to_string()));
    let j = DeviceIdJson { id: id.clone() };

    let content =
        serde_json::to_string(&j).context("Impossible: Failed to serialize firezone-id")?;

    let file = AtomicFile::new(path, OverwriteBehavior::DisallowOverwrite);
    file.write(|f| f.write_all(content.as_bytes()))
        .context("Failed to write firezone-id file")?;

    tracing::debug!(%id, "Saved device ID to disk");
    set_id_permissions(path).context("Couldn't set permissions on Firezone ID file")?;

    Ok(DeviceId {
        id: j.id,
        source: Source::Disk,
    })
}

/// Reads the device ID from the given path, or if that fails, attempts to compute it from a hardware ID.
fn get_at_or_compute(path: &Path, app_id: &str) -> Result<DeviceId> {
    match (get_at(path), compute_from_hardware_id(app_id)) {
        (Ok(fs_id), _) => Ok(fs_id),
        (Err(_), Ok(derived_id)) => Ok(derived_id),
        (Err(fs_err), Err(derive_err)) => {
            anyhow::bail!("Failed to read ({fs_err:#}) and derive ({derive_err:#}) device ID")
        }
    }
}

fn get_at(path: &Path) -> Result<DeviceId> {
    let content = fs::read_to_string(path).context("Failed to read file")?;
    let j = serde_json::from_str::<DeviceIdJson>(&content)
        .context("Failed to deserialize content as JSON")?;

    tracing::debug!(id = %j.id, "Loaded device ID from disk");

    // Correct permissions for #6989
    set_id_permissions(path).context("Couldn't set permissions on Firezone ID file")?;

    Ok(DeviceId {
        id: j.id,
        source: Source::Disk,
    })
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

#[cfg(target_os = "linux")]
fn compute_from_hardware_id(app_id: &str) -> Result<DeviceId> {
    use hmac::Mac;

    let machine_id =
        fs::read_to_string("/etc/machine-id").context("Failed to read `/etc/machine-id`")?;

    let bytes = hmac::Hmac::<sha2::Sha256>::new_from_slice(app_id.as_bytes())
        .context("Failed to create HMAC instance")?
        .chain_update(&machine_id)
        .finalize()
        .into_bytes()
        .to_vec();

    let id = hex::encode(bytes);

    tracing::debug!(%id, "Derived device ID from /etc/machine-id");

    Ok(DeviceId {
        id,
        source: Source::HardwareId,
    })
}

#[cfg(not(target_os = "linux"))]
fn compute_from_hardware_id(_: &str) -> Result<DeviceId> {
    anyhow::bail!("Not implemented")
}

#[derive(serde::Deserialize, serde::Serialize)]
struct DeviceIdJson {
    id: String,
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;
    use uuid::Uuid;

    use super::*;

    #[test]
    fn creates_id_if_not_exist() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("id.json");

        let created_device_id = get_or_create_at(&path, CLIENT_APP_ID).unwrap();
        let read_device_id = get_at_or_compute(&path, CLIENT_APP_ID).unwrap();

        assert_eq!(created_device_id, read_device_id);
    }

    #[test]
    fn does_not_override_existing_id() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("id.json");

        let plain_id = Uuid::new_v4();

        let json = serde_json::to_string(&serde_json::json!({
            "id": plain_id
        }))
        .unwrap();
        std::fs::write(&path, json).unwrap();

        let read_device_id = get_or_create_at(&path, CLIENT_APP_ID).unwrap();

        assert_eq!(read_device_id.id, plain_id.to_string());
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn compute_device_id_hardware_id() {
        let _guard = logging::test("debug");

        let id = compute_from_hardware_id(CLIENT_APP_ID).unwrap();

        assert!(!id.id.is_empty())
    }
}
