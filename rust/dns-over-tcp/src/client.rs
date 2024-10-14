use std::{
    collections::{BTreeSet, HashMap, HashSet, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Instant,
};

use crate::{codec, create_tcp_socket, interface::create_interface, stub_device::InMemoryDevice};
use anyhow::{anyhow, bail, Context as _, Result};
use domain::{base::Message, dep::octseq::OctetsInto};
use ip_packet::IpPacket;
use rand::{rngs::StdRng, Rng, SeedableRng};
use smoltcp::{
    iface::{Interface, SocketSet},
    socket::tcp::{self, Socket},
};

/// A sans-io DNS-over-TCP client.
///
/// The client maintains a single TCP connection for each configured resolver.
/// If the TCP connection fails for some reason, we try to establish a new one.
///
/// One of the design goals of this client is to always provide a result for a query.
/// If the TCP connection fails, we report all currently pending queries to that resolver as failed.
///
/// There are however currently no timeouts.
/// If the upstream resolver refuses to answer, we don't fail the query.
pub struct Client<const MIN_PORT: u16 = 49152, const MAX_PORT: u16 = 65535> {
    device: InMemoryDevice,
    interface: Interface,
    source_ips: Option<(Ipv4Addr, Ipv6Addr)>,

    sockets: SocketSet<'static>,
    sockets_by_remote: HashMap<SocketAddr, smoltcp::iface::SocketHandle>,
    local_ports_by_socket: HashMap<smoltcp::iface::SocketHandle, u16>,
    /// Queries we should send to a DNS resolver.
    pending_queries_by_remote: HashMap<SocketAddr, VecDeque<Message<Vec<u8>>>>,
    /// Queries we have sent to a DNS resolver and are waiting for a reply.
    sent_queries_by_remote: HashMap<SocketAddr, HashMap<u16, Message<Vec<u8>>>>,

    query_results: VecDeque<QueryResult>,

    rng: StdRng,
}

#[derive(Debug)]
pub struct QueryResult {
    pub query: Message<Vec<u8>>,
    pub server: SocketAddr,
    pub result: Result<Message<Vec<u8>>>,
}

impl<const MIN_PORT: u16, const MAX_PORT: u16> Client<MIN_PORT, MAX_PORT> {
    pub fn new(now: Instant, seed: [u8; 32]) -> Self {
        static_assertions::const_assert!(MIN_PORT >= 49152); // Outbound TCP connections should use the ephemeral port range.
        static_assertions::const_assert!(MIN_PORT > MAX_PORT); // Port range must not have length 0.

        let mut device = InMemoryDevice::default();
        let interface = create_interface(&mut device, now);

        Self {
            device,
            interface,
            sockets: SocketSet::new(Vec::default()),
            source_ips: None,
            sent_queries_by_remote: Default::default(),
            query_results: Default::default(),
            rng: StdRng::from_seed(seed),
            sockets_by_remote: Default::default(),
            local_ports_by_socket: Default::default(),
            pending_queries_by_remote: Default::default(),
        }
    }

    /// Sets the IPv4 and IPv6 source ips to use for outgoing packets.
    pub fn set_source_interface(&mut self, v4: Ipv4Addr, v6: Ipv6Addr) {
        self.source_ips = Some((v4, v6));
    }

    /// Connect to the specified DNS resolvers.
    ///
    /// All currently pending queries will be reported as failed.
    pub fn connect_to_resolvers(&mut self, resolvers: BTreeSet<SocketAddr>) -> Result<()> {
        let (ipv4_source, ipv6_source) = self.source_ips.context("Missing source IPs")?;

        // First, clear all local state.
        self.sockets = SocketSet::new(vec![]);
        self.sockets_by_remote.clear();
        self.local_ports_by_socket.clear();

        self.query_results
            .extend(
                self.pending_queries_by_remote
                    .drain()
                    .flat_map(|(server, queries)| {
                        into_failed_results(server, queries, || anyhow!("Aborted"))
                    }),
            );
        self.query_results
            .extend(
                self.sent_queries_by_remote
                    .drain()
                    .flat_map(|(server, queries)| {
                        into_failed_results(server, queries.into_values(), || anyhow!("Aborted"))
                    }),
            );

        // Second, try to create all new sockets.
        let new_sockets = std::iter::zip(self.sample_unique_ports(resolvers.len())?, resolvers).map(|(port, server)| {
            let local_endpoint = match server {
                SocketAddr::V4(_) => SocketAddr::new(ipv4_source.into(), port),
                SocketAddr::V6(_) => SocketAddr::new(ipv6_source.into(), port),
            };

            let mut socket = create_tcp_socket();

            socket
                .connect(self.interface.context(), server, local_endpoint)
                .context("Failed to connect socket")?;

            tracing::info!(local = %local_endpoint, remote = %server, "Connecting to DNS resolver");

            Ok((server, local_endpoint, socket))
        })
        .collect::<Result<Vec<_>>>()?;

        // Third, if everything was successful, change the local state.
        for (server, local_endpoint, socket) in new_sockets {
            let handle = self.sockets.add(socket);

            self.sockets_by_remote.insert(server, handle);
            self.local_ports_by_socket
                .insert(handle, local_endpoint.port());
        }

        Ok(())
    }

    /// Send the given DNS query to the target server.
    ///
    /// This only queues the message. You need to call [`Client::handle_timeout`] to actually send them.
    pub fn send_query(&mut self, server: SocketAddr, message: Message<Vec<u8>>) -> Result<()> {
        anyhow::ensure!(!message.header().qr(), "Message is a DNS response!");
        anyhow::ensure!(
            self.sockets_by_remote.contains_key(&server),
            "Unknown DNS resolver"
        );

        self.pending_queries_by_remote
            .entry(server)
            .or_default()
            .push_back(message);

        Ok(())
    }

    /// Checks whether this client can handle the given packet.
    ///
    /// Only TCP packets originating from one of the connected DNS resolvers are accepted.
    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some(tcp) = packet.as_tcp() else {
            tracing::trace!(?packet, "Not a TCP packet");

            return false;
        };

        let Some((ipv4_source, ipv6_source)) = self.source_ips else {
            tracing::trace!("No source interface");

            return false;
        };

        // If the packet doesn't match our source interface, we don't want it.
        match packet.destination() {
            IpAddr::V4(v4) if v4 != ipv4_source => return false,
            IpAddr::V6(v6) if v6 != ipv6_source => return false,
            _ => {}
        }

        let remote = SocketAddr::new(packet.source(), tcp.source_port());
        let has_socket = self.sockets_by_remote.contains_key(&remote);

        if !has_socket && tracing::enabled!(tracing::Level::TRACE) {
            let open_sockets = BTreeSet::from_iter(self.sockets_by_remote.keys().copied());

            tracing::trace!(%remote, ?open_sockets, "No open socket for remote");
        }

        has_socket
    }

    /// Handle the [`IpPacket`].
    ///
    /// This function only inserts the packet into a buffer.
    /// To actually process the packets in the buffer, [`Client::handle_timeout`] must be called.
    pub fn handle_inbound(&mut self, packet: IpPacket) {
        debug_assert!(self.accepts(&packet));

        self.device.receive(packet);
    }

    /// Returns [`IpPacket`]s that should be sent.
    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.device.next_send()
    }

    /// Returns the next [`QueryResult`].
    pub fn poll_query_result(&mut self) -> Option<QueryResult> {
        self.query_results.pop_front()
    }

    /// Inform the client that time advanced.
    ///
    /// Typical for a sans-IO design, `handle_timeout` will work through all local buffers and process them as much as possible.
    pub fn handle_timeout(&mut self, now: Instant) {
        let Some((ipv4_source, ipv6_source)) = self.source_ips else {
            return;
        };

        let changed = self.interface.poll(
            smoltcp::time::Instant::from(now),
            &mut self.device,
            &mut self.sockets,
        );

        if !changed && self.pending_queries_by_remote.is_empty() {
            return;
        }

        for (remote, handle) in self.sockets_by_remote.iter_mut() {
            let socket = self.sockets.get_mut::<Socket>(*handle);
            let server = *remote;

            // First, attempt to send all pending queries on this socket.
            send_pending_queries(
                socket,
                server,
                &mut self.pending_queries_by_remote,
                &mut self.sent_queries_by_remote,
                &mut self.query_results,
            );

            // Second, attempt to receive responses.
            recv_responses(
                socket,
                server,
                &mut self.pending_queries_by_remote,
                &mut self.sent_queries_by_remote,
                &mut self.query_results,
            );

            let has_pending_dns_queries = !self
                .pending_queries_by_remote
                .entry(server)
                .or_default()
                .is_empty();

            // Third, if the socket got closed, reconnect it.
            if matches!(socket.state(), tcp::State::Closed) && has_pending_dns_queries {
                let local_port = self
                    .local_ports_by_socket
                    .get(handle)
                    .expect("must always have a port for each socket");
                let local_endpoint = match server {
                    SocketAddr::V4(_) => SocketAddr::new(ipv4_source.into(), *local_port),
                    SocketAddr::V6(_) => SocketAddr::new(ipv6_source.into(), *local_port),
                };

                tracing::info!(local = %local_endpoint, remote = %server, "Re-connecting to DNS resolver");

                socket
                    .connect(self.interface.context(), server, local_endpoint)
                    .expect(
                        "re-connecting a closed socket with the same parameters should always work",
                    );
            }
        }
    }

    fn sample_unique_ports(&mut self, num_ports: usize) -> Result<impl Iterator<Item = u16>> {
        let mut ports = HashSet::with_capacity(num_ports);
        let range = MIN_PORT..=MAX_PORT;

        if num_ports > range.len() {
            bail!(
                "Port range only provides {} values but we need {num_ports}",
                range.len()
            )
        }

        while ports.len() < num_ports {
            ports.insert(self.rng.gen_range(range.clone()));
        }

        Ok(ports.into_iter())
    }
}

fn send_pending_queries(
    socket: &mut Socket,
    server: SocketAddr,
    pending_queries_by_remote: &mut HashMap<SocketAddr, VecDeque<Message<Vec<u8>>>>,
    sent_queries_by_remote: &mut HashMap<SocketAddr, HashMap<u16, Message<Vec<u8>>>>,
    query_results: &mut VecDeque<QueryResult>,
) {
    let pending_queries = pending_queries_by_remote.entry(server).or_default();
    let sent_queries = sent_queries_by_remote.entry(server).or_default();

    loop {
        if !socket.can_send() {
            break;
        }

        let Some(query) = pending_queries.pop_front() else {
            break;
        };

        match codec::try_send(socket, query.for_slice_ref()).context("Failed to send DNS query") {
            Ok(()) => {
                let replaced = sent_queries.insert(query.header().id(), query).is_some();
                debug_assert!(!replaced, "Query ID is not unique");
            }
            Err(e) => {
                // We failed to send the query, declare the socket as failed.
                socket.abort();

                query_results.extend(into_failed_results(
                    server,
                    pending_queries
                        .drain(..)
                        .chain(sent_queries.drain().map(|(_, query)| query)),
                    || anyhow!("{e:#}"),
                ));
                query_results.push_back(QueryResult {
                    query,
                    server,
                    result: Err(e),
                });
            }
        }
    }
}

fn recv_responses(
    socket: &mut Socket,
    server: SocketAddr,
    pending_queries_by_remote: &mut HashMap<SocketAddr, VecDeque<Message<Vec<u8>>>>,
    sent_queries_by_remote: &mut HashMap<SocketAddr, HashMap<u16, Message<Vec<u8>>>>,
    query_results: &mut VecDeque<QueryResult>,
) {
    let Some(result) = try_recv_response(socket)
        .context("Failed to receive DNS response")
        .transpose()
    else {
        return; // No messages on this socket, continue.
    };
    let pending_queries = pending_queries_by_remote.entry(server).or_default();
    let sent_queries = sent_queries_by_remote.entry(server).or_default();

    let new_results = result
        .and_then(|response| {
            let query = sent_queries
                .remove(&response.header().id())
                .context("DNS resolver sent response for unknown query")?;

            Ok(vec![QueryResult {
                query,
                server,
                result: Ok(response.octets_into()),
            }])
        })
        .unwrap_or_else(|e| {
            socket.abort();

            into_failed_results(
                server,
                pending_queries
                    .drain(..)
                    .chain(sent_queries.drain().map(|(_, query)| query)),
                || anyhow!("{e:#}"),
            )
            .collect()
        });

    query_results.extend(new_results);
}

fn into_failed_results(
    server: SocketAddr,
    iter: impl IntoIterator<Item = Message<Vec<u8>>>,
    make_error: impl Fn() -> anyhow::Error,
) -> impl Iterator<Item = QueryResult> {
    iter.into_iter().map(move |query| QueryResult {
        query,
        server,
        result: Err(make_error()),
    })
}

fn try_recv_response<'b>(socket: &'b mut tcp::Socket) -> Result<Option<Message<&'b [u8]>>> {
    anyhow::ensure!(socket.is_active(), "Socket is not active");

    if !socket.can_recv() {
        tracing::trace!("Not yet ready to receive next message");

        return Ok(None);
    }

    let Some(message) = codec::try_recv(socket)? else {
        return Ok(None);
    };

    anyhow::ensure!(message.header().qr(), "DNS message is a query!");

    Ok(Some(message))
}
