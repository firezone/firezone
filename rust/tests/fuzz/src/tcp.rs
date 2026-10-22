use std::{
    collections::{BTreeMap, VecDeque},
    net::SocketAddr,
    time::Instant,
};

use anyhow::{Context, Result};
use ip_packet::{IpPacket, Layer4Protocol};
use l3_tcp::Socket;

use crate::{os::SimulatedOs, probe::ProbeId};

pub struct Client {
    sockets: l3_tcp::SocketSet<'static>,
    /// Closed connections are kept so late packets for them are still consumed.
    connections: BTreeMap<(SocketAddr, SocketAddr), Connection>,
    responses: VecDeque<Response>,
    device: l3_tcp::InMemoryDevice,
    interface: l3_tcp::Interface,
    os: SimulatedOs,

    created_at: Instant,
}

/// What answers a connect or write probe.
pub enum Response {
    /// A SYN-ACK, reset or ICMP error.
    Packet { probe: ProbeId, packet: IpPacket },
    /// All of a write was echoed back.
    Echoed { probe: ProbeId },
}

struct Connection {
    /// `None` for a connection that was dropped.
    socket: Option<l3_tcp::SocketHandle>,
    /// The probe of the latest connect or write, until it is answered.
    probe: Option<Probe>,
}

struct Probe {
    id: ProbeId,
    submitted: bool,
    kind: ProbeKind,
}

enum ProbeKind {
    Connect,
    Write { unechoed: usize },
}

pub struct Server {
    sockets: l3_tcp::SocketSet<'static>,
    listen_ports: BTreeMap<l3_tcp::SocketHandle, u16>,
    device: l3_tcp::InMemoryDevice,
    interface: l3_tcp::Interface,

    created_at: Instant,
}

impl Client {
    pub fn new(now: Instant, os: SimulatedOs) -> Self {
        let mut device = l3_tcp::InMemoryDevice::default();
        let interface = l3_tcp::create_interface(&mut device);

        Self {
            sockets: l3_tcp::SocketSet::new(Vec::default()),
            connections: Default::default(),
            responses: Default::default(),
            device,
            interface,
            os,
            created_at: now,
        }
    }

    /// Connects `local` to `remote`; the SYN submits probe `id`.
    pub fn connect(&mut self, local: SocketAddr, remote: SocketAddr, id: ProbeId) -> Result<()> {
        // Sockets are keyed by the full `(local, remote)` 4-tuple, so the client
        // can hold several connections to one remote from different local ports.
        // Re-connecting an already-open 4-tuple is a no-op.
        if let Some(Connection {
            socket: Some(_), ..
        }) = self.connections.get(&(local, remote))
        {
            return Ok(());
        }

        let mut socket = l3_tcp::create_tcp_socket();
        socket
            .connect(self.interface.context(), remote, local)
            .context("Failed to create TCP connection")?;

        // `smoltcp`'s abort timer counts from the last packet received from the
        // remote, whether or not anything is outstanding. Without keep-alives, an
        // idle connection must therefore only arm it while it waits for an ACK.
        socket.set_timeout(Some(self.os.tcp_timeout()));

        let handle = self.sockets.add(socket);

        self.connections.insert(
            (local, remote),
            Connection {
                socket: Some(handle),
                probe: Some(Probe::new(id, ProbeKind::Connect)),
            },
        );

        Ok(())
    }

    /// Writes `data` to the established connection between `local` and `remote`.
    ///
    /// The first segment carrying `data` submits probe `id`, which is answered once all of
    /// `data` was echoed back.
    pub fn send(
        &mut self,
        local: SocketAddr,
        remote: SocketAddr,
        id: ProbeId,
        data: &[u8],
    ) -> Result<()> {
        let connection = self
            .connections
            .get_mut(&(local, remote))
            .context("No TCP connection")?;
        let handle = connection.socket.context("TCP connection was dropped")?;
        let socket = self.sockets.get_mut::<Socket>(handle);
        socket.set_timeout(Some(self.os.tcp_timeout()));

        let sent = socket
            .send_slice(data)
            .context("Failed to write TCP data")?;
        anyhow::ensure!(
            sent == data.len(),
            "Wrote only {sent} of {} bytes",
            data.len()
        );

        let write = ProbeKind::Write {
            unechoed: data.len(),
        };
        connection.probe = Some(Probe::new(id, write));

        Ok(())
    }

    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some(tcp) = packet.as_tcp() else {
            return false;
        };

        let local = SocketAddr::new(packet.destination(), tcp.destination_port());
        let remote = SocketAddr::new(packet.source(), tcp.source_port());

        self.connections.contains_key(&(local, remote))
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        // TODO: Upstream ICMP error handling to `smoltcp`.
        if let Ok(Some((failed_packet, _))) = packet.icmp_error()
            && let Layer4Protocol::Tcp { src, dst } = failed_packet.layer4_protocol()
            && let local = SocketAddr::new(failed_packet.src(), src)
            && let remote = SocketAddr::new(failed_packet.dst(), dst)
            && let Some(connection) = self.connections.get_mut(&(local, remote))
            && let Some(handle) = connection.socket
        {
            tracing::debug!(%local, %remote, "Received ICMP error");

            if let Some(probe) = connection.probe.take().filter(|probe| probe.submitted) {
                self.responses.push_back(Response::Packet {
                    probe: probe.id,
                    packet,
                });
            }
            self.forget(local, remote, handle);

            return;
        }

        if let Some(tcp) = packet.as_tcp()
            && let local = SocketAddr::new(packet.destination(), tcp.destination_port())
            && let remote = SocketAddr::new(packet.source(), tcp.source_port())
            && let Some(connection) = self.connections.get_mut(&(local, remote))
        {
            // A packet for a connection that was dropped has no socket to
            // receive it. Feeding it to the TCP stack would answer it with an RST.
            if connection.socket.is_none() {
                tracing::debug!(%local, %remote, "Ignoring packet for closed connection");

                return;
            }

            self.responses.extend(connection.answered_by(&packet));
        }

        self.device.receive(packet);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let now = l3_tcp::now(self.created_at, now);

        let _result = self
            .interface
            .poll(now, &mut self.device, &mut self.sockets);

        for connection in self.connections.values_mut() {
            let Some(handle) = connection.socket else {
                continue;
            };
            let socket = self.sockets.get_mut::<Socket>(handle);

            if socket.state() == l3_tcp::State::Established && socket.send_queue() == 0 {
                socket.set_timeout(None);
            }

            while let Ok(len) = socket.recv(|buf| (buf.len(), buf.len())) {
                if len == 0 {
                    break;
                }
                self.responses.extend(connection.receive_echo(len));
            }
        }
    }

    /// Returns the next packet to send and the probe it submits, if any.
    ///
    /// That is the SYN of a connect probe or the first segment carrying a write probe's data.
    pub fn poll_outbound(&mut self) -> Option<(IpPacket, Option<ProbeId>)> {
        let packet = self.device.next_send()?;
        let probe = self.submitted_probe(&packet);

        Some((packet, probe))
    }

    pub fn poll_response(&mut self) -> Option<Response> {
        self.responses.pop_front()
    }

    /// Silently drops every connection that is not established, still waits for an ACK or
    /// still waits for an echo.
    ///
    /// Like an application giving up on a connect or write that did not complete in time,
    /// this keeps a failed connection from retransmitting into later transitions.
    pub fn drop_unfinished(&mut self) {
        let dropped = self
            .connections
            .iter()
            .filter_map(|(&(local, remote), connection)| {
                let handle = connection.socket?;
                let socket = self.sockets.get::<Socket>(handle);
                let finished = connection.probe.is_none()
                    && socket.state() == l3_tcp::State::Established
                    && socket.send_queue() == 0;

                (!finished).then_some((local, remote, handle))
            })
            .collect::<Vec<_>>();

        for (local, remote, handle) in dropped {
            self.forget(local, remote, handle);
        }
    }

    /// Forgets all unanswered probes, so that late packets cannot answer them.
    pub fn forget_probes(&mut self) {
        for connection in self.connections.values_mut() {
            connection.probe = None;
        }
        self.responses.clear();
    }

    fn submitted_probe(&mut self, packet: &IpPacket) -> Option<ProbeId> {
        let tcp = packet.as_tcp()?;
        let local = SocketAddr::new(packet.source(), tcp.source_port());
        let remote = SocketAddr::new(packet.destination(), tcp.destination_port());
        let probe = self
            .connections
            .get_mut(&(local, remote))?
            .probe
            .as_mut()
            .filter(|probe| !probe.submitted)?;

        let submits = match probe.kind {
            ProbeKind::Connect => tcp.syn(),
            ProbeKind::Write { .. } => !tcp.payload().is_empty(),
        };
        if !submits {
            return None;
        }
        probe.submitted = true;

        Some(probe.id)
    }

    /// Drops a connection without telling the remote, but keeps consuming its late packets.
    fn forget(&mut self, local: SocketAddr, remote: SocketAddr, handle: l3_tcp::SocketHandle) {
        self.sockets.remove(handle);
        self.connections.insert(
            (local, remote),
            Connection {
                socket: None,
                probe: None,
            },
        );
    }
}

impl Connection {
    /// Returns the response if `packet` accepts or resets the submitted probe.
    fn answered_by(&mut self, packet: &IpPacket) -> Option<Response> {
        let tcp = packet.as_tcp()?;
        let probe = self.probe.as_ref().filter(|probe| probe.submitted)?;

        let answered = match probe.kind {
            ProbeKind::Connect => tcp.rst() || (tcp.syn() && tcp.ack()),
            ProbeKind::Write { .. } => tcp.rst(),
        };
        if !answered {
            return None;
        }
        let probe = self.probe.take()?;

        Some(Response::Packet {
            probe: probe.id,
            packet: packet.clone(),
        })
    }

    /// Returns the response once `len` more bytes complete the echo of the submitted write probe.
    fn receive_echo(&mut self, len: usize) -> Option<Response> {
        let probe = self.probe.as_mut().filter(|probe| probe.submitted)?;
        let ProbeKind::Write { unechoed } = &mut probe.kind else {
            return None;
        };

        *unechoed = unechoed.saturating_sub(len);
        if *unechoed > 0 {
            return None;
        }
        let probe = self.probe.take()?;

        Some(Response::Echoed { probe: probe.id })
    }
}

impl Probe {
    fn new(id: ProbeId, kind: ProbeKind) -> Self {
        Self {
            id,
            submitted: false,
            kind,
        }
    }
}

impl Server {
    pub fn new(now: Instant) -> Self {
        let mut device = l3_tcp::InMemoryDevice::default();
        let interface = l3_tcp::create_interface(&mut device);

        Self {
            sockets: l3_tcp::SocketSet::new(Vec::default()),
            listen_ports: Default::default(),
            device,
            interface,
            created_at: now,
        }
    }

    /// Listens on `port` of every address.
    pub fn listen(&mut self, port: u16) -> Result<()> {
        let mut socket = l3_tcp::create_tcp_socket();
        socket
            .listen(port)
            .with_context(|| format!("Failed to listen on port {port}"))?;

        let handle = self.sockets.add(socket);
        self.listen_ports.insert(handle, port);

        Ok(())
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        self.device.receive(packet);
    }

    /// Returns whether a connection between `local` and `remote` is established.
    pub fn is_established(&self, local: SocketAddr, remote: SocketAddr) -> bool {
        self.sockets.iter().any(|(_, socket)| {
            let l3_tcp::AnySocket::Tcp(socket) = socket;

            socket.state() == l3_tcp::State::Established
                && socket.local_endpoint() == Some(local.into())
                && socket.remote_endpoint() == Some(remote.into())
        })
    }

    /// Echoes everything a connection receives back to its remote.
    pub fn handle_timeout(&mut self, now: Instant) {
        let now = l3_tcp::now(self.created_at, now);

        let _result = self
            .interface
            .poll(now, &mut self.device, &mut self.sockets);

        for (_, socket) in self.sockets.iter_mut() {
            let l3_tcp::AnySocket::Tcp(socket) = socket;

            while let Ok(data) = socket.recv(|buf| (buf.len(), buf.to_vec())) {
                if data.is_empty() {
                    break;
                }
                if socket.send_slice(&data) != Ok(data.len()) {
                    tracing::error!("Failed to echo TCP data");
                }
            }
        }

        let _result = self
            .interface
            .poll(now, &mut self.device, &mut self.sockets);

        // Every port in `listen_ports` always has one socket in `Listen`:
        // a listener that accepted a connection is replaced by a fresh one.
        let accepted = self
            .listen_ports
            .iter()
            .filter(|(handle, _)| {
                self.sockets.get::<l3_tcp::Socket>(**handle).state() != l3_tcp::State::Listen
            })
            .map(|(handle, port)| (*handle, *port))
            .collect::<Vec<_>>();

        for (handle, port) in accepted {
            self.listen_ports.remove(&handle);
            self.listen(port)
                .expect("re-listening on a previously bound port to succeed");
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }

    /// Silently drops every connection that still waits for an ACK.
    pub fn drop_unfinished(&mut self) {
        let dropped = self
            .sockets
            .iter()
            .filter(|(_, socket)| {
                let l3_tcp::AnySocket::Tcp(socket) = socket;

                socket.send_queue() > 0
            })
            .map(|(handle, _)| handle)
            .collect::<Vec<_>>();

        for handle in dropped {
            self.sockets.remove(handle);
        }
    }
}
