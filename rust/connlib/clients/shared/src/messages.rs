use std::{collections::HashSet, net::IpAddr};

use serde::{Deserialize, Serialize};

use connlib_shared::messages::{
    GatewayId, GatewayResponse, Interface, Key, Relay, RequestConnection, ResourceDescription,
    ResourceId, ReuseConnection,
};
use url::Url;

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
pub struct InitClient {
    pub interface: Interface,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub resources: Vec<ResourceDescription>,
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
pub struct ConfigUpdate {
    pub interface: Interface,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct RemoveResource(pub ResourceId);

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ConnectionDetails {
    pub relays: Vec<Relay>,
    pub resource_id: ResourceId,
    pub gateway_id: GatewayId,
    pub gateway_remote_ip: IpAddr,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Connect {
    pub gateway_payload: GatewayResponse,
    pub resource_id: ResourceId,
    pub gateway_public_key: Key,
    pub persistent_keepalive: u64,
}

// Just because RTCSessionDescription doesn't implement partialeq
impl PartialEq for Connect {
    fn eq(&self, other: &Self) -> bool {
        self.resource_id == other.resource_id && self.gateway_public_key == other.gateway_public_key
    }
}

impl Eq for Connect {}

// These messages are the messages that can be received
// by a client.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum IngressMessages {
    Init(InitClient),

    // Resources: arrive in an orderly fashion
    ResourceCreatedOrUpdated(ResourceDescription),
    ResourceDeleted(RemoveResource),

    IceCandidates(GatewayIceCandidates),

    ConfigChanged(ConfigUpdate),
}

/// A gateway's ice candidate message.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct BroadcastGatewayIceCandidates {
    /// Gateway's id the ice candidates are meant for
    pub gateway_ids: Vec<GatewayId>,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
}

/// A gateway's ice candidate message.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct GatewayIceCandidates {
    /// Gateway's id the ice candidates are from
    pub gateway_id: GatewayId,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
}

/// The replies that can arrive from the channel by a client
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(untagged)]
#[allow(clippy::large_enum_variant)]
pub enum ReplyMessages {
    ConnectionDetails(ConnectionDetails),
    Connect(Connect),
    /// Response for [`EgressMessages::CreateLogSink`].
    SignedLogUrl(Url),
}

/// The totality of all messages (might have a macro in the future to derive the other types)
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum Messages {
    Init(InitClient),
    ConnectionDetails(ConnectionDetails),
    Connect(Connect),
    SignedLogUrl(Url),

    // Resources: arrive in an orderly fashion
    ResourceCreatedOrUpdated(ResourceDescription),
    ResourceDeleted(RemoveResource),

    IceCandidates(GatewayIceCandidates),

    ConfigChanged(ConfigUpdate),
}

impl From<IngressMessages> for Messages {
    fn from(value: IngressMessages) -> Self {
        match value {
            IngressMessages::Init(m) => Self::Init(m),
            IngressMessages::ResourceCreatedOrUpdated(m) => Self::ResourceCreatedOrUpdated(m),
            IngressMessages::ResourceDeleted(m) => Self::ResourceDeleted(m),
            IngressMessages::IceCandidates(m) => Self::IceCandidates(m),
            IngressMessages::ConfigChanged(m) => Self::ConfigChanged(m),
        }
    }
}

impl From<ReplyMessages> for Messages {
    fn from(value: ReplyMessages) -> Self {
        match value {
            ReplyMessages::ConnectionDetails(m) => Self::ConnectionDetails(m),
            ReplyMessages::Connect(m) => Self::Connect(m),
            ReplyMessages::SignedLogUrl(url) => Self::SignedLogUrl(url),
        }
    }
}

// These messages can be sent from a client to a control pane
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
// enum_variant_names: These are the names in the portal!
pub enum EgressMessages {
    PrepareConnection {
        resource_id: ResourceId,
        connected_gateway_ids: HashSet<GatewayId>,
    },
    CreateLogSink {},
    RequestConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
    BroadcastIceCandidates(BroadcastGatewayIceCandidates),
}

#[cfg(test)]
mod test {
    use std::collections::HashSet;

    use connlib_shared::{
        control::PhoenixMessage,
        messages::{
            DnsServer, Interface, IpDnsServer, Relay, ResourceDescription, ResourceDescriptionCidr,
            ResourceDescriptionDns, Stun, Turn,
        },
    };

    use chrono::NaiveDateTime;
    use connlib_shared::control::ErrorInfo;

    use crate::messages::{ConnectionDetails, EgressMessages, ReplyMessages};

    use super::{ConfigUpdate, IngressMessages, InitClient};

    // TODO: request_connection tests

    #[test]
    fn connection_ready_deserialization() {
        let message = r#"{
            "ref": "0",
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
                             "ice_lite":false,
                             "password":"pMAxxTgHHSdpqHRzHGNvuNsZinLrMxwe",
                             "username_fragment":"tGeqOjtGuPzPpuOx"
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
        let m = PhoenixMessage::new(
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
        let m = PhoenixMessage::new(
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
                    }),
                    ResourceDescription::Dns(ResourceDescriptionDns {
                        id: "03000143-e25e-45c7-aafb-144990e57dcd".parse().unwrap(),
                        address: "gitlab.mycorp.com".to_string(),
                        name: "gitlab.mycorp.com".to_string(),
                    }),
                ],
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
                        "type": "cidr"
                    },
                    {
                        "address": "gitlab.mycorp.com",
                        "id": "03000143-e25e-45c7-aafb-144990e57dcd",
                        "ipv4": "100.126.44.50",
                        "ipv6": "fd00:2021:1111::e:7758",
                        "name": "gitlab.mycorp.com",
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
    fn list_relays_message() {
        let m = PhoenixMessage::<EgressMessages, ()>::new(
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
        let m = PhoenixMessage::<IngressMessages, ReplyMessages>::new_ok_reply(
            "client",
            ReplyMessages::ConnectionDetails(ConnectionDetails {
                gateway_id: "73037362-715d-4a83-a749-f18eadd970e6".parse().unwrap(),
                gateway_remote_ip: "172.28.0.1".parse().unwrap(),
                resource_id: "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3".parse().unwrap(),
                relays: vec![
                    Relay::Stun(Stun {
                        uri: "stun:189.172.73.111:3478".to_string(),
                    }),
                    Relay::Turn(Turn {
                        expires_at: NaiveDateTime::from_timestamp_opt(1686629954, 0)
                            .unwrap()
                            .and_utc(),
                        uri: "turn:189.172.73.111:3478".to_string(),
                        username: "1686629954:C7I74wXYFdFugMYM".to_string(),
                        password: "OXXRDJ7lJN1cm+4+2BWgL87CxDrvpVrn5j3fnJHye98".to_string(),
                    }),
                    Relay::Stun(Stun {
                        uri: "stun:::1:3478".to_string(),
                    }),
                    Relay::Turn(Turn {
                        expires_at: NaiveDateTime::from_timestamp_opt(1686629954, 0)
                            .unwrap()
                            .and_utc(),
                        uri: "turn:::1:3478".to_string(),
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
                        "relays": [
                            {
                                "type":"stun",
                                "uri":"stun:189.172.73.111:3478"
                            },
                            {
                                "expires_at": 1686629954,
                                "password": "OXXRDJ7lJN1cm+4+2BWgL87CxDrvpVrn5j3fnJHye98",
                                "type": "turn",
                                "uri": "turn:189.172.73.111:3478",
                                "username":"1686629954:C7I74wXYFdFugMYM"
                            },
                            {
                                "type": "stun",
                                "uri": "stun:::1:3478"
                            },
                            {
                                "expires_at": 1686629954,
                                "password": "8Wtb+3YGxO6ia23JUeSEfZ2yFD6RhGLkbgZwqjebyKY",
                                "type": "turn",
                                "uri": "turn:::1:3478",
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
    fn create_log_sink_error_response() {
        let json = r#"{"event":"phx_reply","ref":"unique_log_sink_ref","topic":"client","payload":{"status":"error","response":"disabled"}}"#;

        let actual =
            serde_json::from_str::<PhoenixMessage<EgressMessages, ReplyMessages>>(json).unwrap();
        let expected = PhoenixMessage::new_err_reply(
            "client",
            ErrorInfo::Disabled,
            "unique_log_sink_ref".to_owned(),
        );

        assert_eq!(actual, expected)
    }

    #[test]
    fn create_log_sink_ok_response() {
        let json = r#"{"event":"phx_reply","ref":"unique_log_sink_ref","topic":"client","payload":{"status":"ok","response":"https://storage.googleapis.com/foo/bar"}}"#;

        let actual =
            serde_json::from_str::<PhoenixMessage<EgressMessages, ReplyMessages>>(json).unwrap();
        let expected = PhoenixMessage::new_ok_reply(
            "client",
            ReplyMessages::SignedLogUrl("https://storage.googleapis.com/foo/bar".parse().unwrap()),
            "unique_log_sink_ref".to_owned(),
        );

        assert_eq!(actual, expected)
    }
}
