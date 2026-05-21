#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::unwrap_in_result))]

mod fake_controller;
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
pub mod service;
pub mod settings;

/// Bundle ID / App ID that the client uses to distinguish itself from other programs on the system
///
/// This should be identical to the `tauri.bundle.identifier` over in `tauri.conf.json`,
/// but sometimes I need to use this before Tauri has booted up, or in a place where
/// getting the Tauri app handle would be awkward.
///
/// Luckily this is also the AppUserModelId that Windows uses to label notifications,
/// so if your dev system has Firezone installed by MSI, the notifications will look right.
/// <https://learn.microsoft.com/en-us/windows/configuration/find-the-application-user-model-id-of-an-installed-app>
pub const BUNDLE_ID: &str = "dev.firezone.client";

/// The Sentry "release" we are part of.
///
/// Tunnel service and GUI client are always bundled into a single release.
/// Hence, we have a single constant for Tunnel service and GUI client.
pub const RELEASE: &str = concat!("gui-client@", env!("CARGO_PKG_VERSION"));

pub const FIREZONE_CLIENT_GROUP: &str = "firezone-client";

/// `Name_publisherId` derived from `win_files/AppxManifest.xml`. The
/// `publisherId` half is the Crockford-base32 hash of the cert
/// Subject DN that signs the sparse MSIX, so this value only
/// changes when the cert rotates. Used as a runtime input to
/// `windows_security::pipe_dacl::Trustee::from_package_family_name`
/// for the pipe DACL ACEs that pin access to the
/// MSIX-registered Firezone binaries.
pub const PACKAGE_FAMILY_NAME: &str = "Firezone.Client.GUI_r4567a5vks0bt";

#[cfg(target_os = "linux")]
pub fn firezone_client_group() -> anyhow::Result<nix::unistd::Group> {
    use anyhow::Context as _;

    let group = nix::unistd::Group::from_name(FIREZONE_CLIENT_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_CLIENT_GROUP}` group must exist on the system"))?;

    Ok(group)
}
