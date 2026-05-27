//! Protected on-disk storage for [`AdvancedSettings`].
//!
//! Owned exclusively by the privileged Tunnel service. The file lives in
//! `tunnel_service_config()` with restrictive permissions so that other
//! processes running as the same desktop user cannot rewrite values like
//! `auth_url` to redirect the next sign-in to an attacker-controlled
//! backend. The GUI receives the current settings over IPC.

use anyhow::{Context as _, Result};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use std::{
    fs,
    io::{ErrorKind, Write as _},
    path::{Path, PathBuf},
};

use crate::settings::AdvancedSettings;

pub fn path() -> Result<PathBuf> {
    known_dirs::tunnel_advanced_settings()
        .context("Failed to compute path for advanced_settings file")
}

/// Return the stored advanced settings, or `Ok(None)` if the file is missing.
///
/// Returns an error for IO or deserialization failures so callers can
/// distinguish a fresh install from a corrupt file.
pub fn load() -> Result<Option<AdvancedSettings>> {
    let path = path()?;
    let content = match fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(e).with_context(|| {
                format!(
                    "Failed to read advanced_settings file at `{}`",
                    path.display()
                )
            });
        }
    };
    let settings = serde_json::from_str(&content)
        .context("Failed to deserialize advanced_settings as JSON")?;
    Ok(Some(settings))
}

/// Atomically write the advanced settings, creating the parent directory if
/// needed and applying restrictive permissions.
pub fn save(settings: &AdvancedSettings) -> Result<()> {
    let path = path()?;
    let dir = path
        .parent()
        .context("advanced_settings path should have a parent")?;
    fs::create_dir_all(dir)
        .with_context(|| format!("Failed to create advanced_settings dir `{}`", dir.display()))?;
    set_dir_permissions(dir).with_context(|| {
        format!(
            "Failed to set permissions on Tunnel service config dir `{}`",
            dir.display()
        )
    })?;
    let content =
        serde_json::to_string(settings).context("Failed to serialize advanced_settings")?;
    AtomicFile::new(&path, OverwriteBehavior::AllowOverwrite)
        .write(|f| f.write_all(content.as_bytes()))
        .with_context(|| {
            format!(
                "Failed to write advanced_settings file `{}`",
                path.display()
            )
        })?;
    set_file_permissions(&path).with_context(|| {
        format!(
            "Failed to set permissions on advanced_settings file `{}`",
            path.display()
        )
    })?;
    Ok(())
}

/// One-shot migration of the standalone `log-filter` file into
/// `advanced_settings.json` at service startup.
///
/// The standalone file pre-dates the unified advanced-settings storage on
/// the service side. Best-effort: logs warnings on any failure but never
/// aborts service startup.
// TODO: remove once all clients have migrated.
pub fn migrate_legacy_log_filter_file() {
    let Ok(legacy_path) = known_dirs::tunnel_log_filter() else {
        return;
    };
    if !legacy_path.exists() {
        return;
    }
    let Ok(new_path) = path() else {
        tracing::warn!("Cannot compute advanced_settings path; skipping log-filter migration");
        return;
    };
    if new_path.exists() {
        // Protected file is authoritative; the standalone file is stale.
        if let Err(e) = fs::remove_file(&legacy_path) {
            tracing::warn!(
                path = %legacy_path.display(),
                "Failed to remove redundant legacy log-filter file: {e}"
            );
        }
        return;
    }
    let directives = match fs::read_to_string(&legacy_path) {
        Ok(s) => s.trim().to_string(),
        Err(e) => {
            tracing::warn!("Failed to read legacy log-filter file: {e:#}");
            return;
        }
    };
    let settings = AdvancedSettings {
        log_filter: directives,
        ..AdvancedSettings::default()
    };
    if let Err(e) = save(&settings) {
        tracing::warn!("Failed to migrate legacy log-filter to advanced_settings: {e:#}");
        return;
    }
    if let Err(e) = fs::remove_file(&legacy_path) {
        tracing::warn!(
            path = %legacy_path.display(),
            "Migrated legacy log-filter but failed to delete it: {e}"
        );
    } else {
        tracing::info!("Migrated legacy log-filter into advanced_settings.json");
    }
}

#[cfg(target_os = "linux")]
fn set_dir_permissions(dir: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    // Owner + `firezone-client` group rwx, others none. The group also owns
    // the device-id file in the same directory, which the GUI reads directly.
    let perms = fs::Permissions::from_mode(0o770);
    fs::set_permissions(dir, perms)?;
    Ok(())
}

#[cfg(target_os = "windows")]
fn set_dir_permissions(dir: &Path) -> Result<()> {
    windows_security::SecurityDescriptor::from_sddl(DIR_SDDL)?.apply_to_path(dir)
}

/// SDDL for the Tunnel service config directory.
///
/// Mirrors `bin_shared::device_id`. `D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)`:
/// - `D:P` — protected DACL (don't inherit ACEs from the parent).
/// - `A;OICI;FA;;;SY` — Allow Full Access to LocalSystem with Object +
///   Container inheritance.
/// - `A;OICI;FA;;;BA` — Allow Full Access to BUILTIN\Administrators with
///   the same inheritance.
#[cfg(target_os = "windows")]
const DIR_SDDL: &str = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
#[expect(clippy::unnecessary_wraps)]
fn set_dir_permissions(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn set_file_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    // Owner rw, group nothing, others nothing. Stricter than `firezone-id.json`
    // (`0o640`) because the GUI never reads this file — it receives the values
    // over IPC.
    let perms = fs::Permissions::from_mode(0o600);
    fs::set_permissions(path, perms)?;
    Ok(())
}

#[cfg(target_os = "windows")]
fn set_file_permissions(path: &Path) -> Result<()> {
    windows_security::SecurityDescriptor::from_sddl(FILE_SDDL)?.apply_to_path(path)
}

/// SDDL for the on-disk `advanced_settings.json` file.
///
/// `D:P(A;;FA;;;SY)(A;;FA;;;BA)` — protected DACL, Full Access to
/// LocalSystem and BUILTIN\Administrators only.
#[cfg(target_os = "windows")]
const FILE_SDDL: &str = "D:P(A;;FA;;;SY)(A;;FA;;;BA)";

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
#[expect(clippy::unnecessary_wraps)]
fn set_file_permissions(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_and_load(dir: &Path) -> AdvancedSettings {
        let path = dir.join("advanced_settings.json");
        let original = AdvancedSettings::default();
        let content = serde_json::to_string(&original).unwrap();
        AtomicFile::new(&path, OverwriteBehavior::AllowOverwrite)
            .write(|f| f.write_all(content.as_bytes()))
            .unwrap();
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap()
    }

    #[test]
    fn roundtrip_default() {
        let dir = tempfile::tempdir().unwrap();
        let settings = write_and_load(dir.path());
        assert_eq!(
            serde_json::to_string(&settings).unwrap(),
            serde_json::to_string(&AdvancedSettings::default()).unwrap(),
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn set_file_permissions_applies_0o600() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("advanced_settings.json");
        fs::write(&path, "{}").unwrap();
        set_file_permissions(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
