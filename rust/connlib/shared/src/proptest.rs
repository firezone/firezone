use crate::messages::{
    client::ResourceDescriptionCidr,
    client::{ResourceDescription, ResourceDescriptionDns, Site, SiteId},
    ClientId, GatewayId, ResourceId,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools;
use proptest::{
    arbitrary::{any, any_with},
    collection, sample,
    strategy::{Just, Strategy},
};
use std::net::{Ipv4Addr, Ipv6Addr};

// Generate resources sharing 1 gateway group
pub fn resources_sharing_group() -> impl Strategy<Value = (Vec<ResourceDescription>, Site)> {
    (collection::vec(sites(), 1..=100), site()).prop_flat_map(|(groups, g)| {
        (
            groups
                .iter()
                .map(|gs| {
                    let mut groups = gs.clone();
                    groups.push(g.clone());
                    resource(groups.clone())
                })
                .collect_vec(),
            Just(g),
        )
    })
}

// Generate resources sharing all gateway groups
pub fn resources_sharing_all_groups() -> impl Strategy<Value = Vec<ResourceDescription>> {
    sites().prop_flat_map(|sites| collection::vec(resource(sites), 1..=100))
}

pub fn resource(sites: Vec<Site>) -> impl Strategy<Value = ResourceDescription> {
    any::<bool>().prop_flat_map(move |is_dns| {
        if is_dns {
            dns_resource_with_groups(sites.clone())
                .prop_map(ResourceDescription::Dns)
                .boxed()
        } else {
            cidr_resource_with_groups(8, sites.clone())
                .prop_map(ResourceDescription::Cidr)
                .boxed()
        }
    })
}

pub fn dns_resource_with_groups(sites: Vec<Site>) -> impl Strategy<Value = ResourceDescriptionDns> {
    (
        resource_id(),
        resource_name(),
        dns_resource_address(),
        address_description(),
    )
        .prop_map(
            move |(id, name, address, address_description)| ResourceDescriptionDns {
                id,
                address,
                name,
                sites: sites.clone(),
                address_description,
            },
        )
}

pub fn cidr_resource_with_groups(
    host_mask_bits: usize,
    sites: Vec<Site>,
) -> impl Strategy<Value = ResourceDescriptionCidr> {
    (
        resource_id(),
        resource_name(),
        ip_network(host_mask_bits),
        address_description(),
    )
        .prop_map(
            move |(id, name, address, address_description)| ResourceDescriptionCidr {
                id,
                address,
                name,
                sites: sites.clone(),
                address_description,
            },
        )
}

pub fn dns_resource() -> impl Strategy<Value = ResourceDescriptionDns> {
    sites().prop_flat_map(dns_resource_with_groups)
}

pub fn cidr_resource(host_mask_bits: usize) -> impl Strategy<Value = ResourceDescriptionCidr> {
    sites().prop_flat_map(move |sites| cidr_resource_with_groups(host_mask_bits, sites))
}

pub fn address_description() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{4,10}".into())
}

pub fn sites() -> impl Strategy<Value = Vec<Site>> {
    collection::vec(site(), 1..=10)
}

pub fn site() -> impl Strategy<Value = Site> {
    (any_with::<String>("[a-z]{4,10}".into()), any::<u128>()).prop_map(|(name, id)| Site {
        name,
        id: SiteId::from_u128(id),
    })
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

pub fn resource_name() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{4,10}".into())
}

pub fn dns_resource_address() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{4,10}".into())
}

/// A strategy of IP networks, configurable by the size of the host mask.
///
/// For the full range of networks, specify 0.
pub fn ip_network(host_mask_bits: usize) -> impl Strategy<Value = IpNetwork> {
    (any::<bool>()).prop_flat_map(move |is_ip4| {
        if is_ip4 {
            ip4_network(host_mask_bits).prop_map(IpNetwork::V4).boxed()
        } else {
            ip6_network(host_mask_bits).prop_map(IpNetwork::V6).boxed()
        }
    })
}

/// A strategy of IPv4 networks, configurable by the size of the host mask.
pub fn ip4_network(host_mask_bits: usize) -> impl Strategy<Value = Ipv4Network> {
    assert!(host_mask_bits > 0);
    assert!(host_mask_bits <= 32);

    (any::<Ipv4Addr>(), any::<sample::Index>()).prop_filter_map(
        "ip network must be valid",
        move |(ip, netmask)| {
            let host_mask = netmask.index(host_mask_bits);
            let netmask = 32 - host_mask;

            Ipv4Network::new(ip, netmask as u8).ok()
        },
    )
}

/// A strategy of IPv6 networks, configurable by the size of the host mask.
pub fn ip6_network(host_mask_bits: usize) -> impl Strategy<Value = Ipv6Network> {
    assert!(host_mask_bits > 0);
    assert!(host_mask_bits <= 128);

    (any::<Ipv6Addr>(), any::<sample::Index>()).prop_filter_map(
        "ip network must be valid",
        move |(ip, netmask)| {
            let host_mask = netmask.index(host_mask_bits);
            let netmask = 128 - host_mask;

            Ipv6Network::new(ip, netmask as u8).ok()
        },
    )
}
