//! Message types that are used by both the gateway and client.
use std::{
    borrow::Cow,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
};

use chrono::{serde::ts_seconds, DateTime, Utc};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::{fmt, str::FromStr};
use uuid::Uuid;

mod key;

pub use key::{Key, SecretKey};

use crate::Dname;

#[derive(Hash, Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
pub struct GatewayId(Uuid);
#[derive(Hash, Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
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

impl fmt::Display for ClientId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Display for GatewayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Represents a wireguard peer.
#[derive(Debug, Deserialize, Serialize, Clone)]
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
    pub preshared_key: SecretKey,
}

impl Peer {
    pub fn ips(&self) -> Vec<IpNetwork> {
        vec![self.ipv4.into(), self.ipv6.into()]
    }
}

impl PartialEq for Peer {
    fn eq(&self, other: &Self) -> bool {
        self.persistent_keepalive.eq(&other.persistent_keepalive)
            && self.public_key.eq(&other.public_key)
            && self.ipv4.eq(&other.ipv4)
            && self.ipv6.eq(&other.ipv6)
    }
}

/// Represent a connection request from a client to a given resource.
///
/// While this is a client-only message it's hosted in common since the tunnel
/// makes use of this message type.
#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RequestConnection {
    /// Gateway id for the connection
    pub gateway_id: GatewayId,
    /// Resource id the request is for.
    pub resource_id: ResourceId,
    /// The preshared key the client generated for the connection that it is trying to establish.
    pub client_preshared_key: SecretKey,
    /// Client's local RTC Session Description that the client will use for this connection.
    pub client_payload: ClientPayload,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ClientPayload {
    pub ice_parameters: Offer,
    pub domain: Option<Dname>,
}

/// Represent a request to reuse an existing gateway connection from a client to a given resource.
///
/// While this is a client-only message it's hosted in common since the tunnel
/// make use of this message type.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ReuseConnection {
    /// Resource id the request is for.
    pub resource_id: ResourceId,
    /// Id of the gateway we want to reuse
    pub gateway_id: GatewayId,
    /// Payload that the gateway will receive
    pub payload: Option<Dname>,
}

// Custom implementation of partial eq to ignore client_rtc_sdp
impl PartialEq for RequestConnection {
    fn eq(&self, other: &Self) -> bool {
        self.resource_id == other.resource_id
    }
}

impl Eq for RequestConnection {}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription<TDNS = ResourceDescriptionDns> {
    Dns(TDNS),
    Cidr(ResourceDescriptionCidr),
}

#[derive(Debug, Deserialize, Serialize, Clone, Hash, PartialEq, Eq)]
pub struct DomainResponse {
    pub domain: Dname,
    pub address: Vec<IpAddr>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Answer {
    pub username: String,
    pub password: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Offer {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ConnectionAccepted {
    pub ice_parameters: Answer,
    pub domain_response: Option<DomainResponse>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ResourceAccepted {
    pub domain_response: DomainResponse,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub enum GatewayResponse {
    ConnectionAccepted(ConnectionAccepted),
    ResourceAccepted(ResourceAccepted),
}

/// Description of a resource that maps to a DNS record.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,
}

impl ResourceDescription {
    pub fn dns_name(&self) -> Option<&str> {
        match self {
            ResourceDescription::Dns(r) => Some(&r.address),
            ResourceDescription::Cidr(_) => None,
        }
    }

    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
        }
    }

    /// What the GUI clients should show as the user-friendly display name, e.g. `Firezone GitHub`
    pub fn name(&self) -> &str {
        match self {
            ResourceDescription::Dns(r) => &r.name,
            ResourceDescription::Cidr(r) => &r.name,
        }
    }

    /// What the GUI clients should paste to the clipboard, e.g. `https://github.com/firezone`
    pub fn pastable(&self) -> Cow<'_, str> {
        match self {
            ResourceDescription::Dns(r) => Cow::from(&r.address),
            ResourceDescription::Cidr(r) => Cow::from(r.address.to_string()),
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

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(tag = "protocol", rename_all = "snake_case")]
pub enum DnsServer {
    IpPort(IpDnsServer),
}

impl DnsServer {
    pub fn ip(&self) -> IpAddr {
        match self {
            DnsServer::IpPort(s) => s.address.ip(),
        }
    }

    pub fn address(&self) -> SocketAddr {
        match self {
            DnsServer::IpPort(s) => s.address,
        }
    }
}

impl<T> From<T> for DnsServer
where
    T: Into<SocketAddr>,
{
    fn from(addr: T) -> Self {
        Self::IpPort(IpDnsServer {
            address: addr.into(),
        })
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
pub struct IpDnsServer {
    pub address: SocketAddr,
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
    pub upstream_dns: Vec<DnsServer>,
}

/// A single relay
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Relay {
    /// STUN type of relay
    Stun(Stun),
    /// TURN type of relay
    Turn(Turn),
}

/// Represent a TURN relay
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Turn {
    //// Expire time of the username/password in unix millisecond timestamp UTC
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
    /// URI of the relay
    #[serde(with = "stun_turn_uri", alias = "addr")]
    pub uri: SocketAddr,
    /// Username for the relay
    pub username: String,
    // TODO: SecretString
    /// Password for the relay
    pub password: String,
}

/// Stun kind of relay
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Stun {
    /// URI for the relay
    #[serde(with = "stun_turn_uri", alias = "addr")]
    pub uri: SocketAddr,
}

mod stun_turn_uri {
    use serde::de::Error;
    use serde::Deserialize;
    use std::net::SocketAddr;

    pub fn deserialize<'de, D>(deserializer: D) -> Result<SocketAddr, D::Error>
    where
        D: serde::Deserializer<'de>,
        D::Error: Error,
    {
        let string = String::deserialize(deserializer)?;

        let socket_addr = string
            .trim_start_matches("stun:")
            .trim_start_matches("turn:")
            .parse::<SocketAddr>()
            .map_err(D::Error::custom)?;

        Ok(socket_addr)
    }
}
