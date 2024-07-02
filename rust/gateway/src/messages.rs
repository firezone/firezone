use std::{collections::HashSet, net::IpAddr};

use chrono::{serde::ts_seconds_option, DateTime, Utc};
use connlib_shared::{
    messages::{
        gateway::ResourceDescription, ClientId, GatewayResponse, Interface, Offer, Peer, Relay,
        RelaysPresence, ResourceId,
    },
    DomainName,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Clone, PartialEq)]
pub struct ClientPayload {
    pub ice_parameters: Offer,
    pub domain: Option<ResolveRequest>,
}

// TODO: Should this have a resource?
#[derive(Debug, PartialEq, Eq, Deserialize, Clone)]
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

#[derive(Debug, Deserialize, Clone, PartialEq)]
pub struct Client {
    pub id: ClientId,
    pub payload: ClientPayload,
    pub peer: Peer,
}

#[derive(Debug, Deserialize, Clone, PartialEq)]
pub struct RequestConnection {
    pub resource: ResourceDescription,
    pub client: Client,
    #[serde(rename = "ref")]
    pub reference: String,
    #[serde(with = "ts_seconds_option")]
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct RemoveResource {
    pub id: ResourceId,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(untagged)]
pub enum ResolveRequest {
    ReturnResponse(DomainName),
    MapResponse {
        name: DomainName,
        proxy_ips: Vec<IpAddr>,
    },
}

impl ResolveRequest {
    pub fn name(&self) -> DomainName {
        match self {
            ResolveRequest::ReturnResponse(name) => name.clone(),
            ResolveRequest::MapResponse { name, .. } => name.clone(),
        }
    }

    // TODO: remove me
    pub fn as_tuple(&self) -> (DomainName, Vec<IpAddr>) {
        match self {
            ResolveRequest::ReturnResponse(name) => (name.clone(), Vec::new()),
            ResolveRequest::MapResponse {
                name,
                proxy_ips: proxy,
            } => (name.clone(), proxy.clone()),
        }
    }
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct AllowAccess {
    pub client_id: ClientId,
    pub resource: ResourceDescription,
    #[serde(with = "ts_seconds_option")]
    pub expires_at: Option<DateTime<Utc>>,
    pub payload: Option<ResolveRequest>,
    #[serde(rename = "ref")]
    pub reference: String,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct RejectAccess {
    pub client_id: ClientId,
    pub resource_id: ResourceId,
}

// These messages are the messages that can be received
// either by a client or a gateway by the client.
#[derive(Debug, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum IngressMessages {
    RequestConnection(RequestConnection),
    AllowAccess(AllowAccess),
    RejectAccess(RejectAccess),
    IceCandidates(ClientIceCandidates),
    InvalidateIceCandidates(ClientIceCandidates),
    Init(InitGateway),
    RelaysPresence(RelaysPresence),
    ResourceUpdated(ResourceDescription),
}

/// A client's ice candidate message.
#[derive(Debug, Serialize, Clone, PartialEq, Eq)]
pub struct ClientsIceCandidates {
    /// Client's id the ice candidates are meant for
    pub client_ids: Vec<ClientId>,
    /// Actual RTC ice candidates
    pub candidates: HashSet<String>,
}

/// A client's ice candidate message.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
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
    ConnectionReady(ConnectionReady),
    BroadcastIceCandidates(ClientsIceCandidates),
    BroadcastInvalidatedIceCandidates(ClientsIceCandidates),
}

#[derive(Debug, Serialize, Clone)]
pub struct ConnectionReady {
    #[serde(rename = "ref")]
    pub reference: String,
    pub gateway_payload: GatewayResponse,
}

#[cfg(test)]
mod test {
    use super::*;
    use connlib_shared::messages::gateway::Filter;
    use connlib_shared::messages::gateway::PortRange;
    use connlib_shared::messages::gateway::ResourceDescriptionDns;
    use connlib_shared::messages::Turn;
    use phoenix_channel::PhoenixMessage;

    #[test]
    fn request_connection_message() {
        let message = r#"{
            "ref": null,
            "topic": "gateway",
            "event": "request_connection",
            "payload": {
                "client": {
                    "id": "3a25ff38-f8d7-47de-9b30-c7c40c206083",
                    "peer": {
                        "ipv6": "fd00:2021:1111::3a:ab1b",
                        "public_key": "OR2dYCLwMEtwqtjOxSm4SU7BbHJDfM8ZCqK7HKXXxDw=",
                        "ipv4": "100.114.114.30",
                        "persistent_keepalive": 25,
                        "preshared_key": "sMeTuiJ3mezfpVdan948CmisIWbwBZ1z7jBNnbVtfVg="
                    },
                    "payload": {
                        "ice_parameters": {
                            "username": "PvCPFevCOgkvVCtH",
                            "password": "xEwoXEzHuSyrcgOCSRnwOXQVnbnbeGeF"
                        }
                    }
                },
                "resource": {
                    "id": "ea6570d1-47c7-49d2-9dc3-efff1c0c9e0b",
                    "name": "172.20.0.1/16",
                    "type": "cidr",
                    "address": "172.20.0.0/16",
                    "filters": []
                },
                "ref": "78e1159d-9dc6-480d-b2ef-1fcec2cd5730",
                "expires_at": 1719367575,
                "actor": {
                    "id": "3b1d86a0-4737-4814-8add-cfec42669511"
                },
                "relays": [
                    {
                        "id": "0bfc5e02-a093-423b-827b-002d7d2bb407",
                        "type": "stun",
                        "addr": "172.28.0.101:3478"
                    },
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
        }"#;
        // TODO: We are just testing we can deserialize for now.
        let _: PhoenixMessage<IngressMessages, ()> = serde_json::from_str(message).unwrap();
    }

    #[test]
    fn request_connection_with_payload() {
        let message = r#"{
  "event": "request_connection",
  "ref": null,
  "topic": "gateway",
  "payload": {
    "client": {
      "id": "2e5c0210-3ac0-49cd-bfc9-8005046291de",
      "peer": {
        "ipv6": "fd00:2021:1111::4:4616",
        "public_key": "zHtdIFPDm8QQkqjbmAc1r8O1WegviA6UeUTP6rpminA=",
        "ipv4": "100.87.247.184",
        "persistent_keepalive": 25,
        "preshared_key": "BzPiNE9qszKczZcZzGsyieLYeJ2EQfkfdibls/l3beM="
      },
      "payload": {
        "domain": {
          "name": "download.httpbin",
          "proxy_ips": [
            "100.96.0.1",
            "100.96.0.2",
            "100.96.0.3",
            "100.96.0.4",
            "fd00:2021:1111:8000::",
            "fd00:2021:1111:8000::1",
            "fd00:2021:1111:8000::2",
            "fd00:2021:1111:8000::3"
          ]
        },
        "ice_parameters": {
          "password": "MMceouYA5jGIPkxbvIiLvD",
          "username": "aYaH"
        }
      }
    },
    "resource": {
      "id": "619fbe83-bc95-4635-9a08-68da9a944c88",
      "name": "?.httpbin",
      "type": "dns",
      "address": "?.httpbin",
      "filters": [
        {
          "protocol": "tcp",
          "port_range_end": 80,
          "port_range_start": 80
        },
        {
          "protocol": "tcp",
          "port_range_end": 433,
          "port_range_start": 433
        },
        {
          "protocol": "udp",
          "port_range_end": 53,
          "port_range_start": 53
        },
        {
          "protocol": "icmp"
        }
      ]
    },
    "ref": "SFMyNTY.g2gDbQAAAVhnMmdFV0hjVllYQnBRR0Z3YVM1amJIVnpkR1Z5TG14dlkyRnNBQUFENndBQUFBQm1hakdpYUFWWWR4VmhjR2xBWVhCcExtTnNkWE4wWlhJdWJHOWpZV3dBQUFQZ0FBQUFBR1pxTWFKM0owVnNhWGhwY2k1UWFHOWxibWw0TGxOdlkydGxkQzVXTVM1S1UwOU9VMlZ5YVdGc2FYcGxjbTBBQUFBR1kyeHBaVzUwWVFSaEFHMEFBQUFrTmpFNVptSmxPRE10WW1NNU5TMDBOak0xTFRsaE1EZ3ROamhrWVRsaE9UUTBZemc0YkFBQUFBRm9BbTBBQUFBTGRISmhZMlZ3WVhKbGJuUnRBQUFBTnpBd0xUZzROMlptTUdKaU1EZGhOakU1TkdOa01tTTRNamsxWkRGaE1tSXlabU15TFRnMU9USXpZV1kzTVRZNVlUQmlPR1F0TURGcW4GAKnP0g6QAWIAAVGA.MBccK7A6wR4EA1ZkKnGlHzAnh-tRitZ2d97q_IvzoD8",
    "expires_at": 1718663242,
    "actor": {
      "id": "0f4a5f16-3c59-47c9-a7c1-31de7a51b26c"
    },
    "relays": [
      {
        "id": "75542064-e5f7-491b-b054-5350b4f34963",
        "type": "turn",
        "addr": "172.28.0.101:3478",
        "username": "1719445215:D8RIljXHIIYGn88dBjUIFw",
        "password": "AipiIetIXo33EnV36U+nET8lAtJXr+iSwwFU5VOfF5k",
        "expires_at": 1719445215
      },
      {
        "id": "649cd79f-2536-4f9d-906b-d20b1c5d3ac3",
        "type": "turn",
        "addr": "172.28.0.201:3478",
        "username": "1719445215:hpx751e3Wt-Mg9kv7yv0mg",
        "password": "D6A4ytn/U8xAvfOE1l3G/rNlduZD1gq21BFXhITkjpA",
        "expires_at": 1719445215
      }
    ],
    "flow_id": "b944e68a-c936-4a81-bd8d-88c45efdcb2c"
  }
}"#;
        let _: PhoenixMessage<IngressMessages, ()> = serde_json::from_str(message).unwrap();
    }

    #[test]
    fn request_connection_with_payload_old_format() {
        let message = r#"{
  "event": "request_connection",
  "ref": null,
  "topic": "gateway",
  "payload": {
    "client": {
      "id": "2e5c0210-3ac0-49cd-bfc9-8005046291de",
      "peer": {
        "ipv6": "fd00:2021:1111::4:4616",
        "public_key": "zHtdIFPDm8QQkqjbmAc1r8O1WegviA6UeUTP6rpminA=",
        "ipv4": "100.87.247.184",
        "persistent_keepalive": 25,
        "preshared_key": "BzPiNE9qszKczZcZzGsyieLYeJ2EQfkfdibls/l3beM="
      },
      "payload": {
        "domain": "download.httpbin",
        "ice_parameters": {
          "password": "MMceouYA5jGIPkxbvIiLvD",
          "username": "aYaH"
        }
      }
    },
    "resource": {
      "id": "619fbe83-bc95-4635-9a08-68da9a944c88",
      "name": "?.httpbin",
      "type": "dns",
      "address": "?.httpbin",
      "filters": [
        {
          "protocol": "tcp",
          "port_range_end": 80,
          "port_range_start": 80
        },
        {
          "protocol": "tcp",
          "port_range_end": 433,
          "port_range_start": 433
        },
        {
          "protocol": "udp",
          "port_range_end": 53,
          "port_range_start": 53
        },
        {
          "protocol": "icmp"
        }
      ]
    },
    "ref": "SFMyNTY.g2gDbQAAAVhnMmdFV0hjVllYQnBRR0Z3YVM1amJIVnpkR1Z5TG14dlkyRnNBQUFENndBQUFBQm1hakdpYUFWWWR4VmhjR2xBWVhCcExtTnNkWE4wWlhJdWJHOWpZV3dBQUFQZ0FBQUFBR1pxTWFKM0owVnNhWGhwY2k1UWFHOWxibWw0TGxOdlkydGxkQzVXTVM1S1UwOU9VMlZ5YVdGc2FYcGxjbTBBQUFBR1kyeHBaVzUwWVFSaEFHMEFBQUFrTmpFNVptSmxPRE10WW1NNU5TMDBOak0xTFRsaE1EZ3ROamhrWVRsaE9UUTBZemc0YkFBQUFBRm9BbTBBQUFBTGRISmhZMlZ3WVhKbGJuUnRBQUFBTnpBd0xUZzROMlptTUdKaU1EZGhOakU1TkdOa01tTTRNamsxWkRGaE1tSXlabU15TFRnMU9USXpZV1kzTVRZNVlUQmlPR1F0TURGcW4GAKnP0g6QAWIAAVGA.MBccK7A6wR4EA1ZkKnGlHzAnh-tRitZ2d97q_IvzoD8",
    "expires_at": 1718663242,
    "actor": {
      "id": "0f4a5f16-3c59-47c9-a7c1-31de7a51b26c"
    },
    "relays": [
      {
        "id": "75542064-e5f7-491b-b054-5350b4f34963",
        "type": "turn",
        "addr": "172.28.0.101:3478",
        "username": "1719445215:D8RIljXHIIYGn88dBjUIFw",
        "password": "AipiIetIXo33EnV36U+nET8lAtJXr+iSwwFU5VOfF5k",
        "expires_at": 1719445215
      },
      {
        "id": "649cd79f-2536-4f9d-906b-d20b1c5d3ac3",
        "type": "turn",
        "addr": "172.28.0.201:3478",
        "username": "1719445215:hpx751e3Wt-Mg9kv7yv0mg",
        "password": "D6A4ytn/U8xAvfOE1l3G/rNlduZD1gq21BFXhITkjpA",
        "expires_at": 1719445215
      }
    ],
    "flow_id": "b944e68a-c936-4a81-bd8d-88c45efdcb2c"
  }
}"#;
        let _: PhoenixMessage<IngressMessages, ()> = serde_json::from_str(message).unwrap();
    }

    #[test]
    fn invalidate_ice_candidates_message() {
        let msg = r#"{"event":"invalidate_ice_candidates","ref":null,"topic":"gateway","payload":{"candidates":["candidate:7854631899965427361 1 udp 1694498559 172.28.0.100 47717 typ srflx"],"client_id":"2b1524e6-239e-4570-bc73-70a188e12101"}}"#;
        let expected = IngressMessages::InvalidateIceCandidates(ClientIceCandidates {
            client_id: "2b1524e6-239e-4570-bc73-70a188e12101".parse().unwrap(),
            candidates: vec![
                "candidate:7854631899965427361 1 udp 1694498559 172.28.0.100 47717 typ srflx"
                    .to_owned(),
            ],
        });

        let actual = serde_json::from_str::<IngressMessages>(msg).unwrap();

        assert_eq!(actual, expected);
    }

    #[test]
    fn init_phoenix_message() {
        let m = PhoenixMessage::new_message(
            "gateway",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                config: Config {
                    ipv4_masquerade_enabled: true,
                    ipv6_masquerade_enabled: true,
                },
                relays: vec![],
            }),
            None,
        );

        let message = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}}"#;
        let ingress_message =
            serde_json::from_str::<PhoenixMessage<IngressMessages, ()>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn additional_fields_are_ignore() {
        let m = PhoenixMessage::new_message(
            "gateway",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                config: Config {
                    ipv4_masquerade_enabled: true,
                    ipv6_masquerade_enabled: true,
                },
                relays: vec![],
            }),
            None,
        );

        let message = r#"{"event":"init","ref":null,"topic":"gateway","irrelevant":"field","payload":{"more":"info","interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true,"ignored":"field"}}}"#;
        let ingress_message =
            serde_json::from_str::<PhoenixMessage<IngressMessages, ()>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn additional_null_fields_are_ignored() {
        let m = PhoenixMessage::new_message(
            "gateway",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                config: Config {
                    ipv4_masquerade_enabled: true,
                    ipv6_masquerade_enabled: true,
                },
                relays: vec![],
            }),
            None,
        );

        let message = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"additional":null,"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}}"#;
        let ingress_message =
            serde_json::from_str::<PhoenixMessage<IngressMessages, ()>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn additional_number_fields_are_ignored() {
        let m = PhoenixMessage::new_message(
            "gateway",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                config: Config {
                    ipv4_masquerade_enabled: true,
                    ipv6_masquerade_enabled: true,
                },
                relays: vec![],
            }),
            None,
        );

        let message = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"additional":0.3,"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}}"#;
        let ingress_message =
            serde_json::from_str::<PhoenixMessage<IngressMessages, ()>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn additional_boolean_fields_are_ignored() {
        let m = PhoenixMessage::new_message(
            "gateway",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                config: Config {
                    ipv4_masquerade_enabled: true,
                    ipv6_masquerade_enabled: true,
                },
                relays: vec![],
            }),
            None,
        );

        let message = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"additional":true,"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}}"#;
        let ingress_message =
            serde_json::from_str::<PhoenixMessage<IngressMessages, ()>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn additional_object_fields_are_ignored() {
        let m = PhoenixMessage::new_message(
            "gateway",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                config: Config {
                    ipv4_masquerade_enabled: true,
                    ipv6_masquerade_enabled: true,
                },
                relays: vec![],
            }),
            None,
        );

        let message = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"additional":{"ignored":"field"},"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}}"#;
        let ingress_message =
            serde_json::from_str::<PhoenixMessage<IngressMessages, ()>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn additional_array_fields_are_ignored() {
        let m = PhoenixMessage::new_message(
            "gateway",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                config: Config {
                    ipv4_masquerade_enabled: true,
                    ipv6_masquerade_enabled: true,
                },
                relays: vec![],
            }),
            None,
        );

        let message = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"additional":[true,false],"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"config":{"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}}"#;
        let ingress_message =
            serde_json::from_str::<PhoenixMessage<IngressMessages, ()>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn resource_updated() {
        let message = r#"{"event":"resource_updated","ref":null,"topic":"gateway","payload":{"id":"57f9ebbb-21d5-4f9f-bf86-b25122fc7a43","name":"?.httpbin","type":"dns","address":"?.httpbin","filters":[{"protocol":"icmp"},{"protocol":"tcp"}]}}"#;
        let m =
            IngressMessages::ResourceUpdated(ResourceDescription::Dns(ResourceDescriptionDns {
                id: "57f9ebbb-21d5-4f9f-bf86-b25122fc7a43".parse().unwrap(),
                address: "?.httpbin".to_string(),
                name: "?.httpbin".to_string(),
                filters: vec![
                    Filter::Icmp,
                    Filter::Tcp(PortRange {
                        port_range_end: 65535,
                        port_range_start: 0,
                    }),
                ],
            }));
        let ingress_message = serde_json::from_str::<IngressMessages>(message).unwrap();
        assert_eq!(m, ingress_message);
    }

    #[test]
    fn relays_presence() {
        let message = r#"
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
