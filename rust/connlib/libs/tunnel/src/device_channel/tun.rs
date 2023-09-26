#[cfg(any(target_os = "macos", target_os = "ios"))]
#[path = "tun/tun_darwin.rs"]
mod tun;

#[cfg(target_os = "linux")]
#[path = "tun/tun_linux.rs"]
mod tun;

// TODO: Android and linux are nearly identical; use a common tunnel module?
#[cfg(target_os = "android")]
#[path = "tun/tun_android.rs"]
mod tun;

pub(crate) use tun::*;
