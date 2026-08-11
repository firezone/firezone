//! DNS and route control  for the virtual network interface in `tunnel`

#[cfg(target_os = "linux")]
pub mod linux;
use std::fmt;

#[cfg(target_os = "linux")]
pub use linux as platform;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as platform;

#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
pub use macos as platform;

pub use platform::TunDeviceManager;

/// Waits for the TUN worker threads to exit and joins them, surfacing panics in the log.
///
/// Must be called after the state that keeps the threads alive (channels, sessions)
/// has been dropped; otherwise the threads never exit and we hit the timeout.
#[cfg(any(target_os = "linux", target_os = "windows"))]
pub(crate) fn join_worker_threads(
    recv_thread: std::thread::JoinHandle<()>,
    send_thread: std::thread::JoinHandle<()>,
) {
    use std::time::{Duration, Instant};

    const SHUTDOWN_WAIT: Duration = Duration::from_secs(10);

    let start = Instant::now();

    loop {
        let recv_thread_finished = recv_thread.is_finished();
        let send_thread_finished = send_thread.is_finished();

        if recv_thread_finished && send_thread_finished {
            break;
        }

        if start.elapsed() > SHUTDOWN_WAIT {
            tracing::warn!(%recv_thread_finished, %send_thread_finished, "TUN worker threads did not exit gracefully in {SHUTDOWN_WAIT:?}");
            return;
        }

        std::thread::sleep(Duration::from_millis(100));
    }

    tracing::debug!(
        "Worker threads exited gracefully after {:?}",
        start.elapsed()
    );

    if let Err(error) = recv_thread.join() {
        tracing::error!("`Tun::recv_thread` panicked: {error:?}");
    }
    if let Err(error) = send_thread.join() {
        tracing::error!("`Tun::send_thread` panicked: {error:?}");
    }
}

/// The supported IP stack of the TUN device
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunIpStack {
    V4Only,
    V6Only,
    Dual,
}

impl TunIpStack {
    pub fn supports_ipv4(&self) -> bool {
        match self {
            TunIpStack::V4Only | TunIpStack::Dual => true,
            TunIpStack::V6Only => false,
        }
    }

    pub fn supports_ipv6(&self) -> bool {
        match self {
            TunIpStack::V6Only | TunIpStack::Dual => true,
            TunIpStack::V4Only => false,
        }
    }
}

impl fmt::Display for TunIpStack {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TunIpStack::V4Only => write!(f, "V4Only"),
            TunIpStack::V6Only => write!(f, "V6Only"),
            TunIpStack::Dual => write!(f, "Dual"),
        }
    }
}
