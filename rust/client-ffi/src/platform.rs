#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "ios"
))]
mod fallback;

#[cfg(target_os = "android")]
mod android;

#[cfg(target_os = "android")]
pub use android::*;

#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "ios"
))]
pub use fallback::*;
