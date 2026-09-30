#![cfg(any(target_os = "linux", target_os = "android"))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod ioctl;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::{Io, TunFd};

#[cfg(target_os = "android")]
mod android;
#[cfg(target_os = "android")]
mod plain_ip;
#[cfg(target_os = "android")]
pub use android::Io;
