//! Listens for network roaming and changes in system-wide DNS
//!
//! On Linux, these aren't implemented yet, we just poll the DNS servers every
//! few seconds.
//!
//! This code will move to `firezone-headless-client` soon.
//! - It's more secure for the IPC service to watch the network itself,
//!   since the GUI runs as a non-privileged user
//! - The Headless Client for Linux and Windows will need this code soon
//!
//! It hasn't moved yet because the code is fragile and it may be nice to let
//! it restart when the GUI restarts instead of only when the IPC service restarts.
//! It also isn't tested for repeated on-off cycles, so it's nice to save
//! battery by not running the entire GUI process, instead of turning the
//! listeners off and on in the IPC service.

#[cfg(target_os = "linux")]
#[path = "network_changes/linux.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

#[cfg(target_os = "macos")]
#[path = "network_changes/macos.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

#[cfg(target_os = "windows")]
#[path = "network_changes/windows.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

pub(crate) use imp::{check_internet, dns_notifier, network_notifier};
