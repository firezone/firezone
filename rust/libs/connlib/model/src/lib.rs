//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod view;

pub use boringtun::x25519::PublicKey;
pub use boringtun::x25519::StaticSecret;
pub use view::{
    CidrResourceView, DnsResourceView, InternetResourceView, ResourceStatus, ResourceView,
};

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct GatewayId(Uuid);

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ResourceId(Uuid);

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct RelayId(Uuid);

impl RelayId {
    pub const fn from_u128(v: u128) -> Self {
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

    pub const fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl GatewayId {
    pub const fn from_u128(v: u128) -> Self {
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
    pub const fn from_u128(v: u128) -> Self {
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

#[derive(Debug, Deserialize, Serialize, Clone, Eq, PartialOrd, Ord)]
pub struct Site {
    pub id: SiteId,
    pub name: String,
}

impl std::hash::Hash for Site {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.id.hash(state);
    }
}

impl PartialEq for Site {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SiteId(Uuid);

impl FromStr for SiteId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(SiteId(Uuid::parse_str(s)?))
    }
}

impl SiteId {
    pub const fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl fmt::Display for SiteId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Debug for SiteId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

/// The IP stack of a DNS resource.
#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum IpStack {
    Dual,
    Ipv4Only,
    Ipv6Only,
}

impl IpStack {
    pub fn supports_ipv4(&self) -> bool {
        match self {
            IpStack::Ipv4Only | IpStack::Dual => true,
            IpStack::Ipv6Only => false,
        }
    }

    pub fn supports_ipv6(&self) -> bool {
        match self {
            IpStack::Ipv4Only => false,
            IpStack::Ipv6Only | IpStack::Dual => true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IceCandidate(str0m::Candidate);

impl From<str0m::Candidate> for IceCandidate {
    fn from(value: str0m::Candidate) -> Self {
        Self(value)
    }
}

impl From<IceCandidate> for str0m::Candidate {
    fn from(value: IceCandidate) -> Self {
        value.0
    }
}

impl PartialOrd for IceCandidate {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for IceCandidate {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.0.prio().cmp(&other.0.prio()).reverse()
    }
}

impl Serialize for IceCandidate {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.0.to_sdp_string())
    }
}

impl<'de> Deserialize<'de> for IceCandidate {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::Error as _;

        let string = String::deserialize(deserializer)?;
        let candidate = str0m::Candidate::from_sdp_string(&string).map_err(D::Error::custom)?;

        Ok(IceCandidate(candidate))
    }
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeSet, net::SocketAddr};

    use super::*;

    #[test]
    fn ice_candidate_ordering() {
        let host = IceCandidate::from(str0m::Candidate::host(sock("1.1.1.1:80"), "udp").unwrap());
        let srflx = IceCandidate::from(
            str0m::Candidate::server_reflexive(sock("1.1.1.1:80"), sock("3.3.3.3:80"), "udp")
                .unwrap(),
        );
        let relay = IceCandidate::from(
            str0m::Candidate::relayed(sock("1.1.1.1:80"), sock("2.2.2.2:80"), "udp").unwrap(),
        );

        let candidate_set = BTreeSet::from([relay.clone(), host.clone(), srflx.clone()]);

        let candidate_list = Vec::from_iter(candidate_set);

        assert_eq!(candidate_list, vec![host, srflx, relay]);
    }

    fn sock(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }
}
