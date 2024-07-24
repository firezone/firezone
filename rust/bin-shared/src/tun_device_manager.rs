//! DNS and route control  for the virtual network interface in `firezone-tunnel`

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
pub use linux as platform;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as platform;

#[cfg(any(target_os = "linux", target_os = "windows"))]
pub use platform::TunDeviceManager;

#[cfg(test)]
#[cfg(any(target_os = "linux", target_os = "windows"))]
mod tests {
    use super::*;
    use tracing_subscriber::EnvFilter;

    #[tokio::test]
    #[ignore = "Needs admin / sudo"]
    async fn tunnel() {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(EnvFilter::from_default_env())
            .with_test_writer()
            .try_init();

        #[cfg(target_os = "windows")]
        {
            // Install wintun so the test can run
            let wintun_path = crate::windows::wintun_dll_path().unwrap();
            tokio::fs::create_dir_all(wintun_path.parent().unwrap())
                .await
                .unwrap();
            tokio::fs::write(&wintun_path, crate::windows::wintun_bytes().bytes)
                .await
                .unwrap();
        }

        // Run these tests in series since they would fight over the tunnel interface
        // if they ran concurrently
        create_tun();
        tunnel_drop();
    }

    fn create_tun() {
        let mut tun_device_manager = TunDeviceManager::new().unwrap();
        let _tun = tun_device_manager.make_tun().unwrap();
    }

    /// Checks for regressions in issue #4765, un-initializing Wintun
    /// Redundant but harmless on Linux.
    fn tunnel_drop() {
        // Each cycle takes about half a second, so this will take a fair bit to run.
        for _ in 0..50 {
            let _tun = platform::Tun::new().unwrap(); // This will panic if we don't correctly clean-up the wintun interface.
        }
    }
}
