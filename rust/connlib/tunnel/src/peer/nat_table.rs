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

impl NatTable {
    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        let mut removed = Vec::new();
        for (outside, e) in self.last_seen.iter() {
            if now.duration_since(*e) >= Duration::from_secs(60) {
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
