#[cfg(unix)]
#[path = "signals/unix.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "signals/windows.rs"]
mod platform;

pub use platform::{Hangup, Terminate};
