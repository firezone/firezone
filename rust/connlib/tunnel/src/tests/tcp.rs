use std::{
    collections::BTreeMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use ip_packet::{IpPacket, Layer4Protocol};
use l3_tcp::Socket;

pub struct Client {
    sockets: l3_tcp::SocketSet<'static>,
    sockets_by_remote: BTreeMap<SocketAddr, l3_tcp::SocketHandle>,
    device: l3_tcp::InMemoryDevice,
    interface: l3_tcp::Interface,

    created_at: Instant,
    last_now: Instant,
}

pub struct Server {
    sockets: l3_tcp::SocketSet<'static>,
    listen_endpoints: BTreeMap<l3_tcp::SocketHandle, SocketAddr>,
    device: l3_tcp::InMemoryDevice,
    interface: l3_tcp::Interface,

    created_at: Instant,
    last_now: Instant,
}

impl Client {
    pub fn new(now: Instant) -> Self {
        let mut device = l3_tcp::InMemoryDevice::default();
        let interface = l3_tcp::create_interface(&mut device);

        Self {
            sockets: l3_tcp::SocketSet::new(Vec::default()),
            sockets_by_remote: Default::default(),
            device,
            interface,
            created_at: now,
            last_now: now,
        }
    }

    pub fn connect(&mut self, local: SocketAddr, remote: SocketAddr) -> Result<()> {
        anyhow::ensure!(!self.sockets_by_remote.contains_key(&remote));

        let mut socket = l3_tcp::create_tcp_socket();
        socket
            .connect(self.interface.context(), remote, local)
            .context("Failed to create TCP connection")?;

        // A short keep-alive ensures we detect broken connections.
        socket.set_keep_alive(Some(l3_tcp::Duration::from_secs(5)));

        // 30s is a common timeout for TCP connections.
        socket.set_timeout(Some(l3_tcp::Duration::from_secs(30)));

        let handle = self.sockets.add(socket);

        self.sockets_by_remote.insert(remote, handle);

        Ok(())
    }

    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some(tcp) = packet.as_tcp() else {
            return false;
        };

        self.sockets_by_remote
            .contains_key(&SocketAddr::new(packet.source(), tcp.source_port()))
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        // TODO: Upstream ICMP error handling to `smoltcp`.
        if let Ok(Some((failed_packet, _))) = packet.icmp_error()
            && let Layer4Protocol::Tcp { dst, .. } = failed_packet.layer4_protocol()
            && let socket = SocketAddr::new(failed_packet.dst(), dst)
            && let Some(handle) = self.sockets_by_remote.get(&socket)
        {
            tracing::debug!(%socket, "Received ICMP error");

            self.sockets.get_mut::<l3_tcp::Socket>(*handle).abort();
        }

        self.device.receive(packet);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = now;

        let _result = self.interface.poll(
            l3_tcp::now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }

    pub fn _poll_timeout(&mut self) -> Option<Instant> {
        let now = l3_tcp::now(self.created_at, self.last_now);

        let poll_in = self.interface.poll_delay(now, &self.sockets)?;

        Some(self.last_now + Duration::from(poll_in))
    }

    pub fn iter_sockets(&self) -> impl Iterator<Item = &Socket<'_>> {
        self.sockets.iter().map(|(_, s)| match s {
            l3_tcp::AnySocket::Tcp(socket) => socket,
        })
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
            last_now: now,
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

    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = now;

        let _result = self.interface.poll(
            l3_tcp::now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }
}
