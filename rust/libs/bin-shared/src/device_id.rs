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

impl DeviceId {
    #[cfg(feature = "test")]
    pub fn test() -> Self {
        Self {
            id: "FF85E1A39B9489356C5F5A23134CC80442530B76ED44925FAF787AF4B33ABA94".to_owned(),
            source: Source::Test,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    Disk,
    HardwareId,
    #[cfg(feature = "test")]
    Test,
}

/// Returns the path of the randomly-generated Firezone device ID
///
/// e.g. `C:\ProgramData\dev.firezone.client/firezone-id.json` or
/// `/var/lib/dev.firezone.client/config/firezone-id.json`.
pub fn client_path() -> Result<PathBuf> {
    let path = known_dirs::tunnel_service_config()
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
    // Make sure the dir exists, and fix its permissions before writing files
    // into it.
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

#[cfg(target_os = "windows")]
fn set_dir_permissions(dir: &Path) -> Result<()> {
    set_windows_dacl(dir, "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
}

/// Does nothing on other non-Linux systems
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
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

#[cfg(target_os = "windows")]
fn set_id_permissions(path: &Path) -> Result<()> {
    set_windows_dacl(path, "D:P(A;;FA;;;SY)(A;;FA;;;BA)")
}

#[cfg(target_os = "windows")]
fn set_windows_dacl(path: &Path, sddl: &str) -> Result<()> {
    use anyhow::ensure;
    use std::{ffi::OsStr, os::windows::ffi::OsStrExt, ptr};
    use windows::{
        Win32::{
            Foundation::{ERROR_SUCCESS, HLOCAL, LocalFree},
            Security::{
                Authorization::{
                    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
                    SE_FILE_OBJECT, SetNamedSecurityInfoW,
                },
                DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl,
                PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
            },
        },
        core::{BOOL, PCWSTR},
    };

    fn wide(s: impl AsRef<OsStr>) -> Vec<u16> {
        s.as_ref().encode_wide().chain(Some(0)).collect()
    }

    struct LocalSecurityDescriptor(PSECURITY_DESCRIPTOR);

    impl Drop for LocalSecurityDescriptor {
        fn drop(&mut self) {
            // SAFETY: The security descriptor was allocated by
            // `ConvertStringSecurityDescriptorToSecurityDescriptorW` and must be
            // released with `LocalFree`.
            unsafe {
                LocalFree(Some(HLOCAL(self.0.0)));
            }
        }
    }

    let mut security_descriptor = PSECURITY_DESCRIPTOR::default();
    let sddl = wide(sddl);

    // SAFETY: The SDDL string is null-terminated and the output pointer is valid
    // for the duration of this call.
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(sddl.as_ptr()),
            SDDL_REVISION_1,
            &mut security_descriptor,
            None,
        )
    }
    .context("Failed to build Windows security descriptor from SDDL")?;

    let security_descriptor = LocalSecurityDescriptor(security_descriptor);

    let mut dacl_present = BOOL::default();
    let mut dacl_defaulted = BOOL::default();
    let mut dacl = ptr::null_mut();

    // SAFETY: The security descriptor is valid and the output pointers are local
    // variables that live for the duration of the call.
    unsafe {
        GetSecurityDescriptorDacl(
            security_descriptor.0,
            &mut dacl_present,
            &mut dacl,
            &mut dacl_defaulted,
        )
    }
    .context("Failed to get DACL from Windows security descriptor")?;

    ensure!(
        dacl_present.as_bool(),
        "Windows security descriptor has no DACL"
    );

    let path = wide(path.as_os_str());
    let security_info = DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION;

    // SAFETY: The path is null-terminated, the DACL comes from a valid security
    // descriptor, and Windows does not retain these pointers after the call.
    let err = unsafe {
        SetNamedSecurityInfoW(
            PCWSTR(path.as_ptr()),
            SE_FILE_OBJECT,
            security_info,
            None,
            None,
            Some(dacl),
            None,
        )
    };

    if err != ERROR_SUCCESS {
        return Err(std::io::Error::from_raw_os_error(err.0 as i32))
            .with_context(|| "Failed to set Windows DACL");
    }

    Ok(())
}

/// Does nothing on other non-Linux systems
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
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
