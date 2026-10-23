//! One-shot migration of MDM policy values from the per-user
//! `HKCU\Software\Policies\Firezone` registry hive into the machine-scope
//! `HKLM\Software\Policies\Firezone`.
//!
//! Older clients read MDM policy from the per-user hive. The Tunnel service now
//! reads it from the machine hive, which it owns. On the first connection after
//! upgrade the service copies the connecting user's values across and removes
//! the per-user key. A sentinel in HKLM ensures this runs at most once per
//! machine.
// TODO: remove once all clients have migrated.

use crate::service::ProcessToken;
use anyhow::{Context as _, Result};
use winreg::{
    RegKey,
    enums::{HKEY_LOCAL_MACHINE, HKEY_USERS, KEY_READ},
};

/// Per-user / machine sub-key holding the Firezone MDM policy values.
const POLICIES_SUBKEY: &str = r"Software\Policies\Firezone";
/// Sub-key holding the migration sentinel.
const MIGRATION_SUBKEY: &str = r"Software\Firezone\Migration";
/// Sentinel value, set to `1` once the per-user → machine migration has run.
const MIGRATED_VALUE: &str = "migrated-to-hklm";

/// Best-effort migration. Logs and returns on any error so that a hiccup never
/// blocks an IPC connection.
pub fn run(client_pid: u32) {
    if let Err(e) = try_run(client_pid) {
        tracing::warn!("Failed to migrate MDM policy to machine scope: {e:#}");
    }
}

fn try_run(client_pid: u32) -> Result<()> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    if is_complete(&hklm) {
        return Ok(());
    }

    // Resolve the connecting user's SID so we can address their hive directly:
    // `HKEY_CURRENT_USER` from this service would resolve to LocalSystem.
    let sid = ProcessToken::from_pid(client_pid)
        .context("Failed to open client process token")?
        .user_sid_string()
        .context("Failed to read client user SID")?;

    let hku = RegKey::predef(HKEY_USERS);
    let user_policies = format!(r"{sid}\{POLICIES_SUBKEY}");

    // Don't clobber a machine-scope policy an admin may already have deployed.
    let hklm_populated = hklm
        .open_subkey(POLICIES_SUBKEY)
        .map(|k| k.enum_values().next().is_some())
        .unwrap_or(false);

    if !hklm_populated && let Ok(user_key) = hku.open_subkey_with_flags(&user_policies, KEY_READ) {
        let values: Vec<_> = user_key.enum_values().filter_map(|v| v.ok()).collect();
        if !values.is_empty() {
            let (dst, _) = hklm
                .create_subkey(POLICIES_SUBKEY)
                .context("Failed to create machine-scope policy key")?;
            for (name, value) in &values {
                dst.set_raw_value(name, value)
                    .with_context(|| format!("Failed to copy policy value `{name}`"))?;
            }
            tracing::info!(count = values.len(), "Migrated MDM policy to machine scope");
        }
    }

    // The per-user key is no longer authoritative; remove it.
    if let Err(e) = hku.delete_subkey_all(&user_policies)
        && e.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!("Failed to remove per-user MDM policy key: {e}");
    }

    let (migration, _) = hklm
        .create_subkey(MIGRATION_SUBKEY)
        .context("Failed to create migration sentinel key")?;
    migration
        .set_value(MIGRATED_VALUE, &1u32)
        .context("Failed to write migration sentinel")?;

    Ok(())
}

/// Whether the per-user → machine migration has already run on this machine.
fn is_complete(hklm: &RegKey) -> bool {
    hklm.open_subkey(MIGRATION_SUBKEY)
        .and_then(|k| k.get_value::<u32, _>(MIGRATED_VALUE))
        .map(|v| v == 1)
        .unwrap_or(false)
}
