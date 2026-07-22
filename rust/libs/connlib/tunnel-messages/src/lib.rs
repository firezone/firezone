//! Message types that are used by both the gateway and client.
use std::collections::{BTreeMap, BTreeSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use chrono::{DateTime, Utc, serde::ts_seconds};
use connlib_model::{ClientId, RelayId, ResourceId};
use dns_types::{DoHUrl, DomainName};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use serde_with::{DurationSeconds, serde_as};
use std::fmt;

pub mod client;
pub mod gateway;
mod key;

pub use flow_tracker::IngestToken;
pub use key::{Key, SecretKey};

/// An active authorization: `client_id` may access `resource_id` until `expires_at`.
#[serde_as]
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Authorization {
    pub client_id: ClientId,
    pub resource_id: ResourceId,
    #[serde_as(as = "DurationSeconds<u64>")]
    pub expires_at: Duration,
}

/// Group the authorizations of an `init` message by client, for resyncing
/// against the currently connected peers.
pub fn group_authorizations_by_client(
    authorizations: &[Authorization],
) -> BTreeMap<ClientId, BTreeSet<ResourceId>> {
    authorizations.iter().fold(
        BTreeMap::new(),
        |mut grouped,
         Authorization {
             client_id,
             resource_id,
             ..
         }| {
            grouped.entry(*client_id).or_default().insert(*resource_id);
            grouped
        },
    )
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
        Self {
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

/// Capabilities of a snownet implementation.
///
/// Reported by clients and gateways to the portal on connect. The portal
/// intersects capabilities across both sides of each connection and re-emits
/// the negotiated set with each gateway/client authorization message.
///
/// New fields must always be added with a `false`-equivalent default so older
/// peers that don't send them deserialize as "feature not supported", and
/// existing fields must never be repurposed.
#[derive(Debug, Default, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SnownetCapabilities {
    /// The implementation can negotiate connections without ICE.
    pub iceless: bool,
}

impl SnownetCapabilities {
    /// Capabilities of the local snownet implementation, hard-coded at compile time.
    pub const LOCAL: Self = Self { iceless: true };
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

/// Flow-log upload configuration the portal always sends as part of `init`.
///
/// [`IngestToken`]s arrive with every authorization regardless; whether an
/// authorization's flow logs are spooled for upload is decided per token by
/// its `uploads_enabled` claim.
#[derive(Debug, Deserialize, Clone)]
pub struct FlowLogsConfig {
    /// Base URL flow logs are POSTed to.
    pub api_url: String,
    /// How often, in seconds, to upload batched flow logs. `0` disables uploads.
    pub upload_interval_secs: u64,
    /// Maximum flow-log records per upload request. `0` uses the default.
    pub upload_batch_size: u64,
}

impl FlowLogsConfig {
    pub fn upload_enabled(&self) -> bool {
        self.upload_interval_secs > 0
    }
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

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(tag = "protocol", rename_all = "snake_case")]
pub enum Filter {
    Udp(PortRange),
    Tcp(PortRange),
    Icmp,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PortRange {
    // TODO: we can use a custom deserializer
    // or maybe change the control plane to use start and end would suffice
    #[serde(default = "min_port")]
    pub port_range_start: u16,
    #[serde(default = "max_port")]
    pub port_range_end: u16,
}

// Note: these 2 functions are needed since serde doesn't yet support default_value
// see serde-rs/serde#368
fn min_port() -> u16 {
    0
}

fn max_port() -> u16 {
    u16::MAX
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flow_logs_config_ignores_unknown_fields() {
        let json = r#"{ "api_url": "https://api.firezone.dev", "upload_interval_secs": 60, "upload_batch_size": 1000, "future_field": true }"#;
        let config: FlowLogsConfig = serde_json::from_str(json).unwrap();

        assert!(config.upload_enabled());
    }

    #[test]
    fn snownet_capabilities_default_is_all_false() {
        assert_eq!(
            SnownetCapabilities::default(),
            SnownetCapabilities { iceless: false }
        );
    }

    // Compile-time guard so future edits to `LOCAL` don't accidentally turn
    // off iceless support without us noticing.
    const _: () = assert!(SnownetCapabilities::LOCAL.iceless);

    #[test]
    fn snownet_capabilities_deserialize_empty_object_is_default() {
        let caps: SnownetCapabilities = serde_json::from_str("{}").unwrap();
        assert_eq!(caps, SnownetCapabilities::default());
    }

    #[test]
    fn snownet_capabilities_ignores_unknown_fields() {
        let json = r#"{ "iceless": true, "future_feature": true }"#;
        let caps: SnownetCapabilities = serde_json::from_str(json).unwrap();
        assert!(caps.iceless);
    }
}
