//! ICMP echo, as one host ping socket per peer address and echo identifier.
//!
//! The reply carries the peer's own identifier, sequence and payload back, so
//! ping tools see exactly what they sent. Errors quote the request they are for.

use std::{
    collections::{HashMap, VecDeque},
    net::IpAddr,
    time::{Duration, Instant},
};

use ip_packet::{IcmpEchoHeader, Icmpv4Type, Icmpv6Type, IpPacket};

use crate::{Command, FlowId, FlowIds, Outbox};

/// How long a session stays open without a request.
const IDLE: Duration = Duration::from_secs(30);

/// Requests kept per session for matching replies and errors.
const MAX_OUTSTANDING: usize = 32;

#[derive(Default)]
pub(crate) struct Icmp {
    by_key: HashMap<Key, FlowId>,
    flows: HashMap<FlowId, Flow>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct Key {
    peer: IpAddr,
    id: u16,
}

struct Flow {
    key: Key,
    last_seen: Instant,
    /// Requests awaiting a reply, by sequence; the original quoted in errors.
    outstanding: VecDeque<(u16, IpPacket)>,
}

struct EchoRequest {
    id: u16,
    seq: u16,
    payload: Vec<u8>,
    ttl: u8,
}

fn echo_request(packet: &IpPacket) -> Option<EchoRequest> {
    if let Some(icmp) = packet.as_icmpv4() {
        let Icmpv4Type::EchoRequest(IcmpEchoHeader { id, seq }) = icmp.icmp_type() else {
            return None;
        };

        return Some(EchoRequest {
            id,
            seq,
            payload: icmp.payload().to_vec(),
            ttl: packet.ipv4_header()?.ttl(),
        });
    }

    if let Some(icmp) = packet.as_icmpv6() {
        let Icmpv6Type::EchoRequest(IcmpEchoHeader { id, seq }) = icmp.icmp_type() else {
            return None;
        };

        return Some(EchoRequest {
            id,
            seq,
            payload: icmp.payload().to_vec(),
            ttl: packet.ipv6_header()?.hop_limit(),
        });
    }

    None
}

impl Icmp {
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
        let Some(EchoRequest {
            id,
            seq,
            payload,
            ttl,
        }) = echo_request(&packet)
        else {
            tracing::trace!(src = %packet.source(), dst = %packet.destination(), "Dropping ICMP message that is not an echo request");
            return;
        };

        let key = Key {
            peer: packet.source(),
            id,
        };
        let remote = packet.destination();

        let flow = *self.by_key.entry(key).or_insert_with(|| {
            let flow = ids.next();
            tracing::debug!(%flow, peer = %key.peer, %remote, "Peer opened an ICMP echo session");

            flow
        });

        let f = self.flows.entry(flow).or_insert_with(|| Flow {
            key,
            last_seen: now,
            outstanding: VecDeque::new(),
        });
        f.last_seen = now;
        f.outstanding.retain(|(s, _)| *s != seq);
        f.outstanding.push_back((seq, packet));
        while f.outstanding.len() > MAX_OUTSTANDING {
            f.outstanding.pop_front();
        }

        out.commands.push_back(Command::IcmpEcho {
            flow,
            remote,
            sequence: seq,
            payload,
            ttl,
        });
    }

    pub(crate) fn handle_reply(
        &mut self,
        flow: FlowId,
        sequence: u16,
        payload: Vec<u8>,
        out: &mut Outbox,
    ) {
        let Some(f) = self.flows.get_mut(&flow) else {
            return;
        };

        let Some(request) = take_outstanding(f, Some(sequence)) else {
            tracing::trace!(%flow, %sequence, "Echo reply without a request, dropping");
            return;
        };

        match ip_packet::make::icmp_reply_packet(
            request.destination(),
            request.source(),
            sequence,
            f.key.id,
            &payload,
        ) {
            Ok(packet) => out.packets.push_back(packet),
            Err(e) => tracing::debug!(%flow, "Failed to build echo reply for the peer: {e:#}"),
        }
    }

    pub(crate) fn handle_unreachable(
        &mut self,
        flow: FlowId,
        sequence: Option<u16>,
        out: &mut Outbox,
    ) {
        let Some(f) = self.flows.get_mut(&flow) else {
            return;
        };

        let Some(request) = take_outstanding(f, sequence) else {
            return;
        };

        match ip_packet::make::icmp_dest_unreachable_host(&request) {
            Ok(packet) => out.packets.push_back(packet),
            Err(e) => tracing::debug!(%flow, "Failed to build ICMP error for the peer: {e:#}"),
        }
    }

    pub(crate) fn handle_time_exceeded(
        &mut self,
        flow: FlowId,
        sequence: u16,
        from: IpAddr,
        out: &mut Outbox,
    ) {
        let Some(f) = self.flows.get_mut(&flow) else {
            return;
        };

        let Some(request) = take_outstanding(f, Some(sequence)) else {
            return;
        };

        match ip_packet::make::icmp_time_exceeded(&request, from) {
            Ok(packet) => out.packets.push_back(packet),
            Err(e) => tracing::debug!(%flow, "Failed to build ICMP error for the peer: {e:#}"),
        }
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

            tracing::debug!(%flow, "ICMP echo session idle, closing");
            out.commands.push_back(Command::IcmpClose { flow });
        }
    }
}

/// Takes the request with `sequence`, or the latest one without.
fn take_outstanding(flow: &mut Flow, sequence: Option<u16>) -> Option<IpPacket> {
    let index = match sequence {
        Some(seq) => flow.outstanding.iter().position(|(s, _)| *s == seq)?,
        None => flow.outstanding.len().checked_sub(1)?,
    };

    flow.outstanding.remove(index).map(|(_, packet)| packet)
}
