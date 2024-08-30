//! Gateway related messages that are needed within connlib

use std::net::IpAddr;

use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use serde::Deserialize;

use super::ResourceId;

pub type Filters = Vec<Filter>;

/// Description of a resource that maps to a DNS record.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
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
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedResourceDescriptionDns {
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub domain: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub addresses: Vec<IpAddr>,

    pub filters: Filters,
}

/// Description of an Internet resource.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct ResourceDescriptionInternet {
    pub id: ResourceId,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription<TDNS = ResourceDescriptionDns> {
    Dns(TDNS),
    Cidr(ResourceDescriptionCidr),
    Internet(ResourceDescriptionInternet),
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Hash)]
#[serde(tag = "protocol", rename_all = "snake_case")]
pub enum Filter {
    Udp(PortRange),
    Tcp(PortRange),
    Icmp,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PortRange {
    // TODO: we can use a custom deserializer
    // or maybe change the control plane to use start and end would suffice
    #[serde(default = "max_port")]
    pub port_range_end: u16,
    #[serde(default = "min_port")]
    pub port_range_start: u16,
}

// Note: these 2 functions are needed since serde doesn't yet support default_value
// see serde-rs/serde#368
fn min_port() -> u16 {
    0
}

fn max_port() -> u16 {
    u16::MAX
}

impl ResourceDescription<ResourceDescriptionDns> {
    pub fn into_resolved(
        self,
        addresses: Vec<IpAddr>,
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
            ResourceDescription::Internet(r) => ResourceDescription::Internet(r),
        }
    }
}

impl ResourceDescription<ResourceDescriptionDns> {
    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
            ResourceDescription::Internet(r) => r.id,
        }
    }

    pub fn filters(&self) -> Vec<Filter> {
        match self {
            ResourceDescription::Dns(r) => r.filters.clone(),
            ResourceDescription::Cidr(r) => r.filters.clone(),
            ResourceDescription::Internet(_) => Vec::default(),
        }
    }
}

impl ResourceDescription<ResolvedResourceDescriptionDns> {
    pub fn addresses(&self) -> Vec<IpNetwork> {
        match self {
            ResourceDescription::Dns(r) => r.addresses.iter().copied().map_into().collect_vec(),
            ResourceDescription::Cidr(r) => vec![r.address],
            ResourceDescription::Internet(_) => vec![
                Ipv4Network::DEFAULT_ROUTE.into(),
                Ipv6Network::DEFAULT_ROUTE.into(),
            ],
        }
    }

    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
            ResourceDescription::Internet(r) => r.id,
        }
    }

    pub fn filters(&self) -> Vec<Filter> {
        match self {
            ResourceDescription::Dns(r) => r.filters.clone(),
            ResourceDescription::Cidr(r) => r.filters.clone(),
            ResourceDescription::Internet(_) => vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn can_deserialize_udp_filter() {
        let msg = r#"{ "protocol": "udp", "port_range_start": 10, "port_range_end": 20 }"#;
        let expected_filter = Filter::Udp(PortRange {
            port_range_start: 10,
            port_range_end: 20,
        });

        let actual_filter = serde_json::from_str(msg).unwrap();

        assert_eq!(expected_filter, actual_filter);
    }

    #[test]
    fn can_deserialize_empty_udp_filter() {
        let msg = r#"{ "protocol": "udp" }"#;
        let expected_filter = Filter::Udp(PortRange {
            port_range_start: 0,
            port_range_end: u16::MAX,
        });

        let actual_filter = serde_json::from_str(msg).unwrap();

        assert_eq!(expected_filter, actual_filter);
    }

    #[test]
    fn can_deserialize_tcp_filter() {
        let msg = r#"{ "protocol": "tcp", "port_range_start": 10, "port_range_end": 20 }"#;
        let expected_filter = Filter::Tcp(PortRange {
            port_range_start: 10,
            port_range_end: 20,
        });

        let actual_filter = serde_json::from_str(msg).unwrap();

        assert_eq!(expected_filter, actual_filter);
    }

    #[test]
    fn can_deserialize_empty_tcp_filter() {
        let msg = r#"{ "protocol": "tcp" }"#;
        let expected_filter = Filter::Tcp(PortRange {
            port_range_start: 0,
            port_range_end: u16::MAX,
        });

        let actual_filter = serde_json::from_str(msg).unwrap();

        assert_eq!(expected_filter, actual_filter);
    }

    #[test]
    fn can_deserialize_icmp_filter() {
        let msg = r#"{ "protocol": "icmp" }"#;
        let expected_filter = Filter::Icmp;

        let actual_filter = serde_json::from_str(msg).unwrap();

        assert_eq!(expected_filter, actual_filter);
    }

    #[test]
    fn can_deserialize_internet_resource() {
        let resources = r#"[
            {
                "id": "73037362-715d-4a83-a749-f18eadd970e6",
                "type": "cidr",
                "address": "172.172.0.0/16",
                "name": "172.172.0.0/16",
                "filters": []
            },
            {
                "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                "type": "dns",
                "name": "gitlab.mycorp.com",
                "address": "gitlab.mycorp.com",
                "filters": []
            },
            {
                "id": "1106047c-cd5d-4151-b679-96b93da7383b",
                "type": "internet",
                "not": "relevant",
                "some_other": [
                    "field"
                ]
            }
        ]"#;

        serde_json::from_str::<Vec<ResourceDescription>>(resources).unwrap();
    }
}
