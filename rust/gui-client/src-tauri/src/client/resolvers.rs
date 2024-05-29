//! Module to handle Windows system-wide DNS resolvers

pub(crate) use imp::get;

#[cfg(target_os = "macos")]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    pub fn get() -> Result<Vec<IpAddr>> {
        unimplemented!()
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    pub fn get() -> Result<Vec<IpAddr>> {
        firezone_headless_client::platform::system_resolvers(
            connlib_shared::platform::IPC_SERVICE_DNS_CONTROL,
        )
    }
}
