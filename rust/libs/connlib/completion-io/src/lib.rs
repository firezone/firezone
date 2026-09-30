//! Completion transports for connlib's shared event loop.
//!
//! Apple hosts complete packet operations over FFI with Network.framework.

#![cfg_attr(test, allow(clippy::unwrap_used))]

pub use client_shared::completion::*;
pub mod host;

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "android"))]
pub mod native;
