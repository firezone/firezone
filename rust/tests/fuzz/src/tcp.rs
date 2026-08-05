use std::{collections::BTreeMap, net::SocketAddr, time::Instant};

use anyhow::{Context, Result};
use ip_packet::{IpPacket, Layer4Protocol};
use l3_tcp::Socket;

const MAX_CLOSED_CONNECTIONS: usize = 32;

pub struct Client {
    sockets: l3_tcp::SocketSet<'static>,
    /// The socket for each connection, or `None` for a connection reset while packets could still
    /// be in flight.
    sockets_by_conn: BTreeMap<(SocketAddr, SocketAddr), Option<l3_tcp::SocketHandle>>,
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
            sockets_by_conn: Default::default(),
            device,
            interface,
            created_at: now,
            last_now: now,
        }
    }

    pub fn connect(&mut self, local: SocketAddr, remote: SocketAddr) -> Result<()> {
        // Sockets are keyed by the full `(local, remote)` 4-tuple, so the client
        // can hold several connections to one remote from different local ports.
        // Re-connecting an already-open 4-tuple is a no-op.
        if self
            .sockets_by_conn
            .get(&(local, remote))
            .is_some_and(Option::is_some)
        {
            return Ok(());
        }

        let mut socket = l3_tcp::create_tcp_socket();
        socket
            .connect(self.interface.context(), remote, local)
            .context("Failed to create TCP connection")?;

        // A short keep-alive ensures we detect broken connections.
        socket.set_keep_alive(Some(l3_tcp::Duration::from_secs(5)));

        // 30s is a common timeout for TCP connections.
        socket.set_timeout(Some(l3_tcp::Duration::from_secs(30)));

        let handle = self.sockets.add(socket);

        self.sockets_by_conn.insert((local, remote), Some(handle));

        Ok(())
    }

    pub fn accepts(&self, packet: &IpPacket) -> bool {
        if let Ok(Some((failed_packet, _))) = packet.icmp_error()
            && let Layer4Protocol::Tcp { src, dst } = failed_packet.layer4_protocol()
        {
            let local = SocketAddr::new(failed_packet.src(), src);
            let remote = SocketAddr::new(failed_packet.dst(), dst);

            return self.sockets_by_conn.contains_key(&(local, remote));
        }

        let Some(tcp) = packet.as_tcp() else {
            return false;
        };

        let local = SocketAddr::new(packet.destination(), tcp.destination_port());
        let remote = SocketAddr::new(packet.source(), tcp.source_port());

        self.sockets_by_conn.contains_key(&(local, remote))
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) -> bool {
        if let Ok(Some((failed_packet, _))) = packet.icmp_error()
            && let Layer4Protocol::Tcp { src, dst } = failed_packet.layer4_protocol()
            && let local = SocketAddr::new(failed_packet.src(), src)
            && let remote = SocketAddr::new(failed_packet.dst(), dst)
            && let Some(maybe_handle) = self.sockets_by_conn.get(&(local, remote))
        {
            let Some(handle) = maybe_handle else {
                tracing::debug!(%local, %remote, "Ignoring packet for reset TCP connection");
                return false;
            };

            tracing::debug!(%local, %remote, "Received ICMP error");

            self.sockets.get_mut::<l3_tcp::Socket>(*handle).abort();
            self.device.receive(packet);
            return true;
        }

        let Some(tcp) = packet.as_tcp() else {
            return false;
        };

        let local = SocketAddr::new(packet.destination(), tcp.destination_port());
        let remote = SocketAddr::new(packet.source(), tcp.source_port());

        let Some(maybe_handle) = self.sockets_by_conn.get(&(local, remote)) else {
            return false;
        };

        let Some(_) = maybe_handle else {
            tracing::debug!(%local, %remote, "Ignoring packet for reset TCP connection");
            return false;
        };

        self.device.receive(packet);
        true
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
        for handle in self.sockets_by_conn.values_mut() {
            *handle = None;
        }
        while self.sockets_by_conn.len() > MAX_CLOSED_CONNECTIONS {
            self.sockets_by_conn.pop_first();
        }
        self.device.clear();
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

#[cfg(test)]
mod tests {
    use super::*;
    use ip_packet::make::{TcpFlags, tcp_packet};
    use std::net::{IpAddr, Ipv4Addr};

    #[test]
    fn reset_consumes_late_packets_for_closed_connections() {
        let now = Instant::now();
        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 34542);
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)), 2689);
        let mut client = Client::new(now);

        client.connect(local, remote).unwrap();
        client.reset();

        let packet = tcp_packet(
            remote.ip(),
            local.ip(),
            remote.port(),
            local.port(),
            TcpFlags {
                ack: true,
                ..Default::default()
            },
            &[1],
        )
        .unwrap();

        assert!(client.accepts(&packet));
        assert!(!client.handle_inbound(packet));
        client.handle_timeout(now);
        assert!(client.poll_outbound().is_none());
    }
}
