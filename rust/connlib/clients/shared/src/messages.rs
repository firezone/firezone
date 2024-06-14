use connlib_shared::messages::{
    client::{ResourceDescription, SiteId},
    GatewayId, GatewayResponse, Interface, Key, Relay, RelaysPresence, RequestConnection,
    ResourceId, ReuseConnection,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, net::IpAddr};

#[derive(Debug, PartialEq, Eq, Deserialize, Clone)]
pub struct InitClient {
    pub interface: Interface,
    #[serde(default)]
    pub resources: Vec<ResourceDescription>,
    #[serde(default)]
    pub relays: Vec<Relay>,
}

#[derive(Debug, PartialEq, Eq, Deserialize, Clone)]
pub struct ConfigUpdate {
    pub interface: Interface,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct ConnectionDetails {
    pub relays: Vec<Relay>,
    pub resource_id: ResourceId,
    pub gateway_id: GatewayId,
    pub gateway_remote_ip: IpAddr,
    #[serde(rename = "gateway_group_id")]
    pub site_id: SiteId,
}

#[derive(Debug, Deserialize, Clone, PartialEq)]
pub struct Connect {
    pub gateway_payload: GatewayResponse,
    pub resource_id: ResourceId,
    pub gateway_public_key: Key,
    pub persistent_keepalive: u64,
}

// These messages are the messages that can be received
// by a client.
#[derive(Debug, Deserialize, Clone, PartialEq)]
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

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
pub struct GatewaysIceCandidates {
    /// The list of gateway IDs these candidates will be broadcast to.
    pub gateway_ids: Vec<GatewayId>,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
pub struct GatewayIceCandidates {
    /// Gateway's id the ice candidates are from
    pub gateway_id: GatewayId,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
}

/// The replies that can arrive from the channel by a client
#[derive(Debug, Deserialize, Clone, PartialEq)]
#[serde(untagged)]
#[allow(clippy::large_enum_variant)]
pub enum ReplyMessages {
    ConnectionDetails(ConnectionDetails),
    Connect(Connect),
}

// These messages can be sent from a client to a control pane
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
// enum_variant_names: These are the names in the portal!
pub enum EgressMessages {
    PrepareConnection {
        resource_id: ResourceId,
        connected_gateway_ids: HashSet<GatewayId>,
    },
    RequestConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
    /// Candidates that can be used by the addressed gateways.
    BroadcastIceCandidates(GatewaysIceCandidates),
    /// Candidates that should no longer be used by the addressed gateways.
    BroadcastInvalidatedIceCandidates(GatewaysIceCandidates),
}

#[cfg(test)]
mod test {
    use super::*;
    use chrono::DateTime;
    use connlib_shared::messages::{
        client::{ResourceDescriptionCidr, ResourceDescriptionDns, Site},
        DnsServer, IpDnsServer, Stun, Turn,
    };
    use phoenix_channel::{OutboundRequestId, PhoenixMessage};

    // TODO: request_connection tests

    #[test]
    fn broadcast_ice_candidates() {
        let message = r#"{"topic":"client","event":"broadcast_ice_candidates","payload":{"gateway_ids":["b3d34a15-55ab-40df-994b-a838e75d65d7"],"candidates":["candidate:7031633958891736544 1 udp 50331391 35.244.108.190 53909 typ relay"]},"ref":6}"#;
        let expected = PhoenixMessage::new_message(
            "client",
            EgressMessages::BroadcastIceCandidates(GatewaysIceCandidates {
                gateway_ids: vec!["b3d34a15-55ab-40df-994b-a838e75d65d7".parse().unwrap()],
                candidates: vec![
                    "candidate:7031633958891736544 1 udp 50331391 35.244.108.190 53909 typ relay"
                        .to_owned(),
                ],
            }),
            Some(OutboundRequestId::for_test(6)),
        );

        let ingress_message = serde_json::from_str::<PhoenixMessage<_, ()>>(message).unwrap();

        assert_eq!(ingress_message, expected);
    }

    #[test]
    fn invalidate_ice_candidates_message() {
        let msg = r#"{"event":"invalidate_ice_candidates","ref":null,"topic":"client","payload":{"candidates":["candidate:7854631899965427361 1 udp 1694498559 172.28.0.100 47717 typ srflx"],"gateway_id":"2b1524e6-239e-4570-bc73-70a188e12101"}}"#;
        let expected = IngressMessages::InvalidateIceCandidates(GatewayIceCandidates {
            gateway_id: "2b1524e6-239e-4570-bc73-70a188e12101".parse().unwrap(),
            candidates: vec![
                "candidate:7854631899965427361 1 udp 1694498559 172.28.0.100 47717 typ srflx"
                    .to_owned(),
            ],
        });

        let actual = serde_json::from_str::<IngressMessages>(msg).unwrap();

        assert_eq!(actual, expected);
    }

    #[test]
    fn connection_ready_deserialization() {
        let message = r#"{
            "ref": 0,
            "topic": "client",
            "event": "phx_reply",
            "payload": {
                "status": "ok",
                "response": {
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
                }
            }
        }"#;
        let _: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
    }

    #[test]
    fn config_updated() {
        let m = PhoenixMessage::new_message(
            "client",
            IngressMessages::ConfigChanged(ConfigUpdate {
                interface: Interface {
                    ipv4: "100.67.138.25".parse().unwrap(),
                    ipv6: "fd00:2021:1111::e:65ea".parse().unwrap(),
                    upstream_dns: vec![DnsServer::IpPort(IpDnsServer {
                        address: "1.1.1.1:53".parse().unwrap(),
                    })],
                },
            }),
            None,
        );
        let message = r#"
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
        let ingress_message: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn init_phoenix_message() {
        let m = PhoenixMessage::new_message(
            "client",
            IngressMessages::Init(InitClient {
                interface: Interface {
                    ipv4: "100.72.112.111".parse().unwrap(),
                    ipv6: "fd00:2021:1111::13:efb9".parse().unwrap(),
                    upstream_dns: vec![],
                },
                resources: vec![
                    ResourceDescription::Cidr(ResourceDescriptionCidr {
                        id: "73037362-715d-4a83-a749-f18eadd970e6".parse().unwrap(),
                        address: "172.172.0.0/16".parse().unwrap(),
                        name: "172.172.0.0/16".to_string(),
                        address_description: Some("cidr resource".to_string()),
                        sites: vec![Site {
                            name: "test".to_string(),
                            id: "bf56f32d-7b2c-4f5d-a784-788977d014a4".parse().unwrap(),
                        }],
                    }),
                    ResourceDescription::Cidr(ResourceDescriptionCidr {
                        id: "73037362-715d-4a83-a749-f18eadd970e7".parse().unwrap(),
                        address: "172.173.0.0/16".parse().unwrap(),
                        name: "172.173.0.0/16".to_string(),
                        address_description: None,
                        sites: vec![Site {
                            name: "test".to_string(),
                            id: "bf56f32d-7b2c-4f5d-a784-788977d014a4".parse().unwrap(),
                        }],
                    }),
                    ResourceDescription::Dns(ResourceDescriptionDns {
                        id: "03000143-e25e-45c7-aafb-144990e57dcd".parse().unwrap(),
                        address: "gitlab.mycorp.com".to_string(),
                        name: "gitlab.mycorp.com".to_string(),
                        address_description: Some("dns resource".to_string()),
                        sites: vec![Site {
                            name: "test".to_string(),
                            id: "bf56f32d-7b2c-4f5d-a784-788977d014a4".parse().unwrap(),
                        }],
                    }),
                    ResourceDescription::Dns(ResourceDescriptionDns {
                        id: "03000143-e25e-45c7-aafb-144990e57dce".parse().unwrap(),
                        address: "github.mycorp.com".to_string(),
                        name: "github.mycorp.com".to_string(),
                        address_description: None,
                        sites: vec![Site {
                            name: "test".to_string(),
                            id: "bf56f32d-7b2c-4f5d-a784-788977d014a4".parse().unwrap(),
                        }],
                    }),
                ],
                relays: vec![],
            }),
            None,
        );
        let message = r#"{
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
                    }
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
        let ingress_message: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn messages_ignore_additional_fields() {
        let m = PhoenixMessage::new_message(
            "client",
            IngressMessages::Init(InitClient {
                interface: Interface {
                    ipv4: "100.72.112.111".parse().unwrap(),
                    ipv6: "fd00:2021:1111::13:efb9".parse().unwrap(),
                    upstream_dns: vec![],
                },
                resources: vec![
                    ResourceDescription::Cidr(ResourceDescriptionCidr {
                        id: "73037362-715d-4a83-a749-f18eadd970e6".parse().unwrap(),
                        address: "172.172.0.0/16".parse().unwrap(),
                        name: "172.172.0.0/16".to_string(),
                        address_description: Some("cidr resource".to_string()),
                        sites: vec![Site {
                            name: "test".to_string(),
                            id: "bf56f32d-7b2c-4f5d-a784-788977d014a4".parse().unwrap(),
                        }],
                    }),
                    ResourceDescription::Dns(ResourceDescriptionDns {
                        id: "03000143-e25e-45c7-aafb-144990e57dcd".parse().unwrap(),
                        address: "gitlab.mycorp.com".to_string(),
                        name: "gitlab.mycorp.com".to_string(),
                        address_description: Some("dns resource".to_string()),
                        sites: vec![Site {
                            name: "test".to_string(),
                            id: "bf56f32d-7b2c-4f5d-a784-788977d014a4".parse().unwrap(),
                        }],
                    }),
                ],
                relays: vec![],
            }),
            None,
        );
        let message = r#"{
            "event": "init",
            "payload": {
                "interface": {
                    "ipv4": "100.72.112.111",
                    "ipv6": "fd00:2021:1111::13:efb9",
                    "upstream_dns": [],
                    "extra_config": "foo"
                },
                "resources": [
                    {
                        "address": "172.172.0.0/16",
                        "id": "73037362-715d-4a83-a749-f18eadd970e6",
                        "name": "172.172.0.0/16",
                        "type": "cidr",
                        "address_description": "cidr resource",
                        "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                        "not": "relevant"
                    },
                    {
                        "address": "gitlab.mycorp.com",
                        "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                        "ipv4": "100.126.44.50",
                        "ipv6": "fd00:2021:1111::e:7758",
                        "name": "gitlab.mycorp.com",
                        "type": "dns",
                        "address_description": "dns resource",
                        "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
                        "not": "relevant"
                    }
                ]
            },
            "ref": null,
            "topic": "client"
        }"#;
        let ingress_message: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn messages_ignore_additional_bool_fields() {
        let m = PhoenixMessage::new_message(
            "client",
            IngressMessages::Init(InitClient {
                interface: Interface {
                    ipv4: "100.72.112.111".parse().unwrap(),
                    ipv6: "fd00:2021:1111::13:efb9".parse().unwrap(),
                    upstream_dns: vec![],
                },
                resources: vec![],
                relays: vec![],
            }),
            None,
        );
        let message = r#"{
            "event": "init",
            "payload": {
                "interface": {
                    "ipv4": "100.72.112.111",
                    "ipv6": "fd00:2021:1111::13:efb9",
                    "upstream_dns": [],
                    "additional": true
                },
                "resources": []
            },
            "ref": null,
            "topic": "client"
        }"#;
        let ingress_message: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn messages_ignore_additional_number_fields() {
        let m = PhoenixMessage::new_message(
            "client",
            IngressMessages::Init(InitClient {
                interface: Interface {
                    ipv4: "100.72.112.111".parse().unwrap(),
                    ipv6: "fd00:2021:1111::13:efb9".parse().unwrap(),
                    upstream_dns: vec![],
                },
                resources: vec![],
                relays: vec![],
            }),
            None,
        );
        let message = r#"{
            "event": "init",
            "payload": {
                "interface": {
                    "ipv4": "100.72.112.111",
                    "ipv6": "fd00:2021:1111::13:efb9",
                    "upstream_dns": [],
                    "additional": 0.3
                },
                "resources": []
            },
            "ref": null,
            "topic": "client"
        }"#;
        let ingress_message: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn messages_ignore_additional_object_fields() {
        let m = PhoenixMessage::new_message(
            "client",
            IngressMessages::Init(InitClient {
                interface: Interface {
                    ipv4: "100.72.112.111".parse().unwrap(),
                    ipv6: "fd00:2021:1111::13:efb9".parse().unwrap(),
                    upstream_dns: vec![],
                },
                resources: vec![],
                relays: vec![],
            }),
            None,
        );
        let message = r#"{
            "event": "init",
            "payload": {
                "interface": {
                    "ipv4": "100.72.112.111",
                    "ipv6": "fd00:2021:1111::13:efb9",
                    "upstream_dns": [],
                    "additional": { "ignored": "field" }
                },
                "resources": []
            },
            "ref": null,
            "topic": "client"
        }"#;
        let ingress_message: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn messages_ignore_additional_array_fields() {
        let m = PhoenixMessage::new_message(
            "client",
            IngressMessages::Init(InitClient {
                interface: Interface {
                    ipv4: "100.72.112.111".parse().unwrap(),
                    ipv6: "fd00:2021:1111::13:efb9".parse().unwrap(),
                    upstream_dns: vec![],
                },
                resources: vec![],
                relays: vec![],
            }),
            None,
        );
        let message = r#"{
            "event": "init",
            "payload": {
                "interface": {
                    "ipv4": "100.72.112.111",
                    "ipv6": "fd00:2021:1111::13:efb9",
                    "upstream_dns": [],
                    "additional": [true, false]
                },
                "resources": []
            },
            "ref": null,
            "topic": "client"
        }"#;
        let ingress_message: PhoenixMessage<IngressMessages, ReplyMessages> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn list_relays_message() {
        let m = PhoenixMessage::<EgressMessages, ()>::new_message(
            "client",
            EgressMessages::PrepareConnection {
                resource_id: "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3".parse().unwrap(),
                connected_gateway_ids: HashSet::new(),
            },
            None,
        );
        let message = r#"
            {
                "event": "prepare_connection",
                "payload": {
                    "resource_id": "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3",
                    "connected_gateway_ids": []
                },
                "ref":null,
                "topic": "client"
            }
        "#;
        let egress_message = serde_json::from_str(message).unwrap();
        assert_eq!(m, egress_message);
    }

    #[test]
    fn connection_details_reply() {
        let m = PhoenixMessage::<EgressMessages, ReplyMessages>::new_ok_reply(
            "client",
            ReplyMessages::ConnectionDetails(ConnectionDetails {
                gateway_id: "73037362-715d-4a83-a749-f18eadd970e6".parse().unwrap(),
                gateway_remote_ip: "172.28.0.1".parse().unwrap(),
                resource_id: "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3".parse().unwrap(),
                site_id: "bf56f32d-7b2c-4f5d-a784-788977d014a4".parse().unwrap(),
                relays: vec![
                    Relay::Stun(Stun {
                        id: "c9cb8892-e355-41e6-a882-b6d6c38beb66".parse().unwrap(),
                        addr: "189.172.73.111:3478".parse().unwrap(),
                    }),
                    Relay::Turn(Turn {
                        id: "6a7f3ba9-d9c4-4633-81ab-311276993fbd".parse().unwrap(),
                        expires_at: DateTime::from_timestamp(1686629954, 0).unwrap(),
                        addr: "189.172.73.111:3478".parse().unwrap(),
                        username: "1686629954:C7I74wXYFdFugMYM".to_string(),
                        password: "OXXRDJ7lJN1cm+4+2BWgL87CxDrvpVrn5j3fnJHye98".to_string(),
                    }),
                    Relay::Stun(Stun {
                        id: "1ea93681-aeda-467f-9dca-219c06c18c3d".parse().unwrap(),
                        addr: "[::1]:3478".parse().unwrap(),
                    }),
                    Relay::Turn(Turn {
                        id: "94209389-e18d-4453-a00d-2583ba857592".parse().unwrap(),
                        expires_at: DateTime::from_timestamp(1686629954, 0).unwrap(),
                        addr: "[::1]:3478".parse().unwrap(),
                        username: "1686629954:dpHxHfNfOhxPLfMG".to_string(),
                        password: "8Wtb+3YGxO6ia23JUeSEfZ2yFD6RhGLkbgZwqjebyKY".to_string(),
                    }),
                ],
            }),
            None,
        );
        let message = r#"
            {
                "ref":null,
                "topic":"client",
                "event": "phx_reply",
                "payload": {
                    "response": {
                        "resource_id": "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3",
                        "gateway_id": "73037362-715d-4a83-a749-f18eadd970e6",
                        "gateway_remote_ip": "172.28.0.1",
                        "gateway_group_id": "bf56f32d-7b2c-4f5d-a784-788977d014a4",
                        "relays": [
                            {
                                "id": "c9cb8892-e355-41e6-a882-b6d6c38beb66",
                                "type":"stun",
                                "addr": "189.172.73.111:3478"
                            },
                            {
                                "id": "6a7f3ba9-d9c4-4633-81ab-311276993fbd",
                                "expires_at": 1686629954,
                                "password": "OXXRDJ7lJN1cm+4+2BWgL87CxDrvpVrn5j3fnJHye98",
                                "type": "turn",
                                "addr": "189.172.73.111:3478",
                                "username":"1686629954:C7I74wXYFdFugMYM"
                            },
                            {
                                "id": "1ea93681-aeda-467f-9dca-219c06c18c3d",
                                "type": "stun",
                                "addr": "[::1]:3478"
                            },
                            {
                                "id": "94209389-e18d-4453-a00d-2583ba857592",
                                "expires_at": 1686629954,
                                "password": "8Wtb+3YGxO6ia23JUeSEfZ2yFD6RhGLkbgZwqjebyKY",
                                "type": "turn",
                                "addr": "[::1]:3478",
                                "username": "1686629954:dpHxHfNfOhxPLfMG"
                            }]
                    },
                    "status":"ok"
                }
            }"#;
        let reply_message = serde_json::from_str(message).unwrap();
        assert_eq!(m, reply_message);
    }

    #[test]
    fn relays_presence() {
        let message = r#"
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
        let expected = IngressMessages::RelaysPresence(RelaysPresence {
            disconnected_ids: vec![
                "e95f9517-2152-4677-a16a-fbb2687050a3".parse().unwrap(),
                "b0724bd1-a8cc-4faf-88cd-f21159cfec47".parse().unwrap(),
            ],
            connected: vec![Relay::Turn(Turn {
                id: "0a133356-7a9e-4b9a-b413-0d95a5720fd8".parse().unwrap(),
                expires_at: DateTime::from_timestamp(1719367575, 0).unwrap(),
                addr: "172.28.0.101:3478".parse().unwrap(),
                username: "1719367575:ZQHcVGkdnfgGmcP1".to_owned(),
                password: "ZWYiBeFHOJyYq0mcwAXjRpcuXIJJpzWlOXVdxwttrWg".to_owned(),
            })],
        });

        let ingress_message = serde_json::from_str::<IngressMessages>(message).unwrap();

        assert_eq!(ingress_message, expected);
    }
}
