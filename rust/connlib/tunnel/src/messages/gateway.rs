//! Gateway related messages that are needed within connlib

use crate::messages::{IceCredentials, Interface, Key, Relay, RelaysPresence, SecretKey};

use chrono::{serde::ts_seconds_option, DateTime, Utc};
use connlib_model::{ClientId, ResourceId};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    net::{Ipv4Addr, Ipv6Addr},
};

pub type Filters = Vec<Filter>;

/// Description of a resource that maps to a DNS record.
#[derive(Debug, Deserialize, Clone)]
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
#[derive(Debug, Deserialize, Clone)]
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

/// Description of an Internet resource.
#[derive(Debug, Deserialize, Clone)]
pub struct ResourceDescriptionInternet {
    pub id: ResourceId,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(ResourceDescriptionDns),
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

impl ResourceDescription {
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

// TODO: Should this have a resource?
#[derive(Debug, Deserialize, Clone)]
pub struct InitGateway {
    pub interface: Interface,
    pub config: Config,
    #[serde(default)]
    pub relays: Vec<Relay>,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Config {
    pub ipv4_masquerade_enabled: bool,
    pub ipv6_masquerade_enabled: bool,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RemoveResource {
    pub id: ResourceId,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RejectAccess {
    pub client_id: ClientId,
    pub resource_id: ResourceId,
}

// These messages are the messages that can be received
// either by a client or a gateway by the client.
#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
#[expect(clippy::large_enum_variant)]
pub enum IngressMessages {
    RejectAccess(RejectAccess),
    IceCandidates(ClientIceCandidates),
    InvalidateIceCandidates(ClientIceCandidates),
    Init(InitGateway),
    RelaysPresence(RelaysPresence),
    ResourceUpdated(ResourceDescription),
    AuthorizeFlow {
        resource: ResourceDescription,
        #[serde(with = "ts_seconds_option")]
        expires_at: Option<DateTime<Utc>>,

        client_id: ClientId,
        client_key: Key,
        client_ipv4: Ipv4Addr,
        client_ipv6: Ipv6Addr,

        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,

        #[serde(rename = "ref")]
        reference: String,
    },
}

/// A client's ice candidate message.
#[derive(Debug, Serialize, Clone)]
pub struct ClientsIceCandidates {
    /// Client's id the ice candidates are meant for
    pub client_ids: Vec<ClientId>,
    /// Actual RTC ice candidates
    pub candidates: BTreeSet<String>,
}

/// A client's ice candidate message.
#[derive(Debug, Deserialize, Clone)]
pub struct ClientIceCandidates {
    /// Client's id the ice candidates came from
    pub client_id: ClientId,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
}

// These messages can be sent from a gateway
// to a control pane.
#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum EgressMessages {
    BroadcastIceCandidates(ClientsIceCandidates),
    BroadcastInvalidatedIceCandidates(ClientsIceCandidates),
    AuthorizeFlowOk {
        #[serde(rename = "ref")]
        reference: String,
    },
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

    #[test]
    fn can_deserialize_invalidate_ice_candidates_message() {
        let json = r#"{"event":"invalidate_ice_candidates","ref":null,"topic":"gateway","payload":{"candidates":["candidate:7854631899965427361 1 udp 1694498559 172.28.0.100 47717 typ srflx"],"client_id":"2b1524e6-239e-4570-bc73-70a188e12101"}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(
            message,
            IngressMessages::InvalidateIceCandidates(_)
        ));
    }

    #[test]
    fn can_deserialize_init_message() {
        let json = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::Init(_)));
    }

    #[test]
    fn can_deserialize_resource_updated_message() {
        let json = r#"{"event":"resource_updated","ref":null,"topic":"gateway","payload":{"id":"57f9ebbb-21d5-4f9f-bf86-b25122fc7a43","name":"?.httpbin","type":"dns","address":"?.httpbin","filters":[{"protocol":"icmp"},{"protocol":"tcp"}]}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::ResourceUpdated(_)));
    }

    #[test]
    fn can_deserialize_relays_presence_message() {
        let json = r#"
        {
            "event": "relays_presence",
            "ref": null,
            "topic": "gateway",
            "payload": {
                "disconnected_ids": [
                    "e95f9517-2152-4677-a16a-fbb2687050a3",
                    "b0724bd1-a8cc-4faf-88cd-f21159cfec47"
                ],
                "connected": [
                    {
                        "id": "0a133356-7a9e-4b9a-b413-0d95a5720fd8",
                        "type": "turn",
                        "username": "1719367575:ZQHcVGkdnfgGmcP1",
                        "password": "ZWYiBeFHOJyYq0mcwAXjRpcuXIJJpzWlOXVdxwttrWg",
                        "addr": "172.28.0.101:3478",
                        "expires_at": 1719367575
                    }
                ]
            }
        }
        "#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::RelaysPresence(_)));
    }
}
