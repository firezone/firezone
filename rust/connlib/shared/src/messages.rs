//! Message types that are used by both the gateway and client.
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use chrono::{serde::ts_seconds, DateTime, Utc};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::{fmt, str::FromStr};
use uuid::Uuid;

pub mod client;
pub mod gateway;
mod key;

pub use key::{Key, SecretKey};

use crate::DomainName;

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct GatewayId(Uuid);

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ResourceId(Uuid);

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct RelayId(Uuid);

impl RelayId {
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl FromStr for RelayId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(RelayId(Uuid::parse_str(s)?))
    }
}

impl ResourceId {
    pub fn random() -> ResourceId {
        ResourceId(Uuid::new_v4())
    }

    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl GatewayId {
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ClientId(Uuid);

impl FromStr for ClientId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(ClientId(Uuid::parse_str(s)?))
    }
}

impl ClientId {
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

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

impl fmt::Display for RelayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Debug for ResourceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

impl fmt::Debug for ClientId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

impl fmt::Debug for GatewayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

impl fmt::Debug for RelayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
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
    pub client_payload: ClientPayload,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ResolveRequest {
    pub name: DomainName,
    pub proxy_ips: Vec<IpAddr>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
pub struct ClientPayload {
    pub ice_parameters: Offer,
    pub domain: Option<ResolveRequest>,
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
    pub payload: Option<ResolveRequest>,
}

// Custom implementation of partial eq to ignore client_rtc_sdp
impl PartialEq for RequestConnection {
    fn eq(&self, other: &Self) -> bool {
        self.resource_id == other.resource_id
    }
}

impl Eq for RequestConnection {}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Answer {
    pub username: String,
    pub password: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Offer {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Deserialize, Serialize, Clone, Hash, PartialEq, Eq)]
pub struct DomainResponse {
    pub domain: DomainName,
    pub address: Vec<IpAddr>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
pub struct ConnectionAccepted {
    pub ice_parameters: Answer,
    pub domain_response: Option<DomainResponse>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
pub struct ResourceAccepted {
    pub domain_response: DomainResponse,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
pub enum GatewayResponse {
    ConnectionAccepted(ConnectionAccepted),
    ResourceAccepted(ResourceAccepted),
}

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash)]
#[serde(tag = "protocol", rename_all = "snake_case")]
pub enum DnsServer {
    IpPort(IpDnsServer),
}

impl fmt::Debug for DnsServer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::IpPort(IpDnsServer { address }) => address.fmt(f),
        }
    }
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

#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash)]
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
    pub id: RelayId,
    //// Expire time of the username/password in unix millisecond timestamp UTC
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
    /// Address of the relay
    pub addr: SocketAddr,
    /// Username for the relay
    pub username: String,
    // TODO: SecretString
    /// Password for the relay
    pub password: String,
}

/// Stun kind of relay
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Stun {
    pub id: RelayId,

    /// Address for the relay
    pub addr: SocketAddr,
}

/// A update to the presence of several relays.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct RelaysPresence {
    /// These relays have disconnected from the portal. We need to stop using them.
    pub disconnected_ids: Vec<RelayId>,
    /// These relays are still online. We can/should use these.
    pub connected: Vec<Relay>,
}
