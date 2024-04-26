//! Module to handle Windows system-wide DNS resolvers

pub(crate) use imp::get;

#[cfg(target_os = "linux")]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    // TODO: The code here will depend on the chosen DNS control method.
    // So that will need to be threaded in here somehow.
    #[allow(clippy::unnecessary_wraps)]
    pub fn get() -> Result<Vec<IpAddr>> {
        tracing::error!("Resolvers module not yet implemented for Linux, returning empty Vec");
        Ok(Vec::default())
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
