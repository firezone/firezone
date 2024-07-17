use crate::messages::{
    client::{ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns, Site, SiteId},
    ClientId, GatewayId, RelayId, ResourceId,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use proptest::{
    arbitrary::{any, any_with},
    collection, prop_oneof,
    strategy::{Just, Strategy},
};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    ops::Range,
};

pub fn resource(
    sites: impl Strategy<Value = Vec<Site>> + Clone + 'static,
) -> impl Strategy<Value = ResourceDescription> {
    any::<bool>().prop_flat_map(move |is_dns| {
        if is_dns {
            dns_resource(sites.clone())
                .prop_map(ResourceDescription::Dns)
                .boxed()
        } else {
            cidr_resource(any_ip_network(8), sites.clone())
                .prop_map(ResourceDescription::Cidr)
                .boxed()
        }
    })
}

pub fn dns_resource(
    sites: impl Strategy<Value = Vec<Site>>,
) -> impl Strategy<Value = ResourceDescriptionDns> {
    (
        resource_id(),
        resource_name(),
        domain_name(2..4),
        address_description(),
        sites,
    )
        .prop_map(move |(id, name, address, address_description, sites)| {
            ResourceDescriptionDns {
                id,
                address,
                name,
                sites,
                address_description,
            }
        })
}

pub fn cidr_resource(
    ip_network: impl Strategy<Value = IpNetwork>,
    sites: impl Strategy<Value = Vec<Site>>,
) -> impl Strategy<Value = ResourceDescriptionCidr> {
    (
        resource_id(),
        resource_name(),
        ip_network,
        address_description(),
        sites,
    )
        .prop_map(move |(id, name, address, address_description, sites)| {
            ResourceDescriptionCidr {
                id,
                address,
                name,
                sites,
                address_description,
            }
        })
}

pub fn overlapping_cidr_resource(
    network: IpNetwork,
) -> impl Strategy<Value = ResourceDescriptionCidr> {
    cidr_resource(overlapping_network(network), sites())
}

pub fn cidr_v4_resource(host_mask_bits: usize) -> impl Strategy<Value = ResourceDescriptionCidr> {
    cidr_resource(
        any_ip4_network(host_mask_bits),
        site().prop_map(|s| vec![s]),
    )
}

pub fn cidr_v6_resource(host_mask_bits: usize) -> impl Strategy<Value = ResourceDescriptionCidr> {
    cidr_resource(
        any_ip6_network(host_mask_bits),
        site().prop_map(|s| vec![s]),
    )
}

pub fn address_description() -> impl Strategy<Value = Option<String>> {
    prop_oneof![
        any_with::<String>("[a-z]{4,10}".into()).prop_map(Some),
        Just(None),
    ]
}

pub fn sites() -> impl Strategy<Value = Vec<Site>> {
    collection::vec(site(), 1..=3)
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

pub fn any_ip4_network(host_mask_bits: usize) -> impl Strategy<Value = IpNetwork> {
    any::<Ipv4Addr>().prop_flat_map(move |ip| ip_network(ip.into(), host_mask_bits))
}

pub fn any_ip6_network(host_mask_bits: usize) -> impl Strategy<Value = IpNetwork> {
    any::<Ipv6Addr>().prop_flat_map(move |ip| ip_network(ip.into(), host_mask_bits))
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

pub fn overlapping_network(network: IpNetwork) -> impl Strategy<Value = IpNetwork> {
    (0..=network.netmask()).prop_map(move |netmask| {
        IpNetwork::new_truncate(network.network_address(), netmask).unwrap()
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
