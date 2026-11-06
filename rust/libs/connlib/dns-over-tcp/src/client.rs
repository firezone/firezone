use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

use crate::codec;
use anyhow::{Context as _, Result, anyhow, bail};
use ip_packet::{IpPacket, Layer4Protocol};
use l3_tcp::{
    InMemoryDevice, Interface, PollResult, SocketSet, create_interface, create_tcp_socket,
};
use rand::{RngExt, SeedableRng, rngs::StdRng};

/// How many remotes of closed connections we remember at once.
///
/// A late ICMP error for a closed connection is consumed instead of surfacing on the TUN device.
const MAX_CLOSED_REMOTES: usize = 32;

/// A sans-io DNS-over-TCP client.
///
/// The client maintains a single TCP connection for each configured resolver.
/// If the TCP connection fails for some reason, we try to establish a new one.
///
/// One of the design goals of this client is to always provide a result for a query.
/// If the TCP connection fails, we report all currently pending queries to that resolver as failed.
///
/// Because all queries to a resolver share a single TCP connection,
/// queries are sent upstream with a rewritten, locally-unique query ID.
/// Stub resolvers may issue concurrent queries with overlapping IDs (some always use ID 1 for TCP).
/// Responses are translated back to the original query ID before they are surfaced as a [`QueryResult`].
pub struct Client<const MIN_PORT: u16 = 49152, const MAX_PORT: u16 = 65535> {
    device: InMemoryDevice,
    interface: Interface,
    source_ips: Option<(Ipv4Addr, Ipv6Addr)>,

    sockets: SocketSet<'static>,
    /// The TCP socket for each remote, or `None` for a connection that [`Client::reset`] dropped.
    ///
    /// Closed remotes are kept so late ICMP errors for them are still consumed.
    sockets_by_remote: BTreeMap<SocketAddr, Option<l3_tcp::SocketHandle>>,
    local_ports_by_socket: BTreeMap<l3_tcp::SocketHandle, u16>,
    /// Queries we should send to a DNS resolver.
    pending_queries_by_remote_and_local: BTreeMap<(SocketAddr, SocketAddr), VecDeque<PendingQuery>>,
    /// Queries we have sent to a DNS resolver and are waiting for a reply, keyed by their wire ID.
    sent_queries_by_remote_and_local:
        BTreeMap<(SocketAddr, SocketAddr), BTreeMap<u16, PendingQuery>>,

    query_results: VecDeque<QueryResult>,

    next_token: u64,

    rng: StdRng,

    query_timeout: Duration,

    created_at: Instant,
    last_now: Instant,
}

#[derive(Debug)]
struct PendingQuery {
    query: dns_types::Query,
    /// The query ID we use on the wire towards the resolver.
    ///
    /// Unique per connection, unlike the ID of the original query.
    wire_id: u16,
    token: QueryToken,
    deadline: Instant,
}

/// Identifies a query issued through a [`Client`].
///
/// Unlike the ID of a DNS message, this is unique among all queries the client ever issues.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct QueryToken(u64);

#[derive(Debug)]
pub struct QueryResult {
    /// The token returned by [`Client::send_query`] for this query.
    pub token: QueryToken,
    pub query: dns_types::Query,
    pub server: SocketAddr,
    pub result: Result<dns_types::Response>,
}

impl<const MIN_PORT: u16, const MAX_PORT: u16> Client<MIN_PORT, MAX_PORT> {
    pub fn new(now: Instant, query_timeout: Duration, seed: [u8; 32]) -> Self {
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
            sent_queries_by_remote_and_local: Default::default(),
            query_results: Default::default(),
            next_token: 0,
            rng: StdRng::from_seed(seed),
            sockets_by_remote: Default::default(),
            local_ports_by_socket: Default::default(),
            pending_queries_by_remote_and_local: Default::default(),
            query_timeout,
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
    ///
    /// Returns a [`QueryToken`] which is echoed back in the corresponding [`QueryResult`].
    pub fn send_query(
        &mut self,
        server: SocketAddr,
        message: dns_types::Query,
    ) -> Result<QueryToken> {
        let (ipv4_source, ipv6_source) = self
            .source_ips
            .ok_or_else(|| anyhow!("No source interface set"))?;

        let deadline = self.last_now + self.query_timeout;
        let token = QueryToken(self.next_token);
        self.next_token += 1;

        if let Some(Some(s)) = self.sockets_by_remote.get(&server)
            && let Some(local_port) = self.local_ports_by_socket.get(s).copied()
        {
            let local_endpoint = local_endpoint(server, ipv4_source, ipv6_source, local_port);
            let wire_id = self.sample_new_unique_query_id(server, local_endpoint)?;

            self.pending_queries_by_remote_and_local
                .entry((server, local_endpoint))
                .or_default()
                .push_back(PendingQuery {
                    query: message,
                    wire_id,
                    token,
                    deadline,
                });

            return Ok(token);
        };

        let local_port = self.sample_new_unique_port()?;
        let local_endpoint = local_endpoint(server, ipv4_source, ipv6_source, local_port);
        let wire_id = self.sample_new_unique_query_id(server, local_endpoint)?;

        self.pending_queries_by_remote_and_local
            .entry((server, local_endpoint))
            .or_default()
            .push_back(PendingQuery {
                query: message,
                wire_id,
                token,
                deadline,
            });

        let mut socket = create_tcp_socket();
        socket.set_timeout(Some(self.query_timeout.into()));

        let handle = self.sockets.add(socket);

        self.sockets_by_remote.insert(server, Some(handle));
        self.local_ports_by_socket.insert(handle, local_port);

        Ok(token)
    }

    /// Checks whether this client can handle the given packet.
    ///
    /// Only TCP packets originating from one of the connected DNS resolvers are accepted.
    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some((ipv4_source, ipv6_source)) = self.source_ips else {
            #[cfg(debug_assertions)]
            tracing::trace!("No source interface");

            return false;
        };

        // If the packet doesn't match our source interface, we don't want it.
        match packet.destination() {
            IpAddr::V4(v4) if v4 != ipv4_source => return false,
            IpAddr::V6(v6) if v6 != ipv6_source => return false,
            IpAddr::V4(_) | IpAddr::V6(_) => {}
        }

        if let Ok(Some((failed_packet, _))) = packet.icmp_error()
            && let Layer4Protocol::Tcp { dst, .. } = failed_packet.layer4_protocol()
            && self
                .sockets_by_remote
                .contains_key(&SocketAddr::new(failed_packet.dst(), dst))
        {
            return true;
        }

        let Some(tcp) = packet.as_tcp() else {
            #[cfg(debug_assertions)]
            tracing::trace!(?packet, "Not a TCP packet");

            return false;
        };

        let remote = SocketAddr::new(packet.source(), tcp.source_port());
        let has_socket = self.sockets_by_remote.contains_key(&remote);

        #[cfg(debug_assertions)]
        if !has_socket && tracing::enabled!(tracing::Level::TRACE) {
            let open_sockets =
                std::collections::BTreeSet::from_iter(self.sockets_by_remote.keys().copied());

            tracing::trace!(%remote, ?open_sockets, "No open socket for remote");
        }

        has_socket
    }

    /// Checks whether the given outbound packet belongs to one of our upstream connections.
    ///
    /// Matches packets from our source interface to a connected DNS resolver,
    /// i.e. the reverse direction of [`Client::accepts`].
    pub fn owns_outbound(&self, packet: &IpPacket) -> bool {
        let Some((ipv4_source, ipv6_source)) = self.source_ips else {
            return false;
        };

        match packet.source() {
            IpAddr::V4(v4) if v4 != ipv4_source => return false,
            IpAddr::V6(v6) if v6 != ipv6_source => return false,
            IpAddr::V4(_) | IpAddr::V6(_) => {}
        }

        let Some(tcp) = packet.as_tcp() else {
            return false;
        };

        self.sockets_by_remote
            .get(&SocketAddr::new(
                packet.destination(),
                tcp.destination_port(),
            ))
            .is_some_and(|socket| socket.is_some())
    }

    /// Handle the [`IpPacket`].
    ///
    /// This function only inserts the packet into a buffer.
    /// To actually process the packets in the buffer, [`Client::handle_timeout`] must be called.
    pub fn handle_inbound(&mut self, packet: IpPacket) {
        debug_assert!(self.accepts(&packet));

        if let Ok(Some((failed_packet, icmp_error))) = packet.icmp_error()
            && let Layer4Protocol::Tcp { dst, .. } = failed_packet.layer4_protocol()
            && let server = SocketAddr::new(failed_packet.dst(), dst)
            && let Some(maybe_socket) = self.sockets_by_remote.get(&server)
            && let Some((ipv4_source, ipv6_source)) = self.source_ips
        {
            let Some(handle) = maybe_socket else {
                // The connection was dropped by `reset`; its queries have already been failed.
                tracing::debug!(%server, "Ignoring ICMP error for closed connection");

                return;
            };

            let socket = self.sockets.get_mut::<l3_tcp::Socket>(*handle);
            socket.abort();

            let local_port = *self
                .local_ports_by_socket
                .get(handle)
                .expect("must always have a port for each socket");

            let local_endpoint = local_endpoint(server, ipv4_source, ipv6_source, local_port);

            let pending_queries = self
                .pending_queries_by_remote_and_local
                .entry((server, local_endpoint))
                .or_default();
            let sent_queries = self
                .sent_queries_by_remote_and_local
                .entry((server, local_endpoint))
                .or_default();

            self.query_results.extend(fail_all_queries(
                &anyhow!("Received ICMP error for DNS query: {icmp_error}"),
                server,
                pending_queries,
                sent_queries,
            ));

            return;
        }

        // A late packet for a connection that [`Client::reset`] dropped, e.g. a
        // retransmission or teardown of the old connection. No socket exists for
        // it, so there is nothing to receive it.
        if let Some(tcp) = packet.as_tcp()
            && let remote = SocketAddr::new(packet.source(), tcp.source_port())
            && let Some(None) = self.sockets_by_remote.get(&remote)
        {
            tracing::debug!(%remote, "Ignoring packet for closed connection");

            return;
        }

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
        self.fail_expired_queries(now);

        let Some((ipv4_source, ipv6_source)) = self.source_ips else {
            return;
        };

        let result = self.interface.poll(
            l3_tcp::now(self.created_at, now),
            &mut self.device,
            &mut self.sockets,
        );

        if result == PollResult::None && self.pending_queries_by_remote_and_local.is_empty() {
            return;
        }

        for (remote, maybe_socket) in self.sockets_by_remote.iter_mut() {
            let Some(handle) = maybe_socket else {
                continue;
            };

            let _guard = tracing::trace_span!("socket", %handle).entered();

            let socket = self.sockets.get_mut::<l3_tcp::Socket>(*handle);
            let server = *remote;
            let local_port = *self
                .local_ports_by_socket
                .get(handle)
                .expect("must always have a port for each socket");
            let local_endpoint = local_endpoint(server, ipv4_source, ipv6_source, local_port);

            let pending_queries = self
                .pending_queries_by_remote_and_local
                .entry((server, local_endpoint))
                .or_default();
            let sent_queries = self
                .sent_queries_by_remote_and_local
                .entry((server, local_endpoint))
                .or_default();

            // First, attempt to receive responses.
            recv_responses(
                socket,
                server,
                pending_queries,
                sent_queries,
                &mut self.query_results,
            );

            // Second, if the resolver closed the connection, it will not answer anything else on it.
            // Resolvers close idle connections, so send the queries it did not answer again on a new connection.
            if matches!(socket.state(), l3_tcp::State::CloseWait) {
                tracing::debug!(%server, "DNS resolver closed the connection");

                socket.abort();
            }
            if matches!(socket.state(), l3_tcp::State::Closed) {
                for (_, query) in std::mem::take(sent_queries).into_iter().rev() {
                    pending_queries.push_front(query);
                }
            }

            // Third, attempt to send all pending queries on this socket.
            send_pending_queries(
                socket,
                server,
                pending_queries,
                sent_queries,
                &mut self.query_results,
            );

            // Fourth, if the socket got closed, reconnect it.
            if matches!(socket.state(), l3_tcp::State::Closed) && !pending_queries.is_empty() {
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
        let now = l3_tcp::now(self.created_at, self.last_now);

        let interface_timeout = self
            .interface
            .poll_delay(now, &self.sockets)
            .map(|poll_in| self.last_now + Duration::from(poll_in));
        let pending_deadlines = self
            .pending_queries_by_remote_and_local
            .values()
            .flat_map(|q| q.iter().map(|qq| qq.deadline));
        let sent_deadlines = self
            .sent_queries_by_remote_and_local
            .values()
            .flat_map(|q| q.values().map(|qq| qq.deadline));

        iter::empty()
            .chain(interface_timeout)
            .chain(pending_deadlines)
            .chain(sent_deadlines)
            .min()
    }

    fn fail_expired_queries(&mut self, now: Instant) {
        for ((server, _), queries) in self.pending_queries_by_remote_and_local.iter_mut() {
            while let Some(queued) = queries.pop_front_if(|pq| pq.deadline <= now) {
                let res = QueryResult {
                    token: queued.token,
                    query: queued.query,
                    server: *server,
                    result: Err(anyhow!(
                        "DNS query timed out after {:?}",
                        self.query_timeout
                    )),
                };

                self.query_results.push_back(logging::dbg!(res));
            }
        }

        for ((server, _), queries) in self.sent_queries_by_remote_and_local.iter_mut() {
            self.query_results
                .extend(
                    queries
                        .extract_if(.., |_, pq| pq.deadline <= now)
                        .map(|(_, queued)| QueryResult {
                            token: queued.token,
                            query: queued.query,
                            server: *server,
                            result: Err(anyhow!(
                                "DNS query timed out after {:?}",
                                self.query_timeout
                            )),
                        }),
                );
        }
    }

    pub fn reset(&mut self) {
        tracing::debug!("Resetting state");

        let aborted_pending_queries = std::mem::take(&mut self.pending_queries_by_remote_and_local)
            .into_iter()
            .flat_map(|((server, _), queries)| {
                into_failed_results(server, queries, || anyhow!("Aborted"))
            });
        let aborted_sent_queries = std::mem::take(&mut self.sent_queries_by_remote_and_local)
            .into_iter()
            .flat_map(|((server, _), queries)| {
                into_failed_results(server, queries.into_values(), || anyhow!("Aborted"))
            });

        self.query_results
            .extend(aborted_pending_queries.chain(aborted_sent_queries));

        self.sockets = SocketSet::new(vec![]);
        self.local_ports_by_socket.clear();

        for maybe_socket in self.sockets_by_remote.values_mut() {
            *maybe_socket = None;
        }
        while self.sockets_by_remote.len() > MAX_CLOSED_REMOTES {
            self.sockets_by_remote.pop_first();
        }
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
            let port = self.rng.random_range(range.clone());

            if !used_ports.contains(&port) {
                return Ok(port);
            }
        }
    }

    /// Samples a wire ID that is unique among all in-flight queries on the given connection.
    fn sample_new_unique_query_id(&mut self, server: SocketAddr, local: SocketAddr) -> Result<u16> {
        let pending = self
            .pending_queries_by_remote_and_local
            .get(&(server, local));
        let sent = self.sent_queries_by_remote_and_local.get(&(server, local));

        let num_in_flight = pending.map_or(0, VecDeque::len) + sent.map_or(0, BTreeMap::len);

        if num_in_flight > u16::MAX as usize {
            bail!("All query IDs exhausted")
        }

        loop {
            let id = self.rng.random::<u16>();

            let in_pending = pending.is_some_and(|q| q.iter().any(|pq| pq.wire_id == id));
            let in_sent = sent.is_some_and(|q| q.contains_key(&id));

            if !in_pending && !in_sent {
                return Ok(id);
            }
        }
    }
}

fn local_endpoint(
    server: SocketAddr,
    ipv4_source: Ipv4Addr,
    ipv6_source: Ipv6Addr,
    local_port: u16,
) -> SocketAddr {
    match server {
        SocketAddr::V4(_) => SocketAddr::new(ipv4_source.into(), local_port),
        SocketAddr::V6(_) => SocketAddr::new(ipv6_source.into(), local_port),
    }
}

fn send_pending_queries(
    socket: &mut l3_tcp::Socket,
    server: SocketAddr,
    pending_queries: &mut VecDeque<PendingQuery>,
    sent_queries: &mut BTreeMap<u16, PendingQuery>,
    query_results: &mut VecDeque<QueryResult>,
) {
    loop {
        if !socket.can_send() {
            break;
        }

        let Some(pending) = pending_queries.pop_front() else {
            break;
        };

        let wire_query = pending.query.clone().with_id(pending.wire_id);

        match codec::try_send(socket, wire_query.as_bytes()).context("Failed to send DNS query") {
            Ok(()) => {
                let replaced = sent_queries.insert(pending.wire_id, pending).is_some();
                debug_assert!(!replaced, "Wire ID is not unique");
            }
            Err(e) => {
                // We failed to send the query, declare the socket as failed.
                socket.abort();

                query_results.extend(fail_all_queries(&e, server, pending_queries, sent_queries));
                query_results.push_back(QueryResult {
                    token: pending.token,
                    query: pending.query,
                    server,
                    result: Err(e),
                });
            }
        }
    }
}

fn recv_responses(
    socket: &mut l3_tcp::Socket,
    server: SocketAddr,
    pending_queries: &mut VecDeque<PendingQuery>,
    sent_queries: &mut BTreeMap<u16, PendingQuery>,
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
            let queued = sent_queries
                .remove(&response.id())
                .context("DNS resolver sent response for unknown query")?;

            let original_id = queued.query.id();

            Ok(vec![QueryResult {
                token: queued.token,
                query: queued.query,
                server,
                result: Ok(response.with_id(original_id)),
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
    pending_queries: &'a mut VecDeque<PendingQuery>,
    sent_queries: &'a mut BTreeMap<u16, PendingQuery>,
) -> impl Iterator<Item = QueryResult> + 'a {
    let pending_queries = pending_queries.drain(..);
    let sent_queries = std::mem::take(sent_queries).into_values();
    let queries = pending_queries.chain(sent_queries);

    into_failed_results(server, queries, move || anyhow!("{error:#}"))
}

fn into_failed_results(
    server: SocketAddr,
    iter: impl IntoIterator<Item = PendingQuery>,
    make_error: impl Fn() -> anyhow::Error,
) -> impl Iterator<Item = QueryResult> {
    iter.into_iter().map(move |queued| QueryResult {
        token: queued.token,
        query: queued.query,
        server,
        result: Err(make_error()),
    })
}

fn try_recv_response(socket: &mut l3_tcp::Socket) -> Result<Option<dns_types::Response>> {
    if !socket.can_recv() {
        tracing::trace!(state = %socket.state(), "Not yet ready to receive next message");

        return Ok(None);
    }

    let maybe_response = codec::try_recv(socket)?;

    Ok(maybe_response)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_icmp_error_for_pending_query() {
        let _guard = logging::test("trace");

        let now = Instant::now();
        let mut client = create_test_client(now);
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let query = create_test_query();

        let token = client.send_query(server, query.clone()).unwrap();
        client.handle_timeout(now);
        client.handle_timeout(now);

        let packet = client.poll_outbound().unwrap();
        let icmp_error_response = ip_packet::make::icmp_dest_unreachable_network(&packet).unwrap();

        client.handle_inbound(icmp_error_response);

        let query_result = client.poll_query_result().unwrap();

        assert_eq!(query_result.query.id(), query.id());
        assert_eq!(query_result.query.domain(), query.domain());
        assert_eq!(query_result.token, token);
        assert_eq!(query_result.server, server);
        assert_eq!(
            query_result.result.unwrap_err().to_string(),
            "Received ICMP error for DNS query: Destination is unreachable (code: 0)"
        );
    }

    #[test]
    fn consumes_icmp_error_for_reset_connection() {
        let _guard = logging::test("trace");

        let now = Instant::now();
        let mut client = create_test_client(now);
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);

        client.send_query(server, create_test_query()).unwrap();
        client.handle_timeout(now);
        client.handle_timeout(now);

        let packet = client.poll_outbound().unwrap();
        let icmp_error_response = ip_packet::make::icmp_dest_unreachable_network(&packet).unwrap();

        client.reset();
        while client.poll_query_result().is_some() {} // Drain the `Aborted` results.

        assert!(client.accepts(&icmp_error_response));

        client.handle_inbound(icmp_error_response);

        assert!(client.poll_query_result().is_none());
    }

    #[test]
    fn consumes_late_packet_for_reset_connection() {
        let _guard = logging::test("trace");

        let now = Instant::now();
        let mut client = create_test_client(now);
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);

        client.send_query(server, create_test_query()).unwrap();
        client.handle_timeout(now);
        client.handle_timeout(now);
        let local = local_socket(&client.poll_outbound().unwrap());

        client.reset();
        while client.poll_query_result().is_some() {} // Drain the `Aborted` results.

        let late_packet = ip_packet::make::tcp_packet(
            server.ip(),
            local.ip(),
            server.port(),
            local.port(),
            ip_packet::make::TcpFlags {
                syn: false,
                ack: true,
                rst: false,
            },
            &[],
        )
        .unwrap();

        assert!(client.accepts(&late_packet));

        client.handle_inbound(late_packet);
        client.handle_timeout(now);

        assert!(client.poll_outbound().is_none()); // In particular, no RST is sent.
    }

    #[test]
    fn fails_pending_query_with_timeout() {
        let _guard = logging::test("trace");

        let now = Instant::now();
        let mut client = create_test_client(now);
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let query = create_test_query();

        let token = client.send_query(server, query.clone()).unwrap();

        // Advance time past the query deadline without ever delivering a TCP reply.
        client.handle_timeout(now + Duration::from_secs(10) + Duration::from_millis(1));

        let query_result = client.poll_query_result().unwrap();

        assert_eq!(query_result.query.id(), query.id());
        assert_eq!(query_result.token, token);
        assert_eq!(query_result.server, server);
        assert_eq!(
            query_result.result.unwrap_err().to_string(),
            "DNS query timed out after 10s",
        );
    }

    #[test]
    fn reconnects_after_server_closes_idle_connection() {
        let _guard = logging::test("trace");

        let mut now = Instant::now();
        let mut client = create_test_client(now);
        let server_addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)), 53);
        let mut server = ClosingServer::new(server_addr, now);

        client.send_query(server_addr, create_test_query()).unwrap();
        let first = run_until_result(&mut client, &mut server, &mut now);
        assert!(first.result.is_ok());

        server.close_and_forget(&mut client, &mut now);

        let start = now;
        client.send_query(server_addr, create_test_query()).unwrap();
        let second = run_until_result(&mut client, &mut server, &mut now);

        assert!(second.result.is_ok(), "{:?}", second.result);
        assert!(now - start < Duration::from_secs(1));
    }

    #[test]
    fn resends_query_after_server_resets_connection() {
        let _guard = logging::test("trace");

        let mut now = Instant::now();
        let mut client = create_test_client(now);
        let server_addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)), 53);
        let mut server = ClosingServer::new(server_addr, now);

        client.send_query(server_addr, create_test_query()).unwrap();
        run_until_result(&mut client, &mut server, &mut now);

        server.forget();

        let start = now;
        client.send_query(server_addr, create_test_query()).unwrap();
        let result = run_until_result(&mut client, &mut server, &mut now);

        assert!(result.result.is_ok(), "{:?}", result.result);
        assert!(now - start < Duration::from_secs(1));
    }

    fn local_socket(packet: &IpPacket) -> SocketAddr {
        let tcp = packet.as_tcp().unwrap();

        SocketAddr::new(packet.source(), tcp.source_port())
    }

    fn create_test_client(now: Instant) -> Client {
        let seed = [0u8; 32];
        let mut client = Client::new(now, Duration::from_secs(10), seed);
        client.set_source_interface(Ipv4Addr::new(10, 0, 0, 1), Ipv6Addr::LOCALHOST);
        client
    }

    fn create_test_query() -> dns_types::Query {
        use std::str::FromStr;
        let domain = dns_types::DomainName::from_str("example.com").unwrap();
        dns_types::Query::new(domain, dns_types::RecordType::A)
    }

    /// A DNS server that can close its connection and then forget about it, like an OS socket that the application closed.
    struct ClosingServer {
        addr: SocketAddr,
        device: InMemoryDevice,
        interface: Interface,
        sockets: SocketSet<'static>,
        handle: l3_tcp::SocketHandle,
        created_at: Instant,
    }

    impl ClosingServer {
        fn new(addr: SocketAddr, now: Instant) -> Self {
            let mut device = InMemoryDevice::default();
            let interface = create_interface(&mut device);
            let mut sockets = SocketSet::new(Vec::default());
            let handle = sockets.add(listening_socket(addr));

            Self {
                addr,
                device,
                interface,
                sockets,
                handle,
                created_at: now,
            }
        }

        fn handle_timeout(&mut self, now: Instant) {
            self.interface.poll(
                l3_tcp::now(self.created_at, now),
                &mut self.device,
                &mut self.sockets,
            );

            let socket = self.sockets.get_mut::<l3_tcp::Socket>(self.handle);

            if !socket.can_send() {
                return;
            }

            if let Some(query) = codec::try_recv::<dns_types::Query>(socket).unwrap() {
                let response =
                    dns_types::ResponseBuilder::for_query(&query, dns_types::ResponseCode::NOERROR)
                        .build();

                codec::try_send(socket, &response.into_bytes(u16::MAX)).unwrap();
            }
        }

        /// Closes the connection and, once the client received the FIN, forgets the socket.
        ///
        /// Packets for the forgotten connection then get a RST, like they would from an OS.
        fn close_and_forget(&mut self, client: &mut Client, now: &mut Instant) {
            self.sockets.get_mut::<l3_tcp::Socket>(self.handle).close();

            for _ in 0..100 {
                exchange_packets(client, self, *now);
                *now += Duration::from_millis(10);

                if !matches!(
                    self.sockets.get::<l3_tcp::Socket>(self.handle).state(),
                    l3_tcp::State::Established | l3_tcp::State::FinWait1
                ) {
                    break;
                }
            }

            self.forget();
        }

        /// Forgets the connection without closing it, like a restarted server.
        fn forget(&mut self) {
            self.sockets.remove(self.handle);
            self.handle = self.sockets.add(listening_socket(self.addr));
        }
    }

    fn run_until_result(
        client: &mut Client,
        server: &mut ClosingServer,
        now: &mut Instant,
    ) -> QueryResult {
        let deadline = *now + Duration::from_secs(20);

        while *now < deadline {
            exchange_packets(client, server, *now);

            if let Some(result) = client.poll_query_result() {
                return result;
            }

            *now += Duration::from_millis(10);
        }

        panic!("No query result")
    }

    fn exchange_packets(client: &mut Client, server: &mut ClosingServer, now: Instant) {
        client.handle_timeout(now);
        server.handle_timeout(now);

        while let Some(packet) = client.poll_outbound() {
            server.device.receive(packet);
        }
        while let Some(packet) = server.device.next_send() {
            client.handle_inbound(packet);
        }

        client.handle_timeout(now);
        server.handle_timeout(now);
    }

    fn listening_socket(addr: SocketAddr) -> l3_tcp::Socket<'static> {
        let mut socket = create_tcp_socket();
        socket.listen(addr).unwrap();

        socket
    }
}
