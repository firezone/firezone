use std::net::IpAddr;
use std::num::NonZeroUsize;

use anyhow::{Context as _, Result};
use ip_packet::{IpPacket, IpProtocol, IpVersion, Protocol};

/// The 5-tuple packets are batched by, letting later packets of a flow reuse the routing decision
/// of the first.
///
/// Holds the bytes of the addresses and ports as they appear in the packet.
#[derive(Debug, Clone, Copy)]
pub(crate) struct BatchingKey {
    protocol: IpProtocol,
    ports: [u8; 4],
    addresses: Addresses,
}

#[derive(Debug, Clone, Copy)]
enum Addresses {
    V4([u8; 8]),
    V6([u8; 32]),
}

impl BatchingKey {
    /// Returns the key of a TCP or UDP `packet`, unless it changes the state of its flow.
    ///
    /// A TCP SYN, FIN or RST changes connection-tracking and NAT state, so it takes the slow path.
    /// So does ICMP: an echo request and the echo reply going the same way share addresses and
    /// identifier, yet are routed and authorized differently.
    pub(crate) fn of(packet: &IpPacket) -> Option<Self> {
        if !packet.is_batchable() {
            return None;
        }

        let addresses = match packet.version() {
            IpVersion::V4 => Addresses::V4(packet.address_bytes().try_into().ok()?),
            IpVersion::V6 => Addresses::V6(packet.address_bytes().try_into().ok()?),
        };

        Some(Self {
            protocol: packet.next_header(),
            ports: ports(packet)?,
            addresses,
        })
    }

    /// Returns whether `packet` has this key.
    pub(crate) fn matches(&self, packet: &IpPacket) -> bool {
        if !packet.is_batchable()
            || packet.next_header() != self.protocol
            || ports(packet) != Some(self.ports)
        {
            return false;
        }

        match &self.addresses {
            Addresses::V4(addresses) => packet.address_bytes() == addresses,
            Addresses::V6(addresses) => packet.address_bytes() == addresses,
        }
    }
}

/// Reads the source and destination port at the start of a TCP or UDP header.
fn ports(packet: &IpPacket) -> Option<[u8; 4]> {
    packet.payload().get(..4)?.try_into().ok()
}

/// A batch of packets received on the TUN device that share one flow and thus one routing decision.
///
/// Holds the state borrowed until [`TunBatch::finish`] reserves the batch's WireGuard counters,
/// so no other packet or event can change the decision in between.
#[must_use = "no counters are reserved until the batch is finished"]
pub struct TunBatch<'a, S: flow_tracker::Scope> {
    /// The key further packets must have; `None` admits no further packets.
    key: Option<BatchingKey>,
    /// The source rewrite of the first packet, applied to every further one.
    nat: Option<(Protocol, IpAddr)>,
    tunnel: snownet::EncapsulateBatch<'a>,
    flows: flow_tracker::FlowBatch<'a, S>,
    /// The packets of the batch, starting with the one that routed it.
    packets: Vec<IpPacket>,
}

impl<'a, S: flow_tracker::Scope> TunBatch<'a, S> {
    pub(crate) fn new(
        key: Option<BatchingKey>,
        nat: Option<(Protocol, IpAddr)>,
        tunnel: snownet::EncapsulateBatch<'a>,
        flows: flow_tracker::FlowBatch<'a, S>,
        packet: IpPacket,
    ) -> Self {
        let mut packets = Vec::with_capacity(tun::MAX_BATCH_SIZE);
        packets.push(packet);

        Self {
            key,
            nat,
            tunnel,
            flows,
            packets,
        }
    }

    /// Returns whether `packet` has the batch's key.
    pub fn accepts(&self, packet: &IpPacket) -> bool {
        self.key.as_ref().is_some_and(|key| key.matches(packet))
    }

    /// Adds `packet`, which the batch [accepts](Self::accepts), translating it like the first one.
    pub fn push(&mut self, mut packet: IpPacket) {
        if let Some((proto, ip)) = self.nat {
            let translated = packet.translate_source(proto, ip);

            // The first packet translated fine and this one shares its flow, thus its IP version.
            debug_assert!(translated.is_ok(), "{translated:?}");
        }

        self.flows.add(&packet);
        self.packets.push(packet);
    }

    /// Reserves the batch's counters and records its flow.
    pub fn finish(mut self) -> Result<(snownet::PendingEncapsulate, Vec<IpPacket>)> {
        let len = NonZeroUsize::new(self.packets.len()).expect("A batch starts with a packet");
        let encapsulation = match self.tunnel.finish(len) {
            Ok(encapsulation) => encapsulation,
            Err(e) => {
                self.flows.discard();

                return Err(e).context("Failed to encapsulate");
            }
        };

        self.flows.finish();

        Ok((encapsulation, self.packets))
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use ip_packet::make;

    use super::*;

    const SRC: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);
    const DST: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 2);
    const OTHER: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 3);

    #[test]
    fn matches_packets_of_the_same_flow() {
        let key = BatchingKey::of(&udp(SRC, DST, 1000, 53, b"foo")).unwrap();

        assert!(key.matches(&udp(SRC, DST, 1000, 53, b"foobar")));
    }

    #[test]
    fn does_not_match_packets_of_other_flows() {
        let key = BatchingKey::of(&udp(SRC, DST, 1000, 53, b"")).unwrap();

        for packet in [
            udp(OTHER, DST, 1000, 53, b""),
            udp(SRC, OTHER, 1000, 53, b""),
            udp(SRC, DST, 1001, 53, b""),
            udp(SRC, DST, 1000, 54, b""),
            tcp(SRC, DST, 1000, 53, make::TcpFlags::default()),
            udp(SRC.to_ipv6_mapped(), DST.to_ipv6_mapped(), 1000, 53, b""),
        ] {
            assert!(!key.matches(&packet), "{packet:?}");
        }
    }

    #[test]
    fn ipv6_flow_does_not_match_ipv4_packet() {
        let key = BatchingKey::of(&udp(
            SRC.to_ipv6_mapped(),
            DST.to_ipv6_mapped(),
            1000,
            53,
            b"",
        ))
        .unwrap();

        assert!(!key.matches(&udp(SRC, DST, 1000, 53, b"")));
    }

    #[test]
    fn does_not_match_control_segments_of_its_flow() {
        let ack = make::TcpFlags {
            ack: true,
            ..Default::default()
        };
        let rst = make::TcpFlags {
            rst: true,
            ..Default::default()
        };
        let key = BatchingKey::of(&tcp(SRC, DST, 1000, 443, ack)).unwrap();

        assert!(key.matches(&tcp(SRC, DST, 1000, 443, ack)));
        assert!(!key.matches(&tcp(SRC, DST, 1000, 443, rst)));
    }

    fn udp(
        src: impl Into<IpAddr>,
        dst: impl Into<IpAddr>,
        sport: u16,
        dport: u16,
        payload: &[u8],
    ) -> IpPacket {
        make::udp_packet(src, dst, sport, dport, payload).unwrap()
    }

    fn tcp(
        src: Ipv4Addr,
        dst: Ipv4Addr,
        sport: u16,
        dport: u16,
        flags: make::TcpFlags,
    ) -> IpPacket {
        make::tcp_packet(src, dst, sport, dport, flags, &[]).unwrap()
    }
}
