//! How much CPU time each thread of the current process has consumed.

#![cfg_attr(test, allow(clippy::unwrap_used))]

#[cfg(any(target_os = "linux", target_os = "android"))]
mod linux;
#[cfg(any(target_os = "linux", target_os = "android"))]
use linux as platform;

#[cfg(target_vendor = "apple")]
mod apple;
#[cfg(target_vendor = "apple")]
use apple as platform;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
use windows as platform;

#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_vendor = "apple",
    windows
)))]
mod platform {
    pub fn threads() -> anyhow::Result<Vec<super::Thread>> {
        anyhow::bail!("Reading the CPU time of threads is not supported on this platform")
    }
}

use std::time::Duration;

#[derive(Debug, PartialEq)]
pub struct Thread {
    /// Identifies the thread for as long as it runs.
    pub id: u64,
    /// The name of the thread, truncated to 15 bytes on Linux and Android.
    pub name: String,
    /// The CPU time the thread consumed since it started, in user and kernel mode.
    pub cpu_time: Duration,
}

/// Lists the threads of the current process.
///
/// Threads that exit while they are listed, or that cannot be read, are left out.
pub fn threads() -> anyhow::Result<Vec<Thread>> {
    platform::threads()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_the_calling_thread() {
        let threads = std::thread::Builder::new()
            .name("fz-thread-cpu".to_owned())
            .spawn(threads)
            .unwrap()
            .join()
            .unwrap()
            .unwrap();

        assert!(threads.iter().any(|thread| thread.name == "fz-thread-cpu"));
    }
}
