//! Gateway related messages that are needed within connlib

use ip_network::IpNetwork;
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

    pub addresses: Vec<IpNetwork>,

    pub filters: Filters,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription<TDNS = ResourceDescriptionDns> {
    Dns(TDNS),
    Cidr(ResourceDescriptionCidr),
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
    pub port_range_end: u16,
    pub port_range_start: u16,
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
    fn can_deserialize_icmp_filter() {
        let msg = r#"{ "protocol": "icmp" }"#;
        let expected_filter = Filter::Icmp;

        let actual_filter = serde_json::from_str(msg).unwrap();

        assert_eq!(expected_filter, actual_filter);
    }
}
