#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::unwrap_in_result))]

/// One-shot migration of MDM policy from the per-user registry hive into the
/// machine-scope hive, owned by the Tunnel service.
// TODO: remove once all clients have migrated.
#[cfg(target_os = "windows")]
mod mdm_migration;
mod updates;
mod uptime;
mod view;

// TODO: See how many of these we can make private.
pub mod auth;
pub mod controller;
pub mod deep_link;
pub mod dialog;
pub mod elevation;
pub mod gui;
pub mod ipc;
pub mod launch_lock;
pub mod logging;
#[cfg(debug_assertions)]
pub mod mock_tunnel;
pub mod package_identity;
pub mod service;
pub mod settings;

/// Bundle ID / App ID that the client uses to distinguish itself from other programs on the system
///
/// This should be identical to the `tauri.bundle.identifier` over in `tauri.conf.json`,
/// but sometimes I need to use this before Tauri has booted up, or in a place where
/// getting the Tauri app handle would be awkward.
///
/// Note: this is *not* the AppUserModelId Windows uses to label notifications. Now
/// that the GUI runs under a sparse MSIX identity, that is [`PACKAGE_AUMID`].
pub const BUNDLE_ID: &str = "dev.firezone.client";

/// The Sentry "release" we are part of.
///
/// Tunnel service and GUI client are always bundled into a single release.
/// Hence, we have a single constant for Tunnel service and GUI client.
pub const RELEASE: &str = concat!("gui-client@", env!("CARGO_PKG_VERSION"));

pub const FIREZONE_CLIENT_GROUP: &str = "firezone-client";

/// `Name_publisherId` for the sparse MSIX. Derived at build time
/// from the manifest's `Name` + Publisher DN in `build.rs`. Used by
/// `register-sparse.exe` to stage / provision / deprovision the
/// package against the AppX deployment service.
pub const PACKAGE_FAMILY_NAME: &str = env!("FIREZONE_PACKAGE_FAMILY_NAME");

/// The AppUserModelId of the GUI under its sparse MSIX identity:
/// `<PackageFamilyName>!<Application Id>`, where `Firezone` is the
/// `<Application Id="Firezone">` from `win_files/AppxManifest.xml`.
///
/// Windows attributes toast notifications to the calling process's
/// package AUMID, so this is what we register them under when the
/// process has package identity (not [`BUNDLE_ID`], which only worked
/// back when the GUI was a plain MSI install with a Start Menu shortcut
/// carrying that AUMID).
pub const PACKAGE_AUMID: &str = concat!(env!("FIREZONE_PACKAGE_FAMILY_NAME"), "!Firezone");

#[cfg(target_os = "linux")]
pub fn firezone_client_group() -> anyhow::Result<nix::unistd::Group> {
    use anyhow::Context as _;

    let group = nix::unistd::Group::from_name(FIREZONE_CLIENT_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_CLIENT_GROUP}` group must exist on the system"))?;

    Ok(group)
}
