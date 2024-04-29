//! Module to handle Windows system-wide DNS resolvers

pub(crate) use imp::get;

#[cfg(target_os = "linux")]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    pub fn get() -> Result<Vec<IpAddr>> {
        firezone_headless_client::imp::get_system_default_resolvers_systemd_resolved()
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    pub fn get() -> Result<Vec<IpAddr>> {
        unimplemented!()
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    pub fn get() -> Result<Vec<IpAddr>> {
        firezone_headless_client::imp::system_resolvers()
    }
}
