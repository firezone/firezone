use std::{collections::BTreeMap, net::SocketAddr, time::Instant};

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
    /// Data written to a connection that cannot send yet.
    unsent: BTreeMap<l3_tcp::SocketHandle, Vec<u8>>,
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
            unsent: Default::default(),
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

    /// Writes `data` to the open connection between `local` and `remote`.
    ///
    /// The data is sent by the next [`Client::handle_timeout`] once the connection is established.
    pub fn send(&mut self, local: SocketAddr, remote: SocketAddr, data: &[u8]) -> Result<()> {
        let handle = self
            .sockets_by_conn
            .get(&(local, remote))
            .copied()
            .flatten()
            .context("No open TCP connection")?;

        self.unsent
            .entry(handle)
            .or_default()
            .extend_from_slice(data);

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
            && let Some(Some(handle)) = self.sockets_by_conn.get(&(local, remote))
        {
            tracing::debug!(%local, %remote, "Received ICMP error");

            let handle = *handle;
            self.forget(local, remote, handle);

            return;
        }

        // A packet for a connection that was dropped has no socket to
        // receive it. Feeding it to the TCP stack would answer it with an RST.
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
        let now = l3_tcp::now(self.created_at, now);

        let _result = self
            .interface
            .poll(now, &mut self.device, &mut self.sockets);

        let writable = self
            .unsent
            .extract_if(.., |handle, _| {
                self.sockets.get::<Socket>(*handle).may_send()
            })
            .collect::<Vec<_>>();
        for (handle, data) in writable {
            let socket = self.sockets.get_mut::<Socket>(handle);
            socket.set_timeout(Some(self.os.tcp_timeout()));

            if socket.send_slice(&data) != Ok(data.len()) {
                tracing::error!("Failed to write TCP data");
            }
        }

        let _result = self
            .interface
            .poll(now, &mut self.device, &mut self.sockets);

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

    /// Silently drops every connection that is not established or still waits for an ACK.
    ///
    /// Like an application giving up on a connect or write that did not complete in time,
    /// this keeps a failed connection from retransmitting into later transitions.
    pub fn drop_unfinished(&mut self) {
        let dropped = self
            .sockets_by_conn
            .iter()
            .filter_map(|((local, remote), handle)| Some((*local, *remote, (*handle)?)))
            .filter(|(_, _, handle)| {
                let socket = self.sockets.get::<Socket>(*handle);

                socket.state() != l3_tcp::State::Established || socket.send_queue() > 0
            })
            .collect::<Vec<_>>();

        for (local, remote, handle) in dropped {
            self.forget(local, remote, handle);
        }
    }

    /// Drops a connection without telling the remote, but keeps consuming its late packets.
    fn forget(&mut self, local: SocketAddr, remote: SocketAddr, handle: l3_tcp::SocketHandle) {
        self.sockets.remove(handle);
        self.unsent.remove(&handle);
        self.sockets_by_conn.insert((local, remote), None);
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

    /// Returns whether the server accepted a connection between `local` and `remote`.
    pub fn has_connection(&self, local: SocketAddr, remote: SocketAddr) -> bool {
        self.sockets.iter().any(|(_, socket)| {
            let l3_tcp::AnySocket::Tcp(socket) = socket;

            socket.local_endpoint() == Some(local.into())
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
}
