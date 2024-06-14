//! a stateful symmetric NAT table that performs conversion between a client's picked proxy ip and the actual resource's IP
use bimap::BiMap;
use ip_packet::{IpPacket, Protocol};
use std::collections::HashMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

/// The stateful NAT table converts a client's picked proxy ip for a domain name into the real IP for that IP
/// it also picks a source port to keep track of the original proxy IP used.
/// The NAT sessions, i.e. the mapping between (source_port, proxy_ip) to (source_port', real_ip) is kept for 60 seconds
/// after no incoming traffic is received.
///
/// Note that for ICMP echo/reply the identity number is used as a stand in for the source port.
///
/// Also, the proxy_ip and the real_ip version may not coincide, in that case a translation mechanism must be used (RFC6145)
///
/// This nat table doesn't perform any mangling just provides the converted port/ip for upper layers
#[derive(Default, Debug)]
pub(crate) struct NatTable {
    pub(crate) table: BiMap<(Protocol, IpAddr), (Protocol, IpAddr)>,
    pub(crate) last_seen: HashMap<(Protocol, IpAddr), Instant>,
}

const TTL: Duration = Duration::from_secs(60);

impl NatTable {
    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        let mut removed = Vec::new();
        for (outside, e) in self.last_seen.iter() {
            if now.duration_since(*e) >= TTL {
                if let Some((inside, _)) = self.table.remove_by_right(outside) {
                    tracing::debug!(?inside, ?outside, "NAT session expired");
                }

                removed.push(*outside);
            }
        }

        for r in removed {
            self.last_seen.remove(&r);
        }
    }

    pub(crate) fn translate_outgoing(
        &mut self,
        packet: IpPacket,
        outside_dst: IpAddr,
        now: Instant,
    ) -> Result<(Protocol, IpAddr), connlib_shared::Error> {
        let src = packet
            .source_protocol()
            .map_err(connlib_shared::Error::UnsupportedProtocol)?;
        let dst = packet.destination();

        let inside = (src, dst);

        if let Some(outside) = self.table.get_by_left(&inside) {
            if outside.1 == outside_dst {
                tracing::trace!(?inside, ?outside, "Translating outgoing packet");

                self.last_seen.insert(*outside, now);
                return Ok(*outside);
            }

            tracing::trace!(?inside, ?outside, "Outgoing packet for expired translation");
        }

        // Find the first available public port, starting from the port of the to-be-mapped packet.
        // This will re-assign the same port in most cases, even after the mapping expires.
        let outside = (src.value()..)
            .chain(1..src.value())
            .map(|p| (src.with_value(p), outside_dst))
            .find(|outside| !self.table.contains_right(outside))
            .ok_or(connlib_shared::Error::ExhaustedNat)?;

        let inside = (src, dst);

        self.table.insert(inside, outside);
        self.last_seen.insert(outside, now);

        tracing::debug!(?inside, ?outside, "New NAT session");

        Ok(outside)
    }

    pub(crate) fn translate_incoming(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Result<Option<(Protocol, IpAddr)>, connlib_shared::Error> {
        let outside = (
            packet
                .destination_protocol()
                .map_err(connlib_shared::Error::UnsupportedProtocol)?,
            packet.source(),
        );

        if let Some(inside) = self.table.get_by_right(&outside) {
            tracing::trace!(?inside, ?outside, "Translating incoming packet");

            self.last_seen.insert(*inside, now);
            return Ok(Some(*inside));
        }

        tracing::trace!(?outside, "No active NAT session; skipping translation");

        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ip_packet::{proptest::*, MutableIpPacket};
    use proptest::prelude::*;
    use tracing_subscriber::util::SubscriberInitExt as _;

    #[test_strategy::proptest]
    fn translates_back_and_forth_packet(
        #[strategy(udp_or_tcp_or_icmp_packet())] packet: MutableIpPacket<'static>,
        #[strategy(any::<IpAddr>())] outside_dst: IpAddr,
        #[strategy(0..120u64)] response_delay: u64,
    ) {
        proptest::prop_assume!(packet.destination().is_ipv4() == outside_dst.is_ipv4()); // Required for our test to simulate a response.

        let _set_default = tracing_subscriber::fmt()
            .with_env_filter("trace")
            .set_default();
        let sent_at = Instant::now();
        let mut table = NatTable::default();
        let response_delay = Duration::from_secs(response_delay);

        // Remember original src_p and dst
        let src = packet.as_immutable().source_protocol().unwrap();
        let dst = packet.destination();

        // Translate out
        let (new_source_protocol, new_dst_ip) = table
            .translate_outgoing(packet.as_immutable(), outside_dst, sent_at)
            .unwrap();

        // Pretend we are getting a response.
        let mut response = packet.clone();
        response.set_destination_protocol(new_source_protocol.value());
        response.set_src(new_dst_ip);

        // Update time.
        table.handle_timeout(sent_at + response_delay);

        // Translate in
        let translate_incoming = table
            .translate_incoming(packet.as_immutable(), sent_at + response_delay)
            .unwrap();

        // Assert
        if response_delay >= Duration::from_secs(60) {
            assert!(translate_incoming.is_none());
        } else {
            assert_eq!(translate_incoming, Some((src, dst)));
        }
    }

    #[test_strategy::proptest]
    fn can_handle_multiple_packets(
        #[strategy(udp_or_tcp_or_icmp_packet())] packet1: MutableIpPacket<'static>,
        #[strategy(any::<IpAddr>())] outside_dst1: IpAddr,
        #[strategy(udp_or_tcp_or_icmp_packet())] packet2: MutableIpPacket<'static>,
        #[strategy(any::<IpAddr>())] outside_dst2: IpAddr,
    ) {
        proptest::prop_assume!(packet1.destination().is_ipv4() == outside_dst1.is_ipv4()); // Required for our test to simulate a response.
        proptest::prop_assume!(packet2.destination().is_ipv4() == outside_dst2.is_ipv4()); // Required for our test to simulate a response.
        proptest::prop_assume!(
            packet1.as_immutable().source_protocol().unwrap()
                != packet2.as_immutable().source_protocol().unwrap()
        );

        let _set_default = tracing_subscriber::fmt()
            .with_env_filter("trace")
            .set_default();
        let mut table = NatTable::default();

        let mut packets = [(packet1, outside_dst1), (packet2, outside_dst2)];

        // Remember original src_p and dst
        let original_src_p_and_dst = packets
            .clone()
            .map(|(p, _)| (p.as_immutable().source_protocol().unwrap(), p.destination()));

        // Translate out
        let new_src_p_and_dst = packets.clone().map(|(p, d)| {
            table
                .translate_outgoing(p.as_immutable(), d, Instant::now())
                .unwrap()
        });

        // Pretend we are getting a response.
        for ((p, _), (new_src_p, new_d)) in packets.iter_mut().zip(new_src_p_and_dst) {
            p.set_destination_protocol(new_src_p.value());
            p.set_src(new_d);
        }

        // Translate in
        let responses = packets.map(|(p, _)| {
            table
                .translate_incoming(p.as_immutable(), Instant::now())
                .unwrap()
                .unwrap()
        });

        assert_eq!(responses, original_src_p_and_dst);
    }
}
