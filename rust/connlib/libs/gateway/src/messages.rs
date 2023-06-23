use std::net::IpAddr;

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
    pub client_id: Id,
    pub gateway_rtc_sdp: RTCSessionDescription,
}

#[cfg(test)]
mod test {
    use libs_common::{control::PhoenixMessage, messages::Interface};

    use super::{IngressMessages, InitGateway};

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
