//! What a device hears about the resources it may reach.

use crate::messages::{Filter, Interface, WarnOnInvalidFilter};
use connlib_model::{IpStack, ResourceId, Site};
use ip_network::IpNetwork;
use serde::Deserialize;
use serde_with::{VecSkipError, serde_as};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::Duration;

/// Description of a resource that maps to a DNS record.
#[serde_as]
#[derive(Debug, Deserialize)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: Option<String>,
    #[serde(rename = "gateway_groups", alias = "sites")]
    pub sites: Vec<Site>,

    /// The IP stack supported by this resource.
    #[serde(default)]
    pub ip_stack: Option<IpStack>,

    #[serde_as(as = "VecSkipError<_, WarnOnInvalidFilter>")]
    #[serde(default)]
    pub filters: Vec<Filter>,
}

/// Description of a resource that maps to a CIDR.
#[serde_as]
#[derive(Debug, Deserialize)]
pub struct ResourceDescriptionCidr {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: Option<String>,
    #[serde(rename = "gateway_groups", alias = "sites")]
    pub sites: Vec<Site>,

    #[serde_as(as = "VecSkipError<_, WarnOnInvalidFilter>")]
    #[serde(default)]
    pub filters: Vec<Filter>,
}

fn internet_resource_name() -> String {
    "Internet Resource".to_string()
}

/// A pool of devices the portal admits by its membership criteria.
///
/// Members are never sent: a packet to a tunnel address asks the portal for access with
/// [`EgressMessages::RequestAccess`], and the portal answers with the pool it granted.
#[serde_as]
#[derive(Debug, Deserialize)]
pub struct ResourceDescriptionDevicePool {
    pub id: ResourceId,
    pub name: String,
    #[serde_as(as = "VecSkipError<_, WarnOnInvalidFilter>")]
    #[serde(default)]
    pub filters: Vec<Filter>,
}

/// Description of an internet resource.
#[derive(Debug, Deserialize)]
pub struct ResourceDescriptionInternet {
    /// Name of the resource.
    ///
    /// Used only for display.
    #[serde(default = "internet_resource_name")]
    pub name: String,
    /// Resource's id.
    pub id: ResourceId,
    /// Sites for the internet resource
    #[serde(rename = "gateway_groups", alias = "sites")]
    pub sites: Vec<Site>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(serde_json::Value),
    Cidr(serde_json::Value),
    Internet(serde_json::Value),
    DevicePool(serde_json::Value),
    #[serde(other)]
    Unknown, // Important for forwards-compatibility with future resource types.
}

#[derive(Debug, Deserialize)]
pub struct ConfigUpdate {
    pub interface: Interface,
}

/// Authorization metadata granted by a resource for an inbound peer
/// connection. Built on the target side from [`ClientDeviceAccessAuthorized`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceAuthorization {
    /// The authorising resource ID.
    pub resource_id: ResourceId,

    /// Filters that govern inbound traffic the remote peer is allowed to
    /// send to us through this resource.
    pub filters: Vec<Filter>,

    /// When the authorization expires, measured from the unix epoch.
    pub expires_at: Option<Duration>,
}

/// Sent by the portal when a resource's filters change while access remains
/// authorized. Receivers must update the inbound filter for any peer the
/// resource currently authorizes.
#[serde_as]
#[derive(Debug, Deserialize, Clone)]
pub struct ResourceFiltersUpdated {
    pub id: ResourceId,
    #[serde_as(as = "VecSkipError<_, WarnOnInvalidFilter>")]
    pub filters: Vec<Filter>,
}

/// Portal's response when a device name is resolved.
#[derive(Debug, Deserialize, Clone)]
pub struct DeviceDomainResolved {
    pub domain: String,
    pub ipv4: Ipv4Addr,
    pub ipv6: Ipv6Addr,
}

/// Portal's response when a device name cannot be resolved.
#[derive(Debug, Deserialize, Clone)]
pub struct DeviceDomainResolutionFailed {
    pub domain: String,
    pub reason: FailReason,
}

/// Portal's answer to a PTR query in the device domain.
#[derive(Debug, Deserialize, Clone)]
pub struct DeviceDomainBrowsed {
    pub domain: String,
    pub names: Vec<String>,
    /// How long, in seconds, the answer may be cached.
    pub ttl: u32,
    /// How many names there are in all, more than `names` holds if the portal capped them.
    pub total: usize,
}

/// Portal's response when a PTR query in the device domain cannot be answered.
#[derive(Debug, Deserialize, Clone)]
pub struct DeviceDomainBrowseFailed {
    pub domain: String,
    pub reason: FailReason,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum FailReason {
    NotFound,
    Offline,
    VersionMismatch,
    Forbidden,
    Disabled,
    AmbiguousAddress,
    MissingAddress,
    InvalidAddress,
    NotADevice,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum ViolatedProperty {
    RemoteIpLocationRegion,
    RemoteIp,
    ProviderId,
    CurrentUtcDatetime,
    ClientVerified,
    #[serde(other)]
    Unknown,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn can_deserialize_internet_resource() {
        let resources = r#"[
            {
                "id": "73037362-715d-4a83-a749-f18eadd970e6",
                "type": "cidr",
                "name": "172.172.0.0/16",
                "address": "172.172.0.0/16",
                "address_description": "cidr resource",
                "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]
            },
            {
                "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                "type": "dns",
                "name": "gitlab.mycorp.com",
                "address": "gitlab.mycorp.com",
                "address_description": "dns resource",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]
            },
            {
                "id": "1106047c-cd5d-4151-b679-96b93da7383b",
                "type": "internet",
                "name": "Internet Resource",
                "gateway_groups": [{"name": "test", "id": "eb94482a-94f4-47cb-8127-14fb3afa5516"}],
                "not": "relevant",
                "some_other": [
                    "field"
                ]
            }
        ]"#;

        serde_json::from_str::<Vec<ResourceDescription>>(resources).unwrap();
    }

    #[test]
    fn can_deserialize_unknown_resource() {
        let resources = r#"[
            {
                "id": "73037362-715d-4a83-a749-f18eadd970e6",
                "type": "cidr",
                "name": "172.172.0.0/16",
                "address": "172.172.0.0/16",
                "address_description": "cidr resource",
                "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]
            },
            {
                "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                "type": "dns",
                "name": "gitlab.mycorp.com",
                "address": "gitlab.mycorp.com",
                "address_description": "dns resource",
                "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]
            },
            {
                "id": "1106047c-cd5d-4151-b679-96b93da7383b",
                "type": "internet",
                "name": "Internet Resource",
                "gateway_groups": [{"name": "test", "id": "eb94482a-94f4-47cb-8127-14fb3afa5516"}],
                "not": "relevant",
                "some_other": [
                    "field"
                ]
            },
            {
                "type": "what_is_this"
            }
        ]"#;

        serde_json::from_str::<Vec<ResourceDescription>>(resources).unwrap();
    }

    #[test]
    fn can_deserialize_device_pool_resource() {
        let resources = r#"[
            {
                "id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
                "type": "device_pool",
                "name": "Employee Laptops",
                "filters": [
                    {
                        "protocol": "tcp",
                        "port_range_start": 22,
                        "port_range_end": 22
                    }
                ]
            }
        ]"#;

        let parsed = serde_json::from_str::<Vec<ResourceDescription>>(resources).unwrap();

        let ResourceDescription::DevicePool(json) = &parsed[0] else {
            panic!("Expected DevicePool");
        };
        let desc = ResourceDescriptionDevicePool::deserialize(json).unwrap();
        assert_eq!(desc.name, "Employee Laptops");
        assert_eq!(
            desc.filters,
            vec![Filter::Tcp(crate::messages::PortRange::single(22))]
        );
    }
}
