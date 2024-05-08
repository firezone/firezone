//! A library for the privileged tunnel process for a Linux Firezone Client
//!
//! This is built both standalone and as part of the GUI package. Building it
//! standalone is faster and skips all the GUI dependencies. We can use that build for
//! CLI use cases.
//!
//! Building it as a binary within the `gui-client` package allows the
//! Tauri deb bundler to pick it up easily.
//! Otherwise we would just make it a normal binary crate.

use connlib_client_shared::ResourceDescription;
use std::net::IpAddr;

pub mod known_dirs;

#[cfg(target_os = "linux")]
pub mod imp_linux;
#[cfg(target_os = "linux")]
pub use imp_linux as imp;

#[cfg(target_os = "windows")]
pub mod imp_windows;
#[cfg(target_os = "windows")]
pub use imp_windows as imp;

/// Only used on Linux
pub const FIREZONE_GROUP: &str = "firezone-client";

/// Output of `git describe` at compile time
/// e.g. `1.0.0-pre.4-20-ged5437c88-modified` where:
///
/// * `1.0.0-pre.4` is the most recent ancestor tag
/// * `20` is the number of commits since then
/// * `g` doesn't mean anything
/// * `ed5437c88` is the Git commit hash
/// * `-modified` is present if the working dir has any changes from that commit number
pub const GIT_VERSION: &str = git_version::git_version!(
    args = ["--always", "--dirty=-modified", "--tags"],
    fallback = "unknown"
);

#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub enum IpcClientMsg {
    Connect { api_url: String, token: String },
    Disconnect,
    Reconnect,
    SetDns(Vec<IpAddr>),
}

#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub enum IpcServerMsg {
    Ok,
    OnDisconnect,
    OnUpdateResources(Vec<ResourceDescription>),
    TunnelReady,
}

// Allow dead code because Windows doesn't have an obvious SIGHUP equivalent
#[allow(dead_code)]
pub enum SignalKind {
    Hangup,
    Interrupt,
}
