use super::reference::ReferenceState;
use super::sim_node::SimNode;
use super::sim_portal::SimPortal;
use super::sim_relay::SimRelay;
use super::QueryId;
use crate::tests::assertions::*;
use crate::tests::transition::Transition;
use crate::{dns::DnsQuery, ClientEvent, ClientState, GatewayEvent, GatewayState, Request};
use bimap::BiMap;
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        client::{ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns},
        gateway, ClientId, GatewayId, ResourceId,
    },
    DomainName,
};
use hickory_proto::{
    op::{MessageType, Query},
    rr::{rdata, RData, Record, RecordType},
    serialize::binary::BinDecodable as _,
};
use hickory_resolver::lookup::Lookup;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, MutableIpPacket, Packet as _};
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use rand::{rngs::StdRng, SeedableRng as _};
use secrecy::ExposeSecret as _;
use snownet::Transmit;
use std::collections::{BTreeMap, BTreeSet};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::{IpAddr, SocketAddr},
    ops::ControlFlow,
    str::FromStr as _,
    sync::Arc,
    time::{Duration, Instant},
};
use tracing::{debug_span, subscriber::DefaultGuard};
use tracing_subscriber::{util::SubscriberInitExt as _, EnvFilter};

/// The actual system-under-test.
///
/// [`proptest`] manipulates this using [`Transition`]s and we assert it against [`ReferenceState`].
pub(crate) struct TunnelTest {
    now: Instant,
    utc_now: DateTime<Utc>,

    client: SimNode<ClientId, ClientState>,
    gateway: SimNode<GatewayId, GatewayState>,
    relay: SimRelay<firezone_relay::Server<StdRng>>,
    portal: SimPortal,

    /// The DNS records created on the client as a result of received DNS responses.
    ///
    /// This contains results from both, queries to DNS resources and non-resources.
    client_dns_records: HashMap<DomainName, Vec<IpAddr>>,

    /// Bi-directional mapping between connlib's sentinel DNS IPs and the effective DNS servers.
    client_dns_by_sentinel: BiMap<IpAddr, SocketAddr>,

    pub(crate) client_sent_dns_queries: HashMap<QueryId, IpPacket<'static>>,
    pub(crate) client_received_dns_responses: HashMap<QueryId, IpPacket<'static>>,

    pub(crate) client_sent_icmp_requests: HashMap<(u16, u16), IpPacket<'static>>,
    pub(crate) client_received_icmp_replies: HashMap<(u16, u16), IpPacket<'static>>,
    pub(crate) gateway_received_icmp_requests: VecDeque<IpPacket<'static>>,

    #[allow(dead_code)]
    logger: DefaultGuard,
}

impl StateMachineTest for TunnelTest {
    type SystemUnderTest = Self;
    type Reference = ReferenceState;

    // Initialize the system under test from our reference state.
    fn init_test(
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
    ) -> Self::SystemUnderTest {
        let logger = tracing_subscriber::fmt()
            .with_test_writer()
            .with_env_filter(EnvFilter::from_default_env())
            .finish()
            .set_default();

        // Construct client, gateway and relay from the initial state.
        let mut client = ref_state
            .client
            .map_state(ClientState::new, debug_span!("client"));
        let mut gateway = ref_state
            .gateway
            .map_state(GatewayState::new, debug_span!("gateway"));
        let relay = ref_state.relay.map_state(
            |seed, ip_stack| {
                firezone_relay::Server::new(
                    ip_stack,
                    rand::rngs::StdRng::seed_from_u64(seed),
                    3478,
                    49152,
                    65535,
                )
            },
            debug_span!("relay"),
        );
        let portal = SimPortal::new(client.id, gateway.id, relay.id);

        // Configure client and gateway with the relay.
        client.init_relays([&relay], ref_state.now);
        gateway.init_relays([&relay], ref_state.now);

        client.update_upstream_dns(ref_state.upstream_dns_resolvers.clone());
        client.update_system_dns(ref_state.system_dns_resolvers.clone());

        let mut this = Self {
            now: ref_state.now,
            utc_now: ref_state.utc_now,
            client,
            gateway,
            portal,
            logger,
            relay,
            client_dns_records: Default::default(),
            client_dns_by_sentinel: Default::default(),
            client_sent_icmp_requests: Default::default(),
            client_received_icmp_replies: Default::default(),
            gateway_received_icmp_requests: Default::default(),
            client_received_dns_responses: Default::default(),
            client_sent_dns_queries: Default::default(),
        };

        let mut buffered_transmits = VecDeque::new();
        this.advance(ref_state, &mut buffered_transmits); // Perform initial setup before we apply the first transition.

        this
    }

    /// Apply a generated state transition to our system under test and assert against the reference state machine.
    ///
    /// This is equivalent to "arrange - act - assert" of a regular test:
    /// 1. We start out in a certain state (arrange)
    /// 2. We apply a [`Transition`] (act)
    /// 3. We assert against the reference state (assert)
    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        let mut buffered_transmits = VecDeque::new();

        // Act: Apply the transition
        match transition {
            Transition::AddCidrResource(r) => {
                state.client.add_resource(ResourceDescription::Cidr(r));
            }
            Transition::AddDnsResource { resource, .. } => state
                .client
                .add_resource(ResourceDescription::Dns(resource)),
            Transition::SendICMPPacketToNonResourceIp {
                dst,
                seq,
                identifier,
            } => {
                let packet = ip_packet::make::icmp_request_packet(
                    state.client.tunnel_ip(dst),
                    dst,
                    seq,
                    identifier,
                );

                buffered_transmits.extend(state.send_ip_packet_client_to_gateway(packet));
            }
            Transition::SendICMPPacketToResolvedNonResourceIp {
                idx,
                seq,
                identifier,
            } => {
                let dst = ref_state
                    .sample_resolved_non_resource_dst(&idx)
                    .expect("Transition to only be sampled if we have at least one non-resource resolved domain");
                let packet = ip_packet::make::icmp_request_packet(
                    state.client.tunnel_ip(dst),
                    dst,
                    seq,
                    identifier,
                );

                buffered_transmits.extend(state.send_ip_packet_client_to_gateway(packet));
            }
            Transition::SendICMPPacketToResource {
                idx,
                seq,
                identifier,
                src,
            } => {
                let dst = ref_state
                    .sample_resource_dst(&idx, src)
                    .expect("Transition to only be sampled if we have at least one resource");
                let dst = dst.into_actual_packet_dst(idx, src, &state.client_dns_records);
                let src = src.into_ip(state.client.tunnel_ip4, state.client.tunnel_ip6);

                let packet = ip_packet::make::icmp_request_packet(src, dst, seq, identifier);

                buffered_transmits.extend(state.send_ip_packet_client_to_gateway(packet));
            }
            Transition::SendDnsQuery {
                r_idx,
                r_type,
                query_id,
                dns_server_idx,
            } => {
                let (domain, _) = ref_state.sample_domain(&r_idx);
                let dns_server = ref_state.sample_dns_server(&dns_server_idx);

                let transmit = state.send_dns_query_for(domain, r_type, query_id, dns_server);

                buffered_transmits.extend(transmit)
            }
            Transition::Tick { millis } => {
                state.now += Duration::from_millis(millis);
            }
            Transition::UpdateSystemDnsServers { servers } => {
                state.client.update_system_dns(servers);
            }
            Transition::UpdateUpstreamDnsServers { servers } => {
                state.client.update_upstream_dns(servers);
            }
        };
        state.advance(ref_state, &mut buffered_transmits);
        assert!(buffered_transmits.is_empty()); // Sanity check to ensure we handled all packets.

        // Assert our properties: Check that our actual state is equivalent to our expectation (the reference state).
        assert_icmp_packets_properties(&mut state, ref_state);
        assert_dns_packets_properties(&state, ref_state);
        assert_eq!(
            state.effective_dns_servers(),
            ref_state.expected_dns_servers(),
            "Effective DNS servers should match either system or upstream DNS"
        );

        state
    }
}

impl TunnelTest {
    /// Exhaustively advances all state machines (client, gateway & relay).
    ///
    /// For our tests to work properly, each [`Transition`] needs to advance the state as much as possible.
    /// For example, upon the first packet to a resource, we need to trigger the connection intent and fully establish a connection.
    /// Dispatching a [`Transmit`] (read: packet) to a component can trigger more packets, i.e. receiving a STUN request may trigger a STUN response.
    ///
    /// Consequently, this function needs to loop until no component can make progress at which point we consider the [`Transition`] complete.
    fn advance(
        &mut self,
        ref_state: &ReferenceState,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        loop {
            if let Some((transmit, sending_socket)) = buffered_transmits.pop_front() {
                self.dispatch_transmit(
                    transmit,
                    sending_socket,
                    buffered_transmits,
                    &ref_state.global_dns_records,
                );
                continue;
            }

            if let Some(transmit) = self.client.state.poll_transmit() {
                let sending_socket = self.client.sending_socket_for(transmit.dst.ip());

                buffered_transmits.push_back((transmit, sending_socket));
                continue;
            }
            if let Some(event) = self.client.state.poll_event() {
                self.on_client_event(
                    self.client.id,
                    event,
                    &ref_state.client_cidr_resources,
                    &ref_state.client_dns_resources,
                    &ref_state.global_dns_records,
                );
                continue;
            }
            if let Some(query) = self.client.state.poll_dns_queries() {
                self.on_forwarded_dns_query(query, ref_state);
                continue;
            }
            if let Some(packet) = self.client.state.poll_packets() {
                self.on_client_received_packet(packet);
                continue;
            }

            if let Some(transmit) = self.gateway.state.poll_transmit() {
                let sending_socket = self.gateway.sending_socket_for(transmit.dst.ip());

                buffered_transmits.push_back((transmit, sending_socket));
                continue;
            }
            if let Some(event) = self.gateway.state.poll_event() {
                self.on_gateway_event(self.gateway.id, event);
                continue;
            }
            if let Some(message) = self.relay.state.next_command() {
                match message {
                    firezone_relay::Command::SendMessage { payload, recipient } => {
                        let dst = recipient.into_socket();
                        let src = self
                            .relay
                            .sending_socket_for(dst, 3478)
                            .expect("relay to never emit packets without a matching socket");

                        if let ControlFlow::Break(_) = self.try_handle_client(dst, src, &payload) {
                            continue;
                        }

                        if let ControlFlow::Break(_) = self.try_handle_gateway(
                            dst,
                            src,
                            &payload,
                            buffered_transmits,
                            &ref_state.global_dns_records,
                        ) {
                            continue;
                        }

                        panic!("Unhandled packet: {src} -> {dst}")
                    }

                    firezone_relay::Command::CreateAllocation { port, family } => {
                        self.relay.allocations.insert((family, port));
                    }
                    firezone_relay::Command::FreeAllocation { port, family } => {
                        self.relay.allocations.remove(&(family, port));
                    }
                }
                continue;
            }

            if self.handle_timeout(self.now, self.utc_now) {
                continue;
            }

            break;
        }
    }

    /// Returns the _effective_ DNS servers that connlib is using.
    fn effective_dns_servers(&self) -> BTreeSet<SocketAddr> {
        self.client_dns_by_sentinel
            .right_values()
            .copied()
            .collect()
    }

    /// Forwards time to the given instant iff the corresponding component would like that (i.e. returns a timestamp <= from `poll_timeout`).
    ///
    /// Tying the forwarding of time to the result of `poll_timeout` gives us better coverage because in production, we suspend until the value of `poll_timeout`.
    fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) -> bool {
        let mut any_advanced = false;

        if self.client.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.client
                .span
                .in_scope(|| self.client.state.handle_timeout(now));
        };

        if self.gateway.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.gateway
                .span
                .in_scope(|| self.gateway.state.handle_timeout(now, utc_now))
        };

        if self.relay.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.relay
                .span
                .in_scope(|| self.relay.state.handle_timeout(now))
        };

        any_advanced
    }

    fn send_ip_packet_client_to_gateway(
        &mut self,
        packet: MutableIpPacket<'_>,
    ) -> Option<(Transmit<'static>, Option<SocketAddr>)> {
        {
            let packet = packet.to_owned().into_immutable();

            if let Some(icmp) = packet.as_icmp() {
                let echo_request = icmp.as_echo_request().expect("to be echo request");

                self.client_sent_icmp_requests
                    .insert((echo_request.sequence(), echo_request.identifier()), packet);
            }
        }

        {
            let packet = packet.to_owned().into_immutable();

            if let Some(udp) = packet.as_udp() {
                if let Ok(message) = hickory_proto::op::Message::from_bytes(udp.payload()) {
                    debug_assert_eq!(
                        message.message_type(),
                        MessageType::Query,
                        "every DNS message sent from the client should be a DNS query"
                    );

                    self.client_sent_dns_queries.insert(message.id(), packet);
                }
            }
        }

        let transmit = self
            .client
            .span
            .in_scope(|| self.client.state.encapsulate(packet, self.now))?;
        let transmit = transmit.into_owned();
        let sending_socket = self.client.sending_socket_for(transmit.dst.ip());

        Some((transmit, sending_socket))
    }

    fn send_ip_packet_gateway_to_client(
        &mut self,
        packet: MutableIpPacket<'_>,
    ) -> Option<(Transmit<'static>, Option<SocketAddr>)> {
        let transmit = self
            .gateway
            .span
            .in_scope(|| self.gateway.state.encapsulate(packet, self.now))?;
        let transmit = transmit.into_owned();
        let sending_socket = self.gateway.sending_socket_for(transmit.dst.ip());

        Some((transmit, sending_socket))
    }

    /// Dispatches a [`Transmit`] to the correct component.
    ///
    /// This function is basically the "network layer" of our tests.
    /// It takes a [`Transmit`] and checks, which component accepts it, i.e. has configured the correct IP address.
    /// Our tests don't have a concept of a network topology.
    /// This means, components can have IP addresses in completely different subnets, yet this function will still "route" them correctly.
    fn dispatch_transmit(
        &mut self,
        transmit: Transmit,
        sending_socket: Option<SocketAddr>,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
    ) {
        let dst = transmit.dst;
        let payload = &transmit.payload;

        let Some(src) = sending_socket else {
            tracing::warn!("Dropping packet to {dst}: no socket");
            return;
        };

        if self
            .try_handle_relay(dst, src, payload, buffered_transmits)
            .is_break()
        {
            return;
        }

        let src = transmit
            .src
            .expect("all packets without src should have been handled via relays");

        if self.try_handle_client(dst, src, payload).is_break() {
            return;
        }

        if self
            .try_handle_gateway(dst, src, payload, buffered_transmits, global_dns_records)
            .is_break()
        {
            return;
        }

        panic!("Unhandled packet: {src} -> {dst}")
    }

    fn try_handle_relay(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) -> ControlFlow<()> {
        if !self.relay.wants(dst) {
            return ControlFlow::Continue(());
        }

        self.relay
            .handle_packet(payload, src, dst, self.now, buffered_transmits);

        ControlFlow::Break(())
    }

    fn try_handle_client(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
    ) -> ControlFlow<()> {
        let mut buffer = [0u8; 2000];

        if !self.client.wants(dst) {
            return ControlFlow::Continue(());
        }

        if let Some(packet) = self.client.span.in_scope(|| {
            self.client
                .state
                .decapsulate(dst, src, payload, self.now, &mut buffer)
        }) {
            self.on_client_received_packet(packet);
        };

        ControlFlow::Break(())
    }

    fn try_handle_gateway(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
    ) -> ControlFlow<()> {
        let mut buffer = [0u8; 2000];

        if !self.gateway.wants(dst) {
            return ControlFlow::Continue(());
        }

        if let Some(packet) = self.gateway.span.in_scope(|| {
            self.gateway
                .state
                .decapsulate(dst, src, payload, self.now, &mut buffer)
        }) {
            let packet = packet.to_owned();

            if packet.as_icmp().is_some() {
                self.gateway_received_icmp_requests
                    .push_back(packet.clone());

                let echo_response = ip_packet::make::icmp_response_packet(packet);
                let maybe_transmit = self.send_ip_packet_gateway_to_client(echo_response);

                buffered_transmits.extend(maybe_transmit);

                return ControlFlow::Break(());
            }

            if packet.as_udp().is_some() {
                let response = ip_packet::make::dns_ok_response(packet, |name| {
                    global_dns_records
                        .get(&hickory_name_to_domain(name.clone()))
                        .cloned()
                        .into_iter()
                        .flatten()
                });

                let maybe_transmit = self.send_ip_packet_gateway_to_client(response);
                buffered_transmits.extend(maybe_transmit);

                return ControlFlow::Break(());
            }

            panic!("Unhandled packet")
        };

        ControlFlow::Break(())
    }

    fn on_client_event(
        &mut self,
        src: ClientId,
        event: ClientEvent,
        client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
        client_dns_resource: &BTreeMap<ResourceId, ResourceDescriptionDns>,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
    ) {
        match event {
            ClientEvent::NewIceCandidate { candidate, .. } => self.gateway.span.in_scope(|| {
                self.gateway
                    .state
                    .add_ice_candidate(src, candidate, self.now)
            }),
            ClientEvent::InvalidatedIceCandidate { candidate, .. } => self
                .gateway
                .span
                .in_scope(|| self.gateway.state.remove_ice_candidate(src, candidate)),
            ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids,
            } => {
                let (gateway, site) = self.portal.handle_connection_intent(
                    resource,
                    connected_gateway_ids,
                    client_cidr_resources,
                    client_dns_resource,
                );

                let request = self
                    .client
                    .span
                    .in_scope(|| {
                        self.client.state.create_or_reuse_connection(
                            resource,
                            gateway,
                            site,
                            HashSet::default(),
                            HashSet::default(),
                        )
                    })
                    .unwrap();

                let resource_id = request.resource_id();

                // Resolve the domain name that we want to talk to to the IP that we generated as part of the Transition for sending a DNS query.
                let resolved_ips = request
                    .domain_name()
                    .into_iter()
                    .flat_map(|domain| global_dns_records.get(&domain).cloned().into_iter())
                    .flat_map(|ips| ips.into_iter().map(IpNetwork::from))
                    .collect();

                let resource = map_client_resource_to_gateway_resource(
                    client_cidr_resources,
                    client_dns_resource,
                    resolved_ips,
                    resource_id,
                );

                match request {
                    Request::NewConnection(new_connection) => {
                        let connection_accepted = self
                            .gateway
                            .span
                            .in_scope(|| {
                                self.gateway.state.accept(
                                    self.client.id,
                                    snownet::Offer {
                                        session_key: new_connection
                                            .client_preshared_key
                                            .expose_secret()
                                            .0
                                            .into(),
                                        credentials: snownet::Credentials {
                                            username: new_connection
                                                .client_payload
                                                .ice_parameters
                                                .username,
                                            password: new_connection
                                                .client_payload
                                                .ice_parameters
                                                .password,
                                        },
                                    },
                                    self.client.state.public_key(),
                                    self.client.tunnel_ip4,
                                    self.client.tunnel_ip6,
                                    HashSet::default(),
                                    HashSet::default(),
                                    new_connection.client_payload.domain,
                                    None, // TODO: How to generate expiry?
                                    resource,
                                    self.now,
                                )
                            })
                            .unwrap();

                        self.client
                            .span
                            .in_scope(|| {
                                self.client.state.accept_answer(
                                    snownet::Answer {
                                        credentials: snownet::Credentials {
                                            username: connection_accepted.ice_parameters.username,
                                            password: connection_accepted.ice_parameters.password,
                                        },
                                    },
                                    resource_id,
                                    self.gateway.state.public_key(),
                                    connection_accepted.domain_response,
                                    self.now,
                                )
                            })
                            .unwrap();
                    }
                    Request::ReuseConnection(reuse_connection) => {
                        if let Some(domain_response) = self.gateway.span.in_scope(|| {
                            self.gateway.state.allow_access(
                                resource,
                                self.client.id,
                                None,
                                reuse_connection.payload,
                            )
                        }) {
                            self.client
                                .span
                                .in_scope(|| {
                                    self.client
                                        .state
                                        .received_domain_parameters(resource_id, domain_response)
                                })
                                .unwrap();
                        };
                    }
                };
            }
            ClientEvent::RefreshResources { .. } => {
                tracing::warn!("Unimplemented");
            }
            ClientEvent::ResourcesChanged { .. } => {
                tracing::warn!("Unimplemented");
            }
            ClientEvent::DnsServersChanged { dns_by_sentinel } => {
                self.client_dns_by_sentinel = dns_by_sentinel;
            }
        }
    }

    fn on_gateway_event(&mut self, src: GatewayId, event: GatewayEvent) {
        match event {
            GatewayEvent::NewIceCandidate { candidate, .. } => self.client.span.in_scope(|| {
                self.client
                    .state
                    .add_ice_candidate(src, candidate, self.now)
            }),
            GatewayEvent::InvalidIceCandidate { candidate, .. } => self
                .client
                .span
                .in_scope(|| self.client.state.remove_ice_candidate(src, candidate)),
        }
    }

    /// Process an IP packet received on the client.
    fn on_client_received_packet(&mut self, packet: IpPacket<'_>) {
        if let Some(icmp) = packet.as_icmp() {
            let echo_reply = icmp.as_echo_reply().expect("to be echo reply");

            self.client_received_icmp_replies.insert(
                (echo_reply.sequence(), echo_reply.identifier()),
                packet.to_owned(),
            );

            return;
        };

        if let Some(udp) = packet.as_udp() {
            if udp.get_source() == 53 {
                let mut message = hickory_proto::op::Message::from_bytes(udp.payload())
                    .expect("ip packets on port 53 to be DNS packets");

                self.client_received_dns_responses
                    .insert(message.id(), packet.to_owned());

                for record in message.take_answers().into_iter() {
                    let domain = hickory_name_to_domain(record.name().clone());

                    let ip = match record.data() {
                        Some(RData::A(rdata::A(ip4))) => IpAddr::from(*ip4),
                        Some(RData::AAAA(rdata::AAAA(ip6))) => IpAddr::from(*ip6),
                        unhandled => {
                            panic!("Unexpected record data: {unhandled:?}")
                        }
                    };

                    self.client_dns_records.entry(domain).or_default().push(ip);
                }

                // Ensure all IPs are always sorted.
                for ips in self.client_dns_records.values_mut() {
                    ips.sort()
                }

                return;
            }
        }

        unimplemented!("Unhandled packet")
    }

    fn send_dns_query_for(
        &mut self,
        domain: DomainName,
        r_type: RecordType,
        query_id: u16,
        dns_server: SocketAddr,
    ) -> Option<(Transmit<'static>, Option<SocketAddr>)> {
        let dns_server = *self
            .client_dns_by_sentinel
            .get_by_right(&dns_server)
            .expect("to have a sentinel DNS server for the sampled one");

        let name = domain_to_hickory_name(domain);

        let src = self.client.tunnel_ip(dns_server);

        let packet = ip_packet::make::dns_query(
            name,
            r_type,
            SocketAddr::new(src, 9999), // An application would pick a random source port that is free.
            SocketAddr::new(dns_server, 53),
            query_id,
        );

        self.send_ip_packet_client_to_gateway(packet)
    }

    // TODO: Should we vary the following things via proptests?
    // - Forwarded DNS query timing out?
    // - hickory error?
    // - TTL?
    fn on_forwarded_dns_query(&mut self, query: DnsQuery<'static>, ref_state: &ReferenceState) {
        let resolved_ips = &ref_state
            .global_dns_records
            .get(&query.name)
            .expect("Deferred DNS query to be for known domain");

        let name = domain_to_hickory_name(query.name.clone());
        let record_type = query.record_type;

        let record_data = resolved_ips
            .iter()
            .filter_map(|ip| match (record_type, ip) {
                (RecordType::A, IpAddr::V4(v4)) => Some(RData::A((*v4).into())),
                (RecordType::AAAA, IpAddr::V6(v6)) => Some(RData::AAAA((*v6).into())),
                (RecordType::A, IpAddr::V6(_)) | (RecordType::AAAA, IpAddr::V4(_)) => None,
                _ => unreachable!(),
            })
            .map(|rdata| Record::from_rdata(name.clone(), 86400_u32, rdata))
            .collect::<Arc<_>>();

        self.client.state.on_dns_result(
            query,
            Ok(Ok(Ok(Lookup::new_with_max_ttl(
                Query::query(name, record_type),
                record_data,
            )))),
        );
    }
}

fn map_client_resource_to_gateway_resource(
    client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
    client_dns_resources: &BTreeMap<ResourceId, ResourceDescriptionDns>,
    resolved_ips: Vec<IpNetwork>,
    resource_id: ResourceId,
) -> gateway::ResourceDescription<gateway::ResolvedResourceDescriptionDns> {
    let cidr_resource = client_cidr_resources.iter().find_map(|(_, r)| {
        (r.id == resource_id).then_some(gateway::ResourceDescription::Cidr(
            gateway::ResourceDescriptionCidr {
                id: r.id,
                address: r.address,
                name: r.name.clone(),
                filters: Vec::new(),
            },
        ))
    });
    let dns_resource = client_dns_resources.get(&resource_id).map(|r| {
        gateway::ResourceDescription::Dns(gateway::ResolvedResourceDescriptionDns {
            id: r.id,
            name: r.name.clone(),
            filters: Vec::new(),
            domain: r.address.clone(),
            addresses: resolved_ips.clone(),
        })
    });

    cidr_resource
        .or(dns_resource)
        .expect("resource to be a known CIDR or DNS resource")
}

fn hickory_name_to_domain(mut name: hickory_proto::rr::Name) -> DomainName {
    name.set_fqdn(false); // Hack to work around hickory always parsing as FQ
    let name = name.to_string();

    let domain = DomainName::from_chars(name.chars()).unwrap();
    debug_assert_eq!(name, domain.to_string());

    domain
}

fn domain_to_hickory_name(domain: DomainName) -> hickory_proto::rr::Name {
    let domain = domain.to_string();

    let name = hickory_proto::rr::Name::from_str(&domain).unwrap();
    debug_assert_eq!(name.to_string(), domain);

    name
}
