use crate::messages::{
    client::{ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns, Site, SiteId},
    ClientId, GatewayId, RelayId, ResourceId,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use proptest::{
    arbitrary::{any, any_with},
    collection, prop_oneof, sample,
    strategy::{Just, Strategy},
};
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    ops::Range,
};

pub fn resource(
    site: impl Strategy<Value = Site> + Clone + 'static,
) -> impl Strategy<Value = ResourceDescription> {
    any::<bool>().prop_flat_map(move |is_dns| {
        if is_dns {
            dns_resource(site.clone())
                .prop_map(ResourceDescription::Dns)
                .boxed()
        } else {
            cidr_resource(ip_network(8), site.clone())
                .prop_map(ResourceDescription::Cidr)
                .boxed()
        }
    })
}

pub fn dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = ResourceDescriptionDns> {
    (
        resource_id(),
        resource_name(),
        domain_name(2..4),
        address_description(),
        site,
    )
        .prop_map(move |(id, name, address, address_description, site)| {
            ResourceDescriptionDns {
                id,
                address,
                name,
                sites: vec![site],
                address_description,
            }
        })
}

pub fn cidr_resource(
    ip_network: impl Strategy<Value = IpNetwork>,
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = ResourceDescriptionCidr> {
    (
        resource_id(),
        resource_name(),
        ip_network,
        address_description(),
        site,
    )
        .prop_map(move |(id, name, address, address_description, site)| {
            ResourceDescriptionCidr {
                id,
                address,
                name,
                sites: vec![site],
                address_description,
            }
        })
}

pub fn cidr_v4_resource(host_mask_bits: usize) -> impl Strategy<Value = ResourceDescriptionCidr> {
    cidr_resource(ip4_network(host_mask_bits).prop_map(IpNetwork::V4), site())
}

pub fn cidr_v6_resource(host_mask_bits: usize) -> impl Strategy<Value = ResourceDescriptionCidr> {
    cidr_resource(ip6_network(host_mask_bits).prop_map(IpNetwork::V6), site())
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

    (any::<Ipv4Addr>(), any::<sample::Index>()).prop_map(move |(ip, netmask)| {
        let host_mask = netmask.index(host_mask_bits);
        let netmask = 32 - host_mask;

        Ipv4Network::new_truncate(ip, netmask as u8).expect("netmask to be <= 32")
    })
}

/// A strategy of IPv6 networks, configurable by the size of the host mask.
pub fn ip6_network(host_mask_bits: usize) -> impl Strategy<Value = Ipv6Network> {
    assert!(host_mask_bits > 0);
    assert!(host_mask_bits <= 128);

    (any::<Ipv6Addr>(), any::<sample::Index>()).prop_map(move |(ip, netmask)| {
        let host_mask = netmask.index(host_mask_bits);
        let netmask = 128 - host_mask;

        Ipv6Network::new_truncate(ip, netmask as u8).expect("netmask to be <= 128")
    })
}
