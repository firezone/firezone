//! Sans-IO core of connlib's tunnel implementation.
//!
//! This crate contains the pure, side-effect-free state machines for the Client
//! ([`ClientState`]) and the Gateway ([`GatewayState`]) as well as all supporting logic.
//! The IO / runtime shell lives in the `tunnel` crate which depends on and re-exports this crate.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::print_stdout))]
#![cfg_attr(test, allow(clippy::print_stderr))]

use connlib_model::{
    ClientId, ClientOrGatewayId, GatewayId, IceCandidate, ResourceId, ResourceList,
};
use dns_types::DomainName;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use logging::DisplayBTreeSet;
use std::{
    collections::BTreeSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

mod client;
mod conn_track;
pub mod dns;
mod expiring_map;
mod filter_engine;
mod gateway;
#[cfg(any(test, feature = "malicious-behaviour"))]
mod malicious_behaviour;
pub mod messages;
pub mod otel;
mod p2p_control;
mod packet_kind;
mod peer_store;
mod portal_connection;
#[cfg(test)]
mod proptest;
mod routing_table;
mod unique_packet_buffer;
mod unix_ts;
pub mod unroutable_packet;

pub const IPV4_TUNNEL: Ipv4Network = match Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};
pub const IPV6_TUNNEL: Ipv6Network =
    match Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };
const IPV4_CGNAT: Ipv4Network = match Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 10) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};
const IPV4_RESERVED: Ipv4Network = match Ipv4Network::new(Ipv4Addr::new(240, 0, 0, 0), 4) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};

pub use client::dns_config::DnsMapping;
pub use client::{ClientState, DNS_SENTINELS_V4, DNS_SENTINELS_V6, IPV4_RESOURCES, IPV6_RESOURCES};
pub use dns::DnsResourceRecord;
pub use gateway::{DnsResourceNatEntry, GatewayState, ResolveDnsRequest};
#[cfg(feature = "malicious-behaviour")]
pub use malicious_behaviour::{Guard as MaliciousBehaviourGuard, MaliciousBehaviour};
pub use unroutable_packet::UnroutablePacket;

// TODO: Evaluate moving the data types shared by `tunnel-proto`, `tunnel`, and
// their consumers into `connlib-model` so this crate can expose only the
// state-machine API.

#[derive(Debug)]
pub enum ClientEvent {
    AddedIceCandidates {
        conn_id: ClientOrGatewayId,
        candidates: BTreeSet<IceCandidate>,
    },
    RemovedIceCandidates {
        conn_id: ClientOrGatewayId,
        candidates: BTreeSet<IceCandidate>,
    },
    ResourceConnectionIntent {
        resource: ResourceId,
        preferred_gateways: Vec<GatewayId>,
        /// Set for connection intents to a specific device pool member;
        /// `None` for intents to a gateway-routed resource.
        ip: Option<IpAddr>,
    },
    DevicePoolDomainQueried {
        resource_id: ResourceId,
        domain: DomainName,
    },
    /// The list of resources or connected device peers has changed; UI clients
    /// may have to be updated.
    ResourcesChanged {
        resources: ResourceList,
    },
    DnsRecordsChanged {
        records: BTreeSet<DnsResourceRecord>,
    },
    TunInterfaceUpdated(TunConfig),
    /// We ran out of relays and need a new set from the portal.
    NoRelays,
}

#[derive(Clone, derive_more::Debug, PartialEq, Eq, Hash)]
pub struct TunConfig {
    pub ip: IpConfig,
    /// The map of DNS servers that connlib will use.
    ///
    /// - The "left" values are the connlib-assigned, proxy (or "sentinel") IPs.
    /// - The "right" values are the effective DNS servers.
    ///   If upstream DNS servers are configured (in the portal), we will use those.
    ///   Otherwise, we will use the DNS servers configured on the system.
    pub dns_by_sentinel: DnsMapping,
    pub search_domain: Option<DomainName>,

    #[debug("{}", DisplayBTreeSet(routes))]
    pub routes: BTreeSet<IpNetwork>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IpConfig {
    pub v4: Ipv4Addr,
    pub v6: Ipv6Addr,
}

impl IpConfig {
    pub fn is_ip(&self, ip: IpAddr) -> bool {
        match ip {
            IpAddr::V4(v4) => v4 == self.v4,
            IpAddr::V6(v6) => v6 == self.v6,
        }
    }
}

#[derive(Debug)]
pub enum GatewayEvent {
    AddedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<IceCandidate>,
    },
    RemovedIceCandidates {
        conn_id: ClientId,
        candidates: BTreeSet<IceCandidate>,
    },
    ResolveDns(ResolveDnsRequest),
    /// We ran out of relays and need a new set from the portal.
    NoRelays,
}

#[derive(Debug, thiserror::Error)]
#[error("Not a client IP: {0}")]
pub(crate) struct NotClientIp(IpAddr);

#[derive(Debug, thiserror::Error)]
#[error("Traffic to/from this resource IP is not allowed: {0}")]
pub(crate) struct NotAllowedResource(IpAddr);

#[derive(Debug, thiserror::Error)]
#[error("Failed to decapsulate '{0}' packet")]
pub struct FailedToDecapsulate(packet_kind::Kind);

pub fn is_peer(dst: IpAddr) -> bool {
    match dst {
        IpAddr::V4(v4) => IPV4_TUNNEL.contains(v4),
        IpAddr::V6(v6) => IPV6_TUNNEL.contains(v6),
    }
}

/// Returns whether `ip` may be routed by the Internet Resource.
///
/// Explicit DNS and CIDR resources may still route addresses excluded here.
pub(crate) fn is_internet_resource_ip(ip: IpAddr) -> bool {
    if is_peer(ip) {
        return false;
    }

    match ip {
        IpAddr::V4(v4) => {
            !v4.is_private() && !IPV4_CGNAT.contains(v4) && !IPV4_RESERVED.contains(v4)
        }
        IpAddr::V6(v6) => !IPV6_RESOURCES.contains(v6),
    }
}

#[cfg(test)]
mod unittests {
    use super::*;

    #[test]
    fn mldv2_routers_are_not_peers() {
        assert!(!is_peer("ff02::16".parse().unwrap()))
    }

    #[test]
    fn tunnel_ips_of_both_families_are_peers() {
        assert!(is_peer("100.64.0.3".parse().unwrap()));
        assert!(is_peer("fd00:2021:1111::3".parse().unwrap()));
    }

    #[test]
    fn addresses_outside_the_tunnel_ranges_are_not_peers() {
        assert!(!is_peer("100.96.0.1".parse().unwrap()));
        assert!(!is_peer("fd00:2021:1111:8000::1".parse().unwrap()));
    }

    #[test]
    fn private_cgnat_reserved_and_tunnel_ips_are_not_internet_resource_ips() {
        for ip in [
            "10.0.0.1",
            "172.16.0.1",
            "192.168.0.1",
            "100.64.0.1",
            "100.127.255.254",
            "240.0.0.1",
            "255.255.255.255",
            "fd00:2021:1111::3",
            "fd00:2021:1111:8000::1",
        ] {
            assert!(!is_internet_resource_ip(ip.parse().unwrap()), "{ip}");
        }
    }

    #[test]
    fn public_ips_are_internet_resource_ips() {
        assert!(is_internet_resource_ip("8.8.8.8".parse().unwrap()));
        assert!(is_internet_resource_ip(
            "2606:4700:4700::1111".parse().unwrap()
        ));
    }
}
