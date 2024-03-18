//! Module to handle Windows system-wide DNS resolvers

pub(crate) use imp::get;

#[cfg(target_os = "linux")]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    // TODO: The code here will depend on the chosen DNS control method.
    // So that will need to be threaded in here somehow.
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
        Ok(ipconfig::get_adapters()?
            .iter()
            .flat_map(|adapter| adapter.dns_servers())
            .filter(|ip| match ip {
                IpAddr::V4(_) => true,
                // Filter out bogus DNS resolvers on my dev laptop that start with fec0:
                IpAddr::V6(ip) => !ip.octets().starts_with(&[0xfe, 0xc0]),
            })
            .copied()
            .collect())
    }
}
