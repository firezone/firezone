// Manually vendored from https://github.com/itchyny/uptime-rs/blob/e6e31f4aa69b057d0610c20f8f2b5f8f0724decb/src/lib.rs and https://github.com/itchyny/uptime-rs/blob/e6e31f4aa69b057d0610c20f8f2b5f8f0724decb/tests/lib.rs

use std::time::Duration;

#[cfg(target_os = "linux")]
pub fn get() -> Option<Duration> {
    let mut info: libc::sysinfo = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::sysinfo(&mut info) };
    if ret == 0 {
        Some(Duration::from_secs(info.uptime as u64))
    } else {
        None
    }
}

#[cfg(target_os = "windows")]
// `Result` is needed to match other platforms' signatures
#[allow(clippy::unnecessary_wraps)]
pub fn get() -> Option<Duration> {
    let ret: u64 = unsafe { windows::Win32::System::SystemInformation::GetTickCount64() };
    Some(Duration::from_millis(ret))
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_uptime_get() {
        assert!(super::get().is_some());
    }
}
