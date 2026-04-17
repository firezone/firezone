use super::{
    QueryId,
    reference::PrivateKey,
    sim_net::{ExecMutScope, Host},
    sim_relay::{SimRelay, map_explode},
    transition::{DPort, DnsTransport, Identifier, SPort, Seq},
};
use crate::{
    ClientState, DnsMapping, DnsResourceRecord, dns,
    malicious_behaviour::{Guard, MaliciousBehaviour},
};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, RelayId, ResourceId, ResourceStatus};
use dns_types::{DomainName, Query, RecordData, RecordType};
use ip_network::IpNetwork;
use ip_packet::{IcmpEchoHeader, IcmpError, Icmpv4Type, Icmpv6Type, IpPacket, Layer4Protocol};
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

/// Simulation state for a particular client.
pub(crate) struct SimClient {
    id: ClientId,

    pub(crate) sut: ClientState,

    /// The malicious behaviours sampled for this client.
    malicious_behaviour: MaliciousBehaviour,

    /// The DNS records created on the client as a result of received DNS responses.
    ///
    /// This contains results from both, queries to DNS resources and non-resources.
    pub(crate) dns_records: HashMap<DomainName, Vec<IpAddr>>,

    /// The current DNS resource records emitted by the client.
    ///
    /// In a real system, these would be cached on the local file system
    /// or somewhere where they survive a restart.
    pub(crate) dns_resource_record_cache: BTreeSet<DnsResourceRecord>,

    /// Bi-directional mapping between connlib's sentinel DNS IPs and the effective DNS servers.
    dns_by_sentinel: DnsMapping,

    pub(crate) routes: BTreeSet<IpNetwork>,

    /// The search-domain emitted by connlib.
    pub(crate) search_domain: Option<DomainName>,

    pub(crate) resource_status: BTreeMap<ResourceId, ResourceStatus>,

    pub(crate) sent_udp_dns_queries: HashMap<(dns::Upstream, QueryId, u16), IpPacket>,
    pub(crate) received_udp_dns_responses: BTreeMap<(dns::Upstream, QueryId, u16), IpPacket>,

    pub(crate) sent_tcp_dns_queries: HashSet<(dns::Upstream, QueryId)>,
    pub(crate) received_tcp_dns_responses: BTreeSet<(dns::Upstream, QueryId)>,

    pub(crate) sent_icmp_requests: BTreeMap<(Seq, Identifier), (Instant, IpPacket)>,
    pub(crate) received_icmp_replies: BTreeMap<(Seq, Identifier), IpPacket>,

    /// The received ICMP packets, indexed by our custom ICMP payload.
    pub(crate) received_icmp_requests: BTreeMap<u64, (Instant, IpPacket)>,

    /// The received UDP packets, indexed by our custom UDP payload.
    pub(crate) received_udp_requests: BTreeMap<u64, (Instant, IpPacket)>,

    pub(crate) sent_udp_requests: BTreeMap<(SPort, DPort), (Instant, IpPacket)>,
    pub(crate) received_udp_replies: BTreeMap<(SPort, DPort), IpPacket>,

    pub(crate) tcp_dns_client: dns_over_tcp::Client,

    /// TCP connections to resources.
    pub(crate) tcp_client: crate::tests::tcp::Client,
    pub(crate) failed_tcp_packets: BTreeMap<(SPort, DPort), IcmpError>,
}

impl SimClient {
    pub(crate) fn new(
        id: ClientId,
        sut: ClientState,
        malicious_behaviour: MaliciousBehaviour,
        now: Instant,
    ) -> Self {
        Self {
            id,
            sut,
            malicious_behaviour,
            dns_records: Default::default(),
            dns_by_sentinel: Default::default(),
            sent_udp_dns_queries: Default::default(),
            received_udp_dns_responses: Default::default(),
            sent_tcp_dns_queries: Default::default(),
            received_tcp_dns_responses: Default::default(),
            sent_icmp_requests: Default::default(),
            received_icmp_replies: Default::default(),
            received_icmp_requests: Default::default(),
            received_udp_requests: Default::default(),
            sent_udp_requests: Default::default(),
            received_udp_replies: Default::default(),
            routes: Default::default(),
            search_domain: Default::default(),
            resource_status: Default::default(),
            tcp_dns_client: dns_over_tcp::Client::new(now, Duration::from_secs(15), [0u8; 32]),
            tcp_client: crate::tests::tcp::Client::new(now),
            failed_tcp_packets: Default::default(),
            dns_resource_record_cache: Default::default(),
        }
    }

    pub(crate) fn restart(
        &mut self,
        key: PrivateKey,
        is_internet_resource_active: bool,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) {
        let dns_resource_records = self.dns_resource_record_cache.clone();

        // Overwrite the ClientState with a new key.
        // This is effectively the same as restarting a client / signing out and in again.
        //
        // We keep all the state in `SimClient` which is equivalent to host system.
        // That is where we cache resolved DNS names for example.
        self.sut = ClientState::new(
            key.0,
            dns_resource_records,
            is_internet_resource_active,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        );

        self.search_domain = None;
        self.dns_by_sentinel = DnsMapping::default();
        self.routes.clear();
    }

    /// Returns the _effective_ DNS servers that connlib is using.
    pub(crate) fn effective_dns_servers(&self) -> Vec<dns::Upstream> {
        self.dns_by_sentinel.upstream_servers()
    }

    pub(crate) fn effective_search_domain(&self) -> Option<DomainName> {
        self.search_domain.clone()
    }

    pub(crate) fn set_new_dns_servers(&mut self, mapping: DnsMapping) {
        self.dns_by_sentinel = mapping;
        self.tcp_dns_client.reset();
    }

    pub(crate) fn dns_mapping(&self) -> &DnsMapping {
        &self.dns_by_sentinel
    }

    pub(crate) fn send_dns_query_for(
        &mut self,
        domain: DomainName,
        r_type: RecordType,
        query_id: u16,
        upstream: dns::Upstream,
        dns_transport: DnsTransport,
        now: Instant,
    ) -> Option<Transmit> {
        let Some(sentinel) = self.dns_by_sentinel.sentinel_by_upstream(&upstream) else {
            tracing::error!(%upstream, "Unknown DNS server");
            return None;
        };

        tracing::debug!(%sentinel, %domain, "Sending DNS query");

        let src = self
            .sut
            .tunnel_ip_for(sentinel)
            .expect("tunnel should be initialised");

        let query = Query::new(domain, r_type).with_id(query_id);

        match dns_transport {
            DnsTransport::Udp { local_port } => {
                let query_bytes = query.into_bytes();
                let packet =
                    ip_packet::make::udp_packet(src, sentinel, local_port, 53, &query_bytes)
                        .unwrap();

                self.sent_udp_dns_queries
                    .insert((upstream, query_id, local_port), packet.clone());
                self.encapsulate(packet, now)
            }
            DnsTransport::Tcp => {
                self.tcp_dns_client
                    .send_query(SocketAddr::new(sentinel, 53), query)
                    .unwrap();
                self.sent_tcp_dns_queries.insert((upstream, query_id));

                None
            }
        }
    }

    pub fn connect_tcp(&mut self, src: IpAddr, dst: IpAddr, sport: SPort, dport: DPort) {
        let local = SocketAddr::new(src, sport.0);
        let remote = SocketAddr::new(dst, dport.0);

        if let Err(e) = self.tcp_client.connect(local, remote) {
            tracing::error!("TCP connect failed: {e:#}")
        }
    }

    pub(crate) fn encapsulate(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Option<snownet::Transmit> {
        self.update_sent_requests(&packet, now);

        let Some(transmit) = self.sut.handle_tun_input(packet, now) else {
            self.sut.handle_timeout(now); // If we handled the packet internally, make sure to advance state.
            return None;
        };

        Some(transmit)
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.tcp_dns_client
            .poll_outbound()
            .or_else(|| self.tcp_client.poll_outbound())
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.tcp_dns_client.handle_timeout(now);
        self.tcp_client.handle_timeout(now);

        if self.sut.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.sut.handle_timeout(now)
        }
    }

    fn update_sent_requests(&mut self, packet: &IpPacket, now: Instant) {
        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type()
        {
            self.sent_icmp_requests
                .insert((Seq(echo.seq), Identifier(echo.id)), (now, packet.clone()));
            return;
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
        {
            self.sent_icmp_requests
                .insert((Seq(echo.seq), Identifier(echo.id)), (now, packet.clone()));
            return;
        }

        if let Some(udp) = packet.as_udp() {
            self.sent_udp_requests.insert(
                (SPort(udp.source_port()), DPort(udp.destination_port())),
                (now, packet.clone()),
            );
        }
    }

    pub(crate) fn receive(&mut self, transmit: Transmit, now: Instant) -> Option<Transmit> {
        let Some(packet) = self.sut.handle_network_input(
            transmit.dst,
            transmit.src.unwrap(),
            &transmit.payload,
            now,
        ) else {
            self.sut.handle_timeout(now);
            return None;
        };

        let transmit = self.on_received_packet(packet, now)?;

        Some(transmit)
    }

    /// Process an IP packet received on the client.
    pub(crate) fn on_received_packet(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Option<snownet::Transmit> {
        match packet.icmp_error() {
            Ok(Some((failed_packet, icmp_error))) => {
                match failed_packet.layer4_protocol() {
                    Layer4Protocol::Udp { src, dst } => {
                        self.received_udp_replies
                            .insert((SPort(dst), DPort(src)), packet);
                    }
                    Layer4Protocol::Tcp { src, dst } => {
                        self.failed_tcp_packets
                            .insert((SPort(src), DPort(dst)), icmp_error);

                        // Allow the client to process the ICMP error.
                        self.tcp_client.handle_inbound(packet);
                    }
                    Layer4Protocol::Icmp { seq, id } => {
                        self.received_icmp_replies
                            .insert((Seq(seq), Identifier(id)), packet);
                    }
                }

                return None;
            }
            Ok(None) => {}
            Err(e) => {
                tracing::error!("Failed to extract ICMP unreachable destination: {e:#}")
            }
        }

        if let Some(udp) = packet.as_udp() {
            if udp.source_port() == 53 {
                let response = dns_types::Response::parse(udp.payload())
                    .expect("ip packets on port 53 to be DNS packets");

                // Map back to upstream socket so we can assert on it correctly.
                let sentinel = packet.source();
                let Some(upstream) = self.dns_by_sentinel.upstream_by_sentinel(sentinel) else {
                    tracing::error!(%sentinel, mapping = ?self.dns_by_sentinel, "Unknown DNS server");
                    return None;
                };

                self.received_udp_dns_responses.insert(
                    (upstream, response.id(), udp.destination_port()),
                    packet.clone(),
                );

                if !response.truncated() {
                    self.handle_dns_response(&response);
                }

                return None;
            }

            self.received_udp_replies.insert(
                (SPort(udp.source_port()), DPort(udp.destination_port())),
                packet.clone(),
            );
            return None;
        }

        if self.tcp_dns_client.accepts(&packet) {
            self.tcp_dns_client.handle_inbound(packet);
            return None;
        }

        if self.tcp_client.accepts(&packet) {
            self.tcp_client.handle_inbound(packet);
            return None;
        }

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type()
        {
            let packet_id = u64::from_be_bytes(*icmp.payload().first_chunk().unwrap());
            tracing::debug!(%packet_id, "Received ICMP request");
            self.received_icmp_requests
                .insert(packet_id, (now, packet.clone()));
            let transmit = self.handle_icmp_request(&packet, echo, icmp.payload(), now)?;

            return Some(transmit);
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
        {
            let packet_id = u64::from_be_bytes(*icmp.payload().first_chunk().unwrap());
            tracing::debug!(%packet_id, "Received ICMP request");
            self.received_icmp_requests
                .insert(packet_id, (now, packet.clone()));
            let transmit = self.handle_icmp_request(&packet, echo, icmp.payload(), now)?;

            return Some(transmit);
        }

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoReply(echo) = icmp.icmp_type()
        {
            self.received_icmp_replies
                .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
            return None;
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoReply(echo) = icmp.icmp_type()
        {
            self.received_icmp_replies
                .insert((Seq(echo.seq), Identifier(echo.id)), packet.clone());
            return None;
        }

        tracing::error!(?packet, "Unhandled packet");

        None
    }

    pub(crate) fn update_relays<'a>(
        &mut self,
        to_remove: impl Iterator<Item = RelayId>,
        to_add: impl Iterator<Item = (&'a RelayId, &'a Host<SimRelay>)> + 'a,
        now: Instant,
    ) {
        self.sut.update_relays(
            to_remove.collect(),
            map_explode(to_add, format!("client_{}", self.id)).collect(),
            now,
        )
    }

    pub(crate) fn handle_dns_response(&mut self, response: &dns_types::Response) {
        for record in response.records() {
            #[expect(clippy::wildcard_enum_match_arm)]
            let ip = match record.data() {
                RecordData::A(a) => IpAddr::from(a.addr()),
                RecordData::Aaaa(aaaa) => IpAddr::from(aaaa.addr()),
                RecordData::Ptr(_) => {
                    continue;
                }
                RecordData::Txt(_) => {
                    continue;
                }
                RecordData::Srv(_) => {
                    continue;
                }
                unhandled => {
                    panic!("Unexpected record data: {unhandled:?}")
                }
            };

            self.dns_records
                .entry(response.domain())
                .or_default()
                .push(ip);
        }

        // Ensure all IPs are always sorted.
        for ips in self.dns_records.values_mut() {
            ips.sort()
        }
    }

    fn handle_icmp_request(
        &mut self,
        packet: &IpPacket,
        echo: IcmpEchoHeader,
        payload: &[u8],
        now: Instant,
    ) -> Option<Transmit> {
        let reply = ip_packet::make::icmp_reply_packet(
            packet.destination(),
            packet.source(),
            echo.seq,
            echo.id,
            payload,
        )
        .expect("src and dst are taken from incoming packet");

        let transmit = self.sut.handle_tun_input(reply, now)?;

        Some(transmit)
    }

    pub(crate) fn clear_packets(&mut self) {
        self.sent_icmp_requests.clear();
        self.received_icmp_replies.clear();
        self.received_icmp_requests.clear();
        self.sent_udp_requests.clear();
        self.received_udp_replies.clear();
        self.received_udp_requests.clear();
        self.sent_udp_dns_queries.clear();
        self.received_udp_dns_responses.clear();
        self.sent_tcp_dns_queries.clear();
        self.received_tcp_dns_responses.clear();
        self.tcp_client.reset();
    }
}

impl ExecMutScope for SimClient {
    type Guard = Guard;

    fn enter(&self) -> Self::Guard {
        self.malicious_behaviour.guard()
    }
}
