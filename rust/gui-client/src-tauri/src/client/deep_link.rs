//! A module for registering, catching, and parsing deep links that are sent over to the app's already-running instance

#[cfg(target_os = "linux")]
#[path = "deep_link/linux.rs"]
mod imp;

#[cfg(target_os = "windows")]
#[path = "deep_link/windows.rs"]
mod imp;

pub(crate) use imp::{Error, parse_auth_callback, Server, open, register};
