use crate::{ClientEvent, ClientState, GatewayEvent, GatewayState, Request};
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        client::{ResourceDescription, ResourceDescriptionCidr, SiteId},
        gateway, ClientId, GatewayId, RelayId, ResourceId,
    },
    proptest::cidr_resource,
    StaticSecret,
};
use firezone_relay::ClientSocket;
use ip_network::Ipv4Network;
use ip_network_table::IpNetworkTable;
use ip_packet::IpPacket;
use pretty_assertions::assert_eq;
use proptest::{
    arbitrary::any,
    prop_oneof, sample,
    strategy::{Just, Strategy},
    test_runner::Config,
};
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use rand::{rngs::StdRng, SeedableRng};
use secrecy::ExposeSecret;
use snownet::{RelaySocket, Transmit};
use std::{
    collections::{HashSet, VecDeque},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    ops::ControlFlow,
    time::{Duration, Instant, SystemTime},
};
use tracing::{error_span, subscriber::DefaultGuard, Span};
use tracing_subscriber::util::SubscriberInitExt as _;

proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        // Enable verbose mode to make the state machine test print the
        // transitions for each case.
        verbose: 1,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

/// The actual system-under-test.
///
/// [`proptest`] manipulates this using [`Transition`]s and we assert it against [`ReferenceState`].
struct TunnelTest {
    now: Instant,
    utc_now: DateTime<Utc>,

    client: SimNode<ClientId, ClientState>,
    gateway: SimNode<GatewayId, GatewayState>,
    relay: SimRelay<firezone_relay::Server<StdRng>>,
    portal: SimPortal,

    client_span: Span,
    gateway_span: Span,
    relay_span: Span,

    client_received_packets: VecDeque<IpPacket<'static>>,
    gateway_received_icmp_packets: VecDeque<(Instant, IpAddr, IpAddr)>,

    #[allow(dead_code)]
    logger: DefaultGuard,
    buffer: Box<[u8; 10_000]>,
}

#[derive(Clone, Copy, Debug)]
struct SimNode<ID, S> {
    id: ID,
    state: S,

    ip4_socket: Option<SocketAddrV4>,
    ip6_socket: Option<SocketAddrV6>,

    tunnel_ip4: Ipv4Addr,
    tunnel_ip6: Ipv6Addr,
}

#[derive(Debug, Clone)]
struct SimRelay<S> {
    id: RelayId,
    state: S,

    ip_stack: firezone_relay::IpStack,
}

/// Stub implementation of the portal.
///
/// Currently, we only simulate a connection between a single client and a single gateway on a single site.
#[derive(Debug, Clone)]
struct SimPortal {
    _client: ClientId,
    gateway: GatewayId,
    _relay: RelayId,
    site: SiteId,
}

impl SimPortal {
    /// Picks, which gateway and site we should connect to for the given resource.
    fn handle_connection_intent(
        &self,
        _resource: ResourceId,
        _connected_gateway_ids: HashSet<GatewayId>,
    ) -> (GatewayId, SiteId) {
        // TODO: Should we somehow vary how many gateways we connect to?

        (self.gateway, self.site)
    }
}

impl<ID, S> SimNode<ID, S> {
    fn map_state<T>(self, f: impl FnOnce(S) -> T) -> SimNode<ID, T> {
        SimNode {
            id: self.id,
            state: f(self.state),
            ip4_socket: self.ip4_socket,
            ip6_socket: self.ip6_socket,
            tunnel_ip4: self.tunnel_ip4,
            tunnel_ip6: self.tunnel_ip6,
        }
    }

    fn wants(&self, dst: SocketAddr) -> bool {
        self.ip4_socket.is_some_and(|s| SocketAddr::V4(s) == dst)
            || self.ip6_socket.is_some_and(|s| SocketAddr::V6(s) == dst)
    }

    fn sending_socket_for(&self, dst: SocketAddr) -> Option<SocketAddr> {
        Some(match dst {
            SocketAddr::V4(_) => self.ip4_socket?.into(),
            SocketAddr::V6(_) => self.ip6_socket?.into(),
        })
    }
}

impl SimRelay<firezone_relay::Server<StdRng>> {
    fn wants(&self, dst: SocketAddr) -> bool {
        self.ip_stack
            .as_v4()
            .is_some_and(|s| IpAddr::V4(*s) == dst.ip())
            || self
                .ip_stack
                .as_v6()
                .is_some_and(|s| IpAddr::V6(*s) == dst.ip())
    }

    fn sending_socket_for(&self, dst: SocketAddr, port: u16) -> Option<SocketAddr> {
        Some(match dst {
            SocketAddr::V4(_) => SocketAddr::V4(SocketAddrV4::new(*self.ip_stack.as_v4()?, port)),
            SocketAddr::V6(_) => {
                SocketAddr::V6(SocketAddrV6::new(*self.ip_stack.as_v6()?, port, 0, 0))
            }
        })
    }

    fn explode(&self, username: &str) -> (RelayId, RelaySocket, String, String, String) {
        let relay_socket = match self.ip_stack {
            firezone_relay::IpStack::Ip4(ip4) => RelaySocket::V4(SocketAddrV4::new(ip4, 3478)),
            firezone_relay::IpStack::Ip6(ip6) => {
                RelaySocket::V6(SocketAddrV6::new(ip6, 3478, 0, 0))
            }
            firezone_relay::IpStack::Dual { ip4, ip6 } => RelaySocket::Dual {
                v4: SocketAddrV4::new(ip4, 3478),
                v6: SocketAddrV6::new(ip6, 3478, 0, 0),
            },
        };

        let (username, password) = self.make_credentials(username);

        (
            self.id,
            relay_socket,
            username,
            password,
            "firezone".to_owned(),
        )
    }

    fn make_credentials(&self, username: &str) -> (String, String) {
        let expiry = SystemTime::now() + Duration::from_secs(60);

        let secs = expiry
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("expiry must be later than UNIX_EPOCH")
            .as_secs();

        let password =
            firezone_relay::auth::generate_password(self.state.auth_secret(), expiry, username);

        (format!("{secs}:{username}"), password)
    }
}

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
struct ReferenceState {
    now: Instant,
    utc_now: DateTime<Utc>,
    client: SimNode<ClientId, [u8; 32]>,
    gateway: SimNode<GatewayId, [u8; 32]>,
    relay: SimRelay<u64>,
    site: SiteId,

    /// Which resources the clients is aware of.
    client_cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    connected_resources: HashSet<ResourceId>,

    gateway_received_icmp_packets: VecDeque<(Instant, IpAddr, IpAddr)>,
}

impl StateMachineTest for TunnelTest {
    type SystemUnderTest = Self;
    type Reference = ReferenceState;

    // Initialize the system under test from our reference state.
    fn init_test(
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
    ) -> Self::SystemUnderTest {
        let mut client = ref_state
            .client
            .map_state(|key| ClientState::new(StaticSecret::from(key)));
        let mut gateway = ref_state
            .gateway
            .map_state(|key| GatewayState::new(StaticSecret::from(key)));
        let relay = SimRelay {
            state: firezone_relay::Server::new(
                ref_state.relay.ip_stack,
                rand::rngs::StdRng::seed_from_u64(ref_state.relay.state),
                49152,
                65535,
            ),
            ip_stack: ref_state.relay.ip_stack,
            id: ref_state.relay.id,
        };
        client.state.update_relays(
            HashSet::default(),
            HashSet::from([relay.explode("client")]),
            ref_state.now,
        );
        gateway.state.update_relays(
            HashSet::default(),
            HashSet::from([relay.explode("gateway")]),
            ref_state.now,
        );

        let portal = SimPortal {
            _client: client.id,
            gateway: gateway.id,
            _relay: relay.id,
            site: ref_state.site,
        };

        Self {
            now: ref_state.now,
            utc_now: ref_state.utc_now,
            client,
            gateway,
            portal,
            logger: tracing_subscriber::fmt()
                .with_test_writer()
                .with_env_filter("debug,str0m=trace")
                .finish()
                .set_default(),
            buffer: Box::new([0u8; 10_000]),
            client_received_packets: Default::default(),
            gateway_received_icmp_packets: Default::default(),
            client_span: error_span!("client"),
            gateway_span: error_span!("gateway"),
            relay_span: error_span!("relay"),
            relay,
        }
    }

    // Apply a generated state transition to our system under test and assert against the reference state machine.
    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        // 1. Apply the transition
        match transition {
            Transition::AddCidrResource(r) => {
                state.client_span.in_scope(|| {
                    state
                        .client
                        .state
                        .add_resources(&[ResourceDescription::Cidr(r)]);
                });
            }
            Transition::SendICMPPacketToRandomIp { src, dst } => {
                state.send_icmp_packet_client_to_gateway(src, dst);
            }
            Transition::SendICMPPacketToIp4Resource { src, r_idx } => {
                let dst = ref_state.sample_ipv4_cidr_resource_dst(&r_idx);

                state.send_icmp_packet_client_to_gateway(src, dst);
            }
            Transition::SendICMPPacketToIp6Resource { src, r_idx } => {
                let dst = ref_state.sample_ipv6_cidr_resource_dst(&r_idx);

                state.send_icmp_packet_client_to_gateway(src, dst);
            }
            Transition::Tick { millis } => {
                state.now += Duration::from_millis(millis);
            }
        };

        // 2. Advance all states as far as possible.
        state.advance(ref_state);

        // 3. Assert expected state
        // assert_eq!(state.client_emitted_events, ref_state.client_events);
        // assert_eq!(state.gateway_emitted_events, ref_state.gateway_events); TODO
        assert_eq!(
            state.gateway_received_icmp_packets,
            ref_state.gateway_received_icmp_packets
        );

        state
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    fn on_icmp_packet(&mut self, src: impl Into<IpAddr>, dst: impl Into<IpAddr>) {
        let src = src.into();
        let dst = dst.into();

        // We select which resource to send to based on the _longest match_ of the IP network.
        // We may have resources with overlapping IP ranges so it is important that we do this the same way as connlib.
        let Some((_, resource)) = self.client_cidr_resources.longest_match(dst) else {
            return;
        };
        let resource = resource.id;

        if !self.connected_resources.contains(&resource) {
            self.connected_resources.insert(resource);
            return;
        }

        self.gateway_received_icmp_packets
            .push_back((self.now, src, dst))
    }

    /// Samples an [`Ipv4Addr`] from _any_ of our IPv4 CIDR resources.
    fn sample_ipv4_cidr_resource_dst(&self, idx: &sample::Index) -> Ipv4Addr {
        let num_ip4_resources = self.client_cidr_resources.len().0;
        debug_assert!(num_ip4_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip4_resources);
        let (network, _) = self
            .client_cidr_resources
            .iter_ipv4()
            .nth(r_idx)
            .expect("index to be in range");

        let num_hosts = network.hosts().len();

        if num_hosts == 0 {
            debug_assert!(network.netmask() == 31 || network.netmask() == 32); // /31 and /32 don't have any hosts

            return network.network_address();
        }

        let addr_idx = idx.index(num_hosts);

        network.hosts().nth(addr_idx).expect("index to be in range")
    }

    /// Samples an [`Ipv6Addr`] from _any_ of our IPv6 CIDR resources.
    fn sample_ipv6_cidr_resource_dst(&self, idx: &sample::Index) -> Ipv6Addr {
        let num_ip6_resources = self.client_cidr_resources.len().1;
        debug_assert!(num_ip6_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip6_resources);
        let (network, _) = self
            .client_cidr_resources
            .iter_ipv6()
            .nth(r_idx)
            .expect("index to be in range");

        let num_hosts = network.subnets_with_prefix(128).len();

        let network = if num_hosts == 0 {
            debug_assert!(network.netmask() == 127 || network.netmask() == 128); // /127 and /128 don't have any hosts

            network
        } else {
            let addr_idx = idx.index(num_hosts);

            network
                .subnets_with_prefix(128)
                .nth(addr_idx)
                .expect("index to be in range")
        };

        network.network_address()
    }
}

impl TunnelTest {
    fn advance(&mut self, ref_state: &ReferenceState) {
        loop {
            if let Some(transmit) = self.client.state.poll_transmit() {
                let sending_socket = self.client.sending_socket_for(transmit.dst);

                self.dispatch_transmit(transmit, sending_socket);
                continue;
            }
            if let Some(event) = self.client.state.poll_event() {
                self.on_client_event(self.client.id, event, &ref_state.client_cidr_resources);
                continue;
            }
            if let Some(transmit) = self.gateway.state.poll_transmit() {
                let sending_socket = self.gateway.sending_socket_for(transmit.dst);

                self.dispatch_transmit(transmit, sending_socket);
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

                        if let ControlFlow::Break(_) = self.try_handle_gateway(dst, src, &payload) {
                            continue;
                        }

                        panic!("Unhandled packet: {src} -> {dst}")
                    }
                    firezone_relay::Command::CreateAllocation { .. } => {}
                    firezone_relay::Command::FreeAllocation { .. } => {}
                }
                continue;
            }

            if self.handle_timeout(self.now, self.utc_now) {
                continue;
            }

            break;
        }
    }

    /// Forwards time to the given instant iff the corresponding component would like that (i.e. returns a timestamp <= from `poll_timeout`).
    ///
    /// Tying the forwarding of time to the result of `poll_timeout` gives us better coverage because in production, we suspend until the value of `poll_timeout`.
    fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) -> bool {
        let mut any_advanced = false;

        if self.client.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.client_span
                .in_scope(|| self.client.state.handle_timeout(now));
        };

        if self.gateway.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.gateway_span
                .in_scope(|| self.gateway.state.handle_timeout(now, utc_now))
        };

        if self.relay.state.poll_timeout().is_some_and(|t| t <= now) {
            any_advanced = true;

            self.relay_span
                .in_scope(|| self.relay.state.handle_timeout(now))
        };

        any_advanced
    }

    fn send_icmp_packet_client_to_gateway(
        &mut self,
        src: impl Into<IpAddr>,
        dst: impl Into<IpAddr>,
    ) {
        let Some(transmit) = self.client_span.in_scope(|| {
            self.client.state.encapsulate(
                ip_packet::make::icmp_request_packet(src.into(), dst.into()),
                self.now,
            )
        }) else {
            return;
        };
        let transmit = transmit.into_owned();
        let sending_socket = self.client.sending_socket_for(transmit.dst);

        self.dispatch_transmit(transmit, sending_socket);
    }

    fn dispatch_transmit(&mut self, transmit: Transmit, sending_socket: Option<SocketAddr>) {
        let dst = transmit.dst;
        let payload = &transmit.payload;

        let Some(src) = sending_socket else {
            tracing::warn!("Dropping packet to {dst}: no socket");
            return;
        };

        if self.relay.wants(dst) {
            if dst.port() == 3478 {
                let _maybe_relay = self.relay_span.in_scope(|| {
                    self.relay
                        .state
                        .handle_client_input(payload, ClientSocket::new(src), self.now)
                });

                // TODO: Handle relaying
            }

            return;
        }

        let src = transmit
            .src
            .expect("to have handled all packets without src via relays");

        if let ControlFlow::Break(_) = self.try_handle_client(dst, src, payload) {
            return;
        }

        if let ControlFlow::Break(_) = self.try_handle_gateway(dst, src, payload) {
            return;
        }

        panic!("Unhandled packet: {src} -> {dst}")
    }

    fn try_handle_client(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
    ) -> ControlFlow<()> {
        if self.client.wants(dst) {
            if let Some(packet) = self.client_span.in_scope(|| {
                self.client
                    .state
                    .decapsulate(dst, src, payload, self.now, self.buffer.as_mut())
            }) {
                self.client_received_packets.push_back(packet.to_owned());
            };

            return ControlFlow::Break(());
        }

        ControlFlow::Continue(())
    }

    fn try_handle_gateway(
        &mut self,
        dst: SocketAddr,
        src: SocketAddr,
        payload: &[u8],
    ) -> ControlFlow<()> {
        if self.gateway.wants(dst) {
            if let Some(packet) = self.gateway_span.in_scope(|| {
                self.gateway
                    .state
                    .decapsulate(dst, src, payload, self.now, self.buffer.as_mut())
            }) {
                // TODO: Assert that it is an ICMP packet.

                self.gateway_received_icmp_packets.push_back((
                    self.now,
                    packet.source(),
                    packet.destination(),
                ));
            };

            return ControlFlow::Break(());
        }

        ControlFlow::Continue(())
    }

    fn on_client_event(
        &mut self,
        src: ClientId,
        event: ClientEvent,
        client_cidr_resource: &IpNetworkTable<ResourceDescriptionCidr>,
    ) {
        match event {
            ClientEvent::NewIceCandidate { candidate, .. } => self.client_span.in_scope(|| {
                self.gateway
                    .state
                    .add_ice_candidate(src, candidate, self.now)
            }),
            ClientEvent::InvalidatedIceCandidate { candidate, .. } => self
                .gateway_span
                .in_scope(|| self.gateway.state.remove_ice_candidate(src, candidate)),
            ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids,
            } => {
                let (gateway, site) = self
                    .portal
                    .handle_connection_intent(resource, connected_gateway_ids);

                // TODO: All of the below should be somehow encapsulated in `SimPortal`.

                let request = self
                    .client_span
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
                // TODO: For DNS resources, we need to come up with an IP that our resource resolves to on the other side.
                let resource =
                    map_client_resource_to_gateway_resource(client_cidr_resource, resource_id);

                match request {
                    Request::NewConnection(new_connection) => {
                        let connection_accepted = self
                            .gateway_span
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
                                    vec![
                                        self.client.tunnel_ip4.into(),
                                        self.client.tunnel_ip6.into(),
                                    ],
                                    HashSet::default(),
                                    HashSet::default(),
                                    new_connection.client_payload.domain,
                                    None, // TODO: How to generate expiry?
                                    resource,
                                    self.now,
                                )
                            })
                            .unwrap();

                        self.client_span
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
                        if let Some(domain_response) = self.gateway_span.in_scope(|| {
                            self.gateway.state.allow_access(
                                resource,
                                self.client.id,
                                None,
                                reuse_connection.payload,
                            )
                        }) {
                            self.client_span
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
        }
    }

    fn on_gateway_event(&mut self, src: GatewayId, event: GatewayEvent) {
        match event {
            GatewayEvent::NewIceCandidate { candidate, .. } => self.client_span.in_scope(|| {
                self.client
                    .state
                    .add_ice_candidate(src, candidate, self.now)
            }),
            GatewayEvent::InvalidIceCandidate { candidate, .. } => self
                .client_span
                .in_scope(|| self.client.state.remove_ice_candidate(src, candidate)),
        }
    }
}

fn map_client_resource_to_gateway_resource(
    client_cidr_resource: &IpNetworkTable<ResourceDescriptionCidr>,
    resource_id: ResourceId,
) -> gateway::ResourceDescription<gateway::ResolvedResourceDescriptionDns> {
    let client_resource = client_cidr_resource
        .iter()
        .find_map(|(_, r)| (r.id == resource_id).then_some(r.clone()))
        .expect("to know about ID");

    gateway::ResourceDescription::<gateway::ResolvedResourceDescriptionDns>::Cidr(
        gateway::ResourceDescriptionCidr {
            id: client_resource.id,
            address: client_resource.address,
            name: client_resource.name,
            filters: Vec::new(),
        },
    )
}

/// Generates a [`Transition`] that sends an ICMP packet to a random IP.
///
/// By chance, it could be that we pick a resource IP here.
/// That is okay as our reference state machine checks separately whether we are pinging a resource here.
fn icmp_to_random_ip() -> impl Strategy<Value = Transition> {
    (any::<IpAddr>(), any::<IpAddr>())
        .prop_map(|(src, dst)| Transition::SendICMPPacketToRandomIp { src, dst })
}

fn icmp_to_ipv4_cidr_resource() -> impl Strategy<Value = Transition> {
    (any::<Ipv4Addr>(), any::<sample::Index>())
        .prop_map(|(src, r_idx)| Transition::SendICMPPacketToIp4Resource { src, r_idx })
}

fn icmp_to_ipv6_cidr_resource() -> impl Strategy<Value = Transition> {
    (any::<Ipv6Addr>(), any::<sample::Index>())
        .prop_map(|(src, r_idx)| Transition::SendICMPPacketToIp6Resource { src, r_idx })
}

fn client_id() -> impl Strategy<Value = ClientId> {
    (any::<u128>()).prop_map(ClientId::from_u128)
}

fn gateway_id() -> impl Strategy<Value = GatewayId> {
    (any::<u128>()).prop_map(GatewayId::from_u128)
}

fn site_id() -> impl Strategy<Value = SiteId> {
    (any::<u128>()).prop_map(SiteId::from_u128)
}

/// Generates an IPv4 address for the tunnel interface.
///
/// We use the CG-NAT range for IPv4.
fn tunnel_ip4() -> impl Strategy<Value = Ipv4Addr> {
    any::<sample::Index>().prop_map(|idx| {
        let cgnat_block = Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 10).unwrap();

        let mut hosts = cgnat_block.hosts();

        hosts.nth(idx.index(hosts.len())).unwrap()
    })
}

/// Generates an IPv6 address for the tunnel interface.
///
/// TODO: Which subnet do we use here?
fn tunnel_ip6() -> impl Strategy<Value = Ipv6Addr> {
    any::<Ipv6Addr>()
}

fn sim_node_prototype<ID>(
    id: impl Strategy<Value = ID>,
) -> impl Strategy<Value = SimNode<ID, [u8; 32]>>
where
    ID: fmt::Debug,
{
    (
        id,
        any::<[u8; 32]>(),
        firezone_relay::proptest::ip_stack(), // We are re-using the strategy here because it is exactly what we need although we are generating a node here and not a relay.
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        any::<u16>().prop_filter("port must not be 0", |p| *p != 0),
        tunnel_ip4(),
        tunnel_ip6(),
    )
        .prop_filter_map(
            "must have at least one socket address",
            |(id, key, ip_stack, v4_port, v6_port, tunnel_ip4, tunnel_ip6)| {
                let ip4_socket = ip_stack.as_v4().map(|ip| SocketAddrV4::new(*ip, v4_port));
                let ip6_socket = ip_stack
                    .as_v6()
                    .map(|ip| SocketAddrV6::new(*ip, v6_port, 0, 0));

                Some(SimNode {
                    id,
                    state: key,
                    ip4_socket,
                    ip6_socket,
                    tunnel_ip4,
                    tunnel_ip6,
                })
            },
        )
}

fn sim_relay_prototype() -> impl Strategy<Value = SimRelay<u64>> {
    (
        any::<u64>(),
        firezone_relay::proptest::ip_stack(),
        any::<u128>(),
    )
        .prop_map(|(seed, ip_stack, id)| SimRelay {
            id: RelayId::from_u128(id),
            state: seed,
            ip_stack,
        })
}

/// Implementation of our reference state machine.
///
/// The logic in here represents what we expect the [`ClientState`] & [`GatewayState`] to do.
/// Care has to be taken that we don't implement things in a buggy way here.
/// After all, if your test has bugs, it won't catch any in the actual implementation.
impl ReferenceStateMachine for ReferenceState {
    type State = Self;
    type Transition = Transition;

    fn init_state() -> proptest::prelude::BoxedStrategy<Self::State> {
        (
            sim_node_prototype(client_id()),
            sim_node_prototype(gateway_id()),
            sim_relay_prototype(),
            site_id(),
            Just(Instant::now()),
            Just(Utc::now()),
        )
            .prop_filter(
                "client and gateway priv key must be different",
                |(c, g, _, _, _, _)| c.state != g.state,
            )
            .prop_filter(
                "viable network path must exist",
                |(client, gateway, relay, __, _, _)| {
                    if client.ip4_socket.is_some()
                        && relay.ip_stack.as_v4().is_none()
                        && gateway.ip4_socket.is_none()
                    {
                        return false;
                    }

                    if client.ip6_socket.is_some()
                        && relay.ip_stack.as_v6().is_none()
                        && gateway.ip6_socket.is_none()
                    {
                        return false;
                    }

                    true
                },
            )
            .prop_map(|(client, gateway, relay, site, now, utc_now)| Self {
                now,
                utc_now,
                client,
                gateway,
                relay,
                client_cidr_resources: IpNetworkTable::new(),
                connected_resources: Default::default(),
                gateway_received_icmp_packets: Default::default(),
                site,
            })
            .boxed()
    }

    /// Defines the [`Strategy`] on how we can [transition](Transition) from the current [`ReferenceState`].
    ///
    /// This is invoked by proptest repeatedly to explore further state transitions.
    /// Here, we should only generate [`Transition`]s that make sense for the current state.
    fn transitions(state: &Self::State) -> proptest::prelude::BoxedStrategy<Self::Transition> {
        let add_cidr_resource = cidr_resource(8).prop_map(Transition::AddCidrResource);
        let tick = (0..=1000u64).prop_map(|millis| Transition::Tick { millis });

        let (num_ip4_resources, num_ip6_resources) = state.client_cidr_resources.len();

        let weight_ip4 = if num_ip4_resources == 0 { 0 } else { 1 };
        let weight_ip6 = if num_ip6_resources == 0 { 0 } else { 1 };

        // Note: We use weighted strategies here to conditionally only include the ICMP strategies if we have a resource.
        prop_oneof![
            1 => add_cidr_resource,
            1 => tick,
            1 => icmp_to_random_ip(),
            weight_ip4 => icmp_to_ipv4_cidr_resource(),
            weight_ip6 => icmp_to_ipv6_cidr_resource()
        ]
        .boxed()
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        match transition {
            Transition::AddCidrResource(r) => {
                state.client_cidr_resources.insert(r.address, r.clone());
            }
            Transition::SendICMPPacketToRandomIp { src, dst } => {
                state.on_icmp_packet(*src, *dst);
            }
            Transition::SendICMPPacketToIp4Resource { src, r_idx } => {
                let dst = state.sample_ipv4_cidr_resource_dst(r_idx);
                state.on_icmp_packet(*src, dst);
            }
            Transition::SendICMPPacketToIp6Resource { src, r_idx } => {
                let dst = state.sample_ipv6_cidr_resource_dst(r_idx);
                state.on_icmp_packet(*src, dst);
            }
            Transition::Tick { millis } => state.now += Duration::from_millis(*millis),
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    fn preconditions(state: &Self::State, transition: &Self::Transition) -> bool {
        match transition {
            Transition::AddCidrResource(_) => true,
            Transition::Tick { .. } => true,
            Transition::SendICMPPacketToRandomIp { src, dst } => {
                src.is_ipv4() == dst.is_ipv4() && src != dst
            }
            Transition::SendICMPPacketToIp4Resource { src, r_idx } => {
                if state.client_cidr_resources.len().0 == 0 {
                    return false;
                }

                let dst = state.sample_ipv4_cidr_resource_dst(r_idx);

                src != &dst
            }
            Transition::SendICMPPacketToIp6Resource { src, r_idx } => {
                if state.client_cidr_resources.len().1 == 0 {
                    return false;
                }

                let dst = state.sample_ipv6_cidr_resource_dst(r_idx);

                src != &dst
            }
        }
    }
}

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Send a ICMP packet to random IP.
    SendICMPPacketToRandomIp { src: IpAddr, dst: IpAddr },
    /// Send a ICMP packet to an IPv4 resource.
    SendICMPPacketToIp4Resource { src: Ipv4Addr, r_idx: sample::Index },
    /// Send a ICMP packet to an IPv6 resource.
    SendICMPPacketToIp6Resource { src: Ipv6Addr, r_idx: sample::Index },
    /// Advance time by this many milliseconds.
    Tick { millis: u64 },
}
