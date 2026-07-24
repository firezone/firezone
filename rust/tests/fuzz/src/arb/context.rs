use std::{
    collections::BTreeSet,
    net::{Ipv4Addr, Ipv6Addr},
    ops::RangeInclusive,
    time::Duration,
};

use arbitrary::Unstructured;
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, SiteId};
use ip_network::{Ipv4Network, Ipv6Network};

use crate::reference::PrivateKey;
use crate::transition::{DPort, Identifier, SPort, Seq};

/// Hands out a fresh address per call from a fixed subnet.
///
/// Uniqueness is structural: the iterator never repeats, so no "network IPs must
/// be unique" filter is ever needed.
struct SubnetCursor<A> {
    iter: Box<dyn Iterator<Item = A>>,
}

impl SubnetCursor<Ipv4Addr> {
    fn over(net: Ipv4Network) -> Self {
        Self {
            iter: Box::new(net.hosts()),
        }
    }

    /// Assert (don't wrap) on exhaustion: wrapping would silently reintroduce
    /// the collisions the cursor exists to prevent. The ranges are sized so the
    /// bounded worst case (initial hosts + per-transition roams / relays) stays
    /// far below capacity.
    fn next(&mut self) -> Ipv4Addr {
        self.iter.next().expect("socket subnet (v4) exhausted")
    }
}

impl SubnetCursor<Ipv6Addr> {
    fn over(net: Ipv6Network) -> Self {
        Self {
            iter: Box::new(net.subnets_with_prefix(128).map(|n| n.network_address())),
        }
    }

    fn next(&mut self) -> Ipv6Addr {
        self.iter.next().expect("socket subnet (v6) exhausted")
    }
}

/// The shared generation context: an [`Unstructured`] plus every by-construction
/// allocator used to satisfy uniqueness constraints without rejection loops.
pub struct Generator<'a> {
    input: Unstructured<'a>,

    // Disjoint socket-IP allocators (host routing IPs, distinct from connlib's
    // reserved ranges and from each other).
    socket_ip4: SubnetCursor<Ipv4Addr>, // 203.0.113.0/24 (TEST-NET-3), today's host_ip4s
    socket_ip6: SubnetCursor<Ipv6Addr>, // 2001:db80:1010:1010::/64
    nat_ip4: SubnetCursor<Ipv4Addr>,    // 198.51.100.0/24 (TEST-NET-2), public NAT addresses
    do53_ip4: SubnetCursor<Ipv4Addr>,   // 192.18.0.0/24 (benchmarking range, RFC2544)
    do53_ip6: SubnetCursor<Ipv6Addr>,   // 2001:db80:53:53::/64

    // Monotonic id counters (uniqueness by counter, not by set-dedup resampling).
    next_site: u64,
    next_client: u64,
    next_gateway: u64,
    next_relay: u64,
    next_resource: u64,

    // Monotonic key counter.
    next_key: u32,

    // Monotonic payload counter (packet identity; see `fresh_payload`).
    next_payload: u64,

    // Packet keys used by the simulated clients' request / reply maps.
    icmp_packets: BTreeSet<(Seq, Identifier)>,
    udp_packets: BTreeSet<(SPort, DPort)>,
    tcp_connections: BTreeSet<(SPort, DPort)>,
}

impl<'a> Generator<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self {
            input: Unstructured::new(data),
            socket_ip4: SubnetCursor::<Ipv4Addr>::over(
                "203.0.113.0/24".parse::<Ipv4Network>().unwrap(),
            ),
            socket_ip6: SubnetCursor::<Ipv6Addr>::over(
                Ipv6Network::new_truncate(
                    Ipv6Addr::new(0x2001, 0xDB80, 0x1010, 0x1010, 0, 0, 0, 0),
                    64,
                )
                .unwrap(),
            ),
            nat_ip4: SubnetCursor::<Ipv4Addr>::over(
                "198.51.100.0/24".parse::<Ipv4Network>().unwrap(),
            ),
            do53_ip4: SubnetCursor::<Ipv4Addr>::over(
                "192.18.0.0/24".parse::<Ipv4Network>().unwrap(),
            ),
            do53_ip6: SubnetCursor::<Ipv6Addr>::over(
                Ipv6Network::new_truncate(
                    Ipv6Addr::new(0x2001, 0xDB80, 0x53, 0x53, 0, 0, 0, 0),
                    64,
                )
                .unwrap(),
            ),
            next_site: 0,
            next_client: 0,
            next_gateway: 0,
            next_relay: 0,
            next_resource: 0,
            next_key: 0,
            next_payload: 0,
            icmp_packets: BTreeSet::new(),
            udp_packets: BTreeSet::new(),
            tcp_connections: BTreeSet::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.input.is_empty()
    }

    // --- the locality-preserving byte primitives the generators use ---

    /// Bounded count; on exhaustion returns the minimum so invariant-bearing
    /// collections degrade to their smallest legal size, never empty / unbounded.
    pub(super) fn count(&mut self, lo: usize, hi: usize) -> usize {
        self.input.int_in_range(lo..=hi).unwrap_or(lo)
    }

    /// Pick an index in `0..len`. Exhaustion yields the first element.
    pub(super) fn choose_index(&mut self, len: usize) -> usize {
        assert!(len > 0, "cannot choose from an empty collection");
        self.input.int_in_range(0..=len - 1).unwrap_or(0)
    }

    /// Heads with the given percentage probability.
    pub(super) fn flip(&mut self, heads_pct: u8) -> bool {
        if self.input.is_empty() {
            return false;
        }

        self.input
            .int_in_range(0..=99u32)
            .is_ok_and(|draw| draw < heads_pct as u32)
    }

    pub(super) fn bool(&mut self) -> bool {
        self.input.arbitrary().unwrap_or(false)
    }

    pub(super) fn u8(&mut self) -> u8 {
        self.input.arbitrary().unwrap_or(0)
    }

    pub(super) fn u16(&mut self) -> u16 {
        self.input.arbitrary().unwrap_or(0)
    }

    pub(super) fn u32(&mut self) -> u32 {
        self.input.arbitrary().unwrap_or(0)
    }

    pub(super) fn u64(&mut self) -> u64 {
        self.input.arbitrary().unwrap_or(0)
    }

    pub(super) fn u16_in(&mut self, range: RangeInclusive<u16>) -> u16 {
        let fallback = *range.start();
        self.input.int_in_range(range).unwrap_or(fallback)
    }

    pub(super) fn u32_in(&mut self, range: RangeInclusive<u32>) -> u32 {
        let fallback = *range.start();
        self.input.int_in_range(range).unwrap_or(fallback)
    }

    pub(super) fn u64_in(&mut self, range: RangeInclusive<u64>) -> u64 {
        let fallback = *range.start();
        self.input.int_in_range(range).unwrap_or(fallback)
    }

    pub(super) fn socket_ip4(&mut self) -> Ipv4Addr {
        self.socket_ip4.next()
    }

    pub(super) fn socket_ip6(&mut self) -> Ipv6Addr {
        self.socket_ip6.next()
    }

    pub(super) fn nat_ip4(&mut self) -> Ipv4Addr {
        self.nat_ip4.next()
    }

    pub(super) fn do53_ip4(&mut self) -> Ipv4Addr {
        self.do53_ip4.next()
    }

    pub(super) fn do53_ip6(&mut self) -> Ipv6Addr {
        self.do53_ip6.next()
    }

    pub(super) fn fresh_site_id(&mut self) -> SiteId {
        let n = self.next_site;
        self.next_site += 1;
        SiteId::from_u128(u128::from(n) << 64)
    }

    pub(super) fn fresh_client_id(&mut self) -> ClientId {
        let n = self.next_client;
        self.next_client += 1;
        ClientId::from_u128(u128::from(n) << 64)
    }

    pub(super) fn fresh_gateway_id(&mut self) -> GatewayId {
        let n = self.next_gateway;
        self.next_gateway += 1;
        GatewayId::from_u128(u128::from(n) << 64)
    }

    pub(super) fn fresh_relay_id(&mut self) -> RelayId {
        let n = self.next_relay;
        self.next_relay += 1;
        RelayId::from_u128(u128::from(n) << 64)
    }

    pub(super) fn fresh_resource_id(&mut self) -> ResourceId {
        let n = self.next_resource;
        self.next_resource += 1;
        ResourceId::from_u128(u128::from(n) << 64)
    }

    /// Monotonic, unique private key. The counter occupies the first 4 bytes
    /// (keys are clamped and feed a deterministic HKDF, so this is harmless for
    /// test keys); the remaining bytes carry handshake entropy.
    pub(super) fn fresh_private_key(&mut self) -> PrivateKey {
        let n = self.next_key;
        self.next_key += 1;
        let mut bytes = [0u8; 32];
        bytes[0..4].copy_from_slice(&n.to_be_bytes());
        let _ = self.input.fill_buffer(&mut bytes[4..]);
        PrivateKey(bytes)
    }

    /// A packet payload that is unique within a scenario. Like
    /// [`fresh_private_key`](Self::fresh_private_key) a monotonic counter takes
    /// the high bits and the rest carries entropy. It reads the same eight bytes
    /// as a bare `u64`. The reference model identifies every packet solely by
    /// this value to match a client's send against the gateway's receive; two
    /// packets sharing one would alias in that map.
    pub(super) fn fresh_payload(&mut self) -> u64 {
        let n = self.next_payload;
        self.next_payload += 1;
        let entropy = self.u64();
        ((n & 0xFF_FFFF) << 40) | (entropy & 0xFF_FFFF_FFFF)
    }

    pub(super) fn fresh_icmp_packet(&mut self) -> (Seq, Identifier) {
        let candidate = (self.u16(), self.u16());
        let packet = (0..=u16::MAX)
            .map(|offset| {
                (
                    Seq(candidate.0.wrapping_add(offset)),
                    Identifier(candidate.1),
                )
            })
            .find(|packet| !self.icmp_packets.contains(packet))
            .expect("a scenario cannot exhaust all ICMP packet identifiers");
        self.icmp_packets.insert(packet);

        packet
    }

    pub(super) fn fresh_udp_packet(&mut self, dport: u16) -> (SPort, DPort) {
        let candidate = self.u16();
        let packet = (0..=u16::MAX)
            .map(|offset| (SPort(candidate.wrapping_add(offset)), DPort(dport)))
            .find(|packet| !self.udp_packets.contains(packet))
            .expect("a scenario cannot exhaust all UDP packet identifiers");
        self.udp_packets.insert(packet);

        packet
    }

    pub(super) fn fresh_tcp_connection(&mut self, dport: u16) -> (SPort, DPort) {
        let candidate = self.u16_in(1..=u16::MAX);
        let connection = (0..u32::from(u16::MAX))
            .map(|offset| {
                let sport = ((u32::from(candidate) - 1 + offset) % u32::from(u16::MAX) + 1) as u16;
                (SPort(sport), DPort(dport))
            })
            .find(|connection| !self.tcp_connections.contains(connection))
            .expect("a scenario cannot exhaust all TCP connection identifiers");
        self.tcp_connections.insert(connection);

        connection
    }

    pub(super) fn latency(&mut self, max: u64) -> Duration {
        Duration::from_millis(self.u64_in(10..=max - 1))
    }

    /// `[a-z]{lo..=hi}`.
    pub(super) fn lower_ascii(&mut self, lo: usize, hi: usize) -> String {
        let n = self.count(lo, hi);
        (0..n)
            .map(|_| self.u8_in(b'a'..=b'z') as char)
            .collect::<String>()
    }

    fn u8_in(&mut self, range: RangeInclusive<u8>) -> u8 {
        let fallback = *range.start();
        self.input.int_in_range(range).unwrap_or(fallback)
    }
}

#[cfg(test)]
mod tests {
    use super::Generator;

    #[test]
    fn exhausted_probability_draws_are_false() {
        assert!(!Generator::new(&[]).flip(50));
    }
}
