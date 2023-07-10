use std::net::IpAddr;

use chrono::{serde::ts_seconds, DateTime, Utc};
use firezone_tunnel::RTCSessionDescription;
use libs_common::messages::{Id, Interface, Peer, Relay, ResourceDescription};
use serde::{Deserialize, Serialize};

// TODO: Should this have a resource?
#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
pub struct InitGateway {
    pub interface: Interface,
    pub ipv4_masquerade_enabled: bool,
    pub ipv6_masquerade_enabled: bool,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Actor {
    pub id: Id,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Device {
    pub id: Id,
    pub rtc_session_description: RTCSessionDescription,
    pub peer: Peer,
}

// rtc_sdp is ignored from eq since RTCSessionDescription doesn't implement this
// this will probably be changed in the future.
impl PartialEq for Device {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id && self.peer == other.peer
    }
}

impl Eq for Device {}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct RequestConnection {
    pub actor: Actor,
    pub relays: Vec<Relay>,
    pub resource: ResourceDescription,
    pub device: Device,
    #[serde(rename = "ref")]
    pub reference: String,
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub enum Destination {
    DnsName(String),
    Ip(Vec<IpAddr>),
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Metrics {
    peers_metrics: Vec<Metric>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Metric {
    pub client_id: Id,
    pub resource_id: Id,
    pub rx_bytes: u32,
    pub tx_bytes: u32,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct RemoveResource {
    pub id: Id,
}

// These messages are the messages that can be received
// either by a client or a gateway by the client.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
// TODO: We will need to re-visit webrtc-rs
#[allow(clippy::large_enum_variant)]
pub enum IngressMessages {
    Init(InitGateway),
    RequestConnection(RequestConnection),
    AddResource(ResourceDescription),
    RemoveResource(RemoveResource),
    UpdateResource(ResourceDescription),
}

// These messages can be sent from a gateway
// to a control pane.
#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
// TODO: We will need to re-visit webrtc-rs
#[allow(clippy::large_enum_variant)]
pub enum EgressMessages {
    ConnectionReady(ConnectionReady),
    Metrics(Metrics),
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ConnectionReady {
    #[serde(rename = "ref")]
    pub reference: String,
    pub gateway_rtc_session_description: RTCSessionDescription,
}

#[cfg(test)]
mod test {
    use libs_common::{control::PhoenixMessage, messages::Interface};

    use super::{IngressMessages, InitGateway};

    #[test]
    fn request_connection_message() {
        let message = r#"{
            "ref": null,
            "topic": "gateway",
            "event": "request_connection",
            "payload": {
                "device": {
                    "id": "3a25ff38-f8d7-47de-9b30-c7c40c206083",
                    "peer": {
                        "ipv6": "fd00:2011:1111::3a:ab1b",
                        "public_key": "OR2dYCLwMEtwqtjOxSm4SU7BbHJDfM8ZCqK7HKXXxDw=",
                        "ipv4": "100.114.114.30",
                        "persistent_keepalive": 25,
                        "preshared_key": "sMeTuiJ3mezfpVdan948CmisIWbwBZ1z7jBNnbVtfVg="
                    },
                    "rtc_session_description": {
                        "sdp": "v=0\r\no=- 8696424395893049643 650344226 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\na=fingerprint:sha-256 AF:57:6F:03:CA:BD:0E:6E:F0:26:BA:B4:36:FE:2E:48:2D:FA:B7:39:84:BA:9E:FB:3F:DC:1F:46:ED:18:01:40\r\na=group:BUNDLE 0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\na=setup:actpass\r\na=mid:0\r\na=sendrecv\r\na=sctp-port:5000\r\na=ice-ufrag:KOLSoUEJdNfpgLoM\r\na=ice-pwd:WvOTEYbBZwpRgERbKVjkPGsGwZsUoyKQ\r\na=candidate:312688668 1 udp 2130706431 172.28.0.100 46924 typ host\r\na=candidate:312688668 2 udp 2130706431 172.28.0.100 46924 typ host\r\na=candidate:1090862588 1 udp 2130706431 100.114.114.30 32969 typ host\r\na=candidate:1090862588 2 udp 2130706431 100.114.114.30 32969 typ host\r\na=candidate:2835903154 1 udp 1694498815 172.28.0.100 59817 typ srflx raddr 0.0.0.0 rport 59817\r\na=candidate:2835903154 2 udp 1694498815 172.28.0.100 59817 typ srflx raddr 0.0.0.0 rport 59817\r\na=candidate:2835903154 1 udp 1694498815 172.28.0.100 45350 typ srflx raddr 0.0.0.0 rport 45350\r\na=candidate:2835903154 2 udp 1694498815 172.28.0.100 45350 typ srflx raddr 0.0.0.0 rport 45350\r\na=candidate:167090039 1 udp 2130706431 :: 55852 typ host\r\na=candidate:167090039 2 udp 2130706431 :: 55852 typ host\r\na=end-of-candidates\r\n",
                        "type": "offer"
                    }
                },
                "resource": {
                    "id": "ea6570d1-47c7-49d2-9dc3-efff1c0c9e0b",
                    "name": "172.20.0.1/16",
                    "type": "cidr",
                    "address": "172.20.0.0/16"
                },
                "ref": "78e1159d-9dc6-480d-b2ef-1fcec2cd5730",
                "expires_at": 1719367575,
                "actor": {
                    "id": "3b1d86a0-4737-4814-8add-cfec42669511"
                },
                "relays": [
                    {
                        "type": "stun",
                        "uri": "stun:172.28.0.101:3478"
                    },
                    {
                        "type": "turn",
                        "username": "1719367575:ZQHcVGkdnfgGmcP1",
                        "password": "ZWYiBeFHOJyYq0mcwAXjRpcuXIJJpzWlOXVdxwttrWg",
                        "uri": "turn:172.28.0.101:3478",
                        "expires_at": 1719367575
                    }
                ]
            }
        }"#;
        // TODO: We are just testing we can deserialize for now.
        let _: PhoenixMessage<IngressMessages, ()> = serde_json::from_str(message).unwrap();
    }
    #[test]
    fn init_phoenix_message() {
        let m = PhoenixMessage::new(
            "gateway:83d28051-324e-48fe-98ed-19690899b3b6",
            IngressMessages::Init(InitGateway {
                interface: Interface {
                    ipv4: "100.115.164.78".parse().unwrap(),
                    ipv6: "fd00:2011:1111::2c:f6ab".parse().unwrap(),
                    upstream_dns: vec![],
                },
                ipv4_masquerade_enabled: true,
                ipv6_masquerade_enabled: true,
            }),
            None,
        );

        let message = r#"{
            "event": "init",
            "payload": {
                "interface": {
                    "ipv4": "100.115.164.78",
                    "ipv6": "fd00:2011:1111::2c:f6ab"
                },
                "ipv4_masquerade_enabled": true,
                "ipv6_masquerade_enabled": true
            },
            "ref": null,
            "topic": "gateway:83d28051-324e-48fe-98ed-19690899b3b6"
        }"#;
        let ingress_message: PhoenixMessage<IngressMessages, ()> =
            serde_json::from_str(message).unwrap();
        assert_eq!(m, ingress_message);
    }
}
