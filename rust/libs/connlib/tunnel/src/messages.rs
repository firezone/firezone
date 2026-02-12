//! Message types that are used by both the gateway and client.
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use chrono::{DateTime, Utc, serde::ts_seconds};
use connlib_model::RelayId;
use dns_types::{DoHUrl, DomainName};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::fmt;

pub mod client;
pub mod gateway;
mod key;

pub use key::{Key, SecretKey};

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

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ResolveRequest {
    pub name: DomainName,
    pub proxy_ips: Vec<IpAddr>,
}

#[derive(Debug, Deserialize, Serialize, Clone, Hash, PartialEq, Eq)]
pub struct DomainResponse {
    pub domain: DomainName,
    pub address: Vec<IpAddr>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
pub struct IceCredentials {
    pub username: String,
    pub password: String,
}

impl From<IceCredentials> for snownet::Credentials {
    fn from(value: IceCredentials) -> Self {
        snownet::Credentials {
            username: value.username,
            password: value.password,
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum IceRole {
    Controlling,
    Controlled,
}

impl From<IceRole> for snownet::IceRole {
    fn from(value: IceRole) -> snownet::IceRole {
        match value {
            IceRole::Controlling => snownet::IceRole::Controlling,
            IceRole::Controlled => snownet::IceRole::Controlled,
        }
    }
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
    pub upstream_dns: Vec<DnsServer>, // TODO: Remove once portal with `upstream_do53` support has been deployed.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    #[serde(default)]
    pub upstream_do53: Vec<UpstreamDo53>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    #[serde(default)]
    pub upstream_doh: Vec<UpstreamDoH>,
    #[serde(default)]
    pub search_domain: Option<DomainName>,
}

impl Interface {
    pub fn upstream_do53(&self) -> Vec<IpAddr> {
        if !self.upstream_do53.is_empty() {
            return self.upstream_do53.iter().map(|u| u.ip).collect();
        }

        // Fallback whilst the portal does not send `upstream_do53`.
        self.upstream_dns
            .iter()
            .map(|u| match u {
                DnsServer::IpPort(ip_dns_server) => ip_dns_server.address.ip(),
            })
            .collect()
    }

    pub fn upstream_doh(&self) -> Vec<DoHUrl> {
        self.upstream_doh.iter().map(|u| u.url.clone()).collect()
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct UpstreamDo53 {
    pub ip: IpAddr,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct UpstreamDoH {
    pub url: DoHUrl,
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
