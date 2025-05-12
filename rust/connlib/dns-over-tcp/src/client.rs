use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

use crate::{
    codec, create_tcp_socket, interface::create_interface, stub_device::InMemoryDevice,
    time::smol_now,
};
use anyhow::{Context as _, Result, anyhow, bail};
use ip_packet::IpPacket;
use rand::{Rng, SeedableRng, rngs::StdRng};
use smoltcp::{
    iface::{Interface, PollResult, SocketSet},
    socket::tcp,
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
    sockets_by_remote: BTreeMap<SocketAddr, smoltcp::iface::SocketHandle>,
    local_ports_by_socket: HashMap<smoltcp::iface::SocketHandle, u16>,
    /// Queries we should send to a DNS resolver.
    pending_queries_by_remote: HashMap<SocketAddr, VecDeque<dns_types::Query>>,
    /// Queries we have sent to a DNS resolver and are waiting for a reply.
    sent_queries_by_remote: HashMap<SocketAddr, HashMap<u16, dns_types::Query>>,

    query_results: VecDeque<QueryResult>,

    rng: StdRng,

    created_at: Instant,
    last_now: Instant,
}

#[derive(Debug)]
pub struct QueryResult {
    pub query: dns_types::Query,
    pub server: SocketAddr,
    pub result: Result<dns_types::Response>,
}

impl<const MIN_PORT: u16, const MAX_PORT: u16> Client<MIN_PORT, MAX_PORT> {
    pub fn new(now: Instant, seed: [u8; 32]) -> Self {
        // Sadly, these can't be compile-time assertions :(
        assert!(MIN_PORT >= 49152, "Must use ephemeral port range");
        assert!(MIN_PORT < MAX_PORT, "Port range must not have length 0");

        let mut device = InMemoryDevice::default();
        let interface = create_interface(&mut device);

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
            created_at: now,
            last_now: now,
        }
    }

    /// Sets the IPv4 and IPv6 source ips to use for outgoing packets.
    pub fn set_source_interface(&mut self, v4: Ipv4Addr, v6: Ipv6Addr) {
        self.source_ips = Some((v4, v6));
    }

    /// Send the given DNS query to the target server.
    ///
    /// This only queues the message. You need to call [`Client::handle_timeout`] to actually send them.
    pub fn send_query(&mut self, server: SocketAddr, message: dns_types::Query) -> Result<()> {
        self.pending_queries_by_remote
            .entry(server)
            .or_default()
            .push_back(message);

        if self.sockets_by_remote.contains_key(&server) {
            return Ok(());
        };

        let local_port = self.sample_new_unique_port()?;

        let (ipv4_source, ipv6_source) = self
            .source_ips
            .ok_or_else(|| anyhow!("No source interface set"))?;

        let local_endpoint = match server {
            SocketAddr::V4(_) => SocketAddr::new(ipv4_source.into(), local_port),
            SocketAddr::V6(_) => SocketAddr::new(ipv6_source.into(), local_port),
        };

        let handle = self.sockets.add(create_tcp_socket());

        self.sockets_by_remote.insert(server, handle);
        self.local_ports_by_socket
            .insert(handle, local_endpoint.port());

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
        self.last_now = now;
        let Some((ipv4_source, ipv6_source)) = self.source_ips else {
            return;
        };

        let result = self.interface.poll(
            smol_now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );

        if result == PollResult::None && self.pending_queries_by_remote.is_empty() {
            return;
        }

        for (remote, handle) in self.sockets_by_remote.iter_mut() {
            let _guard = tracing::trace_span!("socket", %handle).entered();

            let socket = self.sockets.get_mut::<tcp::Socket>(*handle);
            let server = *remote;

            let pending_queries = self.pending_queries_by_remote.entry(server).or_default();
            let sent_queries = self.sent_queries_by_remote.entry(server).or_default();

            // First, attempt to send all pending queries on this socket.
            send_pending_queries(
                socket,
                server,
                pending_queries,
                sent_queries,
                &mut self.query_results,
            );

            // Second, attempt to receive responses.
            recv_responses(
                socket,
                server,
                pending_queries,
                sent_queries,
                &mut self.query_results,
            );

            // Third, if the socket got closed, reconnect it.
            if matches!(socket.state(), tcp::State::Closed) && !pending_queries.is_empty() {
                let local_port = self
                    .local_ports_by_socket
                    .get(handle)
                    .expect("must always have a port for each socket");
                let local_endpoint = match server {
                    SocketAddr::V4(_) => SocketAddr::new(ipv4_source.into(), *local_port),
                    SocketAddr::V6(_) => SocketAddr::new(ipv6_source.into(), *local_port),
                };

                if let Err(error) = socket
                    .connect(self.interface.context(), server, local_endpoint)
                    .context("Failed to connect to upstream resolver")
                {
                    self.query_results.extend(fail_all_queries(
                        &error,
                        server,
                        pending_queries,
                        sent_queries,
                    ));
                    continue;
                }

                tracing::info!(local = %local_endpoint, remote = %server, "Connecting to DNS resolver");
            }
        }
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        let now = smol_now(self.created_at, self.last_now);

        let poll_in = self.interface.poll_delay(now, &self.sockets)?;

        Some(self.last_now + Duration::from(poll_in))
    }

    pub fn reset(&mut self) {
        tracing::debug!("Resetting state");

        let aborted_pending_queries =
            self.pending_queries_by_remote
                .drain()
                .flat_map(|(server, queries)| {
                    into_failed_results(server, queries, || anyhow!("Aborted"))
                });
        let aborted_sent_queries =
            self.sent_queries_by_remote
                .drain()
                .flat_map(|(server, queries)| {
                    into_failed_results(server, queries.into_values(), || anyhow!("Aborted"))
                });

        self.query_results
            .extend(aborted_pending_queries.chain(aborted_sent_queries));

        self.sockets = SocketSet::new(vec![]);
        self.sockets_by_remote.clear();
        self.local_ports_by_socket.clear();
    }

    fn sample_new_unique_port(&mut self) -> Result<u16> {
        let used_ports = self
            .local_ports_by_socket
            .values()
            .copied()
            .collect::<HashSet<_>>();

        let range = MIN_PORT..=MAX_PORT;

        if used_ports.len() == range.len() {
            bail!("All ports exhausted")
        }

        loop {
            let port = self.rng.gen_range(range.clone());

            if !used_ports.contains(&port) {
                return Ok(port);
            }
        }
    }
}

fn send_pending_queries(
    socket: &mut tcp::Socket,
    server: SocketAddr,
    pending_queries: &mut VecDeque<dns_types::Query>,
    sent_queries: &mut HashMap<u16, dns_types::Query>,
    query_results: &mut VecDeque<QueryResult>,
) {
    loop {
        if !socket.can_send() {
            break;
        }

        let Some(query) = pending_queries.pop_front() else {
            break;
        };

        match codec::try_send(socket, query.as_bytes()).context("Failed to send DNS query") {
            Ok(()) => {
                let replaced = sent_queries.insert(query.id(), query).is_some();
                debug_assert!(!replaced, "Query ID is not unique");
            }
            Err(e) => {
                // We failed to send the query, declare the socket as failed.
                socket.abort();

                query_results.extend(fail_all_queries(&e, server, pending_queries, sent_queries));
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
    socket: &mut tcp::Socket,
    server: SocketAddr,
    pending_queries: &mut VecDeque<dns_types::Query>,
    sent_queries: &mut HashMap<u16, dns_types::Query>,
    query_results: &mut VecDeque<QueryResult>,
) {
    let Some(result) = try_recv_response(socket)
        .context("Failed to receive DNS response")
        .transpose()
    else {
        return; // No messages on this socket, continue.
    };

    let new_results = result
        .and_then(|response| {
            let query = sent_queries
                .remove(&response.id())
                .context("DNS resolver sent response for unknown query")?;

            Ok(vec![QueryResult {
                query,
                server,
                result: Ok(response),
            }])
        })
        .unwrap_or_else(|e| {
            socket.abort();

            fail_all_queries(&e, server, pending_queries, sent_queries).collect()
        });

    query_results.extend(new_results);
}

fn fail_all_queries<'a>(
    error: &'a anyhow::Error,
    server: SocketAddr,
    pending_queries: &'a mut VecDeque<dns_types::Query>,
    sent_queries: &'a mut HashMap<u16, dns_types::Query>,
) -> impl Iterator<Item = QueryResult> + 'a {
    let pending_queries = pending_queries.drain(..);
    let sent_queries = sent_queries.drain().map(|(_, query)| query);
    let queries = pending_queries.chain(sent_queries);

    into_failed_results(server, queries, move || anyhow!("{error:#}"))
}

fn into_failed_results(
    server: SocketAddr,
    iter: impl IntoIterator<Item = dns_types::Query>,
    make_error: impl Fn() -> anyhow::Error,
) -> impl Iterator<Item = QueryResult> {
    iter.into_iter().map(move |query| QueryResult {
        query,
        server,
        result: Err(make_error()),
    })
}

fn try_recv_response(socket: &mut tcp::Socket) -> Result<Option<dns_types::Response>> {
    if !socket.can_recv() {
        tracing::trace!(state = %socket.state(), "Not yet ready to receive next message");

        return Ok(None);
    }

    let maybe_response = codec::try_recv(socket)?;

    Ok(maybe_response)
}
