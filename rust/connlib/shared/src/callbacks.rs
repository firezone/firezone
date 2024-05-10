use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use serde::Serialize;
use std::fmt::Debug;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::messages::client::GatewayGroup;
use crate::messages::ResourceId;

// Avoids having to map types for Windows
type RawFd = i32;

#[derive(Serialize, Clone, Copy, Debug)]
/// Identical to `ip_network::Ipv4Network` except we implement `Serialize` on the Rust side and the equivalent of `Deserialize` on the Swift / Kotlin side to avoid manually serializing and deserializing.
pub struct Cidrv4 {
    address: Ipv4Addr,
    prefix: u8,
}

/// Identical to `ip_network::Ipv6Network` except we implement `Serialize` on the Rust side and the equivalent of `Deserialize` on the Swift / Kotlin side to avoid manually serializing and deserializing.
#[derive(Serialize, Clone, Copy, Debug)]
pub struct Cidrv6 {
    address: Ipv6Addr,
    prefix: u8,
}

impl From<Ipv4Network> for Cidrv4 {
    fn from(value: Ipv4Network) -> Self {
        Self {
            address: value.network_address(),
            prefix: value.netmask(),
        }
    }
}

impl From<Ipv6Network> for Cidrv6 {
    fn from(value: Ipv6Network) -> Self {
        Self {
            address: value.network_address(),
            prefix: value.netmask(),
        }
    }
}

#[derive(Debug, Serialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Status {
    Unknown,
    Online,
    Offline,
}

#[derive(Debug, Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(ResourceDescriptionDns),
    Cidr(ResourceDescriptionCidr),
}

impl ResourceDescription {
    pub fn with_status(
        r: crate::messages::client::ResourceDescription,
        status: Status,
    ) -> ResourceDescription {
        match r {
            crate::messages::client::ResourceDescription::Dns(r) => {
                ResourceDescription::Dns(ResourceDescriptionDns::with_status(r, status))
            }
            crate::messages::client::ResourceDescription::Cidr(r) => {
                ResourceDescription::Cidr(ResourceDescriptionCidr::with_status(r, status))
            }
        }
    }
}

#[derive(Debug, Serialize, Clone, PartialEq, Eq, Hash)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: String,
    pub gateway_groups: Vec<GatewayGroup>,

    pub status: Status,
}

impl ResourceDescriptionDns {
    fn with_status(
        r: crate::messages::client::ResourceDescriptionDns,
        status: Status,
    ) -> ResourceDescriptionDns {
        ResourceDescriptionDns {
            id: r.id,
            address: r.address,
            name: r.name,
            address_description: r.address_description,
            gateway_groups: r.gateway_groups,
            status,
        }
    }
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Serialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ResourceDescriptionCidr {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: String,
    pub gateway_groups: Vec<GatewayGroup>,

    pub status: Status,
}

impl ResourceDescriptionCidr {
    fn with_status(
        r: crate::messages::client::ResourceDescriptionCidr,
        status: Status,
    ) -> ResourceDescriptionCidr {
        ResourceDescriptionCidr {
            id: r.id,
            address: r.address,
            name: r.name,
            address_description: r.address_description,
            gateway_groups: r.gateway_groups,
            status,
        }
    }
}

/// Traits that will be used by connlib to callback the client upper layers.
pub trait Callbacks: Clone + Send + Sync {
    /// Called when the tunnel address is set.
    ///
    /// This should return a new `fd` if there is one.
    /// (Only happens on android for now)
    fn on_set_interface_config(&self, _: Ipv4Addr, _: Ipv6Addr, _: Vec<IpAddr>) -> Option<RawFd> {
        None
    }

    /// Called when the route list changes.
    fn on_update_routes(&self, _: Vec<Cidrv4>, _: Vec<Cidrv6>) -> Option<RawFd> {
        None
    }

    /// Called when the resource list changes.
    fn on_update_resources(&self, _: Vec<ResourceDescription>) {}

    /// Called when the tunnel is disconnected.
    ///
    /// If the tunnel disconnected due to a fatal error, `error` is the error
    /// that caused the disconnect.
    fn on_disconnect(&self, error: &crate::Error) {
        tracing::error!(error = ?error, "tunnel_disconnected");
        // Note that we can't panic here, since we already hooked the panic to this function.
        std::process::exit(0);
    }
}
