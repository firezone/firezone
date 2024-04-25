//! Gateway related messages that are needed within connlib

use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};

use super::ResourceId;

/*
"resource":
    {
        "id":"d63f11f7-399d-4358-9b33-3d383deeebbc","name":"10.0.0.0/24","type":"cidr","address":"10.0.0.0/24",
    "filters":[{"protocol":"tcp","port_range_end":80,"port_range_start":80},{"protocol":"tcp","port_range_end":120,"port_range_start":100},{"protocol":"tcp","port_range_end":110,"port_range_start":110},{"protocol":"tcp","port_range_end":115,"port_range_start":109}]
    },"ref":"SFMyNTY.g2gDbQAAAVhnMmdFV0hjVllYQnBRR0Z3YVM1amJIVnpkR1Z5TG14dlkyRnNBQUFEdGdBQUFBQm1LQUlDYUFWWWR4VmhjR2xBWVhCcExtTnNkWE4wWlhJdWJHOWpZV3dBQUFPMEFBQUFBR1lvQWdKM0owVnNhWGhwY2k1UWFHOWxibWw0TGxOdlkydGxkQzVXTVM1S1UwOU9VMlZ5YVdGc2FYcGxjbTBBQUFBR1kyeHBaVzUwWVJwaEFHMEFBQUFrWkRZelpqRXhaamN0TXprNVpDMDBNelU0TFRsaU16TXRNMlF6T0ROa1pXVmxZbUpqYkFBQUFBRm9BbTBBQUFBTGRISmhZMlZ3WVhKbGJuUnRBQUFBTnpBd0xUZ3dORGMwTlROa05HWTJOR0l4WVRFMk56TmhZVE13Tm1RNVpUYzNaV0ZtTFdNM1lqRm1PVEk1T0RrM1lUUTNaall0TURGcW4GAEr4UgyPAWIAAVGA.2j38rsHpg3jmWieZ3GRNiH-qZvYfd0g3R746DHbmXhw","expires_at":1714502746,"actor":{"id":"65855db1-b765-458a-93c8-c96ce43e865b"}
*/
pub type Filters = Vec<Filter>;

/// Description of a resource that maps to a DNS record.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub filters: Filters,
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ResourceDescriptionCidr {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub filters: Filters,
}

/// Description of a resource that maps to a DNS record which had its domain already resolved.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ResolvedResourceDescriptionDns {
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub domain: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub addresses: Vec<IpNetwork>,

    pub filters: Filters,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription<TDNS = ResourceDescriptionDns> {
    Dns(TDNS),
    Cidr(ResourceDescriptionCidr),
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Filter {
    pub protocol: Protocol,
    pub port_range_end: u16,
    pub port_range_start: u16,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    Tcp,
    Udp,
    Icmp,
}

impl ResourceDescription<ResourceDescriptionDns> {
    pub fn into_resolved(
        self,
        addresses: Vec<IpNetwork>,
    ) -> ResourceDescription<ResolvedResourceDescriptionDns> {
        match self {
            ResourceDescription::Dns(ResourceDescriptionDns {
                id,
                address,
                name,
                filters,
            }) => ResourceDescription::Dns(ResolvedResourceDescriptionDns {
                id,
                domain: address,
                name,
                addresses,
                filters,
            }),
            ResourceDescription::Cidr(c) => ResourceDescription::Cidr(c),
        }
    }
}
