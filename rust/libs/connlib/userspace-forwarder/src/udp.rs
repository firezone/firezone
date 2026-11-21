//! UDP, as one host socket per peer-and-resource pair.

use std::{
    collections::HashMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

use ip_packet::IpPacket;

use crate::{Command, FlowId, FlowIds, Outbox};

/// How long a pair stays open without a datagram in either direction.
const IDLE: Duration = Duration::from_secs(60);

#[derive(Default)]
pub(crate) struct Udp {
    by_key: HashMap<Key, FlowId>,
    flows: HashMap<FlowId, Flow>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct Key {
    peer: SocketAddr,
    remote: SocketAddr,
}

struct Flow {
    key: Key,
    last_seen: Instant,
    /// The latest datagram from the peer, quoted in an unreachable error.
    last_packet: IpPacket,
}

impl Udp {
    pub(crate) fn num_flows(&self) -> usize {
        self.flows.len()
    }

    pub(crate) fn has_flows(&self) -> bool {
        !self.flows.is_empty()
    }

    pub(crate) fn handle_packet(
        &mut self,
        packet: IpPacket,
        now: Instant,
        ids: &mut FlowIds,
        out: &mut Outbox,
    ) {
        let Some(udp) = packet.as_udp() else {
            return;
        };

        let key = Key {
            peer: SocketAddr::new(packet.source(), udp.source_port()),
            remote: SocketAddr::new(packet.destination(), udp.destination_port()),
        };
        let data = udp.payload().to_vec();

        let flow = *self.by_key.entry(key).or_insert_with(|| {
            let flow = ids.next();
            tracing::debug!(%flow, peer = %key.peer, remote = %key.remote, "Peer opened a UDP flow");

            flow
        });

        self.flows.insert(
            flow,
            Flow {
                key,
                last_seen: now,
                last_packet: packet,
            },
        );

        out.commands.push_back(Command::UdpSend {
            flow,
            remote: key.remote,
            data,
        });
    }

    pub(crate) fn handle_data(
        &mut self,
        flow: FlowId,
        data: Vec<u8>,
        now: Instant,
        out: &mut Outbox,
    ) {
        let Some(f) = self.flows.get_mut(&flow) else {
            return;
        };
        f.last_seen = now;

        let Key { peer, remote } = f.key;

        match ip_packet::make::udp_packet(remote.ip(), peer.ip(), remote.port(), peer.port(), &data)
        {
            Ok(packet) => out.packets.push_back(packet),
            Err(e) => tracing::debug!(%flow, "Failed to build UDP packet for the peer: {e:#}"),
        }
    }

    pub(crate) fn handle_unreachable(&mut self, flow: FlowId, out: &mut Outbox) {
        let Some(f) = self.flows.remove(&flow) else {
            return;
        };
        self.by_key.remove(&f.key);

        match ip_packet::make::icmp_dest_unreachable_port(&f.last_packet) {
            Ok(packet) => out.packets.push_back(packet),
            Err(e) => tracing::debug!(%flow, "Failed to build ICMP error for the peer: {e:#}"),
        }

        out.commands.push_back(Command::UdpClose { flow });
    }

    pub(crate) fn expire(&mut self, now: Instant, out: &mut Outbox) {
        let idle = self
            .flows
            .iter()
            .filter(|(_, f)| now.duration_since(f.last_seen) >= IDLE)
            .map(|(flow, _)| *flow)
            .collect::<Vec<_>>();

        for flow in idle {
            if let Some(f) = self.flows.remove(&flow) {
                self.by_key.remove(&f.key);
            }

            tracing::debug!(%flow, "UDP flow idle, closing");
            out.commands.push_back(Command::UdpClose { flow });
        }
    }
}
