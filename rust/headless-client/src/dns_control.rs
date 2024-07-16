#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;

pub(crate) use platform::{system_resolvers, DnsController};

// TODO: Move DNS and network change listening to the IPC service, so this won't
// need to be public.
pub use platform::system_resolvers_for_gui;
