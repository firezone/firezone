//! Client related messages that are needed within connlib

use crate::messages::{IceCredentials, Interface, Key, Relay, RelaysPresence, SecretKey};
use connlib_model::{ClientId, GatewayId, IceCandidate, IpStack, ResourceId, Site, SiteId};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::net::{Ipv4Addr, Ipv6Addr};

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
    #[serde(rename = "gateway_groups", alias = "sites")]
    pub sites: Vec<Site>,

    /// The IP stack supported by this resource.
    #[serde(default)]
    pub ip_stack: Option<IpStack>,
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
    #[serde(rename = "gateway_groups", alias = "sites")]
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
    #[serde(rename = "gateway_groups", alias = "sites")]
    pub sites: Vec<Site>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(serde_json::Value),
    Cidr(serde_json::Value),
    Internet(serde_json::Value),
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

#[derive(Debug, Deserialize, Clone)]
pub struct FlowCreated {
    pub resource_id: ResourceId,
    pub gateway_id: GatewayId,
    pub gateway_public_key: Key,
    pub gateway_ipv4: Ipv4Addr,
    pub gateway_ipv6: Ipv6Addr,
    #[serde(rename = "gateway_group_id", alias = "site_id")]
    pub site_id: SiteId,
    pub preshared_key: SecretKey,
    pub client_ice_credentials: IceCredentials,
    pub gateway_ice_credentials: IceCredentials,
}

#[derive(Debug, Deserialize, Clone)]
pub struct FlowCreationFailed {
    pub resource_id: ResourceId,
    pub reason: FailReason,
    #[serde(default)]
    pub violated_properties: Vec<ViolatedProperty>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum FailReason {
    NotFound,
    Offline,
    VersionMismatch,
    Forbidden,
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

// These messages are the messages that can be received
// by a client.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum IngressMessages {
    Init(InitClient),

    // Resources: arrive in an orderly fashion
    ResourceCreatedOrUpdated(ResourceDescription),
    ResourceDeleted(ResourceId),

    // Backwards compatibility prior to client <> client feature.
    #[serde(alias = "ice_candidates")]
    GatewayIceCandidates(GatewayIceCandidates),
    // Backwards compatibility prior to client <> client feature.
    #[serde(alias = "invalidate_ice_candidates")]
    InvalidateGatewayIceCandidates(GatewayIceCandidates),

    ClientIceCandidates(ClientIceCandidates),
    InvalidateClientIceCandidates(ClientIceCandidates),

    ConfigChanged(ConfigUpdate),

    RelaysPresence(RelaysPresence),

    FlowCreated(FlowCreated),
    FlowCreationFailed(FlowCreationFailed),
}

#[serde_with::serde_as]
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct GatewayIceCandidates {
    /// Gateway's id the ice candidates are sent to / received from
    pub gateway_id: GatewayId,
    /// Actual RTC ice candidates
    #[serde_as(as = "serde_with::VecSkipError<_>")]
    pub candidates: Vec<IceCandidate>,
}

#[serde_with::serde_as]
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct ClientIceCandidates {
    /// Client's id the ice candidates are sent to / received from
    pub client_id: ClientId,
    /// Actual RTC ice candidates
    #[serde_as(as = "serde_with::VecSkipError<_>")]
    pub candidates: Vec<IceCandidate>,
}

// These messages can be sent from a client to a control pane
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
// enum_variant_names: These are the names in the portal!
pub enum EgressMessages {
    CreateFlow {
        resource_id: ResourceId,
        #[serde(rename = "connected_gateway_ids")]
        preferred_gateways: Vec<GatewayId>,
    },
    NewGatewayIceCandidates(GatewayIceCandidates),
    InvalidatedGatewayIceCandidates(GatewayIceCandidates),
    NewClientIceCandidates(ClientIceCandidates),
    InvalidatedClientIceCandidates(ClientIceCandidates),
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
    fn can_deserialize_ice_candidates_message() {
        let json = r#"{"topic":"client","event":"ice_candidates","payload":{"gateway_id":"b3d34a15-55ab-40df-994b-a838e75d65d7","candidates":["candidate:7031633958891736544 1 udp 50331391 35.244.108.190 53909 typ relay"]},"ref":6}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::GatewayIceCandidates(_)));
    }

    #[test]
    fn can_deserialize_invalidate_ice_candidates_message() {
        let json = r#"{"event":"invalidate_ice_candidates","ref":null,"topic":"client","payload":{"candidates":["candidate:7854631899965427361 1 udp 1694498559 172.28.0.100 47717 typ srflx"],"gateway_id":"2b1524e6-239e-4570-bc73-70a188e12101"}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(
            message,
            IngressMessages::InvalidateGatewayIceCandidates(_)
        ));
    }

    #[test]
    fn can_deserialize_flow_created() {
        let json = r#"{"event":"flow_created","ref":null,"topic":"client","payload":{"gateway_group_id":"ef42a07f-87d0-40da-baa7-e881e619ea1c","gateway_id":"d263d490-a0bb-452a-8990-01d27a1f1144","resource_id":"733e8d14-c18d-4931-af30-3639fa09c0c0","preshared_key":"anX2T9RH9mimT5Xd5+HqNGV0bfCodWDHQch1DLiFNls=","client_ice_credentials":{"username":"resc","password":"rqi3ibvfikfaxj3wgp7muh"},"gateway_ice_credentials":{"username":"jbi4","password":"a6oeevhlutevykcifd5r2a"},"gateway_public_key":"uMBCkAxTewfSgypIyxdQ18uCi84HLtKmQJy0wvQrYWY=","gateway_ipv4":"100.72.145.83","gateway_ipv6":"fd00:2021:1111::5:bcfd"}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::FlowCreated(_)));
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
                        "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
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
    fn can_deserialize_bad_resources() {
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
                        "address_foobar": "172.172.0.0/16",
                        "id": "73037362-715d-4a83-a749-f18eadd970e6",
                        "type": "cidr"
                    },
                    {
                        "i_am_not_a_valid_field": null,
                        "type": "cidr"
                    },
                    {
                        "what": "gitlab.mycorp.com",
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
    fn can_deserialize_unknown_flow_creation_failed_err() {
        let json = r#"{"event":"flow_creation_failed","ref":null,"topic":"client","payload":{"resource_id":"f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3","reason":"foobar"}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(
            message,
            IngressMessages::FlowCreationFailed(FlowCreationFailed {
                reason: FailReason::Unknown,
                ..
            })
        ));
    }

    #[test]
    fn can_deserialize_known_flow_creation_failed_err() {
        let json = r#"{"event":"flow_creation_failed","ref":null,"topic":"client","payload":{"resource_id":"f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3","reason":"offline"}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(
            message,
            IngressMessages::FlowCreationFailed(FlowCreationFailed {
                reason: FailReason::Offline,
                ..
            })
        ));
    }

    #[test]
    fn serialize_create_flow_message() {
        let message = EgressMessages::CreateFlow {
            resource_id: "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3".parse().unwrap(),
            preferred_gateways: Vec::new(),
        };
        let expected_json = r#"{"event":"create_flow","payload":{"resource_id":"f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3","connected_gateway_ids":[]}}"#;
        let actual_json = serde_json::to_string(&message).unwrap();

        assert_eq!(actual_json, expected_json);
    }

    #[test]
    fn faulty_candidate_get_skipped() {
        let bad_candidates = serde_json::json!({ "gateway_id": "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3", "candidates": ["foo", "bar", "baz", "candidate:fffeff6435be70ddbf995982 1 udp 1694498559 87.121.72.60 57114 typ srflx raddr 0.0.0.0 rport 0"] });

        let gateway_candidates = GatewayIceCandidates::deserialize(bad_candidates).unwrap();

        assert_eq!(gateway_candidates.candidates.len(), 1);
    }
}
