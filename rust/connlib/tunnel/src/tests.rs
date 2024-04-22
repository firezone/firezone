use crate::{ClientEvent, ClientState, GatewayState};
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{client::ResourceDescription, client::ResourceDescriptionCidr, ResourceId},
    proptest::cidr_resource,
    StaticSecret,
};
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
use snownet::Transmit;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    time::{Duration, Instant},
};
use tracing::subscriber::DefaultGuard;
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

    client: SimNode<ClientState>,
    gateway: SimNode<GatewayState>,

    client_received_packets: VecDeque<IpPacket<'static>>,
    gateway_received_packets: VecDeque<IpPacket<'static>>,

    #[allow(dead_code)]
    logger: DefaultGuard,
    buffer: Box<[u8; 10_000]>,
}

#[derive(Clone, Copy, Debug)]
struct SimNode<S> {
    state: S,

    ip4_socket: Option<SocketAddrV4>,
    ip6_socket: Option<SocketAddrV6>,
}

impl<S> SimNode<S> {
    fn map_state<T>(self, f: impl FnOnce(S) -> T) -> SimNode<T> {
        SimNode {
            state: f(self.state),
            ip4_socket: self.ip4_socket,
            ip6_socket: self.ip6_socket,
        }
    }

    fn wants(&self, dst: SocketAddr) -> bool {
        self.ip4_socket.is_some_and(|s| SocketAddr::V4(s) == dst)
            || self.ip6_socket.is_some_and(|s| SocketAddr::V6(s) == dst)
    }
}

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
struct ReferenceState {
    now: Instant,
    utc_now: DateTime<Utc>,
    client: SimNode<[u8; 32]>,
    gateway: SimNode<[u8; 32]>,

    /// Which resources the clients is aware of.
    client_resources: IpNetworkTable<ResourceDescriptionCidr>,
    last_connection_intents: HashMap<ResourceId, Instant>,

    /// New events that we expect to be emitted.
    client_new_events: Vec<(Instant, ClientEvent)>,
}

impl StateMachineTest for TunnelTest {
    type SystemUnderTest = Self;
    type Reference = ReferenceState;

    // Initialize the system under test from our reference state.
    fn init_test(
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
    ) -> Self::SystemUnderTest {
        Self {
            now: ref_state.now,
            utc_now: ref_state.utc_now,
            client: ref_state
                .client
                .map_state(|key| ClientState::new(StaticSecret::from(key))),
            gateway: ref_state
                .gateway
                .map_state(|key| GatewayState::new(StaticSecret::from(key))),
            logger: tracing_subscriber::fmt()
                .with_test_writer()
                .with_env_filter("debug")
                .finish()
                .set_default(),
            buffer: Box::new([0u8; 10_000]),
            client_received_packets: Default::default(),
            gateway_received_packets: Default::default(),
        }
    }

    // Apply a generated state transition to our system under test and assert against the reference state machine.
    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        match transition {
            Transition::AddCidrResource(r) => {
                state
                    .client
                    .state
                    .add_resources(&[ResourceDescription::Cidr(r)]);
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
                state.utc_now += Duration::from_millis(millis);
                state.client.state.handle_timeout(state.now);
                state.gateway.state.handle_timeout(state.now, state.utc_now);
            }
        };
        while let Some(transmit) = state.client.state.poll_transmit() {
            state.dispatch_transmit(transmit)
        }
        while let Some(transmit) = state.gateway.state.poll_transmit() {
            state.dispatch_transmit(transmit)
        }

        for (time, expected_event) in &ref_state.client_new_events {
            assert_eq!(time, &state.now);
            assert_eq!(expected_event, &state.client.state.poll_event().unwrap());
        }

        state
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    fn on_icmp_packet_to(&mut self, dst: impl Into<IpAddr>) {
        let dst = dst.into();

        // We select which resource to send to based on the _longest match_ of the IP network.
        // We may have resources with overlapping IP ranges so it is important that we do this the same way as connlib.
        let Some((_, resource)) = self.client_resources.longest_match(dst) else {
            return;
        };
        let resource = resource.id;

        // Only expect a new connection intent if the last one was older than 2s
        if !self.will_send_new_connection_intent(&resource) {
            return;
        }

        self.last_connection_intents.insert(resource, self.now);
        self.client_new_events.push((
            self.now,
            ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids: HashSet::default(),
            },
        ));
    }

    fn will_send_new_connection_intent(&self, resource: &ResourceId) -> bool {
        let Some(last_intent) = self.last_connection_intents.get(resource) else {
            return true;
        };

        self.now.duration_since(*last_intent) >= Duration::from_secs(2)
    }

    /// Samples an [`Ipv4Addr`] from _any_ of our IPv4 CIDR resources.
    fn sample_ipv4_cidr_resource_dst(&self, idx: &sample::Index) -> Ipv4Addr {
        let num_ip4_resources = self.client_resources.len().0;
        debug_assert!(num_ip4_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip4_resources);
        let (network, _) = self
            .client_resources
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
        let num_ip6_resources = self.client_resources.len().1;
        debug_assert!(num_ip6_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip6_resources);
        let (network, _) = self
            .client_resources
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
    fn send_icmp_packet_client_to_gateway(
        &mut self,
        src: impl Into<IpAddr>,
        dst: impl Into<IpAddr>,
    ) {
        let Some(transmit) = self.client.state.encapsulate(
            ip_packet::make::icmp_request_packet(src.into(), dst.into()),
            self.now,
        ) else {
            return;
        };
        let transmit = transmit.into_owned();

        self.dispatch_transmit(transmit);
    }

    fn dispatch_transmit(&mut self, transmit: Transmit) {
        let Some(from) = transmit.src else {
            tracing::debug!("Dropping packet without `src`");
            return;
        };
        let dst = transmit.dst;
        let payload = &transmit.payload;

        if self.client.wants(dst) {
            if let Some(packet) =
                self.client
                    .state
                    .decapsulate(dst, from, payload, self.now, self.buffer.as_mut())
            {
                self.client_received_packets.push_back(packet.to_owned());
            };
            return;
        }

        if self.gateway.wants(dst) {
            if let Some(packet) =
                self.gateway
                    .state
                    .decapsulate(dst, from, payload, self.now, self.buffer.as_mut())
            {
                self.gateway_received_packets.push_back(packet.to_owned());
            };
            return;
        }

        panic!("Unhandled packet: {from} -> {dst}")
    }
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

fn sim_node_prototype() -> impl Strategy<Value = SimNode<[u8; 32]>> {
    (
        any::<[u8; 32]>(),
        any::<Option<SocketAddrV4>>(),
        any::<Option<SocketAddrV6>>(),
    )
        .prop_filter_map(
            "must have at least one socket address",
            |(key, ip4_socket, ip6_socket)| {
                if ip4_socket.is_none() && ip6_socket.is_none() {
                    return None;
                };

                Some(SimNode {
                    state: key,
                    ip4_socket,
                    ip6_socket,
                })
            },
        )
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

            sim_node_prototype(),

            sim_node_prototype(),

            Just(Instant::now()),
        ,
            Just(Utc::now()),
        )
            .prop_filter(
                "client and gateway priv key must be different",
                |(c, g, _, _)| c.state != g.state,
            )
            .prop_map(|(client, gateway, now, utc_now)| Self {
                now,
                utc_now,
                client,
                gateway,
                client_resources: IpNetworkTable::new(),
                client_new_events: Default::default(),
                last_connection_intents: Default::default(),
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

        match state.client_resources.len() {
            (0, 0) => prop_oneof![add_cidr_resource, tick, icmp_to_random_ip()].boxed(),
            (0, _) => prop_oneof![
                add_cidr_resource,
                tick,
                icmp_to_random_ip(),
                icmp_to_ipv6_cidr_resource()
            ]
            .boxed(),
            (_, 0) => prop_oneof![
                add_cidr_resource,
                tick,
                icmp_to_random_ip(),
                icmp_to_ipv4_cidr_resource()
            ]
            .boxed(),
            (_, _) => prop_oneof![
                add_cidr_resource,
                tick,
                icmp_to_random_ip(),
                icmp_to_ipv4_cidr_resource(),
                icmp_to_ipv6_cidr_resource()
            ]
            .boxed(),
        }
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        state.client_new_events.clear();

        match transition {
            Transition::AddCidrResource(r) => {
                state.client_resources.insert(r.address, r.clone());
            }
            Transition::SendICMPPacketToRandomIp { dst, .. } => {
                state.on_icmp_packet_to(*dst);
            }
            Transition::SendICMPPacketToIp4Resource { r_idx, .. } => {
                let dst = state.sample_ipv4_cidr_resource_dst(r_idx);
                state.on_icmp_packet_to(dst);
            }
            Transition::SendICMPPacketToIp6Resource { r_idx, .. } => {
                let dst = state.sample_ipv6_cidr_resource_dst(r_idx);
                state.on_icmp_packet_to(dst);
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
                if state.client_resources.len().0 == 0 {
                    return false;
                }

                let dst = state.sample_ipv4_cidr_resource_dst(r_idx);

                src != &dst
            }
            Transition::SendICMPPacketToIp6Resource { src, r_idx } => {
                if state.client_resources.len().1 == 0 {
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
