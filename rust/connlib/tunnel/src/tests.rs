use crate::{ip_packet::MutableIpPacket, ClientEvent, ClientState, GatewayState};
use connlib_shared::{
    messages::{ResourceDescription, ResourceDescriptionCidr, ResourceId},
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
    collections::HashSet,
    iter,
    net::IpAddr,
    time::{Duration, Instant},
};
use tracing::subscriber::DefaultGuard;
use tracing_subscriber::util::SubscriberInitExt as _;

// Setup the state machine test using the `prop_state_machine!` macro
proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        // Enable verbose mode to make the state machine test print the
        // transitions for each case.
        verbose: 1,
        // Only run 10 cases by default to avoid running out of system resources
        // and taking too long to finish.
        cases: 10,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

struct TunnelTest {
    now: Instant,

    client: ClientState,
    gateway: GatewayState,

    #[allow(dead_code)]
    logger: DefaultGuard,

    actual_client_events: Vec<(Instant, ClientEvent)>,
}

impl StateMachineTest for TunnelTest {
    type SystemUnderTest = Self;
    type Reference = RefState;

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
            actual_client_events: Vec::default(),
        }
    }

    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        match transition {
            Transition::AddCidrResource(r) => {
                state.client.add_resources(&[ResourceDescription::Cidr(r)]);
            }
            Transition::SendICMPPacket { src, dst } => {
                state
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

        // TODO: Assert our routes here.

        state.actual_client_events.extend(iter::from_fn(|| {
            let event = state.client.poll_event()?;

            Some((state.now, event))
        }));

        assert_eq!(state.actual_client_events, ref_state.client_expected_events);

        state
    }
}

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
/// i.e. We compare the actual state of the tunnel with what we have in here.
#[derive(Clone, Debug)]
struct RefState {
    now: Instant,
    client_priv_key: [u8; 32],
    gateway_priv_key: [u8; 32],

    client_resources: IpNetworkTable<ResourceDescriptionCidr>,
    /// Cache for resource IPs.
    resource_ips: Vec<IpAddr>,

    client_expected_events: Vec<(Instant, ClientEvent)>,
}

impl RefState {
    fn will_send_new_connection_intent(&self, candidate: &ResourceId) -> bool {
        let Some(last_intent) = self.last_connection_intent_to(candidate) else {
            return true;
        };

        self.now.duration_since(last_intent) >= Duration::from_secs(2)
    }

    fn last_connection_intent_to(&self, candidate: &ResourceId) -> Option<Instant> {
        self.client_expected_events.iter().filter_map(|(time, event)| {
            matches!(event, ClientEvent::ConnectionIntent { resource, .. } if resource == candidate).then_some(*time)
        }).max()
    }

    fn recompute_resource_ips(&mut self) {
        self.resource_ips = self
            .client_resources
            .iter()
            .map(|(_, r)| r)
            .flat_map(|r| match r.address {
                IpNetwork::V4(v4) => v4.hosts().map(IpAddr::V4).collect::<Vec<_>>(),
                IpNetwork::V6(v6) => v6
                    .subnets_with_prefix(128)
                    .map(|ip| IpAddr::V6(ip.network_address()))
                    .collect::<Vec<_>>(),
            })
            .collect::<Vec<_>>();
    }
}

impl ReferenceStateMachine for RefState {
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
                client_expected_events: Default::default(),
                resource_ips: Default::default(),
            })
            .boxed()
    }

    fn transitions(state: &Self::State) -> proptest::prelude::BoxedStrategy<Self::Transition> {
        if state.resource_ips.is_empty() {
            // TODO: src and dst should not be the same.
            return prop_oneof![
                connlib_shared::proptest::cidr_resource().prop_map(Transition::AddCidrResource),
                // Random packet
                (any::<IpAddr>(), any::<IpAddr>())
                    .prop_filter("src and dst must be same IP version", |(src, dst)| {
                        src.is_ipv4() == dst.is_ipv4()
                    })
                    .prop_map(|(src, dst)| Transition::SendICMPPacket { src, dst }),
                ((0..=1000u64).prop_map(|millis| Transition::Tick { millis }))
            ]
            .boxed();
        }

        let resource_dst = sample::select(state.resource_ips.clone());

        prop_oneof![
            connlib_shared::proptest::cidr_resource().prop_map(Transition::AddCidrResource),
            // Random packet
            (any::<IpAddr>(), any::<IpAddr>())
                .prop_filter("src and dst must be same IP version", |(src, dst)| {
                    src.is_ipv4() == dst.is_ipv4()
                })
                .prop_map(|(src, dst)| Transition::SendICMPPacket { src, dst }),
            // Packet to a resource
            (any::<IpAddr>(), resource_dst)
                .prop_filter("src and dst must be same IP version", |(src, dst)| {
                    src.is_ipv4() == dst.is_ipv4()
                })
                .prop_map(|(src, dst)| Transition::SendICMPPacket { src, dst }),
            ((0..=1000u64).prop_map(|millis| Transition::Tick { millis }))
        ]
        .boxed()
    }

    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        match transition {
            Transition::AddCidrResource(r) => {
                state.client_resources.insert(r.address, r.clone());
                state.recompute_resource_ips();
            }
            Transition::SendICMPPacket { dst, .. } => {
                // Packets to non-resources are ignored.
                // In case resources have over-lapping networks, the longest match is used.
                let Some((_, resource)) = state.client_resources.longest_match(*dst) else {
                    return state;
                };

                if state.will_send_new_connection_intent(&resource.id) {
                    state.client_expected_events.push((
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

    fn preconditions(_: &Self::State, _: &Self::Transition) -> bool {
        true
    }
}

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
enum Transition {
    AddCidrResource(ResourceDescriptionCidr),
    SendICMPPacket { src: IpAddr, dst: IpAddr },
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
