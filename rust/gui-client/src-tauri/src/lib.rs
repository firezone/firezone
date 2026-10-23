#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::unwrap_in_result))]

pub mod updates;
mod uptime;
mod view;

pub use view::export_bindings;

// TODO: See how many of these we can make private.
pub mod auth;
pub mod controller;
pub mod deep_link;
pub mod dialog;
pub mod elevation;
pub mod gui;
pub mod launch_lock;
#[cfg(debug_assertions)]
pub mod mock_tunnel;
pub mod package_identity;

// The tunnel service, its settings and its logging live in their own crate
// so the daemon can be built without Tauri; the GUI reaches them here.
pub use client_service::{logging, service, settings};

/// Bundle ID / App ID that the client uses to distinguish itself from other programs on the system
///
/// This should be identical to the `tauri.bundle.identifier` over in `tauri.conf.json`,
/// but sometimes I need to use this before Tauri has booted up, or in a place where
/// getting the Tauri app handle would be awkward.
///
/// Note: under the sparse MSIX identity this is *not* the
/// AppUserModelId Windows uses to label notifications; that is derived
/// from [`PACKAGE_FAMILY_NAME`] in `gui::os::notification_app_id`. It is
/// still used as the toast AUMID for un-packaged dev builds, which have
/// no package identity.
pub const BUNDLE_ID: &str = "dev.firezone.client";

/// The Sentry "release" we are part of.
///
/// Tunnel service and GUI client are always bundled into a single release.
/// Hence, we have a single constant for Tunnel service and GUI client.
pub const RELEASE: &str = concat!("gui-client@", env!("CARGO_PKG_VERSION"));

pub use client_service::{FIREZONE_CLIENT_GROUP, NO_TELEMETRY};

pub use windows_package_identity::PACKAGE_FAMILY_NAME;

#[cfg(target_os = "linux")]
pub use client_service::firezone_client_group;
