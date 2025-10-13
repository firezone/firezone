#[cfg(any(target_os = "linux", target_os = "windows"))]
mod fallback;

#[cfg(target_os = "android")]
mod android;

#[cfg(any(target_os = "ios", target_os = "macos"))]
mod apple;

#[cfg(target_os = "android")]
pub use android::*;

#[cfg(any(target_os = "ios", target_os = "macos"))]
pub use apple::*;

#[cfg(any(target_os = "linux", target_os = "windows"))]
pub use fallback::*;
