//! A userspace forwarder for the resources a device serves.
//!
//! The kernel forwards a served packet by routing it on, which needs IP forwarding and NAT
//! that only Linux lets the daemon set up. This forwarder terminates each flow instead:
//! TCP in smoltcp, UDP and ICMP echo as per-flow host sockets, which every platform allows.
//!
//! It is sans-IO. Packets from peers go in through [`Forwarder::handle_packet`]; work for
//! the host sockets comes out as [`Command`]s and packets for the peers through
//! [`Forwarder::poll_packet`]; what the sockets report comes back as [`Event`]s.
//! A [`FlowId`] names one TCP connection, one UDP peer-to-resource pair or one ICMP echo
//! session (a peer address and echo identifier), from the first packet until the
//! `*Close` command for it.
//!
//! TCP data toward the host is paced by credit: the forwarder only reads from a smoltcp
//! socket while the driver may still accept bytes ([`Event::TcpSent`] restores the credit),
//! and the driver only reads from the host while the forwarder has granted room in the
//! socket's send buffer ([`Command::TcpRecvCredit`]). Both directions stay bounded without
//! either side blocking the other.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod icmp;
mod tcp;
#[cfg(test)]
mod tests;
mod udp;

use std::{
    collections::VecDeque,
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

use ip_packet::IpPacket;

/// One flow through the forwarder; see the crate docs for what a flow is per protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FlowId(u64);

impl std::fmt::Display for FlowId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "flow#{}", self.0)
    }
}

/// Work for the host sockets.
#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    /// A peer opened a TCP connection to `remote`; connect to it.
    TcpConnect { flow: FlowId, remote: SocketAddr },
    /// Bytes from the peer to write to the host connection.
    TcpSend { flow: FlowId, data: Vec<u8> },
    /// The driver may read this many more bytes from the host connection.
    TcpRecvCredit { flow: FlowId, bytes: usize },
    /// The peer closed its write side; shut down the host connection's write side.
    TcpShutdownWrite { flow: FlowId },
    /// The connection is over; drop the host connection.
    TcpClose { flow: FlowId },
    /// A datagram from the peer for `remote`; the first one for a flow opens the socket.
    UdpSend {
        flow: FlowId,
        remote: SocketAddr,
        data: Vec<u8>,
    },
    /// The flow went idle; drop the socket.
    UdpClose { flow: FlowId },
    /// An echo request from the peer for `remote`; the first one for a flow opens the socket.
    ///
    /// The driver picks the identifier it sends with; only `sequence` and `payload` come back.
    IcmpEcho {
        flow: FlowId,
        remote: IpAddr,
        sequence: u16,
        payload: Vec<u8>,
        ttl: u8,
    },
    /// The echo session went idle; drop the socket.
    IcmpClose { flow: FlowId },
}

/// What the host sockets report.
#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    TcpConnected {
        flow: FlowId,
    },
    /// The connect failed; `refused` distinguishes a reset from a timeout or routing error.
    TcpConnectFailed {
        flow: FlowId,
        refused: bool,
    },
    /// Bytes read from the host connection, within the granted credit.
    TcpData {
        flow: FlowId,
        data: Vec<u8>,
    },
    /// Bytes from [`Command::TcpSend`] were written; restores send credit.
    TcpSent {
        flow: FlowId,
        bytes: usize,
    },
    /// The host closed its write side.
    TcpEof {
        flow: FlowId,
    },
    /// The host connection failed; the peer gets a reset.
    TcpError {
        flow: FlowId,
    },
    UdpData {
        flow: FlowId,
        data: Vec<u8>,
    },
    /// The socket reported the destination unreachable.
    UdpUnreachable {
        flow: FlowId,
    },
    IcmpReply {
        flow: FlowId,
        sequence: u16,
        payload: Vec<u8>,
    },
    /// The destination is unreachable; without a sequence the latest request is meant.
    IcmpUnreachable {
        flow: FlowId,
        sequence: Option<u16>,
    },
    /// A router at `from` reported the request's TTL exceeded.
    IcmpTimeExceeded {
        flow: FlowId,
        sequence: u16,
        from: IpAddr,
    },
}

/// How often idle UDP and ICMP flows are swept.
const SWEEP_INTERVAL: Duration = Duration::from_secs(1);

pub struct Forwarder {
    tcp: tcp::Tcp,
    udp: udp::Udp,
    icmp: icmp::Icmp,

    ids: FlowIds,
    out: Outbox,

    last_sweep: Instant,
}

/// Mints flow ids.
#[derive(Default)]
pub(crate) struct FlowIds(u64);

impl FlowIds {
    pub(crate) fn next(&mut self) -> FlowId {
        self.0 += 1;

        FlowId(self.0)
    }
}

/// What the protocol halves produce.
#[derive(Default)]
pub(crate) struct Outbox {
    pub(crate) commands: VecDeque<Command>,
    pub(crate) packets: VecDeque<IpPacket>,
}

impl Forwarder {
    pub fn new(now: Instant) -> Self {
        Self {
            tcp: tcp::Tcp::new(now),
            udp: udp::Udp::default(),
            icmp: icmp::Icmp::default(),
            ids: FlowIds::default(),
            out: Outbox::default(),
            last_sweep: now,
        }
    }

    /// A packet from a peer for a resource this device serves.
    ///
    /// Anything but TCP, UDP and ICMP echo requests is dropped: there is no host socket
    /// that could carry it.
    pub fn handle_packet(&mut self, packet: IpPacket, now: Instant) {
        if packet.as_tcp().is_some() {
            self.tcp
                .handle_packet(packet, now, &mut self.ids, &mut self.out);
        } else if packet.as_udp().is_some() {
            self.udp
                .handle_packet(packet, now, &mut self.ids, &mut self.out);
        } else if packet.is_icmp() || packet.is_icmpv6() {
            self.icmp
                .handle_packet(packet, now, &mut self.ids, &mut self.out);
        } else {
            tracing::trace!(
                src = %packet.source(),
                dst = %packet.destination(),
                "Dropping packet of a protocol the userspace forwarder cannot carry"
            );
        }
    }

    pub fn handle_event(&mut self, event: Event, now: Instant) {
        match event {
            Event::TcpConnected { .. }
            | Event::TcpConnectFailed { .. }
            | Event::TcpData { .. }
            | Event::TcpSent { .. }
            | Event::TcpEof { .. }
            | Event::TcpError { .. } => self.tcp.handle_event(event, now, &mut self.out),
            Event::UdpData { flow, data } => self.udp.handle_data(flow, data, now, &mut self.out),
            Event::UdpUnreachable { flow } => self.udp.handle_unreachable(flow, &mut self.out),
            Event::IcmpReply {
                flow,
                sequence,
                payload,
            } => self
                .icmp
                .handle_reply(flow, sequence, payload, &mut self.out),
            Event::IcmpUnreachable { flow, sequence } => {
                self.icmp.handle_unreachable(flow, sequence, &mut self.out)
            }
            Event::IcmpTimeExceeded {
                flow,
                sequence,
                from,
            } => self
                .icmp
                .handle_time_exceeded(flow, sequence, from, &mut self.out),
        }
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.tcp.handle_timeout(now, &mut self.ids, &mut self.out);

        if now.duration_since(self.last_sweep) >= SWEEP_INTERVAL {
            self.last_sweep = now;
            self.udp.expire(now, &mut self.out);
            self.icmp.expire(now, &mut self.out);
        }
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        let sweep = (self.udp.has_flows() || self.icmp.has_flows())
            .then_some(self.last_sweep + SWEEP_INTERVAL);

        [self.tcp.poll_timeout(), sweep].into_iter().flatten().min()
    }

    pub fn poll_command(&mut self) -> Option<Command> {
        self.out.commands.pop_front()
    }

    /// A packet for a peer, as if it had been read from the TUN device.
    pub fn poll_packet(&mut self) -> Option<IpPacket> {
        self.out.packets.pop_front()
    }

    /// How many flows of each kind are open: TCP, UDP, ICMP.
    pub fn num_flows(&self) -> (usize, usize, usize) {
        (
            self.tcp.num_flows(),
            self.udp.num_flows(),
            self.icmp.num_flows(),
        )
    }
}
