// There is no special way to prevent `cargo-mutants` from throwing false
// positives on code for other platforms.
#[cfg(target_os = "linux")]
#[path = "ipc/linux.rs"]
pub mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc/windows.rs"]
pub mod platform;

pub(crate) use platform::{Server, Stream};

/// A name that both the server and client can use to find each other
#[derive(Clone, Copy)]
pub enum ServiceId {
    /// The IPC service used by Firezone GUI Client in production
    ///
    /// This must go in `/run/dev.firezone.client` on Linux, which requires
    /// root permission
    Prod,
    /// An IPC service used for unit tests.
    ///
    /// This must go in `/run/user/$UID/dev.firezone.client` on Linux so
    /// the unit tests won't need root.
    ///
    /// Includes an ID so that multiple tests can
    /// run in parallel
    Test(&'static str),
}
