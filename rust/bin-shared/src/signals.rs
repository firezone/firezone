#[cfg(target_os = "linux")]
#[path = "signals/linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "signals/windows.rs"]
mod platform;

#[cfg(target_os = "macos")]
#[path = "signals/macos.rs"]
mod platform;

pub use platform::{Hangup, Terminate};
