use crate::messages::{ResourceDescriptionCidr, ResourceDescriptionDns, ResourceId};
use ip_network::IpNetwork;
use proptest::{
    arbitrary::{any, any_with},
    strategy::Strategy,
};
use std::net::IpAddr;

pub fn dns_resource() -> impl Strategy<Value = ResourceDescriptionDns> {
    (resource_id(), resource_name(), dns_resource_address())
        .prop_map(|(id, name, address)| ResourceDescriptionDns { id, address, name })
}

pub fn cidr_resource() -> impl Strategy<Value = ResourceDescriptionCidr> {
    (resource_id(), resource_name(), ip_network())
        .prop_map(|(id, name, address)| ResourceDescriptionCidr { id, address, name })
}

pub fn resource_id() -> impl Strategy<Value = ResourceId> {
    any::<u128>().prop_map(ResourceId::from_u128)
}

pub fn resource_name() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{4,10}".into())
}

pub fn dns_resource_address() -> impl Strategy<Value = String> {
    any_with::<String>("[a-z]{4,10}".into())
}

pub fn ip_network() -> impl Strategy<Value = IpNetwork> {
    (any::<IpAddr>(), netmask()).prop_filter_map(
        "ip + netmask combination must be a valid `IpNetwork`",
        |(ip, netmask)| IpNetwork::new(ip, netmask).ok(),
    )
}

pub fn netmask() -> impl Strategy<Value = u8> {
    any::<u8>()
        .prop_filter("must not be zero", |v| *v != 0)
        .prop_map(|v| v % 33)
}
