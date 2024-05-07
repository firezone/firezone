use crate::messages::{
    client::ResourceDescriptionCidr,
    client::{GatewayGroup, ResourceDescriptionDns, SiteId},
    ClientId, ResourceId,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use proptest::{
    arbitrary::{any, any_with},
    collection, sample,
    strategy::Strategy,
};
use std::net::{Ipv4Addr, Ipv6Addr};

pub fn dns_resource() -> impl Strategy<Value = ResourceDescriptionDns> {
    (
        resource_id(),
        resource_name(),
        dns_resource_address(),
        gateway_groups(),
        address_description(),
    )
        .prop_map(|(id, name, address, gateway_groups, address_description)| {
            ResourceDescriptionDns {
                id,
                address,
                name,
                gateway_groups,
                address_description,
            }
        })
}

pub fn cidr_resource(host_mask_bits: usize) -> impl Strategy<Value = ResourceDescriptionCidr> {
    (
        resource_id(),
        resource_name(),
        ip_network(host_mask_bits),
        gateway_groups(),
        address_description(),
    )
        .prop_map(|(id, name, address, gateway_groups, address_description)| {
            ResourceDescriptionCidr {
                id,
                address,
                name,
                gateway_groups,
                address_description,
            }
        })
}

pub fn address_description() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{4,10}".into())
}

pub fn gateway_groups() -> impl Strategy<Value = Vec<GatewayGroup>> {
    collection::vec(gateway_group(), 1..=10)
}

pub fn gateway_group() -> impl Strategy<Value = GatewayGroup> {
    (any_with::<String>("[a-z]{4,10}".into()), any::<u128>()).prop_map(|(name, id)| GatewayGroup {
        name,
        id: SiteId::from_u128(id),
    })
}

pub fn resource_id() -> impl Strategy<Value = ResourceId> + Clone {
    any::<u128>().prop_map(ResourceId::from_u128)
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
