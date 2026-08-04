use super::{
    QueryId,
    echo::echo_reply,
    icmp_error_hosts::{IcmpErrorHosts, icmp_error_reply},
    probe::{
        ProbeId, ProbeObservation, ProbeProtocol, ReceivedRequest, ReceivedResponse, Remote,
        SubmittedRequest,
    },
    reference::PrivateKey,
    sim_net::{ExecMutScope, Host},
    sim_relay::{SimRelay, map_explode},
    transition::{DPort, DnsTransport, Identifier, IpFamily, MalformedDnsQuery, SPort, Seq},
};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, RelayId, ResourceList};
use dns_types::{DomainName, Query, RecordData, RecordType};
use ip_network::IpNetwork;
use ip_packet::{IcmpEchoHeader, IcmpError, Icmpv4Type, Icmpv6Type, IpPacket, Layer4Protocol};
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};
use tunnel_proto::{
    ClientState, DNS_SENTINELS_V4, DNS_SENTINELS_V6, DnsMapping, DnsResourceRecord,
    MaliciousBehaviour, MaliciousBehaviourGuard as Guard, dns,
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

    /// The latest resource list emitted by connlib.
    pub(crate) observed_resource_list: ResourceList,

    pub(crate) sent_udp_dns_queries: HashMap<(dns::Upstream, QueryId, u16), IpPacket>,
    pub(crate) received_udp_dns_responses: BTreeMap<(dns::Upstream, QueryId, u16), IpPacket>,

    pub(crate) sent_tcp_dns_queries: HashSet<(dns::Upstream, QueryId)>,
    pub(crate) received_tcp_dns_responses: BTreeSet<(dns::Upstream, QueryId)>,

    pub(crate) probe_observations: Vec<ProbeObservation>,
    sent_probes: BTreeMap<ProbeProtocol, ProbeId>,

    pub(crate) tcp_dns_client: dns_over_tcp::Client,

    /// TCP connections to resources.
    pub(crate) tcp_client: crate::tcp::Client,
    pub(crate) failed_tcp_packets: BTreeMap<(SPort, DPort), IcmpError>,

    /// Collects datagrams encapsulated via [`ClientState::handle_tun_input`].
    transmit_buffer: snownet::TransmitBuffer,
}

impl SimClient {
    pub(crate) fn new(
        id: ClientId,
        mut sut: ClientState,
        malicious_behaviour: MaliciousBehaviour,
        os: crate::os::SimulatedOs,
        now: Instant,
    ) -> Self {
        sut.set_flow_logs_enabled(true);

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
            probe_observations: Default::default(),
            sent_probes: Default::default(),
            routes: Default::default(),
            search_domain: Default::default(),
            observed_resource_list: Default::default(),
            tcp_dns_client: dns_over_tcp::Client::new(now, Duration::from_secs(15), [0u8; 32]),
            tcp_client: crate::tcp::Client::new(now, os),
            failed_tcp_packets: Default::default(),
            dns_resource_record_cache: Default::default(),
            transmit_buffer: snownet::TransmitBuffer::new(),
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
        self.sut.set_flow_logs_enabled(true);

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

    pub(crate) fn send_dns_resource_ptr_query_for(
        &mut self,
        record_domain: DomainName,
        family: IpFamily,
        address_index: u32,
        query_id: u16,
        upstream: dns::Upstream,
        dns_transport: DnsTransport,
        now: Instant,
    ) -> Option<Transmit> {
        let ips = self
            .dns_records
            .get(&record_domain)
            .expect("resolved domain should have DNS records")
            .iter()
            .filter(|ip| match family {
                IpFamily::Ipv4 => ip.is_ipv4(),
                IpFamily::Ipv6 => ip.is_ipv6(),
            })
            .copied()
            .collect::<Vec<_>>();
        let ip = ips[address_index as usize % ips.len()];
        let reverse_domain =
            DomainName::reverse_from_addr(ip).expect("reverse DNS names always fit");

        self.send_dns_query_for(
            reverse_domain,
            RecordType::PTR,
            query_id,
            upstream,
            dns_transport,
            now,
        )
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

    pub(crate) fn send_malformed_dns_query(
        &mut self,
        kind: MalformedDnsQuery,
        query_id: u16,
        upstream: dns::Upstream,
        local_port: u16,
        now: Instant,
    ) -> Option<Transmit> {
        let Some(sentinel) = self.dns_by_sentinel.sentinel_by_upstream(&upstream) else {
            tracing::error!(%upstream, "Unknown DNS server");
            return None;
        };

        tracing::debug!(%sentinel, ?kind, "Sending malformed DNS query");

        let src = self
            .sut
            .tunnel_ip_for(sentinel)
            .expect("tunnel should be initialised");

        let payload = malformed_dns_query(kind, query_id);
        let packet = ip_packet::make::udp_packet(src, sentinel, local_port, 53, &payload).unwrap();

        // Deliberately not tracked in `sent_udp_dns_queries`: the client must drop
        // the query, and any response shows up as an unexpected UDP DNS reply.
        self.encapsulate(packet, now)
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
        match self.handle_tun_input(packet, now) {
            Ok(Some(transmit)) => Some(transmit),
            Ok(None) => {
                self.sut.handle_timeout(now); // If we handled the packet internally, make sure to advance state.

                None
            }
            Err(e) => {
                tracing::warn!("{e:#}");

                None
            }
        }
    }

    pub(crate) fn encapsulate_probe(
        &mut self,
        id: ProbeId,
        packet: IpPacket,
        now: Instant,
    ) -> Option<snownet::Transmit> {
        let protocol = probe_protocol_from_request(&packet)
            .expect("probe packets must be ICMP echo requests or UDP packets");
        let previous = self.sent_probes.insert(protocol, id);

        assert!(previous.is_none(), "probe transport tuples must be unique");

        self.probe_observations
            .push(ProbeObservation::RequestSubmitted(SubmittedRequest {
                id,
                at: now,
                client: self.id,
                packet: packet.clone(),
            }));

        self.encapsulate(packet, now)
    }

    /// Drive the SUT's TUN -> network path, collecting the encapsulated datagram (if any).
    ///
    /// Routes encapsulation through the [`snownet::TransmitBuffer`] field so the rest of the
    /// simulation can keep working with a single [`snownet::Transmit`] per packet.
    fn handle_tun_input(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> anyhow::Result<Option<snownet::Transmit>> {
        self.sut
            .handle_tun_input(packet, now, &mut self.transmit_buffer)?;

        Ok(self.transmit_buffer.poll_transmit())
    }

    pub fn poll_outbound(&mut self) -> Option<IpPacket> {
        self.tcp_dns_client
            .poll_outbound()
            .or_else(|| self.tcp_client.poll_outbound())
    }

    pub fn drive_tcp(&mut self, now: Instant) {
        self.tcp_dns_client.handle_timeout(now);
        self.tcp_client.handle_timeout(now);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        if self.sut.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.sut.handle_timeout(now)
        }
    }

    pub(crate) fn receive(
        &mut self,
        transmit: Transmit,
        icmp_error_hosts: &IcmpErrorHosts,
        now: Instant,
    ) -> Option<Transmit> {
        let Some(packet) = self
            .sut
            .handle_network_input(transmit.dst, transmit.src.unwrap(), &transmit.payload, now)
            .inspect_err(|e| tracing::warn!("{e:#}"))
            .ok()
            .flatten()
        else {
            self.sut.handle_timeout(now);
            return None;
        };

        let transmit = self.on_received_packet(packet, icmp_error_hosts, now)?;

        Some(transmit)
    }

    /// Process an IP packet received on the client.
    pub(crate) fn on_received_packet(
        &mut self,
        packet: IpPacket,
        icmp_error_hosts: &IcmpErrorHosts,
        now: Instant,
    ) -> Option<snownet::Transmit> {
        match packet.icmp_error() {
            Ok(Some((failed_packet, icmp_error))) => {
                match failed_packet.layer4_protocol() {
                    Layer4Protocol::Udp { src, dst } => {
                        let protocol = ProbeProtocol::Udp {
                            sport: SPort(src),
                            dport: DPort(dst),
                        };

                        if let Some(id) = self.sent_probes.get(&protocol).copied() {
                            self.record_received_response(id, packet, now);
                        } else if dst != 53 {
                            tracing::error!(?protocol, "Received ICMP error for unknown UDP probe");
                        }
                    }
                    Layer4Protocol::Tcp { src, dst } => {
                        self.failed_tcp_packets
                            .insert((SPort(src), DPort(dst)), icmp_error);

                        // Allow the client to process the ICMP error.
                        self.tcp_client.handle_inbound(packet);
                    }
                    Layer4Protocol::Icmp { seq, id } => {
                        let protocol = ProbeProtocol::Icmp {
                            seq: Seq(seq),
                            identifier: Identifier(id),
                        };

                        if let Some(id) = self.sent_probes.get(&protocol).copied() {
                            self.record_received_response(id, packet, now);
                        } else {
                            tracing::error!(
                                ?protocol,
                                "Received ICMP error for unknown ICMP probe"
                            );
                        }
                    }
                }

                return None;
            }
            Ok(None) => {}
            Err(e) => {
                tracing::error!("Failed to extract ICMP unreachable destination: {e:#}")
            }
        }

        // Only answers a fresh UDP request from a peer: a port that nothing listens on
        // is meaningless for an ICMP echo, which has no port to be unreachable.
        let icmp_error = icmp_error_hosts
            .icmp_error_for_ip(packet.destination())
            .map(|error| icmp_error_reply(&packet, error).unwrap());

        if let Some(udp) = packet.as_udp() {
            if udp.source_port() == 53
                && let Some(upstream) = self.dns_by_sentinel.upstream_by_sentinel(packet.source())
            {
                let response = dns_types::Response::parse(udp.payload())
                    .expect("packets from DNS sentinels on port 53 to be DNS packets");

                self.received_udp_dns_responses.insert(
                    (upstream, response.id(), udp.destination_port()),
                    packet.clone(),
                );

                if !response.truncated() {
                    self.handle_dns_response(&response);
                }

                return None;
            }

            let Some(id) = ProbeId::from_payload(udp.payload()) else {
                tracing::error!("UDP probe payload does not contain a probe ID");
                return None;
            };

            if self.sent_probes.values().any(|sent| *sent == id) {
                self.record_received_response(id, packet, now);
                return None;
            }

            self.record_received_request(id, packet.clone(), now);

            let reply = icmp_error.or_else(|| echo_reply(packet))?;
            return self.handle_tun_input(reply, now).ok().flatten();
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
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return None;
            };

            self.record_received_request(id, packet.clone(), now);
            let transmit = self.handle_icmp_request(&packet, echo, icmp.payload(), now)?;

            return Some(transmit);
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
        {
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return None;
            };

            self.record_received_request(id, packet.clone(), now);
            let transmit = self.handle_icmp_request(&packet, echo, icmp.payload(), now)?;

            return Some(transmit);
        }

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoReply(_) = icmp.icmp_type()
        {
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return None;
            };

            self.record_received_response(id, packet, now);
            return None;
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoReply(_) = icmp.icmp_type()
        {
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return None;
            };

            self.record_received_response(id, packet, now);
            return None;
        }

        // Silently ignore TCP packets on port 53 originating from connlib's DNS
        // sentinel range. The TCP-DNS client consumes packets for connections it
        // still remembers, but a teardown (e.g. RST) can arrive after the remote
        // was evicted from its bounded map of closed connections, e.g. following
        // repeated sentinel mapping changes (`UpdateSystemDnsServers` /
        // `UpdateUpstream*`), and would otherwise fall through to the
        // `Unhandled packet` error below. This is connlib's DNS infrastructure
        // closing a connection, not application traffic the reference models, so
        // it must not fail the test. We match the fixed sentinel *range* rather
        // than the current mapping precisely because the mapping may no longer
        // contain the (old) sentinel by the time the RST arrives.
        if let Some(tcp) = packet.as_tcp()
            && tcp.source_port() == 53
            && match packet.source() {
                IpAddr::V4(v4) => DNS_SENTINELS_V4.contains(v4),
                IpAddr::V6(v6) => DNS_SENTINELS_V6.contains(v6),
            }
        {
            tracing::debug!(?packet, "Ignoring TCP teardown from DNS sentinel");
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

        let transmit = self.handle_tun_input(reply, now).unwrap()?;

        Some(transmit)
    }

    fn record_received_request(&mut self, id: ProbeId, packet: IpPacket, at: Instant) {
        self.probe_observations
            .push(ProbeObservation::RequestReceived(ReceivedRequest {
                id,
                at,
                remote: Remote::Client(self.id),
                packet,
            }));
    }

    fn record_received_response(&mut self, id: ProbeId, packet: IpPacket, at: Instant) {
        self.probe_observations
            .push(ProbeObservation::ResponseReceived(ReceivedResponse {
                id,
                at,
                client: self.id,
                packet,
            }));
    }

    pub(crate) fn clear_packets(&mut self) {
        self.sent_udp_dns_queries.clear();
        self.received_udp_dns_responses.clear();
        self.sent_tcp_dns_queries.clear();
        self.received_tcp_dns_responses.clear();
        self.tcp_client.reset();
        self.failed_tcp_packets.clear();
    }
}

fn probe_protocol_from_request(packet: &IpPacket) -> Option<ProbeProtocol> {
    if let Some(icmp) = packet.as_icmpv4()
        && let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type()
    {
        return Some(ProbeProtocol::Icmp {
            seq: Seq(echo.seq),
            identifier: Identifier(echo.id),
        });
    }

    if let Some(icmp) = packet.as_icmpv6()
        && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
    {
        return Some(ProbeProtocol::Icmp {
            seq: Seq(echo.seq),
            identifier: Identifier(echo.id),
        });
    }

    let udp = packet.as_udp()?;

    Some(ProbeProtocol::Udp {
        sport: SPort(udp.source_port()),
        dport: DPort(udp.destination_port()),
    })
}

impl ExecMutScope for SimClient {
    type Guard = Guard;

    fn enter(&self) -> Self::Guard {
        self.malicious_behaviour.guard()
    }
}

/// Serializes a structurally invalid DNS query of the given kind.
///
/// Starts from a valid single-question query and patches the wire format;
/// the header is id (2 bytes), flags (2 bytes) and four section counts
/// (2 bytes each), followed by the question section.
fn malformed_dns_query(kind: MalformedDnsQuery, query_id: u16) -> Vec<u8> {
    let domain = DomainName::vec_from_str("malformed.example.com").unwrap();
    let mut bytes = Query::new(domain, RecordType::A)
        .with_id(query_id)
        .into_bytes();

    match kind {
        MalformedDnsQuery::QrBitSet => {
            bytes[2] |= 0b1000_0000; // The QR bit is the top bit of the flags.
        }
        MalformedDnsQuery::NoQuestion => {
            bytes.truncate(12); // Just the header ...
            bytes[5] = 0; // ... with QDCOUNT set to match.
        }
        MalformedDnsQuery::TwoQuestions => {
            let question = bytes[12..].to_vec();
            bytes.extend_from_slice(&question); // Repeat the question ...
            bytes[5] = 2; // ... with QDCOUNT set to match.
        }
        MalformedDnsQuery::TruncatedHeader => {
            bytes.truncate(11); // One byte short of a full header.
        }
    }

    bytes
}
