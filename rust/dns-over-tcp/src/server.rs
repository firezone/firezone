use std::{
    collections::{BTreeSet, HashMap, VecDeque},
    net::SocketAddr,
    time::Instant,
};

use crate::stub_device::InMemoryDevice;
use anyhow::{Context as _, Result};
use domain::{base::Message, dep::octseq::OctetsInto as _, rdata::AllRecordData};
use ip_packet::IpPacket;
use itertools::Itertools as _;
use smoltcp::{
    iface::{Config, Interface, Route, SocketSet},
    socket::tcp,
    storage::RingBuffer,
    wire::{HardwareAddress, IpEndpoint, Ipv4Address, Ipv4Cidr, Ipv6Address, Ipv6Cidr},
};

/// A sans-IO implementation of DNS-over-TCP server.
///
/// Listens on a specified number of socket addresses, parses incoming DNS queries and allows writing back responses.
pub struct Server {
    device: InMemoryDevice,
    interface: Interface,

    sockets: SocketSet<'static>,
    listen_endpoints: HashMap<smoltcp::iface::SocketHandle, SocketAddr>,

    received_queries: VecDeque<Query>,
}

/// Opaque handle to a TCP socket.
///
/// This purposely does not implement [`Clone`] or [`Copy`] to make them single-use.
#[derive(Debug, PartialEq, Eq, Hash)]
#[must_use = "An active `SocketHandle` means a TCP socket is waiting for a reply somewhere"]
pub struct SocketHandle(smoltcp::iface::SocketHandle);

pub struct Query {
    pub message: Message<Vec<u8>>,
    pub socket: SocketHandle,
    /// The address of the socket that received the query.
    pub local: SocketAddr,
}

const SERVER_IP4_ADDR: Ipv4Address = Ipv4Address::new(127, 0, 0, 1);
const SERVER_IP6_ADDR: Ipv6Address = Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, 1);

impl Server {
    pub fn new(now: Instant) -> Self {
        let mut device = InMemoryDevice::default();

        let mut interface =
            Interface::new(Config::new(HardwareAddress::Ip), &mut device, now.into());
        // Accept packets with any destination IP, not just our interface.
        interface.set_any_ip(true);

        // Set our interface IPs. These are just dummies and don't show up anywhere!
        interface.update_ip_addrs(|ips| {
            ips.push(Ipv4Cidr::new(SERVER_IP4_ADDR, 32).into()).unwrap();
            ips.push(Ipv6Cidr::new(SERVER_IP6_ADDR, 128).into())
                .unwrap();
        });

        // Configure catch-all routes, meaning all packets given to `smoltcp` will be routed to our interface.
        interface.routes_mut().update(|routes| {
            routes
                .push(Route::new_ipv4_gateway(SERVER_IP4_ADDR))
                .unwrap();
            routes
                .push(Route::new_ipv6_gateway(SERVER_IP6_ADDR))
                .unwrap();
        });

        Self {
            device,
            interface,
            sockets: SocketSet::new(Vec::default()),
            listen_endpoints: Default::default(),
            received_queries: Default::default(),
        }
    }

    /// Listen on the specified addresses.
    ///
    /// This resets all sockets we were previously listening on.
    /// This function is generic over a `NUM_CONCURRENT_CLIENTS` constant.
    /// The constant configures, how many concurrent clients you would like to be able to serve per listen address.
    pub fn set_listen_addresses<const NUM_CONCURRENT_CLIENTS: usize>(
        &mut self,
        addresses: Vec<SocketAddr>,
    ) {
        assert!(NUM_CONCURRENT_CLIENTS > 0);

        let mut sockets =
            SocketSet::new(Vec::with_capacity(addresses.len() * NUM_CONCURRENT_CLIENTS));
        let mut listen_endpoints = HashMap::with_capacity(addresses.len());

        for listen_endpoint in addresses {
            for _ in 0..NUM_CONCURRENT_CLIENTS {
                let handle = sockets.add(create_tcp_socket(listen_endpoint));
                listen_endpoints.insert(handle, listen_endpoint);
            }

            tracing::info!(%listen_endpoint, concurrency = %NUM_CONCURRENT_CLIENTS, "Created listening TCP socket");
        }

        self.sockets = sockets;
        self.listen_endpoints = listen_endpoints;
        self.received_queries.clear();
    }

    /// Checks whether this server can handle the given packet.
    ///
    /// Only TCP packets targeted at one of sockets configured with [`Server::set_listen_addresses`] are accepted.
    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some(tcp) = packet.as_tcp() else {
            tracing::trace!(?packet, "Not a TCP packet");

            return false;
        };

        let dst = SocketAddr::new(packet.destination(), tcp.destination_port());
        let is_listening = self.listen_endpoints.values().any(|listen| listen == &dst);

        if !is_listening && tracing::enabled!(tracing::Level::TRACE) {
            let listen_endpoints = BTreeSet::from_iter(self.listen_endpoints.values().copied());

            tracing::trace!(%dst, ?listen_endpoints, "No listening socket for destination");
        }

        is_listening
    }

    /// Handle the [`IpPacket`].
    ///
    /// This function only inserts the packet into a buffer.
    /// To actually process the packets in the buffer, [`Server::handle_timeout`] must be called.
    pub fn handle_inbound(&mut self, packet: IpPacket) {
        debug_assert!(self.accepts(&packet));

        self.device.receive(packet);
    }

    /// Send a message on the socket associated with the handle.
    ///
    /// This fails if the socket is not writeable.
    /// On any error, the TCP connection is automatically reset.
    pub fn send_message(&mut self, socket: SocketHandle, message: Message<Vec<u8>>) -> Result<()> {
        let socket = self.sockets.get_mut::<tcp::Socket>(socket.0);

        let result = write_tcp_dns_response(socket, message.for_slice_ref());

        if result.is_err() {
            socket.abort();
        }

        result.context("Failed to write DNS response")?; // Bail before logging in case we failed to write the response.

        if tracing::event_enabled!(target: "wire::dns::res", tracing::Level::TRACE) {
            if let Ok(question) = message.sole_question() {
                let qtype = question.qtype();
                let qname = question.into_qname();
                let rcode = message.header().rcode();

                if let Ok(record_section) = message.answer() {
                    let records = record_section
                        .into_iter()
                        .filter_map(|r| {
                            let data = r
                                .ok()?
                                .into_any_record::<AllRecordData<_, _>>()
                                .ok()?
                                .data()
                                .clone();

                            Some(data)
                        })
                        .join(" | ");
                    let qid = message.header().id();

                    tracing::trace!(target: "wire::dns::res", %qid, %rcode, "{:5} {qname} => [{records}]", qtype.to_string());
                }
            }
        }

        Ok(())
    }

    /// Resets the socket associated with the given handle.
    ///
    /// Use this if you encountered an error while processing a previously emitted DNS query.
    pub fn reset(&mut self, handle: SocketHandle) {
        self.sockets.get_mut::<tcp::Socket>(handle.0).abort();
    }

    /// Inform the server that time advanced.
    ///
    /// Typical for a sans-IO design, `handle_timeout` will work through all local buffers and process them as much as possible.
    pub fn handle_timeout(&mut self, now: Instant) {
        let changed = self.interface.poll(
            smoltcp::time::Instant::from(now),
            &mut self.device,
            &mut self.sockets,
        );

        if !changed {
            return;
        }

        for (handle, smoltcp::socket::Socket::Tcp(socket)) in self.sockets.iter_mut() {
            let listen = self.listen_endpoints.get(&handle).copied().unwrap();

            match try_recv_query(socket, listen) {
                Ok(Some(message)) => {
                    if tracing::event_enabled!(target: "wire::dns::qry", tracing::Level::TRACE) {
                        if let Ok(question) = message.sole_question() {
                            let qtype = question.qtype();
                            let qname = question.into_qname();
                            let qid = message.header().id();

                            tracing::trace!(target: "wire::dns::qry", %qid, "{:5} {qname}", qtype.to_string());
                        }
                    }

                    self.received_queries.push_back(Query {
                        message,
                        socket: SocketHandle(handle),
                        local: listen,
                    });
                }
                Ok(None) => {}
                Err(e) => {
                    tracing::debug!("Error on receiving DNS query: {e}");
                    socket.abort();
                }
            }
        }
    }

    /// Returns [`IpPacket`]s that should be sent.
    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }

    /// Returns queries received from a DNS client.
    pub fn poll_queries(&mut self) -> Option<Query> {
        self.received_queries.pop_front()
    }
}

fn create_tcp_socket(listen_endpoint: SocketAddr) -> tcp::Socket<'static> {
    /// The 2-byte length prefix of DNS over TCP messages limits their size to effectively u16::MAX.
    /// It is quite unlikely that we have to buffer _multiple_ of these max-sized messages.
    /// Being able to buffer at least one of them means we can handle the extreme case.
    /// In practice, this allows the OS to queue multiple queries even if we can't immediately process them.
    const MAX_TCP_DNS_MSG_LENGTH: usize = u16::MAX as usize;

    let mut socket = tcp::Socket::new(
        RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
        RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
    );
    socket
        .listen(listen_endpoint)
        .expect("A fresh socket should always be able to listen");

    socket
}

fn try_recv_query(
    socket: &mut tcp::Socket,
    listen: SocketAddr,
) -> Result<Option<Message<Vec<u8>>>> {
    // smoltcp's sockets can only ever handle a single remote, i.e. there is no permanent listening socket.
    // to be able to handle a new connection, reset the socket back to `listen` once the connection is closed / closing.
    {
        use smoltcp::socket::tcp::State::*;

        if matches!(socket.state(), Closed | TimeWait | CloseWait) {
            tracing::debug!(state = %socket.state(), "Resetting socket to listen state");

            socket.abort();
            socket
                .listen(listen)
                .expect("Can always listen after `abort()`");
        }
    }

    // We configure `smoltcp` with "any-ip", meaning packets to technically any IP will be routed here to us.
    if let Some(local) = socket.local_endpoint() {
        anyhow::ensure!(
            local == IpEndpoint::from(listen),
            "Bad destination socket: {local}"
        )
    }

    // Ensure we can recv, send and have space to send.
    if !socket.can_recv() || !socket.can_send() || socket.send_queue() > 0 {
        tracing::trace!(
            can_recv = %socket.can_recv(),
            can_send = %socket.can_send(),
            send_queue = %socket.send_queue(),
            "Not yet ready to receive next message"
        );

        return Ok(None);
    }

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

    anyhow::ensure!(!message.header().qr(), "DNS message is a response!");

    Ok(Some(message.octets_into()))
}

fn write_tcp_dns_response(socket: &mut tcp::Socket, response: Message<&[u8]>) -> Result<()> {
    anyhow::ensure!(response.header().qr(), "DNS message is a query!");

    let response = response.as_slice();

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
