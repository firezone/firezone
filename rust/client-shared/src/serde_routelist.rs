use ip_network::{Ipv4Network, Ipv6Network};
use std::net::{Ipv4Addr, Ipv6Addr};

#[derive(serde::Serialize, Clone, Copy, Debug)]
struct Cidr<T> {
    address: T,
    prefix: u8,
}

/// Custom adaptor for a different serialisation format for the Apple and Android clients.
#[derive(serde::Serialize)]
#[serde(transparent)]
pub struct V4RouteList(Vec<Cidr<Ipv4Addr>>);

impl V4RouteList {
    pub fn new(route: Vec<Ipv4Network>) -> Self {
        Self(
            route
                .into_iter()
                .map(|n| Cidr {
                    address: n.network_address(),
                    prefix: n.netmask(),
                })
                .collect(),
        )
    }
}

/// Custom adaptor for a different serialisation format for the Apple and Android clients.
#[derive(serde::Serialize)]
#[serde(transparent)]
pub struct V6RouteList(Vec<Cidr<Ipv6Addr>>);

impl V6RouteList {
    pub fn new(route: Vec<Ipv6Network>) -> Self {
        Self(
            route
                .into_iter()
                .map(|n| Cidr {
                    address: n.network_address(),
                    prefix: n.netmask(),
                })
                .collect(),
        )
    }
}
