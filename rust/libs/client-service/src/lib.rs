//! The tunnel service: runs connlib for a user's session and serves the IPC
//! socket the GUI and the CLI talk to.
//!
//! This used to live inside the Tauri package, which meant building the
//! daemon compiled Tauri. It is its own crate so the `firezone` binary and
//! the GUI can both link it.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::unwrap_in_result))]

/// One-shot migration of MDM policy from the per-user registry hive into the
/// machine-scope hive, owned by the Tunnel service.
// TODO: remove once all clients have migrated.
#[cfg(target_os = "windows")]
mod mdm_migration;

pub mod logging;
pub mod service;
pub mod settings;

/// Whether `FIREZONE_NO_TELEMETRY` was set when this binary was built.
///
/// CI stamps it into every build that is not a release, so the smoke test, the
/// install test and any artifact from a pull request stay silent even where nothing
/// sets the variable at run time.
pub const NO_TELEMETRY: bool = cfg!(no_telemetry);

/// The group whose members may control the tunnel service over its socket.
pub const FIREZONE_CLIENT_GROUP: &str = "firezone-client";

#[cfg(target_os = "linux")]
pub fn firezone_client_group() -> anyhow::Result<nix::unistd::Group> {
    use anyhow::Context as _;

    let group = nix::unistd::Group::from_name(FIREZONE_CLIENT_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_CLIENT_GROUP}` group must exist on the system"))?;

    Ok(group)
}
