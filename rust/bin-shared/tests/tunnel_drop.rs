use firezone_bin_shared::TunDeviceManager;

/// Checks for regressions in issue #4765, un-initializing Wintun
/// Redundant but harmless on Linux.
#[test]
#[ignore = "Needs admin / sudo and Internet"]
fn tunnel_drop() {
    firezone_logging::test_global("debug"); // `Tun` uses threads and we want to see the logs of all threads.

    let mut tun_device_manager = TunDeviceManager::new(1280, 1).unwrap();

    // Each cycle takes about half a second, so this will take a fair bit to run.
    for _ in 0..50 {
        let _tun = tun_device_manager.make_tun().unwrap(); // This will panic if we don't correctly clean-up the wintun interface.
    }
}
