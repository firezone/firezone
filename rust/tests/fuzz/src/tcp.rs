use std::{collections::BTreeMap, net::SocketAddr, time::Instant};

use anyhow::{Context, Result, ensure};
use ip_packet::{IpPacket, Layer4Protocol};
use l3_tcp::Socket;

use crate::os::SimulatedOs;

pub struct Client {
    sockets: l3_tcp::SocketSet<'static>,
    /// The socket for each connection, or `None` for one that [`Client::retain`] dropped.
    ///
    /// Closed connections are kept so late packets for them are still consumed.
    sockets_by_conn: BTreeMap<(SocketAddr, SocketAddr), Option<l3_tcp::SocketHandle>>,
    /// The data each connection received since [`Client::clear_received`].
    received: BTreeMap<(SocketAddr, SocketAddr), Vec<u8>>,
    device: l3_tcp::InMemoryDevice,
    interface: l3_tcp::Interface,
    os: SimulatedOs,

    created_at: Instant,
}

pub struct Server {
    sockets: l3_tcp::SocketSet<'static>,
    listen_endpoints: BTreeMap<l3_tcp::SocketHandle, SocketAddr>,
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
            received: Default::default(),
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

    /// Writes `data` to the open connection between `local_port` and `remote_port`.
    pub fn send(&mut self, local_port: u16, remote_port: u16, data: &[u8]) -> Result<()> {
        let handle = self
            .sockets_by_conn
            .iter()
            .find_map(|((local, remote), handle)| {
                (local.port() == local_port && remote.port() == remote_port).then_some(*handle)
            })
            .flatten()
            .context("No open TCP connection")?;

        let socket = self.sockets.get_mut::<Socket>(handle);
        socket.set_timeout(Some(self.os.tcp_timeout()));
        let written = socket
            .send_slice(data)
            .context("Failed to write TCP data")?;
        ensure!(written == data.len(), "TCP send buffer is full");

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

        // A packet for a connection that [`Client::retain`] dropped has no socket to
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
        let _result = self.interface.poll(
            l3_tcp::now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );

        for (conn, handle) in &self.sockets_by_conn {
            let Some(handle) = handle else {
                continue;
            };
            let socket = self.sockets.get_mut::<Socket>(*handle);

            while let Ok(data) = socket.recv(|buf| (buf.len(), buf.to_vec())) {
                if data.is_empty() {
                    break;
                }

                self.received.entry(*conn).or_default().extend(data);
            }

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

    pub fn received(&self) -> impl Iterator<Item = ((SocketAddr, SocketAddr), &[u8])> {
        self.received
            .iter()
            .map(|(conn, data)| (*conn, data.as_slice()))
    }

    pub fn clear_received(&mut self) {
        self.received.clear();
    }

    /// Silently drops every connection for which `keep` returns `false`.
    pub fn retain(&mut self, mut keep: impl FnMut(SocketAddr, SocketAddr) -> bool) {
        let dropped = self
            .sockets_by_conn
            .iter()
            .filter_map(|((local, remote), handle)| Some((*local, *remote, (*handle)?)))
            .filter(|(local, remote, _)| !keep(*local, *remote))
            .collect::<Vec<_>>();

        for (local, remote, handle) in dropped {
            self.forget(local, remote, handle);
        }
    }

    /// Drops a connection without telling the remote, but keeps consuming its late packets.
    fn forget(&mut self, local: SocketAddr, remote: SocketAddr, handle: l3_tcp::SocketHandle) {
        self.sockets.remove(handle);
        self.sockets_by_conn.insert((local, remote), None);
    }
}

impl Server {
    pub fn new(now: Instant) -> Self {
        let mut device = l3_tcp::InMemoryDevice::default();
        let interface = l3_tcp::create_interface(&mut device);

        Self {
            sockets: l3_tcp::SocketSet::new(Vec::default()),
            listen_endpoints: Default::default(),
            device,
            interface,
            created_at: now,
        }
    }

    pub fn listen(&mut self, address: SocketAddr) -> Result<()> {
        let mut socket = l3_tcp::create_tcp_socket();
        socket
            .listen(address)
            .with_context(|| format!("Failed to listen on {address}"))?;

        let handle = self.sockets.add(socket);
        self.listen_endpoints.insert(handle, address);

        Ok(())
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        self.device.receive(packet);
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

        // Every address in `listen_endpoints` always has one socket in `Listen`:
        // a listener that accepted a connection is replaced by a fresh one.
        let accepted = self
            .listen_endpoints
            .iter()
            .filter(|(handle, _)| {
                self.sockets.get::<l3_tcp::Socket>(**handle).state() != l3_tcp::State::Listen
            })
            .map(|(handle, address)| (*handle, *address))
            .collect::<Vec<_>>();

        for (handle, address) in accepted {
            self.listen_endpoints.remove(&handle);
            self.listen(address)
                .expect("re-listening on a previously bound address to succeed");
        }
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }
}
