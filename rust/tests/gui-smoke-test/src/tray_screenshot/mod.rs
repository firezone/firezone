#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "linux")]
pub(crate) use linux::capture;
#[cfg(target_os = "windows")]
pub(crate) use windows::capture;
