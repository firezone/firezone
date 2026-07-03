//! Stateful connection tracker for client-to-client flows.
//!
//! Records each flow under a normalised "from this peer's perspective" key
//! (local IP + protocol, peer IP + protocol). The same key is produced for:
//!
//! - An outbound we initiated (`record_outbound`) and the inbound reply
//!   that comes back (`inbound_flow_originator`).
//! - An inbound we received from a peer (`record_inbound`) and the outbound
//!   reply we may produce (`outbound_flow_originator`).
//!
//! That symmetry lets a single map serve both directions: a peer initiates
//! to us → we record on inbound → our reply outbound is admitted as a known
//! flow without firing a fresh connection intent. Each entry remembers who
//! sent the flow's first packet, so packet processing can tell replies to
//! our flows apart from flows the peer initiated. The IP pair is part of
//! the key so a v4 flow and a v6 flow with identical port pairs don't
//! collide.

use ip_packet::{IpPacket, Protocol};
use std::collections::BTreeMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

#[derive(Default, Debug)]
pub(crate) struct ConnTrack {
    entries: BTreeMap<Key, Entry>,
}

/// Which side sent the first packet of a tracked flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Originator {
    Us,
    Peer,
}

#[derive(Debug, Clone, Copy)]
struct Entry {
    last_seen: Instant,
    originator: Originator,
}

impl ConnTrack {
    /// Record an outbound packet we sent to a peer.
    pub(crate) fn record_outbound(&mut self, packet: &IpPacket, now: Instant) {
        let Ok(local) = packet.source_protocol() else {
            return;
        };
        let Ok(peer) = packet.destination_protocol() else {
            return;
        };

        self.record(
            Key {
                local,
                peer,
                local_ip: packet.source(),
                peer_ip: packet.destination(),
            },
            Originator::Us,
            now,
        );
    }

    /// Record an inbound packet we received from a peer.
    pub(crate) fn record_inbound(&mut self, packet: &IpPacket, now: Instant) {
        let Ok(local) = packet.destination_protocol() else {
            return;
        };
        let Ok(peer) = packet.source_protocol() else {
            return;
        };

        self.record(
            Key {
                local,
                peer,
                local_ip: packet.destination(),
                peer_ip: packet.source(),
            },
            Originator::Peer,
            now,
        );
    }

    /// The flow's first packet fixes the originator; later packets only refresh.
    fn record(&mut self, key: Key, originator: Originator, now: Instant) {
        self.entries
            .entry(key)
            .and_modify(|entry| entry.last_seen = now)
            .or_insert(Entry {
                last_seen: now,
                originator,
            });
    }

    /// Who initiated the flow this *inbound* packet belongs to, if it is tracked.
    pub(crate) fn inbound_flow_originator(&self, packet: &IpPacket) -> Option<Originator> {
        let Ok(peer) = packet.source_protocol() else {
            return None;
        };
        let Ok(local) = packet.destination_protocol() else {
            return None;
        };

        let entry = self.entries.get(&Key {
            local,
            peer,
            local_ip: packet.destination(),
            peer_ip: packet.source(),
        })?;

        Some(entry.originator)
    }

    /// Who initiated the flow this *outbound* packet belongs to, if it is tracked.
    pub(crate) fn outbound_flow_originator(&self, packet: &IpPacket) -> Option<Originator> {
        let Ok(local) = packet.source_protocol() else {
            return None;
        };
        let Ok(peer) = packet.destination_protocol() else {
            return None;
        };

        let entry = self.entries.get(&Key {
            local,
            peer,
            local_ip: packet.source(),
            peer_ip: packet.destination(),
        })?;

        Some(entry.originator)
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        for _ in self.entries.extract_if(.., |key, entry| {
            now.saturating_duration_since(entry.last_seen) >= ttl(key)
        }) {}
    }
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Key {
    /// Our local endpoint — source port for TCP/UDP, identifier for ICMP.
    local: Protocol,
    /// The peer's endpoint.
    peer: Protocol,
    /// Our local tunnel IP (v4 or v6).
    local_ip: IpAddr,
    /// The peer's tunnel IP (v4 or v6).
    peer_ip: IpAddr,
}

// RFC 5382 REQ-5 floor for an established connection: 2h4m (see `nat_table`).
const TCP_TTL: Duration = Duration::from_secs(60 * 60 * 2 + 60 * 4);
const UDP_TTL: Duration = Duration::from_secs(60 * 2);
const ICMP_TTL: Duration = Duration::from_secs(60 * 2);

fn ttl(key: &Key) -> Duration {
    match key.local {
        Protocol::Tcp(_) => TCP_TTL,
        Protocol::Udp(_) => UDP_TTL,
        Protocol::IcmpEcho(_) => ICMP_TTL,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ip_packet::make;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    #[test]
    fn records_outbound_admits_reply() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound(&outbound, now);

        let reply = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 8080, 53535, &[])
            .expect("valid packet");
        assert_eq!(ct.inbound_flow_originator(&reply), Some(Originator::Us));
    }

    #[test]
    fn unrelated_inbound_is_not_return_traffic() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound(&outbound, now);

        // Different source port — not the reply we expected.
        let unrelated = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 9999, 53535, &[])
            .expect("valid packet");
        assert_eq!(ct.inbound_flow_originator(&unrelated), None);
    }

    #[test]
    fn originator_is_fixed_by_first_packet() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let inbound = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 8080, 53535, &[])
            .expect("valid packet");
        ct.record_inbound(&inbound, now);

        // Our reply refreshes the entry but must not flip the originator.
        let reply = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound(&reply, now);

        assert_eq!(ct.outbound_flow_originator(&reply), Some(Originator::Peer));
        assert_eq!(ct.inbound_flow_originator(&inbound), Some(Originator::Peer));
    }

    #[test]
    fn entries_expire_after_ttl() {
        let mut ct = ConnTrack::default();
        let start = Instant::now();

        let outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound(&outbound, start);

        ct.handle_timeout(start + UDP_TTL + Duration::from_secs(1));

        let reply = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 8080, 53535, &[])
            .expect("valid packet");
        assert_eq!(ct.inbound_flow_originator(&reply), None);
    }

    #[test]
    fn icmp_echo_reply_admitted_via_identifier() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let request =
            make::icmp_request_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 1, 42, &[]).expect("valid");
        ct.record_outbound(&request, now);

        let reply =
            make::icmp_reply_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 1, 42, &[]).expect("valid");
        assert_eq!(ct.inbound_flow_originator(&reply), Some(Originator::Us));
    }

    #[test]
    fn ipv4_and_ipv6_flows_with_same_ports_do_not_alias() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let v4_outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 5353, 5353, &[])
            .expect("valid packet");
        ct.record_outbound(&v4_outbound, now);

        // A v6 reply on the same port pair must NOT count as return traffic.
        let v6_reply = make::udp_packet(
            IpAddr::V6(Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 2)),
            IpAddr::V6(Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 1)),
            5353,
            5353,
            &[],
        )
        .expect("valid packet");
        assert_eq!(ct.inbound_flow_originator(&v6_reply), None);
    }

    fn ip(a: u8, b: u8, c: u8, d: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(a, b, c, d))
    }
}
