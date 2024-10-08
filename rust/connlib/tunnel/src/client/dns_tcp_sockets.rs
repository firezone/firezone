use std::{
    collections::{HashMap, VecDeque},
    io,
    net::{IpAddr, SocketAddr},
    time::Instant,
};

use anyhow::Context as _;
use bimap::BiMap;
use domain::{base::Message, dep::octseq::OctetsInto};
use ip_packet::{IpPacket, IpPacketBuf};
use smoltcp::{
    iface::{Config, Interface, SocketHandle, SocketSet},
    socket::tcp,
    wire::{HardwareAddress, IpCidr},
};

use crate::messages::DnsServer;

const MAX_DNS_SERVERS: usize = smoltcp::config::IFACE_MAX_ADDR_COUNT;

pub(crate) struct DnsTcpSockets {
    device: SmolDeviceAdapter,
    interface: Interface,

    tcp_sockets: SocketSet<'static>,
    tcp_socket_listen_endpoints: HashMap<SocketHandle, SocketAddr>,

    dns_mapping: BiMap<IpAddr, DnsServer>,
    received_queries: VecDeque<(SocketAddr, Message<Vec<u8>>)>,

    socket_handles_by_query: HashMap<(u16, SocketAddr), SocketHandle>,
}

impl DnsTcpSockets {
    pub(crate) fn new(now: Instant) -> Self {
        let mut device = SmolDeviceAdapter {
            inbound_packets: VecDeque::default(),
            outbound_packets: VecDeque::default(),
        };
        let interface = Interface::new(Config::new(HardwareAddress::Ip), &mut device, now.into());

        Self {
            device,
            interface,
            tcp_sockets: SocketSet::new(vec![]),
            tcp_socket_listen_endpoints: Default::default(),
            dns_mapping: Default::default(),
            socket_handles_by_query: Default::default(),
            received_queries: Default::default(),
        }
    }

    pub(crate) fn handle_inbound_packet(&mut self, packet: IpPacket, now: Instant) {
        self.device.inbound_packets.push_back(packet);
        self.handle_timeout(now);
    }

    pub(crate) fn write_dns_response(
        &mut self,
        query_id: u16,
        server: SocketAddr,
        message: io::Result<Message<Vec<u8>>>,
    ) -> anyhow::Result<()> {
        let handle = self
            .socket_handles_by_query
            .remove(&(query_id, server))
            .context("Unknown query")?;

        let socket = self.tcp_sockets.get_mut::<tcp::Socket>(handle);

        match message {
            Ok(message) => {
                let response = message.as_octets();

                write_tcp_dns_response(socket, response)?;
            }
            Err(e) => {
                tracing::debug!("TCP DNS query failed: {e}");

                socket.abort();
            }
        }

        Ok(())
    }

    pub(crate) fn poll_received_queries(&mut self) -> Option<(SocketAddr, Message<Vec<u8>>)> {
        self.received_queries.pop_front()
    }

    pub(crate) fn poll_outbound_packets(&mut self) -> Option<IpPacket> {
        self.device.outbound_packets.pop_front()
    }

    fn handle_timeout(&mut self, now: Instant) {
        let changed = self.interface.poll(
            smoltcp::time::Instant::from(now),
            &mut self.device,
            &mut self.tcp_sockets,
        );

        if !changed {
            return;
        }

        for (handle, smoltcp::socket::Socket::Tcp(socket)) in self.tcp_sockets.iter_mut() {
            let listen_endpoint = self.tcp_socket_listen_endpoints.get(&handle).unwrap();

            match try_handle_tcp_socket(socket, *listen_endpoint, &self.dns_mapping) {
                Ok(Some((upstream, message))) => {
                    self.socket_handles_by_query
                        .insert((message.header().id(), upstream), handle);
                    self.received_queries.push_back((upstream, message));
                }
                Ok(None) => {}
                Err(e) => {
                    tracing::debug!("Failed to process TCP socket: {e}");
                    socket.abort();
                }
            }
        }
    }

    pub(crate) fn set_dns_mapping(&mut self, new_mapping: BiMap<IpAddr, DnsServer>) {
        self.dns_mapping = new_mapping;
        self.tcp_sockets = SocketSet::new(vec![]);
        self.tcp_socket_listen_endpoints.clear();
        self.interface.update_ip_addrs(|ips| ips.clear());

        let tcp_listen_endpoints = self
            .dns_mapping
            .clone()
            .into_iter()
            .map(|(ip, _)| SocketAddr::from((ip, 53)));

        if tcp_listen_endpoints.len() > MAX_DNS_SERVERS {
            tracing::warn!("TCP DNS only works for up to {MAX_DNS_SERVERS} DNS servers");
        }

        // Limiting the number here as two purposes:
        // 1. We can't handle more than these anyway due to limitations in `smoltcp`.
        // 2. We need to allocate a buffer for each one. If we don't limit these, defining a large number of DNS servers would be a memory-DoS vector.
        let tcp_listen_endpoints = tcp_listen_endpoints.take(MAX_DNS_SERVERS);

        // Create a bunch of sockets per address so we can serve multiple clients at once.
        // DNS queries may be sent concurrently on the same socket, but only be a single other remote socket.
        // Having multiple sockets for the same sentinel IP allows multiple clients to connect concurrently.
        // Each one of these needs to allocate a buffer.
        for listen_endpoint in tcp_listen_endpoints {
            self.create_tcp_socket(listen_endpoint);
            self.create_tcp_socket(listen_endpoint);
            self.create_tcp_socket(listen_endpoint);
            self.create_tcp_socket(listen_endpoint);
            self.create_tcp_socket(listen_endpoint);

            self.interface.update_ip_addrs(|ips| {
                let ip = listen_endpoint.ip();
                let cidr = match ip {
                    IpAddr::V4(_) => IpCidr::new(ip.into(), 32),
                    IpAddr::V6(_) => IpCidr::new(ip.into(), 128),
                };
                ips.push(cidr).expect(
                    "We clear all entries before and never emit more than the maximum allowed",
                )
            });
        }
    }

    fn create_tcp_socket(&mut self, listen_endpoint: SocketAddr) {
        /// The 2-byte length prefix of DNS over TCP messages limits their size to effectively u16::MAX.
        /// It is quite unlikely that we have to buffer _multiple_ of these max-sized messages.
        /// Being able to buffer at least one of them means we can handle the extreme case.
        /// In practice, this allows the OS to queue multiple queries even if we can't immediately process them.
        const MAX_TCP_DNS_MSG_LENGTH: usize = u16::MAX as usize;

        let mut socket = tcp::Socket::new(
            smoltcp::storage::RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
            smoltcp::storage::RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
        );
        socket
            .listen(listen_endpoint)
            .expect("A fresh socket should always be able to listen");

        let handle = self.tcp_sockets.add(socket);
        self.tcp_socket_listen_endpoints
            .insert(handle, listen_endpoint);
    }
}

fn try_handle_tcp_socket(
    socket: &mut tcp::Socket,
    listen_endpoint: SocketAddr,
    dns_mapping: &BiMap<IpAddr, DnsServer>,
) -> anyhow::Result<Option<(SocketAddr, Message<Vec<u8>>)>> {
    // smoltcp's sockets can only ever handle a single remote, i.e. there is no permanent listening socket.
    // to be able to handle a new connection, reset the socket back to `listen` once the connection is closed / closing.
    {
        use smoltcp::socket::tcp::State::*;

        if matches!(socket.state(), Closed | TimeWait | CloseWait) {
            tracing::debug!("Resetting TCP socket to listen");

            socket.abort();
            socket.listen(listen_endpoint).unwrap();
            return Ok(None);
        }
    }

    let Some(local) = socket.local_endpoint().map(|e| IpAddr::from(e.addr)) else {
        return Ok(None); // Unless we are connected with someone, there is nothing to do.
    };

    // Ensure we can recv, send and have space to send.
    if !socket.can_recv() || !socket.can_send() || socket.send_queue() > 0 {
        return Ok(None);
    }

    let upstream = dns_mapping
        .get_by_left(&local)
        .map(|d| d.address())
        .with_context(|| format!("Not a DNS server: {local}"))?;

    // Read a DNS message from the socket.
    let Some(message) = socket
        .recv(|r| {
            // DNS over TCP has a 2-byte length prefix at the start, see <https://datatracker.ietf.org/doc/html/rfc1035#section-4.2.2>.
            let Some((header, message)) = r.split_first_chunk::<2>() else {
                return (0, None);
            };
            let dns_message_length = u16::from_be_bytes(*header) as usize;
            if message.len() < dns_message_length {
                return (0, None); // Don't consume any bytes unless we can read the full message at once.
            }

            (2 + dns_message_length, Some(Message::from_octets(message)))
        })
        .context("Failed to recv TCP data")?
        .transpose()
        .context("Failed to parse DNS message")?
    else {
        return Ok(None);
    };

    Ok(Some((upstream, message.octets_into())))
}

fn write_tcp_dns_response(socket: &mut tcp::Socket, response: &[u8]) -> anyhow::Result<()> {
    let dns_message_length = (response.len() as u16).to_be_bytes();

    let written = socket
        .send_slice(&dns_message_length)
        .context("Failed to write TCP DNS length header")?;

    anyhow::ensure!(
        written == 2,
        "Not enough space in write buffer for TCP DNS length header"
    );

    let written = socket
        .send_slice(response)
        .context("Failed to write DNS message")?;

    anyhow::ensure!(
        written == response.len(),
        "Not enough space in write buffer for DNS response"
    );

    Ok(())
}

/// An adapter struct between our managed TUN device and [`smoltcp`].
struct SmolDeviceAdapter {
    /// Packets that we have received on the TUN device and selected to be processed by [`smoltcp`].
    inbound_packets: VecDeque<IpPacket>,
    outbound_packets: VecDeque<IpPacket>,
}

impl smoltcp::phy::Device for SmolDeviceAdapter {
    type RxToken<'a> = SmolRxToken;
    type TxToken<'a> = SmolTxToken<'a>;

    fn receive(
        &mut self,
        _timestamp: smoltcp::time::Instant,
    ) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let rx_token = SmolRxToken {
            packet: self.inbound_packets.pop_front()?,
        };
        let tx_token = SmolTxToken {
            outbound_packets: &mut self.outbound_packets,
        };

        Some((rx_token, tx_token))
    }

    fn transmit(&mut self, _timestamp: smoltcp::time::Instant) -> Option<Self::TxToken<'_>> {
        Some(SmolTxToken {
            outbound_packets: &mut self.outbound_packets,
        })
    }

    fn capabilities(&self) -> smoltcp::phy::DeviceCapabilities {
        let mut caps = smoltcp::phy::DeviceCapabilities::default();
        caps.medium = smoltcp::phy::Medium::Ip;
        caps.max_transmission_unit = ip_packet::PACKET_SIZE;

        caps
    }
}

struct SmolTxToken<'a> {
    outbound_packets: &'a mut VecDeque<IpPacket>,
}

impl<'a> smoltcp::phy::TxToken for SmolTxToken<'a> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut ip_packet_buf = IpPacketBuf::new();
        let result = f(ip_packet_buf.buf());

        let mut ip_packet = IpPacket::new(ip_packet_buf, len).unwrap();
        ip_packet.update_checksum();
        self.outbound_packets.push_back(ip_packet);

        result
    }
}

struct SmolRxToken {
    packet: IpPacket,
}

impl smoltcp::phy::RxToken for SmolRxToken {
    fn consume<R, F>(mut self, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        f(self.packet.packet_mut())
    }
}
