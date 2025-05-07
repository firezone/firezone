#![cfg_attr(test, allow(clippy::unwrap_used))]

mod about;
mod clear_logs;
mod updates;
mod uptime;
mod welcome;

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

pub use clear_logs::clear_logs;

/// The Sentry "release" we are part of.
///
/// IPC service and GUI client are always bundled into a single release.
/// Hence, we have a single constant for IPC service and GUI client.
pub const RELEASE: &str = concat!("gui-client@", env!("CARGO_PKG_VERSION"));
