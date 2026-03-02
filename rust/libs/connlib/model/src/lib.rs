//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

#![cfg_attr(test, allow(clippy::unwrap_used))]

#[macro_use]
mod make_id;
mod view;

pub use boringtun::x25519::PublicKey;
pub use boringtun::x25519::StaticSecret;
pub use view::{
    CidrResourceView, DnsResourceView, InternetResourceView, ResourceStatus, ResourceView,
};

use serde::{Deserialize, Serialize};
use std::fmt;

make_id!(GatewayId);
make_id!(ResourceId);
make_id!(RelayId);
make_id!(ClientId);
make_id!(SiteId);

#[derive(
    Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, derive_more::From,
)]
pub enum ClientOrGatewayId {
    Client(ClientId),
    Gateway(GatewayId),
}

impl fmt::Display for ClientOrGatewayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ClientOrGatewayId::Client(inner) => write!(f, "Client({inner})"),
            ClientOrGatewayId::Gateway(inner) => write!(f, "Gateway({inner})"),
        }
    }
}

impl fmt::Debug for ClientOrGatewayId {
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
