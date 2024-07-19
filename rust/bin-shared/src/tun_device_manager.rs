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
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "needs sudo"]
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    async fn create_tun() {
        #[cfg(target_os = "windows")]
        {
            // Install wintun so the test can run
            let wintun_path = connlib_shared::windows::wintun_dll_path().unwrap();
            tokio::fs::create_dir_all(wintun_path.parent().unwrap())
                .await
                .unwrap();
            tokio::fs::write(&wintun_path, connlib_shared::windows::wintun_bytes())
                .await
                .unwrap();
        }

        let mut tun_device_manager = TunDeviceManager::new().unwrap();
        let _tun = tun_device_manager.make_tun().unwrap();
    }
}
