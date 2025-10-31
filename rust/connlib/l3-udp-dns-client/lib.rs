use std::{
    collections::{HashMap, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, anyhow, bail};
use ip_packet::IpPacket;
use rand::{Rng, SeedableRng, rngs::StdRng};

const TIMEOUT: Duration = Duration::from_secs(5);

/// A sans-io DNS-over-UDP client.
pub struct Client<const MIN_PORT: u16 = 49152, const MAX_PORT: u16 = 65535> {
    source_ips: Option<(Ipv4Addr, Ipv6Addr)>,

    pending_queries_by_local_port: HashMap<u16, PendingQuery>,

    scheduled_queries: VecDeque<IpPacket>,
    query_results: VecDeque<QueryResult>,

    rng: StdRng,

    _created_at: Instant,
    last_now: Instant,
}

struct PendingQuery {
    message: dns_types::Query,
    expires_at: Instant,
    server: SocketAddr,
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

        Self {
            source_ips: None,
            rng: StdRng::from_seed(seed),
            _created_at: now,
            last_now: now,
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
    /// This only queues the message. You need to call [`Client::handle_timeout`] to actually send them.
    pub fn send_query(
        &mut self,
        server: SocketAddr,
        message: dns_types::Query,
        now: Instant,
    ) -> Result<()> {
        let local_port = self.sample_new_unique_port()?;

        let (ipv4_source, ipv6_source) = self
            .source_ips
            .ok_or_else(|| anyhow!("No source interface set"))?;

        let local_ip = match server {
            SocketAddr::V4(_) => IpAddr::V4(ipv4_source),
            SocketAddr::V6(_) => IpAddr::V6(ipv6_source),
        };

        self.pending_queries_by_local_port.insert(
            local_port,
            PendingQuery {
                message: message.clone(),
                expires_at: now + TIMEOUT,
                server,
            },
        );

        let payload = message.into_bytes();

        let ip_packet =
            ip_packet::make::udp_packet(local_ip, server.ip(), local_port, server.port(), payload)
                .context("Failed to make IP packet")?;

        self.scheduled_queries.push_back(ip_packet);

        Ok(())
    }

    /// Checks whether this client can handle the given packet.
    ///
    /// Only TCP packets originating from one of the connected DNS resolvers are accepted.
    pub fn accepts(&self, packet: &IpPacket) -> bool {
        let Some(udp) = packet.as_udp() else {
            #[cfg(debug_assertions)]
            tracing::trace!(?packet, "Not a UDP packet");

            return false;
        };

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

        self.pending_queries_by_local_port
            .contains_key(&udp.destination_port())
    }

    /// Handle the [`IpPacket`].
    ///
    /// This function only inserts the packet into a buffer.
    /// To actually process the packets in the buffer, [`Client::handle_timeout`] must be called.
    pub fn handle_inbound(&mut self, packet: IpPacket) {
        debug_assert!(self.accepts(&packet));

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

        let Some(PendingQuery {
            message, server, ..
        }) = self
            .pending_queries_by_local_port
            .remove(&udp.destination_port())
        else {
            return;
        };

        self.query_results.push_back(QueryResult {
            query: message,
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

    /// Inform the client that time advanced.
    ///
    /// Typical for a sans-IO design, `handle_timeout` will work through all local buffers and process them as much as possible.
    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = now;

        for (
            _,
            PendingQuery {
                message, server, ..
            },
        ) in self
            .pending_queries_by_local_port
            .extract_if(|_, pending_query| now >= pending_query.expires_at)
        {
            self.query_results.push_back(QueryResult {
                query: message,
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
            let port = self.rng.gen_range(range.clone());

            if !self.pending_queries_by_local_port.contains_key(&port) {
                return Ok(port);
            }
        }
    }
}
