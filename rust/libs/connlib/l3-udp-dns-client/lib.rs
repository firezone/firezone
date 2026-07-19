#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    collections::{
        BTreeMap, VecDeque,
        btree_map::{Entry, OccupiedEntry},
    },
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, anyhow, bail};
use ip_packet::{FailedPacket, IpPacket, Layer4Protocol};
use rand::{RngExt, SeedableRng, rngs::StdRng};

const TIMEOUT: Duration = Duration::from_secs(10);

/// How many DNS queries we track at once, in-flight and timed-out ones combined.
///
/// Instead of removing a query when it times out, we keep it around so that a response arriving
/// after we already gave up can still be matched to it and dropped, rather than being forwarded to
/// the TUN device as an unsolicited packet. To stay bounded, reaching this limit evicts the oldest
/// timed-out query first; a new query is only rejected if there is no timed-out query to evict. We
/// don't mind "leaking" a late response for a query evicted long ago; the footprint stays tiny.
const MAX_PENDING_QUERIES: usize = 1024;

/// A sans-io DNS-over-UDP client.
pub struct Client<const MIN_PORT: u16 = 49152, const MAX_PORT: u16 = 65535> {
    source_ips: Option<(Ipv4Addr, Ipv6Addr)>,

    /// Queries we have sent and are tracking, bounded by [`MAX_PENDING_QUERIES`].
    ///
    /// Timed-out queries are retained here (not removed) so a late response can still be matched
    /// and dropped rather than forwarded to the TUN device.
    pending_queries_by_local_port: BTreeMap<u16, PendingQuery>,

    scheduled_queries: VecDeque<IpPacket>,
    query_results: VecDeque<QueryResult>,

    rng: StdRng,
}

struct PendingQuery {
    message: dns_types::Query,
    expires_at: Instant,
    server: SocketAddr,
    local: SocketAddr,
    /// Whether the query already timed out and we surfaced its timeout result.
    ///
    /// Such a query is kept around only to recognise and drop a late response.
    timed_out: bool,
}

#[derive(Debug)]
pub struct QueryResult {
    pub query: dns_types::Query,
    pub local: SocketAddr,
    pub server: SocketAddr,
    pub result: Result<dns_types::Response>,
}

impl<const MIN_PORT: u16, const MAX_PORT: u16> Client<MIN_PORT, MAX_PORT> {
    pub fn new(seed: [u8; 32]) -> Self {
        // Sadly, these can't be compile-time assertions :(
        assert!(MIN_PORT >= 49152, "Must use ephemeral port range");
        assert!(MIN_PORT < MAX_PORT, "Port range must not have length 0");

        Self {
            source_ips: None,
            rng: StdRng::from_seed(seed),
            pending_queries_by_local_port: Default::default(),
            scheduled_queries: Default::default(),
            query_results: Default::default(),
        }
    }

    /// Sets the IPv4 and IPv6 source ips to use for outgoing packets.
    pub fn set_source_interface(&mut self, v4: Ipv4Addr, v6: Ipv6Addr) {
        self.source_ips = Some((v4, v6));
    }

    /// Send the given DNS query to the target server.
    ///
    /// This only queues the message. You need to call [`Client::poll_outbound`] to retrieve
    /// the resulting IP packet and send it to the server.
    pub fn send_query(
        &mut self,
        server: SocketAddr,
        message: dns_types::Query,
        now: Instant,
    ) -> Result<SocketAddr> {
        self.make_room_for_new_query()?;

        let local_port = self.sample_new_unique_port()?;

        let (ipv4_source, ipv6_source) = self
            .source_ips
            .ok_or_else(|| anyhow!("No source interface set"))?;

        let local_ip = match server {
            SocketAddr::V4(_) => IpAddr::V4(ipv4_source),
            SocketAddr::V6(_) => IpAddr::V6(ipv6_source),
        };
        let local_socket = SocketAddr::new(local_ip, local_port);

        self.pending_queries_by_local_port.insert(
            local_port,
            PendingQuery {
                message: message.clone(),
                expires_at: now + TIMEOUT,
                server,
                local: local_socket,
                timed_out: false,
            },
        );

        let payload = message.into_bytes();

        let ip_packet =
            ip_packet::make::udp_packet(local_ip, server.ip(), local_port, server.port(), &payload)
                .context("Failed to make IP packet")?;

        self.scheduled_queries.push_back(ip_packet);

        Ok(local_socket)
    }

    /// Checks whether this client can handle the given packet.
    ///
    /// Only UDP packets for queries we are tracking (still pending or already timed out) are
    /// accepted.
    pub fn accepts(&mut self, packet: &IpPacket) -> bool {
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
            && self.entry_for_failed_packet(&failed_packet).is_some()
        {
            return true;
        }

        let Some(udp) = packet.as_udp() else {
            #[cfg(debug_assertions)]
            tracing::trace!(?packet, "Not a UDP packet");

            return false;
        };

        self.pending_queries_by_local_port
            .contains_key(&udp.destination_port())
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        debug_assert!(self.accepts(&packet));

        if let Ok(Some((failed_packet, icmp_error))) = packet.icmp_error()
            && let Some(entry) = self.entry_for_failed_packet(&failed_packet)
        {
            // We already answered this query on timeout; drop the ICMP error.
            if entry.get().timed_out {
                return;
            }

            let pending_query = entry.remove();
            self.query_results.push_back(QueryResult {
                query: pending_query.message,
                local: pending_query.local,
                server: pending_query.server,
                result: Err(anyhow!("Received ICMP error for DNS query: {icmp_error}")),
            });
            return;
        }

        let Some(udp) = packet.as_udp() else {
            return;
        };

        let result =
            dns_types::Response::parse(udp.payload()).context("Failed to parse DNS response");
        let source = SocketAddr::new(packet.source(), udp.source_port());
        let local_port = udp.destination_port();

        let Some(pending) = self.pending_queries_by_local_port.get(&local_port) else {
            return;
        };
        let server = pending.server;
        let query_id = pending.message.id();

        // Ignore a response that doesn't match the query we sent on this port.
        if let Ok(response) = result.as_ref()
            && (response.id() != query_id || source != server)
        {
            tracing::debug!(%server, %source, %query_id, response_id = %response.id(), "Response from server does not match query ID or original destination");
            return;
        }

        // A query only ever receives a single response, so remove it now that one has arrived.
        let PendingQuery {
            message,
            local,
            timed_out,
            ..
        } = self
            .pending_queries_by_local_port
            .remove(&local_port)
            .expect("to still be present");

        // If the query already timed out, we surfaced its result back then; don't surface another.
        if timed_out {
            tracing::debug!(%server, %query_id, %source, "Dropping late response to timed-out DNS query");
            return;
        }

        self.query_results.push_back(QueryResult {
            query: message,
            local,
            server,
            result,
        });
    }

    /// Returns [`IpPacket`]s that should be sent.
    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.scheduled_queries.pop_front()
    }

    /// Returns the next [`QueryResult`].
    pub fn poll_query_result(&mut self) -> Option<QueryResult> {
        self.query_results.pop_front()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.time_out_queries(|pending| now >= pending.expires_at);
    }

    /// Times out every tracked query for which `should_time_out` returns `true`, surfacing a
    /// timeout result for each.
    ///
    /// Timed-out queries are kept around (rather than removed) so that a late response can still be
    /// matched and dropped instead of being forwarded to the TUN device.
    fn time_out_queries(&mut self, should_time_out: impl Fn(&PendingQuery) -> bool) {
        for pending in self.pending_queries_by_local_port.values_mut() {
            if pending.timed_out || !should_time_out(pending) {
                continue;
            }

            pending.timed_out = true;
            self.query_results.push_back(QueryResult {
                query: pending.message.clone(),
                local: pending.local,
                server: pending.server,
                result: Err(anyhow!("Timeout")),
            });
        }
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        self.pending_queries_by_local_port
            .values()
            .filter(|p| !p.timed_out)
            .map(|p| p.expires_at)
            .min()
    }

    pub fn reset(&mut self) {
        tracing::debug!("Resetting state");

        // Abort every pending query, but keep them around (marked as timed out) so that late
        // responses are still matched and dropped rather than forwarded to the TUN device.
        self.time_out_queries(|_| true);
    }

    /// Ensures there is room to track another query.
    ///
    /// If we are at capacity, the oldest timed-out query is evicted to make room. In-flight queries
    /// are never evicted, so if none have timed out yet, the new query is rejected instead.
    fn make_room_for_new_query(&mut self) -> Result<()> {
        if self.pending_queries_by_local_port.len() < MAX_PENDING_QUERIES {
            return Ok(());
        }

        let oldest_timed_out = self
            .pending_queries_by_local_port
            .iter()
            .filter(|(_, query)| query.timed_out)
            .min_by_key(|(_, query)| query.expires_at)
            .map(|(port, _)| *port);

        let Some(port) = oldest_timed_out else {
            bail!("Too many concurrent DNS queries")
        };

        self.pending_queries_by_local_port.remove(&port);

        Ok(())
    }

    fn sample_new_unique_port(&mut self) -> Result<u16> {
        let range = MIN_PORT..=MAX_PORT;

        // A timed-out query is still tracked in `pending_queries_by_local_port`, so this also
        // ensures we never reuse the port of a query we might still receive a late response for.
        if self.pending_queries_by_local_port.len() == range.len() {
            bail!("All ports exhausted")
        }

        loop {
            let port = self.rng.random_range(range.clone());

            if !self.pending_queries_by_local_port.contains_key(&port) {
                return Ok(port);
            }
        }
    }

    fn entry_for_failed_packet(
        &mut self,
        failed_packet: &FailedPacket,
    ) -> Option<OccupiedEntry<'_, u16, PendingQuery>> {
        let Layer4Protocol::Udp { src, dst } = failed_packet.layer4_protocol() else {
            return None;
        };

        let dst_socket = SocketAddr::new(failed_packet.dst(), dst);
        let Entry::Occupied(entry) = self.pending_queries_by_local_port.entry(src) else {
            return None;
        };

        if entry.get().server != dst_socket {
            return None;
        };

        Some(entry)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_timeout_multiple_queries() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server1 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let server2 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 4, 4)), 53);

        // Send two queries at the same time
        client
            .send_query(server1, create_test_query(), now)
            .unwrap();
        client
            .send_query(server2, create_test_query(), now)
            .unwrap();
        assert_eq!(client.poll_timeout(), Some(now + TIMEOUT));

        // Send third query 10 seconds later
        let later = now + Duration::from_secs(10);
        client
            .send_query(server1, create_test_query(), later)
            .unwrap();

        // poll_timeout should return the earliest timeout
        assert_eq!(client.poll_timeout(), Some(now + TIMEOUT));

        // Advance to after first two timeouts but before third
        client.handle_timeout(now + TIMEOUT + Duration::from_secs(1));

        // First two queries should have timed out
        assert!(client.poll_query_result().unwrap().result.is_err());
        assert!(client.poll_query_result().unwrap().result.is_err());
        assert!(client.poll_query_result().is_none());

        // Third query should still be pending
        assert_eq!(client.poll_timeout(), Some(later + TIMEOUT));

        // Advance past third timeout
        client.handle_timeout(later + TIMEOUT + Duration::from_secs(1));
        assert!(client.poll_query_result().unwrap().result.is_err());
        assert!(client.poll_timeout().is_none());
    }

    #[test]
    fn test_reset_times_out_all_pending_queries() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server1 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let server2 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 4, 4)), 53);
        let query1 = create_test_query();
        let query2 = create_test_query();

        // Send multiple queries
        client.send_query(server1, query1, now).unwrap();
        client.send_query(server2, query2, now).unwrap();

        // Reset should abort all pending queries
        client.reset();

        // Both queries should have error results
        assert!(client.poll_query_result().unwrap().result.is_err());
        assert!(client.poll_query_result().unwrap().result.is_err());
        assert!(client.poll_query_result().is_none());
    }

    #[test]
    fn test_poll_timeout_returns_none_when_no_pending_queries() {
        let mut client = create_test_client();

        // No pending queries, should return None
        assert!(client.poll_timeout().is_none());
    }

    #[test]
    fn handles_icmp_error_for_pending_query() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let query = create_test_query();

        let local = client.send_query(server, query.clone(), now).unwrap();

        let packet = client.poll_outbound().unwrap();
        let icmp_error_response = ip_packet::make::icmp_dest_unreachable_network(&packet).unwrap();

        client.handle_inbound(icmp_error_response);

        let query_result = client.poll_query_result().unwrap();

        assert_eq!(query_result.query.id(), query.id());
        assert_eq!(query_result.query.domain(), query.domain());
        assert_eq!(query_result.local, local);
        assert_eq!(query_result.server, server);
        assert_eq!(
            query_result.result.unwrap_err().to_string(),
            "Received ICMP error for DNS query: Destination is unreachable (code: 0)"
        );
    }

    #[test]
    fn matching_response_to_pending_query_is_returned() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let query = create_test_query();

        let local = client.send_query(server, query.clone(), now).unwrap();
        let response = dns_response_packet(server, local, &query);

        assert!(client.accepts(&response));
        client.handle_inbound(response);

        let result = client.poll_query_result().unwrap();
        assert_eq!(result.query.id(), query.id());
        assert_eq!(result.local, local);
        assert_eq!(result.server, server);
        assert!(result.result.is_ok());
    }

    #[test]
    fn late_response_to_timed_out_query_is_dropped() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let query = create_test_query();

        let local = client.send_query(server, query.clone(), now).unwrap();

        // The query times out before any response arrives.
        client.handle_timeout(now + TIMEOUT + Duration::from_secs(1));
        assert!(client.poll_query_result().unwrap().result.is_err());
        assert!(client.poll_query_result().is_none());

        // A late response finally arrives for the query we already gave up on.
        let late_response = dns_response_packet(server, local, &query);

        // The client still recognises the packet as one of its own ...
        assert!(client.accepts(&late_response));

        // ... but consumes it without surfacing a result or leaking it to the TUN device.
        client.handle_inbound(late_response);
        assert!(client.poll_query_result().is_none());
    }

    #[test]
    fn late_response_after_reset_is_dropped() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);
        let query = create_test_query();

        let local = client.send_query(server, query.clone(), now).unwrap();

        // Resetting aborts the query but keeps it around to recognise a late response.
        client.reset();
        assert!(client.poll_query_result().unwrap().result.is_err());
        assert!(client.poll_query_result().is_none());

        let late_response = dns_response_packet(server, local, &query);
        assert!(client.accepts(&late_response));

        client.handle_inbound(late_response);
        assert!(client.poll_query_result().is_none());
    }

    #[test]
    fn does_not_reuse_the_port_of_a_timed_out_query() {
        // A tiny port range makes the assertion deterministic: with one port timed out, the next
        // query must land on the only other port.
        let mut client = Client::<49152, 49153>::new([0u8; 32]);
        client.set_source_interface(Ipv4Addr::new(10, 0, 0, 1), Ipv6Addr::LOCALHOST);
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);

        let first = client.send_query(server, create_test_query(), now).unwrap();
        client.handle_timeout(now + TIMEOUT + Duration::from_secs(1));

        // The timed-out query is retained, so its port is not sampled again.
        let second = client.send_query(server, create_test_query(), now).unwrap();
        assert_ne!(first.port(), second.port());
    }

    #[test]
    fn evicting_timed_out_queries_keeps_the_map_bounded() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);

        // Fill to capacity, then time everything out.
        for i in 0..MAX_PENDING_QUERIES {
            client
                .send_query(
                    server,
                    create_test_query(),
                    now + Duration::from_millis(i as u64),
                )
                .unwrap();
        }
        client.handle_timeout(now + Duration::from_secs(3600));

        // Further queries evict the oldest timed-out ones instead of growing the map.
        for i in 0..10 {
            client
                .send_query(
                    server,
                    create_test_query(),
                    now + Duration::from_secs(3600 + i),
                )
                .unwrap();
        }

        assert_eq!(
            client.pending_queries_by_local_port.len(),
            MAX_PENDING_QUERIES
        );
    }

    #[test]
    fn eviction_never_drops_an_in_flight_query() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);

        // Fill all but one slot with queries that then time out.
        for i in 0..MAX_PENDING_QUERIES - 1 {
            client
                .send_query(
                    server,
                    create_test_query(),
                    now + Duration::from_millis(i as u64),
                )
                .unwrap();
        }
        client.handle_timeout(now + Duration::from_secs(3600));

        // The final slot holds a still-in-flight query.
        let in_flight = client
            .send_query(server, create_test_query(), now + Duration::from_secs(3600))
            .unwrap();

        // The map is full; another query evicts a timed-out one, never the in-flight query.
        client
            .send_query(server, create_test_query(), now + Duration::from_secs(3601))
            .unwrap();

        assert!(
            client
                .pending_queries_by_local_port
                .contains_key(&in_flight.port())
        );
    }

    #[test]
    fn rejects_a_new_query_when_full_of_in_flight_queries() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);

        // Fill to capacity without timing anything out.
        for _ in 0..MAX_PENDING_QUERIES {
            client.send_query(server, create_test_query(), now).unwrap();
        }

        // There is nothing to evict, so a further query is rejected.
        assert!(client.send_query(server, create_test_query(), now).is_err());
    }

    fn create_test_client() -> Client {
        let seed = [0u8; 32];
        let mut client = Client::new(seed);
        client.set_source_interface(Ipv4Addr::new(10, 0, 0, 1), Ipv6Addr::LOCALHOST);
        client
    }

    fn create_test_query() -> dns_types::Query {
        use std::str::FromStr;
        let domain = dns_types::DomainName::from_str("example.com").unwrap();
        dns_types::Query::new(domain, dns_types::RecordType::A)
    }

    fn dns_response_packet(
        server: SocketAddr,
        local: SocketAddr,
        query: &dns_types::Query,
    ) -> IpPacket {
        let response = dns_types::Response::no_error(query).into_bytes(512);

        ip_packet::make::udp_packet(
            server.ip(),
            local.ip(),
            server.port(),
            local.port(),
            &response,
        )
        .unwrap()
    }
}
