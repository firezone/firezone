//! Module to handle Windows system-wide DNS resolvers

use std::net::IpAddr;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("can't get system DNS resolvers: {0}")]
    #[cfg(target_os = "windows")]
    CantGetResolvers(#[from] ipconfig::error::Error),
}

#[cfg(target_os = "linux")]
pub fn get() -> Result<Vec<IpAddr>, Error> {
    tracing::error!("Resolvers module not yet implemented for Linux, returning empty Vec");
    Ok(Vec::default())
}

#[cfg(target_os = "macos")]
pub fn get() -> Result<Vec<IpAddr>, Error> {
    todo!()
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
