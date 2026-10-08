use std::{collections::BTreeMap, mem, net::SocketAddr, time::Instant};

use anyhow::{Context, Result};
use ip_packet::{IpPacket, Layer4Protocol};
use l3_tcp::Socket;

use crate::os::SimulatedOs;

pub struct Client {
    sockets: l3_tcp::SocketSet<'static>,
    /// The socket for each connection, or `None` for one that was dropped.
    ///
    /// Closed connections are kept so late packets for them are still consumed.
    sockets_by_conn: BTreeMap<(SocketAddr, SocketAddr), Option<l3_tcp::SocketHandle>>,
    device: l3_tcp::InMemoryDevice,
    interface: l3_tcp::Interface,
    os: SimulatedOs,

    created_at: Instant,
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
            sockets_by_conn: Default::default(),
            device,
            interface,
            os,
            created_at: now,
        }
    }

    pub fn connect(&mut self, local: SocketAddr, remote: SocketAddr) -> Result<()> {
        // Sockets are keyed by the full `(local, remote)` 4-tuple, so the client
        // can hold several connections to one remote from different local ports.
        // Re-connecting an already-open 4-tuple is a no-op.
        if let Some(Some(_)) = self.sockets_by_conn.get(&(local, remote)) {
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

        self.sockets_by_conn.insert((local, remote), Some(handle));

        Ok(())
    }

    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some(tcp) = packet.as_tcp() else {
            return false;
        };

        let local = SocketAddr::new(packet.destination(), tcp.destination_port());
        let remote = SocketAddr::new(packet.source(), tcp.source_port());

        self.sockets_by_conn.contains_key(&(local, remote))
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        // TODO: Upstream ICMP error handling to `smoltcp`.
        if let Ok(Some((failed_packet, _))) = packet.icmp_error()
            && let Layer4Protocol::Tcp { src, dst } = failed_packet.layer4_protocol()
            && let local = SocketAddr::new(failed_packet.src(), src)
            && let remote = SocketAddr::new(failed_packet.dst(), dst)
            && let Some(maybe_socket) = self.sockets_by_conn.get_mut(&(local, remote))
            && let Some(handle) = maybe_socket.take()
        {
            tracing::debug!(%local, %remote, "Received ICMP error");

            self.sockets.remove(handle);

            return;
        }

        // A packet for a connection that was dropped has no socket to receive it.
        // Feeding it to the TCP stack would answer it with an RST.
        if let Some(tcp) = packet.as_tcp()
            && let local = SocketAddr::new(packet.destination(), tcp.destination_port())
            && let remote = SocketAddr::new(packet.source(), tcp.source_port())
            && let Some(None) = self.sockets_by_conn.get(&(local, remote))
        {
            tracing::debug!(%local, %remote, "Ignoring packet for closed connection");

            return;
        }

        self.device.receive(packet);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let _result = self.interface.poll(
            l3_tcp::now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );

        for (_, socket) in self.sockets.iter_mut() {
            let l3_tcp::AnySocket::Tcp(socket) = socket;

            if socket.state() == l3_tcp::State::Established && socket.send_queue() == 0 {
                socket.set_timeout(None);
            }
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }

    pub fn iter_sockets(&self) -> impl Iterator<Item = &Socket<'_>> {
        self.sockets.iter().map(|(_, s)| match s {
            l3_tcp::AnySocket::Tcp(socket) => socket,
        })
    }

    pub fn reset(&mut self) {
        self.sockets = l3_tcp::SocketSet::new(Vec::default());
        self.device.clear();

        for maybe_socket in self.sockets_by_conn.values_mut() {
            *maybe_socket = None;
        }
    }

    /// Silently drops every connection that has not completed its handshake.
    pub fn drop_unfinished(&mut self) {
        for maybe_socket in self.sockets_by_conn.values_mut() {
            let Some(handle) = *maybe_socket else {
                continue;
            };
            if self.sockets.get::<Socket>(handle).state() == l3_tcp::State::Established {
                continue;
            }

            self.sockets.remove(handle);
            *maybe_socket = None;
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

    pub fn has_connection(&self, local: SocketAddr, remote: SocketAddr) -> bool {
        self.sockets.iter().any(|(_, socket)| {
            let l3_tcp::AnySocket::Tcp(socket) = socket;

            socket.local_endpoint() == Some(local.into())
                && socket.remote_endpoint() == Some(remote.into())
        })
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        self.device.receive(packet);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let _result = self.interface.poll(
            l3_tcp::now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );

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

    /// Drops all connections but keeps listening on the same ports.
    pub fn reset(&mut self) {
        self.sockets = l3_tcp::SocketSet::new(Vec::default());
        self.device.clear();

        let ports = mem::take(&mut self.listen_ports)
            .into_values()
            .collect::<Vec<_>>();

        for port in ports {
            self.listen(port)
                .expect("re-listening on a previously bound port to succeed");
        }
    }
}
