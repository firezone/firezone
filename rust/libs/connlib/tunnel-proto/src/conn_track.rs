//! Stateful connection tracker for client-to-client flows.
//!
//! Flows are tracked separately by which side opened them: only flows *we*
//! opened grant a return-traffic exemption from the inbound filter, so
//! revoking or expiring an authorization cuts off peer-opened flows.

use ip_packet::{IpPacket, Protocol};
use std::collections::BTreeMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

#[derive(Default, Debug)]
pub(crate) struct ConnTrack {
    initiated: BTreeMap<Key, Instant>,
    received: BTreeMap<Key, Instant>,
}

/// Which side opened a tracked flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Originator {
    Us,
    Peer,
}

impl ConnTrack {
    /// Records or refreshes an outbound flow we opened to a peer.
    ///
    /// Remembers the packet's flow as one that we opened. Replies to flows
    /// that the peer opened are ignored: those flows must keep passing the
    /// inbound filter, so that they stop once their authorization is gone.
    pub(crate) fn record_outbound_as_originator(&mut self, packet: &IpPacket, now: Instant) {
        let Ok(local) = packet.source_protocol() else {
            return;
        };
        let Ok(peer) = packet.destination_protocol() else {
            return;
        };

        let key = Key {
            local,
            peer,
            local_ip: packet.source(),
            peer_ip: packet.destination(),
        };

        if self.received.contains_key(&key) && !self.initiated.contains_key(&key) {
            return;
        }

        self.initiated.insert(key, now);
    }

    /// Record an inbound packet of a flow the *peer* opened to us.
    pub(crate) fn record_inbound(&mut self, packet: &IpPacket, now: Instant) {
        let Ok(local) = packet.destination_protocol() else {
            return;
        };
        let Ok(peer) = packet.source_protocol() else {
            return;
        };

        self.received.insert(
            Key {
                local,
                peer,
                local_ip: packet.destination(),
                peer_ip: packet.source(),
            },
            now,
        );
    }

    /// Returns `true` if the packet is the reply to a flow *we* opened.
    pub(crate) fn is_return_traffic(&self, packet: &IpPacket) -> bool {
        let Ok(peer) = packet.source_protocol() else {
            return false;
        };
        let Ok(local) = packet.destination_protocol() else {
            return false;
        };

        self.initiated.contains_key(&Key {
            local,
            peer,
            local_ip: packet.destination(),
            peer_ip: packet.source(),
        })
    }

    /// Returns `true` if the packet belongs to an existing flow in either direction.
    ///
    /// An ICMP error belongs to the flow of the failed packet it references.
    pub(crate) fn is_known_flow(&self, packet: &IpPacket) -> bool {
        if let Ok(Some((failed, _))) = packet.icmp_error() {
            return self.contains(Key {
                local: failed.src_proto(),
                peer: failed.dst_proto(),
                local_ip: failed.src(),
                peer_ip: failed.dst(),
            });
        }

        let Ok(local) = packet.source_protocol() else {
            return false;
        };
        let Ok(peer) = packet.destination_protocol() else {
            return false;
        };

        self.contains(Key {
            local,
            peer,
            local_ip: packet.source(),
            peer_ip: packet.destination(),
        })
    }

    fn contains(&self, key: Key) -> bool {
        self.initiated.contains_key(&key) || self.received.contains_key(&key)
    }

    /// Who opened the flow this *outbound* packet belongs to, if it is tracked.
    pub(crate) fn outbound_flow_originator(&self, packet: &IpPacket) -> Option<Originator> {
        let Ok(local) = packet.source_protocol() else {
            return None;
        };
        let Ok(peer) = packet.destination_protocol() else {
            return None;
        };

        let key = Key {
            local,
            peer,
            local_ip: packet.source(),
            peer_ip: packet.destination(),
        };

        if self.initiated.contains_key(&key) {
            return Some(Originator::Us);
        }

        if self.received.contains_key(&key) {
            return Some(Originator::Peer);
        }

        None
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        for map in [&mut self.initiated, &mut self.received] {
            for _ in map.extract_if(.., |key, last_seen| {
                now.saturating_duration_since(*last_seen) >= ttl(key)
            }) {}
        }
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
        ct.record_outbound_as_originator(&outbound, now);

        let reply = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 8080, 53535, &[])
            .expect("valid packet");
        assert!(ct.is_return_traffic(&reply));
    }

    #[test]
    fn unrelated_inbound_is_not_return_traffic() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound_as_originator(&outbound, now);

        // Different source port — not the reply we expected.
        let unrelated = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 9999, 53535, &[])
            .expect("valid packet");
        assert!(!ct.is_return_traffic(&unrelated));
    }

    #[test]
    fn peer_opened_flow_is_not_return_traffic() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let inbound = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 40000, 80, &[])
            .expect("valid packet");
        ct.record_inbound(&inbound, now);

        let next = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 40000, 80, &[1])
            .expect("valid packet");
        assert!(!ct.is_return_traffic(&next));

        let reply = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 80, 40000, &[])
            .expect("valid packet");
        assert!(ct.is_known_flow(&reply));
    }

    #[test]
    fn continued_traffic_keeps_initiated_flow_alive() {
        let mut ct = ConnTrack::default();
        let start = Instant::now();

        let outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound_as_originator(&outbound, start);

        ct.record_outbound_as_originator(&outbound, start + UDP_TTL - Duration::from_secs(1));

        ct.handle_timeout(start + UDP_TTL + Duration::from_secs(1));

        let reply = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 8080, 53535, &[])
            .expect("valid packet");
        assert!(ct.is_return_traffic(&reply));
    }

    #[test]
    fn reply_to_peer_opened_flow_does_not_create_exemption() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let inbound = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 40000, 80, &[])
            .expect("valid packet");
        ct.record_inbound(&inbound, now);

        let reply = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 80, 40000, &[])
            .expect("valid packet");
        ct.record_outbound_as_originator(&reply, now);

        let next = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 40000, 80, &[1])
            .expect("valid packet");
        assert!(!ct.is_return_traffic(&next));
    }

    #[test]
    fn entries_expire_after_ttl() {
        let mut ct = ConnTrack::default();
        let start = Instant::now();

        let outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound_as_originator(&outbound, start);

        ct.handle_timeout(start + UDP_TTL + Duration::from_secs(1));

        let reply = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 8080, 53535, &[])
            .expect("valid packet");
        assert!(!ct.is_return_traffic(&reply));
    }

    #[test]
    fn icmp_echo_reply_admitted_via_identifier() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let request =
            make::icmp_request_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 1, 42, &[]).expect("valid");
        ct.record_outbound_as_originator(&request, now);

        let reply =
            make::icmp_reply_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 1, 42, &[]).expect("valid");
        assert!(ct.is_return_traffic(&reply));
    }

    #[test]
    fn ipv4_and_ipv6_flows_with_same_ports_do_not_alias() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let v4_outbound = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 5353, 5353, &[])
            .expect("valid packet");
        ct.record_outbound_as_originator(&v4_outbound, now);

        // A v6 reply on the same port pair must NOT count as return traffic.
        let v6_reply = make::udp_packet(
            IpAddr::V6(Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 2)),
            IpAddr::V6(Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 1)),
            5353,
            5353,
            &[],
        )
        .expect("valid packet");
        assert!(!ct.is_return_traffic(&v6_reply));
    }

    #[test]
    fn outbound_originator_follows_who_opened_the_flow() {
        let mut ct = ConnTrack::default();
        let now = Instant::now();

        let ours = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 53535, 8080, &[])
            .expect("valid packet");
        ct.record_outbound_as_originator(&ours, now);
        assert_eq!(ct.outbound_flow_originator(&ours), Some(Originator::Us));

        let inbound = make::udp_packet(ip(10, 0, 0, 2), ip(10, 0, 0, 1), 40000, 80, &[])
            .expect("valid packet");
        ct.record_inbound(&inbound, now);

        // Our reply belongs to the peer's flow, not to one we opened.
        let reply = make::udp_packet(ip(10, 0, 0, 1), ip(10, 0, 0, 2), 80, 40000, &[])
            .expect("valid packet");
        ct.record_outbound_as_originator(&reply, now);
        assert_eq!(ct.outbound_flow_originator(&reply), Some(Originator::Peer));
    }

    fn ip(a: u8, b: u8, c: u8, d: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(a, b, c, d))
    }
}
