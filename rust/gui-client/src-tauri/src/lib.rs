#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::unwrap_in_result))]

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

#[cfg(target_os = "linux")]
pub fn firezone_client_group() -> anyhow::Result<nix::unistd::Group> {
    use anyhow::Context as _;

    let group = nix::unistd::Group::from_name(FIREZONE_CLIENT_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_CLIENT_GROUP}` group must exist on the system"))?;

    Ok(group)
}
