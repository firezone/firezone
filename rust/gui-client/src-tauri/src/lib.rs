#![cfg_attr(test, allow(clippy::unwrap_used))]

mod updates;
mod uptime;
mod view;

// TODO: See how many of these we can make private.
pub mod auth;
pub mod controller;
pub mod deep_link;
pub mod elevation;
pub mod gui;
pub mod ipc;
pub mod logging;
pub mod service;
pub mod settings;

/// The Sentry "release" we are part of.
///
/// Tunnel service and GUI client are always bundled into a single release.
/// Hence, we have a single constant for Tunnel service and GUI client.
pub const RELEASE: &str = concat!("gui-client@", env!("CARGO_PKG_VERSION"));
