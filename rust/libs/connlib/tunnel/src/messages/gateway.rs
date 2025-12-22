//! Gateway related messages that are needed within connlib

use crate::messages::{
    GatewayResponse, IceCredentials, Interface, Key, Peer, Relay, RelaysPresence, ResolveRequest,
    SecretKey,
};
use chrono::{
    DateTime, Utc,
    serde::{ts_seconds, ts_seconds_option},
};
use connlib_model::{ClientId, IceCandidate, ResourceId};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    net::{Ipv4Addr, Ipv6Addr},
};

use super::Offer;

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

#[derive(Debug, Deserialize, Clone)]
pub struct ClientPayload {
    pub ice_parameters: Offer,
    pub domain: Option<ResolveRequest>,
}

// TODO: Should this have a resource?
#[derive(Debug, Deserialize, Clone)]
pub struct InitGateway {
    pub interface: Interface,
    pub config: Config,
    #[serde(default)]
    pub relays: Vec<Relay>,
    #[serde(default)]
    pub account_slug: Option<String>,
    #[serde(default)]
    pub authorizations: Vec<Authorization>,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Config {
    pub ipv4_masquerade_enabled: bool,
    pub ipv6_masquerade_enabled: bool,
}

#[derive(Debug, Deserialize, Clone)]
pub struct LegacyClient {
    pub id: ClientId,
    pub payload: ClientPayload,
    pub peer: Peer,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RequestConnection {
    pub resource: ResourceDescription,
    pub client: LegacyClient,
    #[serde(rename = "ref")]
    pub reference: String,
    #[serde(with = "ts_seconds_option")]
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RemoveResource {
    pub id: ResourceId,
}

#[derive(Debug, Deserialize, Clone)]
pub struct AllowAccess {
    pub client_id: ClientId,
    pub resource: ResourceDescription,
    #[serde(with = "ts_seconds_option")]
    pub expires_at: Option<DateTime<Utc>>,
    pub payload: Option<ResolveRequest>,
    #[serde(rename = "ref")]
    pub reference: String,
    /// Tunnel IPv4 address.
    pub client_ipv4: Ipv4Addr,
    /// Tunnel IPv6 address.
    pub client_ipv6: Ipv6Addr,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Authorization {
    pub client_id: ClientId,
    pub resource_id: ResourceId,
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
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
pub enum IngressMessages {
    RequestConnection(RequestConnection), // Deprecated.
    AllowAccess(AllowAccess),             // Deprecated.
    RejectAccess(RejectAccess),
    IceCandidates(ClientIceCandidates),
    InvalidateIceCandidates(ClientIceCandidates),
    Init(InitGateway),
    RelaysPresence(RelaysPresence),
    ResourceUpdated(ResourceDescription),
    AuthorizeFlow(AuthorizeFlow),
    AccessAuthorizationExpiryUpdated(AccessAuthorizationExpiryUpdated),
}

#[derive(Debug, Deserialize, Clone)]
pub struct Client {
    pub id: ClientId,
    pub public_key: Key,
    pub preshared_key: SecretKey,
    pub ipv4: Ipv4Addr,
    pub ipv6: Ipv6Addr,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub device_os_name: Option<String>,
    #[serde(default)]
    pub device_os_version: Option<String>,
    #[serde(default)]
    pub device_serial: Option<String>,
    #[serde(default)]
    pub device_uuid: Option<String>,
    #[serde(default)]
    pub identifier_for_vendor: Option<String>,
    #[serde(default)]
    pub firebase_installation_id: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct Subject {
    #[serde(default)]
    pub auth_provider_id: Option<String>,
    #[serde(default)]
    pub actor_name: Option<String>,
    #[serde(default)]
    pub actor_id: Option<String>,
    #[serde(default)]
    pub actor_email: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct AuthorizeFlow {
    #[serde(rename = "ref")]
    pub reference: String,

    pub resource: ResourceDescription,
    pub gateway_ice_credentials: IceCredentials,
    pub client: Client,
    #[serde(default)]
    pub subject: Subject,
    pub client_ice_credentials: IceCredentials,

    #[serde(with = "ts_seconds_option")]
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct AccessAuthorizationExpiryUpdated {
    pub client_id: ClientId,
    pub resource_id: ResourceId,
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
}

/// A client's ice candidate message.
#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct ClientsIceCandidates {
    /// Client's id the ice candidates are meant for
    pub client_ids: Vec<ClientId>,
    /// Actual RTC ice candidates
    pub candidates: BTreeSet<IceCandidate>,
}

/// A client's ice candidate message.
#[serde_with::serde_as]
#[derive(Debug, Deserialize, Clone)]
pub struct ClientIceCandidates {
    /// Client's id the ice candidates came from
    pub client_id: ClientId,
    /// Actual RTC ice candidates
    #[serde_as(as = "serde_with::VecSkipError<_>")]
    pub candidates: Vec<IceCandidate>,
}

// These messages can be sent from a gateway
// to a control pane.
#[derive(Debug, Serialize, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum EgressMessages {
    ConnectionReady(ConnectionReady), // Deprecated.
    BroadcastIceCandidates(ClientsIceCandidates),
    BroadcastInvalidatedIceCandidates(ClientsIceCandidates),
    FlowAuthorized {
        #[serde(rename = "ref")]
        reference: String,
    },
}

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct ConnectionReady {
    #[serde(rename = "ref")]
    pub reference: String,
    pub gateway_payload: GatewayResponse,
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
    fn can_deserialize_request_connection_messages() {
        let json = r#"{
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

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::RequestConnection(_)));
    }

    #[test]
    fn can_deserialize_legacy_request_connection_message() {
        let json = r#"{
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

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::RequestConnection(_)));
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

    #[test]
    fn can_deserialize_authorize_flow() {
        let json = r#"{"event":"authorize_flow","ref":null,"topic":"gateway","payload":{"client":{"id":"3abd725a-733b-4801-ac16-72f26cd98a24","ipv6":"fd00:2021:1111::f:853b","public_key":"fiAjSBWDgQfD1CFJkTwOf4zg+1QhH0eTT+oLaVIMpH8=","ipv4":"100.93.74.51","preshared_key":"BzPiNE9qszKczZcZzGsyieLYeJ2EQfkfdibls/l3beM="},"resource":{"id":"c7793628-8579-465b-83e3-1a5d4af4db3b","name":"MyCorp Network","type":"cidr","address":"172.20.0.0/16","filters":[]},"actor":{"id":"24eb631e-c529-4182-a746-d99ee66f7426"},"ref":"SFMyNTY.g2gDbQAAAkxnMmdHV0hjVllYQnBRR0Z3YVM1amJIVnpkR1Z5TG14dlkyRnNBQUFEWlFBQUFBQm5FYU9DYUFWWWR4VmhjR2xBWVhCcExtTnNkWE4wWlhJdWJHOWpZV3dBQUFOakFBQUFBR2NSbzRKM0owVnNhWGhwY2k1UWFHOWxibWw0TGxOdlkydGxkQzVXTVM1S1UwOU9VMlZ5YVdGc2FYcGxjbTBBQUFBR1kyeHBaVzUwWVFGaEFHMEFBQUFrWXpjM09UTTJNamd0T0RVM09TMDBOalZpTFRnelpUTXRNV0UxWkRSaFpqUmtZak5pYlFBQUFDQnRTWFZ3TldWUVYwUkRVa1Z3WTNNM2QwaE5VMWREZGxwYWNqQlpTalZCZEhRQUFBQUNkd1pqYkdsbGJuUjBBQUFBQW5jSWRYTmxjbTVoYldWdEFBQUFCR2huZDJoM0NIQmhjM04zYjNKa2JRQUFBQlpxTW1aeGRXWmhkRzQzZUd4eWNuWjJObVp6ZG1WaGR3ZG5ZWFJsZDJGNWRBQUFBQUozQ0hWelpYSnVZVzFsYlFBQUFBUmxhbkYwZHdod1lYTnpkMjl5WkcwQUFBQVdlbVpxY25KcVpHdGlZMmswTW5ReVlYaDVaRFExWVd3QUFBQUJhQUp0QUFBQUMzUnlZV05sY0dGeVpXNTBiUUFBQURjd01DMDFNRGRoTUdSbE9HWm1NekpsWmpVMU9EaGlZV1psWkRZMk1XWXpaVFZrTlMxa1ptTTVZMkl3Wm1NeE5tRTBNbUU1TFRBeGFnPT1uBgCeY-eckgFiAAFRgA.5-aLUjF4RiPoYASwWYfSmWuTEc4cT0u8J9cyBUiP9BY","expires_at":1729813989,"flow_id":"eeb66205-5f53-4f64-acbc-deed47293f04","client_ice_credentials":{"username":"hgwh","password":"j2fqufatn7xlrrvv6fsvea"},"gateway_ice_credentials":{"username":"ejqt","password":"zfjrrjdkbci42t2axyd45a"}}}"#;

        let message = serde_json::from_str::<IngressMessages>(json).unwrap();

        assert!(matches!(message, IngressMessages::AuthorizeFlow(_)));
    }

    #[test]
    fn faulty_candidate_get_skipped() {
        let bad_candidates = serde_json::json!({ "client_id": "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3", "candidates": ["foo", "bar", "baz", "candidate:fffeff6435be70ddbf995982 1 udp 1694498559 87.121.72.60 57114 typ srflx raddr 0.0.0.0 rport 0"] });

        let client_candidates = ClientIceCandidates::deserialize(bad_candidates).unwrap();

        assert_eq!(client_candidates.candidates.len(), 1);
    }
}
