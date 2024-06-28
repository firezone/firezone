// Manually vendored from https://github.com/itchyny/uptime-rs/blob/e6e31f4aa69b057d0610c20f8f2b5f8f0724decb/src/lib.rs and https://github.com/itchyny/uptime-rs/blob/e6e31f4aa69b057d0610c20f8f2b5f8f0724decb/tests/lib.rs

use std::time::Duration;

#[derive(Debug, thiserror::Error)]
#[cfg_attr(target_os = "windows", allow(unused))]
pub enum Error {
    #[cfg(target_os = "linux")]
    #[error("sysinfo failed")]
    Sysinfo,

    #[cfg(any(
        target_os = "macos",
        target_os = "freebsd",
        target_os = "openbsd",
        target_os = "netbsd"
    ))]
    #[error("sysctl failed")]
    Sysctl,

    #[cfg(any(
        target_os = "macos",
        target_os = "freebsd",
        target_os = "openbsd",
        target_os = "netbsd"
    ))]
    #[error(transparent)]
    SystemTime(#[from] std::time::SystemTimeError),
}

#[cfg(target_os = "linux")]
pub fn get() -> Result<Duration, Error> {
    let mut info: libc::sysinfo = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::sysinfo(&mut info) };
    if ret == 0 {
        Ok(Duration::from_secs(info.uptime as u64))
    } else {
        Err(Error::Sysinfo)
    }
}

#[cfg(any(
    target_os = "macos",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd"
))]
pub fn get() -> Result<Duration, Error> {
    use std::time::SystemTime;
    let mut request = [libc::CTL_KERN, libc::KERN_BOOTTIME];
    let mut boottime: libc::timeval = unsafe { std::mem::zeroed() };
    let mut size: libc::size_t = std::mem::size_of_val(&boottime) as libc::size_t;
    let ret = unsafe {
        libc::sysctl(
            &mut request[0],
            2,
            &mut boottime as *mut libc::timeval as *mut libc::c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if ret == 0 {
        Ok(SystemTime::now().duration_since(SystemTime::UNIX_EPOCH)?
            - Duration::new(boottime.tv_sec as u64, boottime.tv_usec as u32 * 1000))
    } else {
        Err(Error::Sysctl)
    }
}

#[cfg(target_os = "windows")]
// `Result` is needed to match other platforms' signatures
#[allow(clippy::unnecessary_wraps)]
pub fn get() -> Result<Duration, Error> {
    let ret: u64 = unsafe { windows::Win32::System::SystemInformation::GetTickCount64() };
    Ok(Duration::from_millis(ret))
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_uptime_get() {
        assert!(super::get().is_ok());
    }
}
