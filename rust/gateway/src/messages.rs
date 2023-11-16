use std::net::IpAddr;

use chrono::{serde::ts_seconds, DateTime, Utc};
use connlib_shared::messages::{
    ActorId, ClientId, ClientPayload, GatewayResponse, Interface, Peer, Relay, ResourceDescription,
    ResourceId,
};
use connlib_shared::Dname;
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
    pub id: ActorId,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Client {
    pub id: ClientId,
    pub payload: ClientPayload,
    pub peer: Peer,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct RequestConnection {
    pub actor: Actor,
    pub relays: Vec<Relay>,
    pub resource: ResourceDescription,
    pub client: Client,
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
    pub client_id: ClientId,
    pub resource_id: ResourceId,
    pub rx_bytes: u32,
    pub tx_bytes: u32,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct RemoveResource {
    pub id: ResourceId,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct AllowAccess {
    pub client_id: ClientId,
    pub resource: ResourceDescription,
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
    pub payload: Option<Dname>,
    #[serde(rename = "ref")]
    pub reference: String,
}

// These messages are the messages that can be received
// either by a client or a gateway by the client.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
// TODO: We will need to re-visit webrtc-rs
#[allow(clippy::large_enum_variant)]
pub enum IngressMessages {
    RequestConnection(RequestConnection),
    AllowAccess(AllowAccess),
    IceCandidates(ClientIceCandidates),
}

/// A client's ice candidate message.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct BroadcastClientIceCandidates {
    /// Client's id the ice candidates are meant for
    pub client_ids: Vec<ClientId>,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
}

/// A client's ice candidate message.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ClientIceCandidates {
    /// Client's id the ice candidates came from
    pub client_id: ClientId,
    /// Actual RTC ice candidates
    pub candidates: Vec<String>,
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
    BroadcastIceCandidates(BroadcastClientIceCandidates),
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ConnectionReady {
    #[serde(rename = "ref")]
    pub reference: String,
    pub gateway_payload: GatewayResponse,
}

#[cfg(test)]
mod test {
    use connlib_shared::{control::PhoenixMessage, messages::Interface};
    use phoenix_channel::InitMessage;

    use super::{IngressMessages, InitGateway};

    #[test]
    fn request_connection_message() {
        let message = r#"{
            "ref": null,
            "topic": "gateway",
            "event": "request_connection",
            "payload": {
                "client": {
                  "id": "5a3fdcdf-425d-4997-921b-5fa87441e03c",
                  "peer": {
                    "ipv6": "fd00:2021:1111::d:b6b5",
                    "public_key": "E5oyYdkzRoQ3tkk62DtsNBdvLSmjLgqqEzFe1N+mvQA=",
                    "ipv4": "100.66.111.33",
                    "persistent_keepalive": 25,
                    "preshared_key": "zbxh6XtSCMmjEuUMOifgG+rfJAfq4bWBAwa+XaKHDYs="
                  },
                  "payload": {
                    "domain": null,
                    "ice_parameters": {
                      "pass": "VAx4BSFsJNXluHa2Tujk3E",
                      "ufrag": "bKzr"
                    }
                  }
                },
                "resource": {
                  "id": "4b6dbf34-9ed7-453d-947f-c4e92833c31e",
                  "name": "MyCorp Network",
                  "type": "cidr",
                  "address": "172.20.0.0/16",
                  "filters": []
                },
                "ref": "dfa04c93-710b-4594-933b-b8586250f0c3",
                "expires_at": 1702881277,
                "actor": {
                  "id": "c4a781f7-94c3-4fac-b0d8-c1f04490e84b"
                },
                "relays": [
                  {
                    "type": "turn",
                    "username": "1702881277:yjma2TJfzV92orcb0ehCpQ",
                    "password": "zxGXBR8M/qzJxlJy1qZChO/oXl61DgzLn578HF7T9jU",
                    "uri": "turn:172.28.0.101:3478",
                    "expires_at": 1702881277
                  },
                  {
                    "type": "turn",
                    "username": "1702881277:l0FW-zjmaPxuE6uDg_yfKQ",
                    "password": "75+qea9mT473920qxt8otzrW1WL87J1uddFW03uvKY8",
                    "uri": "turn:[fcff:3990:3990::101]:3478",
                    "expires_at": 1702881277
                  }
                ],
                "flow_id": "6400fb21-58cc-48b7-b7c7-a35cf06a778e"
              }
            
        }"#;
        // TODO: We are just testing we can deserialize for now.
        let _: PhoenixMessage<IngressMessages, ()> = serde_json::from_str(message).unwrap();
    }
    #[test]
    fn init_phoenix_message() {
        let m = InitMessage::Init(InitGateway {
            interface: Interface {
                ipv4: "100.115.164.78".parse().unwrap(),
                ipv6: "fd00:2021:1111::2c:f6ab".parse().unwrap(),
                upstream_dns: vec![],
            },
            ipv4_masquerade_enabled: true,
            ipv6_masquerade_enabled: true,
        });

        let message = r#"{"event":"init","ref":null,"topic":"gateway","payload":{"interface":{"ipv6":"fd00:2021:1111::2c:f6ab","ipv4":"100.115.164.78"},"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true}}"#;
        let ingress_message = serde_json::from_str::<InitMessage<InitGateway>>(message).unwrap();
        assert_eq!(m, ingress_message);
    }
}
