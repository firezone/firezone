#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    collections::{
        HashMap, VecDeque,
        hash_map::{Entry, OccupiedEntry},
    },
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    num::NonZeroUsize,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, anyhow, bail};
use ip_packet::{FailedPacket, IpPacket, Layer4Protocol};
use lru::LruCache;
use rand::{RngExt, SeedableRng, rngs::StdRng};

const TIMEOUT: Duration = Duration::from_secs(10);

/// How many timed-out queries we remember in order to match (and drop) late responses.
///
/// A response that arrives after we already gave up on its query is no longer tracked by
/// [`Client::pending_queries_by_local_port`] and would otherwise be forwarded to the TUN device
/// as an unsolicited packet. Remembering a bounded number of timed-out queries lets us recognise
/// these late responses and drop them instead. The set never expires entries on its own and only
/// evicts the least-recently-used one once full, keeping the memory footprint tiny.
const MAX_TIMED_OUT_QUERIES: NonZeroUsize = NonZeroUsize::new(128).expect("128 > 0");

/// A sans-io DNS-over-UDP client.
pub struct Client<const MIN_PORT: u16 = 49152, const MAX_PORT: u16 = 65535> {
    source_ips: Option<(Ipv4Addr, Ipv6Addr)>,

    pending_queries_by_local_port: HashMap<u16, PendingQuery>,
    /// Queries we already timed out, retained so we can match and drop a late response.
    timed_out_queries_by_local_port: LruCache<u16, TimedOutQuery>,

    scheduled_queries: VecDeque<IpPacket>,
    query_results: VecDeque<QueryResult>,

    rng: StdRng,
}

struct PendingQuery {
    message: dns_types::Query,
    expires_at: Instant,
    server: SocketAddr,
    local: SocketAddr,
}

/// A query we stopped waiting for after it timed out.
struct TimedOutQuery {
    server: SocketAddr,
    query_id: u16,
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
            timed_out_queries_by_local_port: LruCache::new(MAX_TIMED_OUT_QUERIES),
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
    /// Only UDP packets for pending DNS queries are accepted.
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

        let local_port = udp.destination_port();

        // A response to a query we are still waiting for.
        if self.pending_queries_by_local_port.contains_key(&local_port) {
            return true;
        }

        // A late response to a query we already timed out. Match it precisely (same server and
        // DNS query ID) so we only ever intercept the actual response and never blackhole
        // unrelated traffic that happens to reuse this local port. `handle_inbound` then drops it
        // instead of leaking it to the TUN device.
        if let Some(&TimedOutQuery { server, query_id }) =
            self.timed_out_queries_by_local_port.peek(&local_port)
        {
            let source = SocketAddr::new(packet.source(), udp.source_port());

            return source == server
                && dns_types::Response::parse(udp.payload())
                    .is_ok_and(|response| response.id() == query_id);
        }

        false
    }

    pub fn handle_inbound(&mut self, packet: IpPacket) {
        debug_assert!(self.accepts(&packet));

        if let Ok(Some((failed_packet, icmp_error))) = packet.icmp_error()
            && let Some(entry) = self.entry_for_failed_packet(&failed_packet)
        {
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

        if let Some(PendingQuery {
            message, server, ..
        }) = self
            .pending_queries_by_local_port
            .get(&udp.destination_port())
            && let Ok(response) = result.as_ref()
            && (response.id() != message.id() || source != *server)
        {
            tracing::debug!(%server, %source, query_id = %message.id(), response_id = %response.id(), "Response from server does not match query ID or original destination");
            return;
        }

        // A response to a query we are still waiting for.
        if let Some(PendingQuery {
            message,
            server,
            local,
            ..
        }) = self
            .pending_queries_by_local_port
            .remove(&udp.destination_port())
        {
            self.query_results.push_back(QueryResult {
                query: message,
                local,
                server,
                result,
            });
            return;
        }

        // A late response to a query we already timed out. Drop it so it isn't forwarded to the
        // TUN device.
        if let Some(timed_out) = self
            .timed_out_queries_by_local_port
            .peek(&udp.destination_port())
        {
            tracing::debug!(server = %timed_out.server, query_id = %timed_out.query_id, %source, "Dropping late response to timed-out DNS query");
        }
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
        for (
            local_port,
            PendingQuery {
                message,
                server,
                local,
                ..
            },
        ) in self
            .pending_queries_by_local_port
            .extract_if(|_, pending_query| now >= pending_query.expires_at)
        {
            // Remember the query so we can still match (and drop) a late response to it.
            self.timed_out_queries_by_local_port.put(
                local_port,
                TimedOutQuery {
                    server,
                    query_id: message.id(),
                },
            );

            self.query_results.push_back(QueryResult {
                query: message,
                local,
                server,
                result: Err(anyhow!("Timeout")),
            });
        }
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "We don't care about the ordering of the Iterator here."
    )]
    pub fn poll_timeout(&mut self) -> Option<Instant> {
        self.pending_queries_by_local_port
            .values()
            .map(|p| p.expires_at)
            .min()
    }

    pub fn reset(&mut self) {
        tracing::debug!("Resetting state");

        let aborted_pending_queries =
            self.pending_queries_by_local_port
                .drain()
                .map(|(_, pending_query)| QueryResult {
                    query: pending_query.message,
                    local: pending_query.local,
                    server: pending_query.server,
                    result: Err(anyhow!("Timeout")),
                });

        self.query_results.extend(aborted_pending_queries);
    }

    fn sample_new_unique_port(&mut self) -> Result<u16> {
        let range = MIN_PORT..=MAX_PORT;

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
    fn unrelated_traffic_reusing_a_timed_out_port_is_not_intercepted() {
        let mut client = create_test_client();
        let now = Instant::now();
        let server = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53);

        let local = client.send_query(server, create_test_query(), now).unwrap();
        client.handle_timeout(now + TIMEOUT + Duration::from_secs(1));

        // A packet from a different peer that happens to reuse the local port is unrelated
        // traffic, not the late response we are waiting for. It must reach the TUN device.
        let other_peer = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(9, 9, 9, 9)), 443);
        let unrelated = ip_packet::make::udp_packet(
            other_peer.ip(),
            local.ip(),
            other_peer.port(),
            local.port(),
            b"not a dns response",
        )
        .unwrap();

        assert!(!client.accepts(&unrelated));
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
