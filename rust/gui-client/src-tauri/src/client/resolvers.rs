//! Module to handle Windows system-wide DNS resolvers

pub(crate) use imp::{get, Error};

#[cfg(target_os = "linux")]
mod imp {
    use anyhow::Result;
    use connlib_shared::linux::{etc_resolv_conf, get_dns_control_from_env, DnsControlMethod};
    use std::net::IpAddr;

    pub type Error = anyhow::Error;

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

    pub type Error = anyhow::Error;

    pub fn get() -> Result<Vec<IpAddr>> {
        unimplemented!()
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use anyhow::Result;
    use std::net::IpAddr;

    #[derive(thiserror::Error, Debug)]
    pub enum Error {
        #[error("can't get system DNS resolvers: {0}")]
        CantGetResolvers(#[from] ipconfig::error::Error),
    }

    pub fn get() -> Result<Vec<IpAddr>, Error> {
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
