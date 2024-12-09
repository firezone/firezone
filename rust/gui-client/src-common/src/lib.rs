#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod auth;
pub mod compositor;
pub mod controller;
pub mod deep_link;
pub mod errors;
pub mod ipc;
pub mod logging;
pub mod settings;
pub mod system_tray;
pub mod updates;
pub mod uptime;

/// The Sentry "release" we are part of.
///
/// IPC service and GUI client are always bundled into a single release.
/// Hence, we have a single constant for IPC service and GUI client.
pub const RELEASE: &str = concat!("gui-client@", env!("CARGO_PKG_VERSION"));
