//! a stateful symmetric NAT table that performs conversion between a client's picked proxy ip and the actual resource's IP
use bimap::BiMap;
use ip_packet::{IpPacket, Protocol};
use itertools::Itertools;
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

impl NatTable {
    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        let mut removed = Vec::new();
        for (r, e) in self.last_seen.iter() {
            if now.duration_since(*e) >= Duration::from_secs(60) {
                let inside = self.table.remove_by_right(r);
                tracing::trace!(?inside, outside = ?r, "NAT session expired");
                removed.push(*r);
            }
        }

        for r in removed {
            self.last_seen.remove(&r);
        }
    }

    pub(crate) fn translate_outgoing(
        &mut self,
        outgoing_pkt: &IpPacket,
        real_address: IpAddr,
        now: Instant,
    ) -> Option<(Protocol, IpAddr)> {
        let source_protocol = outgoing_pkt.source_protocol()?;
        let inside = (source_protocol, outgoing_pkt.destination());
        if let Some(outside) = self.table.get_by_left(&inside) {
            if outside.1 == real_address {
                tracing::trace!(?inside, ?outside, "Translating packet");

                self.last_seen.insert(*outside, now);
                return Some(*outside);
            }

            tracing::trace!(?inside, ?outside, "Outgoing packet for expired translation");
        }

        let mut occupied_ports = self
            .table
            .iter()
            .filter(|(_, (proto, ip))| *ip == real_address && proto.same_type(&source_protocol))
            .map(|(_, (proto, _))| proto.value())
            .sorted_unstable();

        for p in 1.. {
            if !occupied_ports.contains(&p) {
                let proxy_protocol = source_protocol.with_value(p);

                let inside = (source_protocol, outgoing_pkt.destination());
                let outside = (proxy_protocol, real_address);

                self.table.insert(inside, outside);
                self.last_seen.insert(outside, now);

                tracing::trace!(?inside, ?outside, "New NAT session");

                return Some((proxy_protocol, real_address));
            }
        }

        tracing::warn!("available nat ports exhausted");
        None
    }

    pub(crate) fn translate_incoming(
        &mut self,
        incoming_packet: &IpPacket,
        now: Instant,
    ) -> Option<(Protocol, IpAddr)> {
        let outside = (
            incoming_packet.destination_protocol()?,
            incoming_packet.source(),
        );

        if let Some(inside) = self.table.get_by_right(&outside) {
            tracing::trace!(?inside, ?outside, "Reverting translation");

            self.last_seen.insert(*inside, now);
            return Some(*inside);
        }

        None
    }
}
