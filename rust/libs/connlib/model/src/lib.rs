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
    CidrResourceView, ConnectedDeviceView, DnsResourceView, InternetResourceView, ResourceList,
    ResourceStatus, ResourceView,
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

/// A signalling candidate on the wire: an SDP `candidate:` string.
///
/// A thin wrapper — the codec (ICE vs ICE-less) lives in `snownet`. `priority`
/// is extracted once to preserve the `host > srflx > relay` signalling order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IceCandidate {
    sdp: String,
    priority: u32,
}

impl From<String> for IceCandidate {
    fn from(sdp: String) -> Self {
        let priority = parse_priority(&sdp).unwrap_or(0);

        Self { sdp, priority }
    }
}

impl From<IceCandidate> for String {
    fn from(candidate: IceCandidate) -> Self {
        candidate.sdp
    }
}

impl PartialOrd for IceCandidate {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for IceCandidate {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Higher priority first; the tie-break keeps distinct candidates that
        // share a priority (ICE-less priority is per-kind, so same-kind collide).
        self.priority
            .cmp(&other.priority)
            .reverse()
            .then_with(|| self.sdp.cmp(&other.sdp))
    }
}

impl Serialize for IceCandidate {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.sdp)
    }
}

impl<'de> Deserialize<'de> for IceCandidate {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::Error as _;

        let sdp = String::deserialize(deserializer)?;
        let priority =
            parse_priority(&sdp).ok_or_else(|| D::Error::custom("not an SDP candidate line"))?;

        Ok(Self { sdp, priority })
    }
}

/// Extracts the `priority` (4th field) from an SDP `candidate:` line.
fn parse_priority(sdp: &str) -> Option<u32> {
    if !sdp.starts_with("candidate:") {
        return None;
    }

    sdp.split_ascii_whitespace().nth(3)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn ice_candidate_ordering() {
        // Higher priority sorts first: host > srflx > relay.
        let host =
            IceCandidate::from("candidate:1 1 udp 2130706431 1.1.1.1 80 typ host".to_owned());
        let srflx = IceCandidate::from(
            "candidate:2 1 udp 1694498815 1.1.1.1 80 typ srflx raddr 3.3.3.3 rport 80".to_owned(),
        );
        let relay = IceCandidate::from(
            "candidate:3 1 udp 16777215 1.1.1.1 80 typ relay raddr 2.2.2.2 rport 80".to_owned(),
        );

        let candidate_set = BTreeSet::from([relay.clone(), host.clone(), srflx.clone()]);

        let candidate_list = Vec::from_iter(candidate_set);

        assert_eq!(candidate_list, vec![host, srflx, relay]);
    }

    #[test]
    fn parse_priority_extracts_or_rejects() {
        assert_eq!(
            parse_priority("candidate:1 1 udp 12345 1.1.1.1 80 typ host"),
            Some(12345)
        );
        assert_eq!(parse_priority("garbage"), None);
        assert_eq!(
            parse_priority("candidate:1 1 udp not-a-number 1.1.1.1 80 typ host"),
            None
        );
    }
}
