use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, Site, SiteId};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use proptest::{
    arbitrary::{any, any_with},
    collection, prop_oneof,
    sample::subsequence,
    strategy::{Just, Strategy},
};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    ops::Range,
};

use crate::{
    client::InternetResource,
    messages::gateway::{Filter, Filters, PortRange},
};

/// Full model of a dns resource, proyections of this are sent to the client and gateways
#[derive(Debug, Clone, PartialEq, Eq, derivative::Derivative)]
#[derivative(PartialOrd, Ord)]
pub(crate) struct PortalResourceDescriptionDns {
    pub id: ResourceId,
    pub address: String,
    pub name: String,
    #[derivative(PartialOrd = "ignore")]
    #[derivative(Ord = "ignore")]
    pub filters: Filters,
    pub sites: Vec<Site>,
    pub address_description: Option<String>,
}

/// Full model of a cidr resource, proyections of this are sent to the client and gateways
#[derive(Debug, Clone, PartialEq, Eq, derivative::Derivative)]
#[derivative(PartialOrd, Ord)]
pub(crate) struct PortalResourceDescriptionCidr {
    pub id: ResourceId,
    pub address: IpNetwork,
    pub name: String,
    #[derivative(PartialOrd = "ignore")]
    #[derivative(Ord = "ignore")]
    pub filters: Filters,
    pub sites: Vec<Site>,
    pub address_description: Option<String>,
}

impl From<PortalResourceDescriptionCidr> for crate::messages::client::ResourceDescriptionCidr {
    fn from(value: PortalResourceDescriptionCidr) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            address_description: value.address_description,
            sites: value.sites,
        }
    }
}

impl From<PortalResourceDescriptionDns> for crate::messages::client::ResourceDescriptionDns {
    fn from(value: PortalResourceDescriptionDns) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            address_description: value.address_description,
            sites: value.sites,
        }
    }
}

impl From<PortalResourceDescriptionCidr> for crate::messages::gateway::ResourceDescriptionCidr {
    fn from(value: PortalResourceDescriptionCidr) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            filters: value.filters,
        }
    }
}

impl From<PortalResourceDescriptionDns> for crate::messages::gateway::ResourceDescriptionDns {
    fn from(value: PortalResourceDescriptionDns) -> Self {
        Self {
            id: value.id,
            address: value.address,
            name: value.name,
            filters: value.filters,
        }
    }
}

const ALLOWED_SERVICES: [Filter; 4] = [
    Filter::Tcp(PortRange {
        port_range_end: 22,
        port_range_start: 22,
    }),
    Filter::Udp(PortRange {
        port_range_end: 53,
        port_range_start: 53,
    }),
    Filter::Tcp(PortRange {
        port_range_end: 80,
        port_range_start: 80,
    }),
    Filter::Tcp(PortRange {
        port_range_end: 443,
        port_range_start: 443,
    }),
];

fn filters() -> impl Strategy<Value = Filters> {
    subsequence(&ALLOWED_SERVICES, 0..4).prop_map(|f| f.to_vec())
}

pub fn dns_resource(
    sites: impl Strategy<Value = Vec<Site>>,
) -> impl Strategy<Value = PortalResourceDescriptionDns> {
    (
        resource_id(),
        resource_name(),
        domain_name(2..4),
        address_description(),
        filters(),
        sites,
    )
        .prop_map(
            move |(id, name, address, address_description, filters, sites)| {
                PortalResourceDescriptionDns {
                    id,
                    address,
                    name,
                    sites,
                    address_description,
                    filters,
                }
            },
        )
}

pub fn cidr_resource(
    ip_network: impl Strategy<Value = IpNetwork>,
    sites: impl Strategy<Value = Vec<Site>>,
) -> impl Strategy<Value = PortalResourceDescriptionCidr> {
    (
        resource_id(),
        resource_name(),
        ip_network,
        address_description(),
        filters(),
        sites,
    )
        .prop_map(
            move |(id, name, address, address_description, filters, sites)| {
                PortalResourceDescriptionCidr {
                    id,
                    address,
                    name,
                    sites,
                    address_description,
                    filters,
                }
            },
        )
}

pub fn internet_resource(
    sites: impl Strategy<Value = Vec<Site>>,
) -> impl Strategy<Value = InternetResource> {
    (resource_id(), sites).prop_map(move |(id, sites)| InternetResource {
        name: "Internet Resource".to_string(),
        id,
        sites,
    })
}

pub fn address_description() -> impl Strategy<Value = Option<String>> {
    prop_oneof![
        any_with::<String>("[a-z]{4,10}".into()).prop_map(Some),
        Just(None),
    ]
}

pub fn site() -> impl Strategy<Value = Site> + Clone {
    (site_name(), site_id()).prop_map(|(name, id)| Site { name, id })
}

pub fn resource_id() -> impl Strategy<Value = ResourceId> + Clone {
    any::<u128>().prop_map(ResourceId::from_u128)
}

pub fn gateway_id() -> impl Strategy<Value = GatewayId> + Clone {
    any::<u128>().prop_map(GatewayId::from_u128)
}

pub fn client_id() -> impl Strategy<Value = ClientId> {
    any::<u128>().prop_map(ClientId::from_u128)
}

pub fn relay_id() -> impl Strategy<Value = RelayId> {
    any::<u128>().prop_map(RelayId::from_u128)
}

pub fn site_id() -> impl Strategy<Value = SiteId> + Clone {
    any::<u128>().prop_map(SiteId::from_u128)
}

pub fn site_name() -> impl Strategy<Value = String> + Clone {
    any_with::<String>("[a-z]{4,10}".into())
}

pub fn resource_name() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{4,10}".into())
}

pub fn domain_label() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{3,6}".into())
}

pub fn domain_name(depth: Range<usize>) -> impl Strategy<Value = String> {
    collection::vec(domain_label(), depth).prop_map(|labels| labels.join("."))
}

/// A strategy of IP networks, configurable by the size of the host mask.
pub fn any_ip_network(host_mask_bits: usize) -> impl Strategy<Value = IpNetwork> {
    any::<IpAddr>().prop_flat_map(move |ip| ip_network(ip, host_mask_bits))
}

pub fn ip_network(network: IpAddr, host_mask_bits: usize) -> impl Strategy<Value = IpNetwork> {
    assert!(host_mask_bits > 0);

    let max_netmask = match network {
        IpAddr::V4(_) => 32,
        IpAddr::V6(_) => 128,
    };
    assert!(host_mask_bits <= max_netmask);

    (0..host_mask_bits).prop_map(move |mask| {
        let netmask = max_netmask - mask;
        IpNetwork::new_truncate(network, netmask as u8).unwrap()
    })
}

fn number_of_hosts_ipv4(mask: u8) -> u32 {
    2u32.checked_pow(32 - mask as u32)
        .map(|i| i - 1)
        .unwrap_or(u32::MAX)
}

fn number_of_hosts_ipv6(mask: u8) -> u128 {
    2u128
        .checked_pow(128 - mask as u32)
        .map(|i| i - 1)
        .unwrap_or(u128::MAX)
}

// Note: for these tests we don't really care that it's a valid host
// we only need a host.
// If we filter valid hosts it generates too many rejects
pub fn host_v4(ip: Ipv4Network) -> impl Strategy<Value = Ipv4Addr> {
    (0u32..=number_of_hosts_ipv4(ip.netmask()))
        .prop_map(move |n| (u32::from(ip.network_address()) + n).into())
}

// Note: for these tests we don't really care that it's a valid host
// we only need a host.
// If we filter valid hosts it generates too many rejects
pub fn host_v6(ip: Ipv6Network) -> impl Strategy<Value = Ipv6Addr> {
    (0u128..=number_of_hosts_ipv6(ip.netmask()))
        .prop_map(move |n| (u128::from(ip.network_address()) + n).into())
}

pub fn host(ip: IpNetwork) -> impl Strategy<Value = IpAddr> {
    match ip {
        IpNetwork::V4(ip) => host_v4(ip).prop_map_into().boxed(),
        IpNetwork::V6(ip) => host_v6(ip).prop_map_into().boxed(),
    }
}
