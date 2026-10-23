//! TCP, terminated in smoltcp.
//!
//! Every connection a peer opens is accepted by a smoltcp socket listening on the
//! destination port, with the interface accepting any destination address. The
//! socket's local endpoint is then the resource the peer asked for, and the driver
//! opens a host connection to it.

use std::{
    collections::HashMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

use ip_packet::IpPacket;
use l3_tcp::{
    InMemoryDevice, Interface, IpAddress, IpEndpoint, Socket, SocketHandle, SocketSet, State,
    create_interface, create_tcp_socket,
};

use crate::{Command, Event, FlowId, FlowIds, Outbox};

/// Bytes the driver may have in flight toward the host before we stop reading from a socket.
const INITIAL_SEND_CREDIT: usize = 64 * 1024;

/// Room in a socket's send buffer worth telling the driver about.
///
/// Smaller grants would have the driver read in tiny pieces.
const CREDIT_GRANT_THRESHOLD: usize = 8 * 1024;

pub(crate) struct Tcp {
    device: InMemoryDevice,
    interface: Interface,
    sockets: SocketSet<'static>,

    /// A socket in the listen state per destination port a peer has connected to.
    listeners: HashMap<u16, SocketHandle>,
    flows: HashMap<FlowId, Flow>,

    created_at: Instant,
    last_now: Instant,
}

struct Flow {
    handle: SocketHandle,
    host: Host,
    /// Bytes we may still hand the driver for the host connection.
    send_credit: usize,
    /// Bytes the driver may still read from the host for us.
    recv_outstanding: usize,
    shutdown_sent: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Host {
    Connecting,
    Connected,
    Closed,
}

impl Tcp {
    pub(crate) fn new(now: Instant) -> Self {
        let mut device = InMemoryDevice::default();
        let interface = create_interface(&mut device);

        Self {
            device,
            interface,
            sockets: SocketSet::new(Vec::new()),
            listeners: HashMap::new(),
            flows: HashMap::new(),
            created_at: now,
            last_now: now,
        }
    }

    pub(crate) fn num_flows(&self) -> usize {
        self.flows.len()
    }

    pub(crate) fn handle_packet(
        &mut self,
        packet: IpPacket,
        now: Instant,
        ids: &mut FlowIds,
        out: &mut Outbox,
    ) {
        let Some(tcp) = packet.as_tcp() else {
            return;
        };

        if tcp.syn() && !tcp.ack() {
            self.ensure_listener(tcp.destination_port());
        }

        self.device.receive(packet);
        self.poll(now, ids, out);
    }

    pub(crate) fn handle_event(&mut self, event: Event, now: Instant, out: &mut Outbox) {
        match event {
            Event::TcpConnected { flow } => {
                if let Some(f) = self.flows.get_mut(&flow) {
                    f.host = Host::Connected;
                }
            }
            Event::TcpConnectFailed { flow, refused } => {
                if let Some(f) = self.flows.get_mut(&flow) {
                    tracing::debug!(%flow, %refused, "Host connection failed, resetting the peer");

                    f.host = Host::Closed;
                    self.sockets.get_mut::<Socket>(f.handle).abort();
                }
            }
            Event::TcpError { flow } => {
                if let Some(f) = self.flows.get_mut(&flow) {
                    f.host = Host::Closed;
                    self.sockets.get_mut::<Socket>(f.handle).abort();
                }
            }
            Event::TcpData { flow, data } => {
                if let Some(f) = self.flows.get_mut(&flow) {
                    f.recv_outstanding = f.recv_outstanding.saturating_sub(data.len());

                    let socket = self.sockets.get_mut::<Socket>(f.handle);
                    match socket.send_slice(&data) {
                        Ok(n) if n == data.len() => {}
                        Ok(n) => {
                            tracing::warn!(%flow, sent = n, len = data.len(), "Host data exceeded the granted credit, dropping the rest");
                        }
                        Err(e) => {
                            tracing::debug!(%flow, "Cannot send host data to the peer: {e}");
                        }
                    }
                }
            }
            Event::TcpSent { flow, bytes } => {
                if let Some(f) = self.flows.get_mut(&flow) {
                    f.send_credit += bytes;
                }
            }
            Event::TcpEof { flow } => {
                if let Some(f) = self.flows.get_mut(&flow) {
                    // Sends the FIN once everything queued before it has gone out.
                    self.sockets.get_mut::<Socket>(f.handle).close();
                }
            }
            Event::UdpData { .. }
            | Event::UdpUnreachable { .. }
            | Event::IcmpReply { .. }
            | Event::IcmpUnreachable { .. }
            | Event::IcmpTimeExceeded { .. } => {
                debug_assert!(false, "not a TCP event");
            }
        }

        let mut ids = FlowIds::default();
        self.poll(now, &mut ids, out);
        debug_assert_eq!(ids.0, 0, "events never open flows");
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant, ids: &mut FlowIds, out: &mut Outbox) {
        self.poll(now, ids, out);
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        let at = self
            .interface
            .poll_at(l3_tcp::now(self.created_at, self.last_now), &self.sockets)?;

        Some(self.created_at + Duration::from_millis(at.total_millis().max(0) as u64))
    }

    fn ensure_listener(&mut self, port: u16) {
        if let Some(handle) = self.listeners.get(&port)
            && self.sockets.get::<Socket>(*handle).state() == State::Listen
        {
            return;
        }

        let mut socket = create_tcp_socket();
        if let Err(e) = socket.listen(port) {
            tracing::warn!(%port, "Failed to listen for a peer's connection: {e}");
            return;
        }

        let handle = self.sockets.add(socket);
        self.listeners.insert(port, handle);
    }

    fn poll(&mut self, now: Instant, ids: &mut FlowIds, out: &mut Outbox) {
        self.last_now = now;
        let timestamp = l3_tcp::now(self.created_at, now);

        self.interface
            .poll(timestamp, &mut self.device, &mut self.sockets);
        self.adopt_connections(ids, out);
        self.pump(out);
        self.interface
            .poll(timestamp, &mut self.device, &mut self.sockets);
        self.reap(out);

        while let Some(packet) = self.device.next_send() {
            out.packets.push_back(packet);
        }
    }

    /// Turns listeners that accepted a connection into flows.
    fn adopt_connections(&mut self, ids: &mut FlowIds, out: &mut Outbox) {
        let accepted = self
            .listeners
            .iter()
            .filter(|(_, handle)| self.sockets.get::<Socket>(**handle).state() != State::Listen)
            .map(|(port, handle)| (*port, *handle))
            .collect::<Vec<_>>();

        for (port, handle) in accepted {
            self.listeners.remove(&port);

            let socket = self.sockets.get::<Socket>(handle);
            let Some(remote) = socket.local_endpoint().map(to_socket_addr) else {
                // Reset before it was established.
                self.sockets.remove(handle);
                continue;
            };

            let flow = ids.next();
            tracing::debug!(%flow, %remote, "Peer opened a TCP connection");

            self.flows.insert(
                flow,
                Flow {
                    handle,
                    host: Host::Connecting,
                    send_credit: INITIAL_SEND_CREDIT,
                    recv_outstanding: 0,
                    shutdown_sent: false,
                },
            );
            out.commands.push_back(Command::TcpConnect { flow, remote });
        }
    }

    /// Moves bytes between the sockets and the driver within the credit.
    fn pump(&mut self, out: &mut Outbox) {
        for (flow, f) in self.flows.iter_mut() {
            if f.host != Host::Connected {
                continue;
            }

            let socket = self.sockets.get_mut::<Socket>(f.handle);

            while socket.can_recv() && f.send_credit > 0 {
                let credit = f.send_credit;
                let data = socket
                    .recv(|buf| {
                        let n = buf.len().min(credit);
                        (n, buf[..n].to_vec())
                    })
                    .unwrap_or_default();

                if data.is_empty() {
                    break;
                }

                f.send_credit -= data.len();
                out.commands
                    .push_back(Command::TcpSend { flow: *flow, data });
            }

            if !socket.may_recv() && !f.shutdown_sent {
                f.shutdown_sent = true;
                out.commands
                    .push_back(Command::TcpShutdownWrite { flow: *flow });
            }

            if socket.may_send() {
                let free = socket.send_capacity().saturating_sub(socket.send_queue());
                let grant = free.saturating_sub(f.recv_outstanding);

                if grant >= CREDIT_GRANT_THRESHOLD || (grant > 0 && f.recv_outstanding == 0) {
                    f.recv_outstanding += grant;
                    out.commands.push_back(Command::TcpRecvCredit {
                        flow: *flow,
                        bytes: grant,
                    });
                }
            }
        }
    }

    /// Drops flows whose socket reached the closed state.
    fn reap(&mut self, out: &mut Outbox) {
        let closed = self
            .flows
            .iter()
            .filter(|(_, f)| self.sockets.get::<Socket>(f.handle).state() == State::Closed)
            .map(|(flow, _)| *flow)
            .collect::<Vec<_>>();

        for flow in closed {
            let Some(f) = self.flows.remove(&flow) else {
                continue;
            };

            tracing::debug!(%flow, "TCP connection closed");

            self.sockets.remove(f.handle);
            if f.host != Host::Closed {
                out.commands.push_back(Command::TcpClose { flow });
            }
        }
    }
}

fn to_socket_addr(endpoint: IpEndpoint) -> SocketAddr {
    match endpoint.addr {
        IpAddress::Ipv4(ip) => SocketAddr::new(ip.into(), endpoint.port),
        IpAddress::Ipv6(ip) => SocketAddr::new(ip.into(), endpoint.port),
    }
}
