//! Module to handle Windows system-wide DNS resolvers

use std::net::IpAddr;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[cfg(target_os = "windows")]
    #[error("can't get system DNS resolvers: {0}")]
    CantGetResolvers(#[from] ipconfig::error::Error),
}

#[cfg(target_os = "windows")]
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

#[cfg(not(target_os = "windows"))]
pub fn get() -> Result<Vec<IpAddr>, Error> {
    Ok(vec![])
}
