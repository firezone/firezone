pub fn get_user_agent(os_version_override: Option<String>, app_version: &str) -> String {
    const LIB_NAME: &str = "connlib";

    // Note: we could switch to sys-info and get the hostname
    // but we lose the arch
    // and neither of the libraries provide the kernel version.
    // so I rather keep os_info which seems like the most popular
    // and keep implementing things that we are missing on top
    let info = os_info::get();

    // iOS returns "Unknown", but we already know we're on iOS here
    #[cfg(target_os = "ios")]
    let os_type = "iOS";
    #[cfg(not(target_os = "ios"))]
    let os_type = info.os_type();

    let os_version = os_version_override.unwrap_or(info.version().to_string());
    let additional_info = additional_info();
    let lib_name = LIB_NAME;
    format!("{os_type}/{os_version} {lib_name}/{app_version}{additional_info}")
}

fn additional_info() -> String {
    let info = os_info::get();
    match (info.architecture(), kernel_version()) {
        (None, None) => "".to_string(),
        (None, Some(k)) => format!(" ({k})"),
        (Some(a), None) => format!(" ({a})"),
        (Some(a), Some(k)) => format!(" ({a}; {k})"),
    }
}

#[cfg(not(target_family = "unix"))]
fn kernel_version() -> Option<String> {
    None
}

#[cfg(target_family = "unix")]
fn kernel_version() -> Option<String> {
    #[cfg(any(target_os = "android", target_os = "linux"))]
    let mut utsname = libc::utsname {
        sysname: [0; 65],
        nodename: [0; 65],
        release: [0; 65],
        version: [0; 65],
        machine: [0; 65],
        domainname: [0; 65],
    };

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let mut utsname = libc::utsname {
        sysname: [0; 256],
        nodename: [0; 256],
        release: [0; 256],
        version: [0; 256],
        machine: [0; 256],
    };

    // SAFETY: we just allocated the pointer
    if unsafe { libc::uname(&mut utsname as *mut _) } != 0 {
        return None;
    }

    #[cfg_attr(
        all(target_os = "linux", target_arch = "aarch64"),
        allow(clippy::unnecessary_cast)
    )]
    let version: Vec<u8> = utsname
        .release
        .split(|c| *c == 0)
        .next()?
        .iter()
        .map(|x| *x as u8)
        .collect();

    String::from_utf8(version).ok()
}
