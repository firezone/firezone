use std::{collections::BTreeMap, net::SocketAddr, time::Instant};

use anyhow::{Context, Result};
use ip_packet::{IpPacket, Layer4Protocol};
use l3_tcp::Socket;

/// The TCP give-up behaviour of the operating system a client simulates.
///
/// Established connections abort once outstanding data goes unacknowledged for
/// the profile's duration, mirroring each stack's retransmission budget. Idle
/// connections never time out: keep-alives are opt-in on every stack and
/// default to probing only after two hours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TcpStackProfile {
    /// Linux and Android: `tcp_retries2 = 15` gives up after ~15 minutes.
    Linux,
    /// macOS and iOS: `TCP_MAXRXTSHIFT = 12` gives up after ~7.5 minutes.
    Apple,
    /// Windows: 5 data retransmissions give up within ~90 seconds.
    Windows,
}

impl TcpStackProfile {
    fn timeout(&self) -> l3_tcp::Duration {
        match self {
            TcpStackProfile::Linux => l3_tcp::Duration::from_secs(924),
            TcpStackProfile::Apple => l3_tcp::Duration::from_secs(450),
            TcpStackProfile::Windows => l3_tcp::Duration::from_secs(90),
        }
    }
}

pub struct Client {
    sockets: l3_tcp::SocketSet<'static>,
    /// The socket for each connection, or `None` for one that [`Client::reset`] dropped.
    ///
    /// Closed connections are kept so late packets for them are still consumed.
    sockets_by_conn: BTreeMap<(SocketAddr, SocketAddr), Option<l3_tcp::SocketHandle>>,
    device: l3_tcp::InMemoryDevice,
    interface: l3_tcp::Interface,
    stack_profile: TcpStackProfile,

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
    pub fn new(now: Instant, stack_profile: TcpStackProfile) -> Self {
        let mut device = l3_tcp::InMemoryDevice::default();
        let interface = l3_tcp::create_interface(&mut device);

        Self {
            sockets: l3_tcp::SocketSet::new(Vec::default()),
            sockets_by_conn: Default::default(),
            device,
            interface,
            stack_profile,
            created_at: now,
            last_now: now,
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

        socket.set_timeout(Some(self.stack_profile.timeout()));

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
            && let Some(Some(handle)) = self.sockets_by_conn.get(&(local, remote))
        {
            tracing::debug!(%local, %remote, "Received ICMP error");

            self.sockets.get_mut::<l3_tcp::Socket>(*handle).abort();
        }

        // A packet for a connection that [`Client::reset`] dropped has no socket to
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
