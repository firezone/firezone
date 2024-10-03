//! Client related messages that are needed within connlib

use crate::messages::{
    GatewayResponse, Interface, Key, Relay, RelaysPresence, RequestConnection, ReuseConnection,
};
use connlib_model::{GatewayId, ResourceId, Site, SiteId};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, net::IpAddr};

/// Description of a resource that maps to a DNS record.
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
    #[serde(rename = "gateway_groups")]
    pub sites: Vec<Site>,
}

/// Description of a resource that maps to a CIDR.
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
    #[serde(rename = "gateway_groups")]
    pub sites: Vec<Site>,
}

fn internet_resource_name() -> String {
    "Internet Resource".to_string()
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
    #[serde(rename = "gateway_groups")]
    pub sites: Vec<Site>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(ResourceDescriptionDns),
    Cidr(ResourceDescriptionCidr),
    Internet(ResourceDescriptionInternet),
    #[serde(other)]
    Unknown, // Important for forwards-compatibility with future resource types.
}

#[derive(Debug, Deserialize)]
pub struct InitClient {
    pub interface: Interface,
    #[serde(default)]
    pub resources: Vec<ResourceDescription>,
    #[serde(default)]
    pub relays: Vec<Relay>,
}

#[derive(Debug, Deserialize)]
pub struct ConfigUpdate {
    pub interface: Interface,
}

#[derive(Debug, Deserialize)]
pub struct ConnectionDetails {
    pub resource_id: ResourceId,
    pub gateway_id: GatewayId,
    pub gateway_remote_ip: IpAddr,
    #[serde(rename = "gateway_group_id")]
    pub site_id: SiteId,
}

#[derive(Debug, Deserialize)]
pub struct Connect {
    pub gateway_payload: GatewayResponse,
    pub resource_id: ResourceId,
    pub gateway_public_key: Key,
    pub persistent_keepalive: u64,
}

// These messages are the messages that can be received
// by a client.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum IngressMessages {
    Init(InitClient),

    // Resources: arrive in an orderly fashion
    ResourceCreatedOrUpdated(ResourceDescription),
    ResourceDeleted(ResourceId),

    IceCandidates(GatewayIceCandidates),
    InvalidateIceCandidates(GatewayIceCandidates),

    ConfigChanged(ConfigUpdate),

    RelaysPresence(RelaysPresence),
}

#[derive(Debug, Serialize)]
pub struct GatewaysIceCandidates {
    /// The list of gateway IDs these candidates will be broadcast to.
    pub gateway_ids: Vec<GatewayId>,
    /// Actual RTC ice candidates
    pub candidates: BTreeSet<String>,
}

#[derive(Debug, Deserialize)]
pub struct GatewayIceCandidates {
    /// Gateway's id the ice candidates are from
    pub gateway_id: GatewayId,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
}

/// The replies that can arrive from the channel by a client
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum ReplyMessages {
    ConnectionDetails(ConnectionDetails),
    Connect(Connect),
}

// These messages can be sent from a client to a control pane
#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
// enum_variant_names: These are the names in the portal!
pub enum EgressMessages {
    PrepareConnection {
        resource_id: ResourceId,
        connected_gateway_ids: BTreeSet<GatewayId>,
    },
    RequestConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
    /// Candidates that can be used by the addressed gateways.
    BroadcastIceCandidates(GatewaysIceCandidates),
    /// Candidates that should no longer be used by the addressed gateways.
    BroadcastInvalidatedIceCandidates(GatewaysIceCandidates),
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
                "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]
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
                "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]
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
    fn can_deserialize_ice_candidates_message() {
        let json = r#"{"topic":"client","event":"ice_candidates","payload":{"gateway_id":"b3d34a15-55ab-40df-994b-a838e75d65d7","candidates":["candidate:7031633958891736544 1 udp 50331391 35.244.108.190 53909 typ relay"]},"ref":6}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::IceCandidates(_)));
    }

    #[test]
    fn can_deserialize_invalidate_ice_candidates_message() {
        let json = r#"{"event":"invalidate_ice_candidates","ref":null,"topic":"client","payload":{"candidates":["candidate:7854631899965427361 1 udp 1694498559 172.28.0.100 47717 typ srflx"],"gateway_id":"2b1524e6-239e-4570-bc73-70a188e12101"}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(
            message,
            IngressMessages::InvalidateIceCandidates(_)
        ));
    }

    #[test]
    fn can_deserialize_connect_reply() {
        let json = r#"{
            "resource_id": "ea6570d1-47c7-49d2-9dc3-efff1c0c9e0b",
            "gateway_public_key": "dvy0IwyxAi+txSbAdT7WKgf7K4TekhKzrnYwt5WfbSM=",
            "gateway_payload": {
               "ConnectionAccepted":{
                  "domain_response":{
                     "address":[
                        "2607:f8b0:4008:804::200e",
                        "142.250.64.206"
                     ],
                     "domain":"google.com"
                  },
                  "ice_parameters":{
                     "username":"tGeqOjtGuPzPpuOx",
                     "password":"pMAxxTgHHSdpqHRzHGNvuNsZinLrMxwe"
                  }
               }
            },
            "persistent_keepalive": 25
        }"#;

        let message = serde_json::from_str::<ReplyMessages>(json).unwrap();

        assert!(matches!(message, ReplyMessages::Connect(_)))
    }

    #[test]
    fn can_deserialize_connection_details_reply() {
        let json = r#"
            {
                "resource_id": "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3",
                "gateway_id": "73037362-715d-4a83-a749-f18eadd970e6",
                "gateway_remote_ip": "172.28.0.1",
                "gateway_group_id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"
            }"#;

        let message = serde_json::from_str::<ReplyMessages>(json).unwrap();

        assert!(matches!(message, ReplyMessages::ConnectionDetails(_)));
    }

    #[test]
    fn can_deserialize_config_changed_message() {
        let json = r#"
        {
            "event": "config_changed",
            "ref": null,
            "topic": "client",
            "payload": {
              "interface": {
                "ipv6": "fd00:2021:1111::e:65ea",
                "upstream_dns": [
                  {
                    "protocol": "ip_port",
                    "address": "1.1.1.1:53"
                  }
                ],
                "ipv4": "100.67.138.25"
              }
            }
          }
        "#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::ConfigChanged(_)))
    }

    #[test]
    fn can_deserialize_init_message() {
        let json = r#"{
            "event": "init",
            "payload": {
                "interface": {
                    "ipv4": "100.72.112.111",
                    "ipv6": "fd00:2021:1111::13:efb9",
                    "upstream_dns": []
                },
                "resources": [
                    {
                        "address": "172.172.0.0/16",
                        "id": "73037362-715d-4a83-a749-f18eadd970e6",
                        "name": "172.172.0.0/16",
                        "address_description": "cidr resource",
                        "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                        "type": "cidr"
                    },
                    {
                        "address": "172.173.0.0/16",
                        "id": "73037362-715d-4a83-a749-f18eadd970e7",
                        "name": "172.173.0.0/16",
                        "address_description": null,
                        "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                        "type": "cidr"
                    },
                    {
                        "address": "gitlab.mycorp.com",
                        "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                        "ipv4": "100.126.44.50",
                        "ipv6": "fd00:2021:1111::e:7758",
                        "name": "gitlab.mycorp.com",
                        "address_description": "dns resource",
                        "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                        "type": "dns"
                    },
                    {
                        "address": "github.mycorp.com",
                        "id": "03000143-e25e-45c7-aafb-144990e57dce",
                        "name": "github.mycorp.com",
                        "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                        "type": "dns"
                    }
                ]
            },
            "ref": null,
            "topic": "client"
        }"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::Init(_)));
    }

    #[test]
    fn can_deserialize_relay_presence() {
        let json = r#"
            {
                "event": "relays_presence",
                "ref": null,
                "topic": "client",
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

    #[test]
    fn serialize_prepare_connection_message() {
        let message = EgressMessages::PrepareConnection {
            resource_id: "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3".parse().unwrap(),
            connected_gateway_ids: BTreeSet::new(),
        };
        let expected_json = r#"{"event":"prepare_connection","payload":{"resource_id":"f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3","connected_gateway_ids":[]}}"#;
        let actual_json = serde_json::to_string(&message).unwrap();

        assert_eq!(actual_json, expected_json);
    }
}
