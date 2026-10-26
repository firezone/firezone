use super::{
    DeviceListing, DeviceListingQuery, QueryId,
    buffered_transmits::BufferedTransmits,
    dns_records::DnsRecords,
    echo::echo_reply,
    probe::{
        CompletedStream, ProbeId, ProbeObservation, ProbeProtocol, ReceivedRequest,
        ReceivedResponse, Remote, SubmittedRequest,
    },
    reference::PrivateKey,
    sim_net::{ExecMutScope, Host},
    sim_relay::{SimRelay, map_explode},
    sim_tunnel::SimTunnel,
    site_network::{IcmpError, icmp_error_reply},
    transition::{DPort, DnsTransport, Identifier, IpFamily, SPort, Seq},
};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, RelayId, ResourceView};
use dns_types::{DomainName, Query, RecordData, RecordType, ResponseCode, prelude::*};
use ip_network::IpNetwork;
use ip_packet::{IcmpEchoHeader, Icmpv4Type, Icmpv6Type, IpPacket, Layer4Protocol};
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};
use tun::PacketBatch;
use tunnel_proto::{
    ClientEvent, ClientState, DNS_SENTINELS_V4, DNS_SENTINELS_V6, DnsMapping, DnsResourceRecord,
    MaliciousBehaviour, MaliciousBehaviourGuard as Guard, dns,
};

/// Simulation state for a particular client.
pub(crate) struct SimClient {
    id: ClientId,

    pub(crate) tunnel: SimTunnel<ClientState>,

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
    pub(crate) observed_resource_list: Vec<ResourceView>,

    pub(crate) sent_udp_dns_queries: HashMap<(dns::Upstream, QueryId, u16), IpPacket>,
    pub(crate) received_udp_dns_responses: BTreeMap<(dns::Upstream, QueryId, u16), IpPacket>,

    pub(crate) sent_tcp_dns_queries: HashSet<(dns::Upstream, QueryId)>,
    pub(crate) received_tcp_dns_responses: BTreeSet<(dns::Upstream, QueryId)>,

    /// The answers to the PTR queries in the device domain.
    pub(crate) device_listings: BTreeMap<DeviceListingQuery, DeviceListing>,

    pub(crate) probe_observations: Vec<ProbeObservation>,
    sent_probes: Vec<(ProbeId, ProbeProtocol)>,

    pub(crate) tcp_dns_client: dns_over_tcp::Client,

    /// TCP connections to resources.
    pub(crate) tcp_client: crate::tcp::Client,
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
            tunnel: SimTunnel::new(sut),
            malicious_behaviour,
            dns_records: Default::default(),
            dns_by_sentinel: Default::default(),
            sent_udp_dns_queries: Default::default(),
            received_udp_dns_responses: Default::default(),
            sent_tcp_dns_queries: Default::default(),
            received_tcp_dns_responses: Default::default(),
            device_listings: Default::default(),
            probe_observations: Default::default(),
            sent_probes: Default::default(),
            routes: Default::default(),
            search_domain: Default::default(),
            observed_resource_list: Default::default(),
            tcp_dns_client: dns_over_tcp::Client::new(now, Duration::from_secs(15), [0u8; 32]),
            tcp_client: crate::tcp::Client::new(now, os),
            dns_resource_record_cache: Default::default(),
        }
    }

    pub(crate) fn sut(&self) -> &ClientState {
        self.tunnel.inner().state()
    }

    pub(crate) fn sut_mut(&mut self) -> &mut ClientState {
        self.tunnel.inner_mut().state_mut()
    }

    /// Shuts the tunnel down and starts a new one, returning the datagrams the old one sent on
    /// the way out.
    ///
    /// A crashed tunnel sends nothing and the new one starts without the cached DNS resource
    /// records, so applications have to resolve their domains again.
    pub(crate) fn restart(
        &mut self,
        key: PrivateKey,
        crash: bool,
        is_internet_resource_active: bool,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> Vec<Transmit> {
        if crash {
            self.dns_resource_record_cache.clear();
            self.dns_records.clear();
        }
        let dns_resource_records = self.dns_resource_record_cache.clone();

        // A new tunnel with a new key is effectively the same as restarting a client / signing
        // out and in again.
        //
        // We keep all the state in `SimClient` which is equivalent to host system.
        // That is where we cache resolved DNS names for example.
        let mut sut = ClientState::new(
            key.0,
            dns_resource_records,
            is_internet_resource_active,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        );
        sut.set_flow_logs_enabled(true);
        let old = std::mem::replace(&mut self.tunnel, SimTunnel::new(sut));

        self.search_domain = None;
        self.dns_by_sentinel = DnsMapping::default();
        self.routes.clear();

        if crash {
            return Vec::new();
        }

        old.shut_down(now)
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

    pub(crate) fn send_dns_resource_ptr_query_for(
        &mut self,
        record_domain: DomainName,
        family: IpFamily,
        address_index: u32,
        query_id: u16,
        upstream: dns::Upstream,
        dns_transport: DnsTransport,
    ) {
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
            false,
        )
    }

    pub(crate) fn send_dns_query_for(
        &mut self,
        domain: DomainName,
        r_type: RecordType,
        query_id: u16,
        upstream: dns::Upstream,
        dns_transport: DnsTransport,
        edns: bool,
    ) {
        let Some(sentinel) = self.dns_by_sentinel.sentinel_by_upstream(&upstream) else {
            tracing::error!(%upstream, "Unknown DNS server");
            return;
        };

        tracing::debug!(%sentinel, %domain, "Sending DNS query");

        let src = self
            .sut()
            .tunnel_ip_for(sentinel)
            .expect("tunnel should be initialised");

        let query = Query::new(domain, r_type).with_id(query_id);
        let query = if edns { query.with_edns() } else { query };

        match dns_transport {
            DnsTransport::Udp { local_port } => {
                let query_bytes = query.into_bytes();
                let packet =
                    ip_packet::make::udp_packet(src, sentinel, local_port, 53, &query_bytes)
                        .unwrap();

                self.sent_udp_dns_queries
                    .insert((upstream, query_id, local_port), packet.clone());
                self.send(packet);
            }
            DnsTransport::Tcp => {
                self.tcp_dns_client
                    .send_query(SocketAddr::new(sentinel, 53), query)
                    .unwrap();
                self.sent_tcp_dns_queries.insert((upstream, query_id));
            }
        }
    }

    /// Connects `local` to `remote`; the SYN submits probe `id`.
    pub(crate) fn connect_tcp_probe(&mut self, id: ProbeId, local: SocketAddr, remote: SocketAddr) {
        if let Err(e) = self.tcp_client.connect(local, remote, id) {
            tracing::error!("TCP connect failed: {e:#}");
        }
    }

    /// Writes `payload` to a TCP connection; the first segment that carries it submits probe `id`.
    pub(crate) fn write_tcp_probe(
        &mut self,
        id: ProbeId,
        local: SocketAddr,
        remote: SocketAddr,
        payload: &[u8],
    ) {
        if let Err(e) = self.tcp_client.send(local, remote, id, payload) {
            tracing::error!("TCP send failed: {e:#}");
        }
    }

    pub(crate) fn send(&mut self, packet: IpPacket) {
        self.tunnel
            .ends
            .tun_inbound
            .try_send(PacketBatch::new(packet))
            .expect("TUN channel has room");
    }

    pub(crate) fn send_probe(&mut self, id: ProbeId, packet: IpPacket, now: Instant) {
        let protocol = probe_protocol_from_request(&packet)
            .expect("probe packets must be ICMP echo requests, UDP or TCP packets");
        assert!(
            self.sent_probes.iter().all(|(sent, _)| *sent != id),
            "probe IDs must be unique"
        );
        self.sent_probes.push((id, protocol));

        self.probe_observations
            .push(ProbeObservation::RequestSubmitted(SubmittedRequest {
                id,
                at: now,
                client: self.id,
                packet: packet.clone(),
            }));

        self.send(packet);
    }

    /// Hands what the simulated applications send to the TUN device and records the TCP DNS
    /// responses they received.
    fn drive_apps(&mut self, now: Instant) {
        while let Some(result) = self.tcp_dns_client.poll_query_result() {
            match result.result {
                Ok(message) => {
                    let upstream = self
                        .dns_by_sentinel
                        .upstream_by_sentinel(result.server.ip())
                        .unwrap();

                    self.received_tcp_dns_responses
                        .insert((upstream.clone(), result.query.id()));
                    self.handle_dns_response(upstream, DnsTransport::Tcp, &message)
                }
                Err(e) => {
                    tracing::error!("TCP DNS query failed: {e:#}");
                }
            }
        }

        self.tcp_dns_client.handle_timeout(now);
        self.tcp_client.handle_timeout(now);
        self.record_tcp_responses(now);

        while let Some((packet, probe)) = self
            .tcp_dns_client
            .poll_outbound()
            .map(|packet| (packet, None))
            .or_else(|| self.tcp_client.poll_outbound())
        {
            match probe {
                Some(id) => self.send_probe(id, packet, now),
                None => self.send(packet),
            }
        }
    }

    /// Answers the next recursive DNS query the tunnel sent, returning whether there was one.
    fn answer_dns_query(&mut self, global_dns_records: &DnsRecords) -> bool {
        // Long enough that a query repeated within one `advance` window is served
        // from connlib's DNS cache, short enough that an `Idle` (minutes) expires
        // the entry, so the corpus exercises the cache hit and expiry paths. The
        // reference model is cache-agnostic (it expects a response per query
        // regardless of how it is produced), so activating the cache is
        // observationally transparent.
        const TTL: u32 = 30;

        let Some(query) = self.tunnel.poll_dns_query() else {
            return false;
        };

        let server = query
            .server
            .expect("Clients always name the upstream server");

        // DoH queries are always sent with an ID of 0, simulate that in the tests.
        let message = match server {
            dns::Upstream::DoH { .. } => query.message.clone().with_id(0),
            dns::Upstream::Do53 { .. } => query.message.clone(),
        };
        let qtype = message.qtype();
        let domain = message.domain();

        tracing::debug!(%domain, %qtype, "Responding to DNS query");

        let response = dns_types::ResponseBuilder::for_query(&message, ResponseCode::NOERROR)
            .with_records(
                global_dns_records
                    .domain_records_iter(&domain)
                    .filter(|record| qtype == record.rtype())
                    .map(|rdata| (domain.clone(), TTL, rdata)),
            )
            .build();

        self.tunnel
            .ends
            .dns
            .respond(dns::RecursiveResponse {
                server,
                query: query.message,
                message: Ok(response), // TODO: Vary this?
                transport: query.transport,
                local: query.local,
                remote: query.remote,
                started_at: query.started_at,
                recursion: dns::Recursion::Local,
            })
            .expect("DNS response channel has room");

        true
    }

    /// Process an IP packet received on the client.
    fn on_received_packet(&mut self, packet: IpPacket, now: Instant) {
        match packet.icmp_error() {
            Ok(Some((failed_packet, _))) => {
                match failed_packet.layer4_protocol() {
                    Layer4Protocol::Udp { src, dst } => {
                        let protocol = ProbeProtocol::Udp {
                            sport: SPort(src),
                            dport: DPort(dst),
                        };

                        if let Some(id) = self.latest_probe_for(protocol) {
                            self.record_received_response(id, packet, now);
                        } else if dst != 53 {
                            tracing::error!(?protocol, "Received ICMP error for unknown UDP probe");
                        }
                    }
                    Layer4Protocol::Tcp { .. } => {
                        self.tcp_client.handle_inbound(packet);
                        self.record_tcp_responses(now);
                    }
                    Layer4Protocol::Icmp { seq, id } => {
                        let protocol = ProbeProtocol::Icmp {
                            seq: Seq(seq),
                            identifier: Identifier(id),
                        };

                        if let Some(id) = self.latest_probe_for(protocol) {
                            self.record_received_response(id, packet, now);
                        } else {
                            tracing::error!(
                                ?protocol,
                                "Received ICMP error for unknown ICMP probe"
                            );
                        }
                    }
                }

                return;
            }
            Ok(None) => {}
            Err(e) => {
                tracing::error!("Failed to extract ICMP unreachable destination: {e:#}")
            }
        }

        // A port that nothing listens on is the only error a Client's TUN IP can originate.
        //
        // Only answers a fresh UDP request from a peer: a port that nothing listens on
        // is meaningless for an ICMP echo, which has no port to be unreachable.
        let icmp_error = self
            .malicious_behaviour
            .send_untracked_icmp_errors
            .then(|| icmp_error_reply(&packet, IcmpError::Port).unwrap());

        if let Some(udp) = packet.as_udp() {
            if udp.source_port() == 53
                && let Some(upstream) = self.dns_by_sentinel.upstream_by_sentinel(packet.source())
            {
                let response = dns_types::Response::parse(udp.payload())
                    .expect("packets from DNS sentinels on port 53 to be DNS packets");

                self.received_udp_dns_responses.insert(
                    (upstream.clone(), response.id(), udp.destination_port()),
                    packet.clone(),
                );

                if !response.truncated() {
                    let transport = DnsTransport::Udp {
                        local_port: udp.destination_port(),
                    };

                    self.handle_dns_response(upstream, transport, &response);
                }

                return;
            }

            let Some(id) = ProbeId::from_payload(udp.payload()) else {
                tracing::error!("UDP probe payload does not contain a probe ID");
                return;
            };

            if self.sent_probes.iter().any(|(sent, _)| *sent == id) {
                self.record_received_response(id, packet, now);
                return;
            }

            self.record_received_request(id, packet.clone(), now);

            if let Some(reply) = icmp_error.or_else(|| echo_reply(packet)) {
                self.send(reply);
            }
            return;
        }

        if self.tcp_dns_client.accepts(&packet) {
            self.tcp_dns_client.handle_inbound(packet);
            return;
        }

        if self.tcp_client.accepts(&packet) {
            self.tcp_client.handle_inbound(packet);
            self.record_tcp_responses(now);
            return;
        }

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type()
        {
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return;
            };

            self.record_received_request(id, packet.clone(), now);
            self.handle_icmp_request(&packet, echo, icmp.payload());

            return;
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
        {
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return;
            };

            self.record_received_request(id, packet.clone(), now);
            self.handle_icmp_request(&packet, echo, icmp.payload());

            return;
        }

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoReply(_) = icmp.icmp_type()
        {
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return;
            };

            self.record_received_response(id, packet, now);
            return;
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoReply(_) = icmp.icmp_type()
        {
            let Some(id) = ProbeId::from_payload(icmp.payload()) else {
                tracing::error!("ICMP probe payload does not contain a probe ID");
                return;
            };

            self.record_received_response(id, packet, now);
            return;
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
            return;
        }

        tracing::error!(?packet, "Unhandled packet");
    }

    pub(crate) fn update_relays<'a>(
        &mut self,
        to_remove: impl Iterator<Item = RelayId>,
        to_add: impl Iterator<Item = (&'a RelayId, &'a Host<SimRelay>)> + 'a,
        now: Instant,
    ) {
        let to_add = map_explode(to_add, format!("client_{}", self.id)).collect();
        self.sut_mut()
            .update_relays(to_remove.collect(), to_add, now)
    }

    pub(crate) fn handle_dns_response(
        &mut self,
        upstream: dns::Upstream,
        transport: DnsTransport,
        response: &dns_types::Response,
    ) {
        let domain = response.domain();
        if response.qtype() == RecordType::PTR && dns::is_in_device_domain(&domain) {
            let records = response
                .records()
                .map(|record| {
                    let ttl = record.ttl().as_secs();

                    (record.into_data().flatten_into(), ttl)
                })
                .collect();

            self.device_listings.insert(
                (domain, upstream, response.id(), transport),
                (
                    response.response_code(),
                    records,
                    response.note().map(ToOwned::to_owned),
                ),
            );
        }

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

    fn handle_icmp_request(&mut self, packet: &IpPacket, echo: IcmpEchoHeader, payload: &[u8]) {
        let reply = ip_packet::make::icmp_reply_packet(
            packet.destination(),
            packet.source(),
            echo.seq,
            echo.id,
            payload,
        )
        .expect("src and dst are taken from incoming packet");

        self.send(reply);
    }

    fn record_received_request(&mut self, id: ProbeId, packet: IpPacket, at: Instant) {
        self.probe_observations
            .push(ProbeObservation::RequestReceived(ReceivedRequest {
                id: Some(id),
                at,
                remote: Remote::Client(self.id),
                gateway_order: None,
                dns_nat_version: None,
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

    fn record_tcp_responses(&mut self, at: Instant) {
        while let Some(response) = self.tcp_client.poll_response() {
            match response {
                crate::tcp::Response::Packet { probe, packet } => {
                    self.record_received_response(probe, packet, at)
                }
                crate::tcp::Response::Echoed { probe } => {
                    self.probe_observations
                        .push(ProbeObservation::StreamCompleted(CompletedStream {
                            id: probe,
                            client: self.id,
                        }))
                }
            }
        }
    }

    pub(crate) fn clear_packets(&mut self) {
        self.sent_udp_dns_queries.clear();
        self.received_udp_dns_responses.clear();
        self.sent_tcp_dns_queries.clear();
        self.received_tcp_dns_responses.clear();
        self.device_listings.clear();
    }

    pub(crate) fn clear_probe_observations(&mut self) {
        self.probe_observations.clear();
        self.tcp_client.forget_probes();
    }

    fn latest_probe_for(&self, protocol: ProbeProtocol) -> Option<ProbeId> {
        self.sent_probes
            .iter()
            .rev()
            .find_map(|(id, candidate)| (*candidate == protocol).then_some(*id))
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

    if let Some(tcp) = packet.as_tcp() {
        return Some(ProbeProtocol::Tcp {
            sport: SPort(tcp.source_port()),
            dport: DPort(tcp.destination_port()),
        });
    }

    let udp = packet.as_udp()?;

    Some(ProbeProtocol::Udp {
        sport: SPort(udp.source_port()),
        dport: DPort(udp.destination_port()),
    })
}

impl Host<SimClient> {
    /// Takes one turn with what has arrived by `now` and puts what it sent onto the network.
    ///
    /// Returns the event for the portal or another host and whether it has more to do at `now`.
    pub(crate) fn step(
        &mut self,
        global_dns_records: &DnsRecords,
        transmits: &mut BufferedTransmits,
        now: Instant,
    ) -> (Option<ClientEvent>, bool) {
        let arrived = std::iter::from_fn(|| self.poll_inbox(now)).collect::<Vec<_>>();
        let (event, busy) = self.exec_mut(|c| {
            c.tunnel.receive(arrived);
            c.drive_apps(now);

            let (event, mut busy) = c.tunnel.poll_event(now);

            busy |= c.answer_dns_query(global_dns_records);
            while let Ok(mut batch) = c.tunnel.ends.tun_outbound.try_recv() {
                for packet in batch.drain() {
                    c.on_received_packet(packet, now);
                }
                busy = true;
            }

            (event.and_then(|event| c.handle_local_event(event)), busy)
        });

        for transmit in self.exec_mut(|c| c.tunnel.take_sent()) {
            transmits.push_from(transmit, self, now);
        }

        (event, busy)
    }
}

impl SimClient {
    /// Handles `event` if it only concerns the Client, and returns it otherwise.
    fn handle_local_event(&mut self, event: ClientEvent) -> Option<ClientEvent> {
        match event {
            ClientEvent::ResourcesChanged { resources } => {
                self.observed_resource_list = resources;
                None
            }
            ClientEvent::DnsRecordsChanged { records } => {
                self.dns_resource_record_cache = records;
                None
            }
            ClientEvent::TunInterfaceUpdated(config) => {
                if self.dns_by_sentinel == config.dns_by_sentinel
                    && self.routes == config.routes
                    && self.search_domain == config.search_domain
                {
                    tracing::error!(
                        "Emitted `TunInterfaceUpdated` without changing DNS servers, routes or search domain"
                    );
                }

                self.set_new_dns_servers(config.dns_by_sentinel);
                self.routes = config.routes;
                self.search_domain = config.search_domain;
                self.tcp_dns_client
                    .set_source_interface(config.ip.v4, config.ip.v6);
                None
            }
            event @ (ClientEvent::AddedIceCandidates { .. }
            | ClientEvent::RemovedIceCandidates { .. }
            | ClientEvent::RequestAccess { .. }
            | ClientEvent::DeviceDomainQueried { .. }
            | ClientEvent::DeviceDomainBrowsed { .. }
            | ClientEvent::NoRelays { .. }) => Some(event),
        }
    }
}

impl ExecMutScope for SimClient {
    type Guard = Guard;

    fn enter(&self) -> Self::Guard {
        self.malicious_behaviour.guard()
    }
}
