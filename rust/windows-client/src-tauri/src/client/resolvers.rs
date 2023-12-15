//! Module to handle Windows system-wide DNS resolvers

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
            IpAddr::V4(ip) => *ip != connlib_shared::DNS_SENTINEL,
            IpAddr::V6(ip) => !ip.octets().starts_with(&[0xfe, 0xc0]),
        })
        .cloned()
        .collect())
}
