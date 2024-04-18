use crate::{ip_packet::MutableIpPacket, ClientEvent, ClientState, GatewayState};
use connlib_shared::{
    messages::{ResourceDescription, ResourceDescriptionCidr, ResourceId},
    proptest::cidr_resource,
    StaticSecret,
};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use pretty_assertions::assert_eq;
use proptest::{
    arbitrary::any,
    prop_oneof, sample,
    strategy::{Just, Strategy},
    test_runner::Config,
};
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
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

    client: ClientState,
    gateway: GatewayState,

    #[allow(dead_code)]
    logger: DefaultGuard,
}

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Clone, Debug)]
struct ReferenceState {
    now: Instant,
    client_priv_key: [u8; 32],
    gateway_priv_key: [u8; 32],

    /// Which resources the clients is aware of.
    client_resources: IpNetworkTable<ResourceDescriptionCidr>,
    /// Cache for resource IPs.
    ip4_resource_ips: Vec<Ipv4Addr>,
    ip6_resource_ips: Vec<Ipv6Addr>,

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
            client: ClientState::new(StaticSecret::from(ref_state.client_priv_key)),
            gateway: GatewayState::new(StaticSecret::from(ref_state.gateway_priv_key)),
            logger: tracing_subscriber::fmt()
                .with_test_writer()
                .with_env_filter("debug")
                .finish()
                .set_default(),
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
                state.client.add_resources(&[ResourceDescription::Cidr(r)]);
            }
            Transition::SendICMPPacketToResource { src, dst } => {
                let _maybe_transmit = state
                    .client
                    .encapsulate(icmp_request_packet(src, dst), state.now);

                // TODO: Handle transmit (send to relay / gateway)
            }
            Transition::Tick { millis } => {
                state.now += Duration::from_millis(millis);
                state.client.handle_timeout(state.now);
                state.gateway.handle_timeout(state.now);
            }
        };

        for (time, expected_event) in &ref_state.client_new_events {
            assert_eq!(time, &state.now);
            assert_eq!(expected_event, &state.client.poll_event().unwrap());
        }

        // TODO: Drain `poll_transmit` and execute it.

        state
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    fn will_send_new_connection_intent(&self, resource: &ResourceId) -> bool {
        let Some(last_intent) = self.last_connection_intents.get(resource) else {
            return true;
        };

        self.now.duration_since(*last_intent) >= Duration::from_secs(2)
    }

    /// Generates a [`Transition`] that sends an ICMP packet to a random IP.
    ///
    /// By chance, it could be that we pick a resource IP here.
    /// That is okay as our reference state machine checks separately whether we are pinging a resource here.
    fn icmp_to_random_ip(&self) -> impl Strategy<Value = Transition> {
        (any::<IpAddr>(), any::<IpAddr>())
            .prop_map(|(src, dst)| Transition::SendICMPPacketToResource { src, dst })
    }

    fn icmp_to_ipv4_cidr_resource(&self) -> impl Strategy<Value = Transition> {
        (
            any::<Ipv4Addr>(),
            sample::select(self.ip4_resource_ips.clone()),
        )
            .prop_map(|(src, dst)| Transition::SendICMPPacketToResource {
                src: src.into(),
                dst: dst.into(),
            })
    }

    fn icmp_to_ipv6_cidr_resource(&self) -> impl Strategy<Value = Transition> {
        (
            any::<Ipv6Addr>(),
            sample::select(self.ip6_resource_ips.clone()),
        )
            .prop_map(|(src, dst)| Transition::SendICMPPacketToResource {
                src: src.into(),
                dst: dst.into(),
            })
    }
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
        (any::<[u8; 32]>(), any::<[u8; 32]>(), Just(Instant::now()))
            .prop_filter(
                "client and gateway priv key must be different",
                |(c, g, _)| c != g,
            )
            .prop_map(|(client_priv_key, gateway_priv_key, now)| Self {
                now,
                client_priv_key,
                gateway_priv_key,
                client_resources: IpNetworkTable::new(),
                client_new_events: Default::default(),
                last_connection_intents: Default::default(),
                ip4_resource_ips: Default::default(),
                ip6_resource_ips: Default::default(),
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

        match (state.ip4_resource_ips.len(), state.ip6_resource_ips.len()) {
            (0, 0) => prop_oneof![add_cidr_resource, tick, state.icmp_to_random_ip()].boxed(),
            (0, _) => prop_oneof![
                add_cidr_resource,
                tick,
                state.icmp_to_random_ip(),
                state.icmp_to_ipv4_cidr_resource()
            ]
            .boxed(),
            (_, 0) => prop_oneof![
                add_cidr_resource,
                tick,
                state.icmp_to_random_ip(),
                state.icmp_to_ipv6_cidr_resource()
            ]
            .boxed(),
            (_, _) => prop_oneof![
                add_cidr_resource,
                tick,
                state.icmp_to_random_ip(),
                state.icmp_to_ipv6_cidr_resource(),
                state.icmp_to_ipv4_cidr_resource()
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
                match r.address {
                    IpNetwork::V4(v4) => state.ip4_resource_ips.extend(v4.hosts()),
                    IpNetwork::V6(v6) => state
                        .ip6_resource_ips
                        .extend(v6.subnets_with_prefix(128).map(|ip| ip.network_address())),
                };
            }
            Transition::SendICMPPacketToResource { dst, .. } => {
                // Packets to non-resources are ignored.
                // In case resources have over-lapping networks, the longest match is used.
                let Some((_, resource)) = state.client_resources.longest_match(*dst) else {
                    return state;
                };

                // Only expect a new connection intent if the last one was older than 2s
                if state.will_send_new_connection_intent(&resource.id) {
                    state.last_connection_intents.insert(resource.id, state.now);
                    state.client_new_events.push((
                        state.now,
                        ClientEvent::ConnectionIntent {
                            resource: resource.id,
                            connected_gateway_ids: HashSet::default(),
                        },
                    ))
                }
            }
            Transition::Tick { millis } => state.now += Duration::from_millis(*millis),
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    fn preconditions(_: &Self::State, transition: &Self::Transition) -> bool {
        match transition {
            Transition::AddCidrResource(_) => true,
            Transition::Tick { .. } => true,
            Transition::SendICMPPacketToResource { src, dst } => {
                src.is_ipv4() == dst.is_ipv4() && src != dst
            }
        }
    }
}

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Send a ICMP packet to resource.
    SendICMPPacketToResource { src: IpAddr, dst: IpAddr },
    /// Advance time by this many milliseconds.
    Tick { millis: u64 },
}

fn icmp_request_packet(source: IpAddr, dst: IpAddr) -> MutableIpPacket<'static> {
    match (source, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            use pnet_packet::{
                icmp::{
                    echo_request::{IcmpCodes, MutableEchoRequestPacket},
                    IcmpTypes, MutableIcmpPacket,
                },
                ip::IpNextHeaderProtocols,
                ipv4::MutableIpv4Packet,
                MutablePacket as _, Packet as _,
            };

            let mut buf = vec![0u8; 60];

            let mut ipv4_packet = MutableIpv4Packet::new(&mut buf[..]).unwrap();
            ipv4_packet.set_version(4);
            ipv4_packet.set_header_length(5);
            ipv4_packet.set_total_length(60);
            ipv4_packet.set_ttl(64);
            ipv4_packet.set_next_level_protocol(IpNextHeaderProtocols::Icmp);
            ipv4_packet.set_source(src);
            ipv4_packet.set_destination(dst);
            ipv4_packet.set_checksum(pnet_packet::ipv4::checksum(&ipv4_packet.to_immutable()));

            let mut icmp_packet = MutableIcmpPacket::new(&mut buf[20..]).unwrap();
            icmp_packet.set_icmp_type(IcmpTypes::EchoRequest);
            icmp_packet.set_icmp_code(IcmpCodes::NoCode);
            icmp_packet.set_checksum(0);

            let mut echo_request_packet =
                MutableEchoRequestPacket::new(icmp_packet.payload_mut()).unwrap();
            echo_request_packet.set_sequence_number(1);
            echo_request_packet.set_identifier(0);
            echo_request_packet.set_checksum(pnet_packet::util::checksum(
                echo_request_packet.to_immutable().packet(),
                2,
            ));

            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            use pnet_packet::{
                icmpv6::{
                    echo_request::MutableEchoRequestPacket, Icmpv6Code, Icmpv6Types,
                    MutableIcmpv6Packet,
                },
                ip::IpNextHeaderProtocols,
                ipv6::MutableIpv6Packet,
                MutablePacket as _,
            };

            let mut buf = vec![0u8; 128];

            let mut ipv6_packet = MutableIpv6Packet::new(&mut buf[..]).unwrap();

            ipv6_packet.set_version(6);
            ipv6_packet.set_payload_length(16);
            ipv6_packet.set_next_header(IpNextHeaderProtocols::Icmpv6);
            ipv6_packet.set_hop_limit(64);
            ipv6_packet.set_source(src);
            ipv6_packet.set_destination(dst);

            let mut icmp_packet = MutableIcmpv6Packet::new(&mut buf[40..]).unwrap();

            icmp_packet.set_icmpv6_type(Icmpv6Types::EchoRequest);
            icmp_packet.set_icmpv6_code(Icmpv6Code::new(0)); // No code for echo request

            let mut echo_request_packet =
                MutableEchoRequestPacket::new(icmp_packet.payload_mut()).unwrap();
            echo_request_packet.set_identifier(0);
            echo_request_packet.set_sequence_number(1);
            echo_request_packet.set_checksum(0);

            let checksum = pnet_packet::icmpv6::checksum(&icmp_packet.to_immutable(), &src, &dst);
            MutableEchoRequestPacket::new(icmp_packet.payload_mut())
                .unwrap()
                .set_checksum(checksum);

            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(_), IpAddr::V4(_)) | (IpAddr::V4(_), IpAddr::V6(_)) => {
            panic!("IPs must be of the same version")
        }
    }
}
