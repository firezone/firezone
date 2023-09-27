//! Message types that are used by both the gateway and client.
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use chrono::{serde::ts_seconds, DateTime, Utc};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::{fmt, str::FromStr};
use uuid::Uuid;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

mod key;

pub use key::Key;

#[derive(Hash, Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
pub struct GatewayId(Uuid);
#[derive(Hash, Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
pub struct ResourceId(Uuid);
#[derive(Hash, Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
pub struct ClientId(Uuid);
#[derive(Hash, Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
pub struct ActorId(Uuid);

impl FromStr for ResourceId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(ResourceId(Uuid::parse_str(s)?))
    }
}

impl FromStr for GatewayId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(GatewayId(Uuid::parse_str(s)?))
    }
}

impl fmt::Display for ResourceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Represents a wireguard peer.
#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
pub struct Peer {
    /// Keepalive: How often to send a keep alive message.
    pub persistent_keepalive: Option<u16>,
    /// Peer's public key.
    pub public_key: Key,
    /// Peer's Ipv4 (only 1 ipv4 per peer for now and mandatory).
    pub ipv4: Ipv4Addr,
    /// Peer's Ipv6 (only 1 ipv6 per peer for now and mandatory).
    pub ipv6: Ipv6Addr,
    /// Preshared key for the given peer.
    pub preshared_key: Key,
}

/// Represent a connection request from a client to a given resource.
///
/// While this is a client-only message it's hosted in common since the tunnel
/// make use of this message type.
#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RequestConnection {
    /// Gateway id for the connection
    pub gateway_id: GatewayId,
    /// Resource id the request is for.
    pub resource_id: ResourceId,
    /// The preshared key the client generated for the connection that it is trying to establish.
    pub client_preshared_key: Key,
    /// Client's local RTC Session Description that the client will use for this connection.
    pub client_rtc_session_description: RTCSessionDescription,
}

/// Represent a request to reuse an existing gateway connection from a client to a given resource.
///
/// While this is a client-only message it's hosted in common since the tunnel
/// make use of this message type.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ReuseConnection {
    /// Resource id the request is for.
    pub resource_id: ResourceId,
    /// Id of the gateway we want to re-use
    pub gateway_id: GatewayId,
}

// Custom implementation of partial eq to ignore client_rtc_sdp
impl PartialEq for RequestConnection {
    fn eq(&self, other: &Self) -> bool {
        self.resource_id == other.resource_id
            && self.client_preshared_key == other.client_preshared_key
    }
}

impl Eq for RequestConnection {}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(ResourceDescriptionDns),
    Cidr(ResourceDescriptionCidr),
}

/// Description of a resource that maps to a DNS record.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Resource's ipv4 mapping.
    ///
    /// Note that this is not the actual ipv4 for the resource not even wireguard's ipv4 for the resource.
    /// This is just the mapping we use internally between a resource and its ip for intercepting packets.
    pub ipv4: Ipv4Addr,
    /// Resource's ipv6 mapping.
    ///
    /// Note that this is not the actual ipv6 for the resource not even wireguard's ipv6 for the resource.
    /// This is just the mapping we use internally between a resource and its ip for intercepting packets.
    pub ipv6: Ipv6Addr,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,
}

impl ResourceDescription {
    pub fn dns_name(&self) -> Option<&str> {
        match self {
            ResourceDescription::Dns(r) => Some(&r.name),
            ResourceDescription::Cidr(_) => None,
        }
    }

    pub fn ips(&self) -> Vec<IpNetwork> {
        match self {
            ResourceDescription::Dns(r) => vec![r.ipv4.into(), r.ipv6.into()],
            ResourceDescription::Cidr(r) => vec![r.address],
        }
    }

    pub fn ipv4(&self) -> Option<Ipv4Addr> {
        match self {
            ResourceDescription::Dns(r) => Some(r.ipv4),
            ResourceDescription::Cidr(_) => None,
        }
    }

    pub fn ipv6(&self) -> Option<Ipv6Addr> {
        match self {
            ResourceDescription::Dns(r) => Some(r.ipv6),
            ResourceDescription::Cidr(_) => None,
        }
    }

    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
        }
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
        match self {
            ResourceDescription::Dns(r) => r.ipv4 == ip || r.ipv6 == ip,
            ResourceDescription::Cidr(r) => r.address.contains(ip),
        }
    }
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ResourceDescriptionCidr {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,
}

/// Represents a wireguard interface configuration.
///
/// Note that the ips are /32 for ipv4 and /128 for ipv6.
/// This is done to minimize collisions and we update the routing table manually.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Interface {
    /// Interface's Ipv4.
    pub ipv4: Ipv4Addr,
    /// Interface's Ipv6.
    pub ipv6: Ipv6Addr,
    /// DNS that will be used to query for DNS that aren't within our resource list.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    #[serde(default)]
    pub upstream_dns: Vec<IpAddr>,
}

/// A single relay
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Relay {
    /// STUN type of relay
    Stun(Stun),
    /// TURN type of relay
    Turn(Turn),
}

/// Represent a TURN relay
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Turn {
    //// Expire time of the username/password in unix millisecond timestamp UTC
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
    /// URI of the relay
    pub uri: String,
    /// Username for the relay
    pub username: String,
    // TODO: SecretString
    /// Password for the relay
    pub password: String,
}

/// Stun kind of relay
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Stun {
    /// URI for the relay
    pub uri: String,
}
