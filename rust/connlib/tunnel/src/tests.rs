use crate::{ClientEvent, ClientState, GatewayState};
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        client::ResourceDescription,
        client::{ResourceDescriptionCidr, ResourceDescriptionDns},
        DnsServer, Interface, IpDnsServer, ResourceId,
    },
    proptest::{cidr_resource, dns_resource},
    StaticSecret,
};
use ip_network_table::IpNetworkTable;
use ip_packet::make::dns_query;
use itertools::Itertools;
use pretty_assertions::assert_eq;
use proptest::{
    arbitrary::{any, any_with},
    collection,
    sample::{self, select},
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
    utc_now: DateTime<Utc>,

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
    utc_now: DateTime<Utc>,
    client_priv_key: [u8; 32],
    gateway_priv_key: [u8; 32],

    /// Which resources the clients is aware of.
    cidr_client_resources: IpNetworkTable<ResourceDescriptionCidr>,
    dns_client_resources: HashMap<String, ResourceDescriptionDns>,
    last_connection_intents: HashMap<ResourceId, Instant>,

    /// New events that we expect to be emitted.
    client_new_events: Vec<(Instant, ClientEvent)>,

    proxy_ips_fqdn: HashMap<IpAddr, String>,

    interface_config: Option<Interface>,
    system_resolvers: Vec<IpAddr>,
}

// 1. Dns packet returns 1:1 proxy-ip:dns-name
// ensure:
//   TTL is 1 Day(infinite?)
//   DNS response is queued(assert record fileds and so on)
// 2. Packets for that ip creates intents
// ensure:
//   Can pick resource based on port/protocol
//   A connection intent and the whole flow is created
//   There is some criteria to resolve conflicts(TBD!)
// 3. After the intent is reached at the gateway the DNS is resolved in the gateway
// the mapping is stored in the gateway (this works pretty similarly but the resolution is not sent back to the client)
// 4. Packets flowing through the gateway are mangled
//   ensure:
//   we use the src port as a way to distinguish between packets to the same ip
// 5. DNS is refreshed after 30 seconds of incoming inactivity

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
            Transition::AddDnsResource(r) => {
                state.client.add_resources(&[ResourceDescription::Dns(r)]);
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
                state.client.handle_timeout(state.now);
                state.gateway.handle_timeout(state.now, state.utc_now);
            }
            Transition::SendDnsQueryToResource {
                qname,
                dns_server_idx,
                src_port,
            } => {
                let servers: Vec<IpAddr> =
                    state.client.dns_mapping().left_values().copied().collect();
                debug_assert!(servers.len() > 0, "Can't send DNS queries without servers");
                let index = dns_server_idx.index(servers.len());
                let dns_server = servers[index];

                let src = match dns_server {
                    IpAddr::V4(_) => ref_state.interface_config.as_ref().unwrap().ipv4.into(),
                    IpAddr::V6(_) => ref_state.interface_config.as_ref().unwrap().ipv6.into(),
                };

                let packet = dns_query(src, dns_server, src_port, 53, qname);
                state.client.encapsulate(packet, state.now);
            }
            Transition::UpdateInterface(interface) => {
                let _ = state.client.update_interface_config(interface.clone());
            }
            Transition::UpdateSystemResolver(resolvers) => {
                let _ = state.client.update_system_resolvers(resolvers.clone());
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
    fn on_icmp_packet_to(&mut self, dst: impl Into<IpAddr>) {
        let dst = dst.into();

        // We select which resource to send to based on the _longest match_ of the IP network.
        // We may have resources with overlapping IP ranges so it is important that we do this the same way as connlib.
        let Some((_, resource)) = self.cidr_client_resources.longest_match(dst) else {
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
        let num_ip4_resources = self.cidr_client_resources.len().0;
        debug_assert!(num_ip4_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip4_resources);
        let (network, _) = self
            .cidr_client_resources
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
        let num_ip6_resources = self.cidr_client_resources.len().1;
        debug_assert!(num_ip6_resources > 0, "cannot sample without any resources");
        let r_idx = idx.index(num_ip6_resources);
        let (network, _) = self
            .cidr_client_resources
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

    fn next_proxy_ip4(&self) -> Vec<IpAddr> {
        let last_ip = self
            .proxy_ips_fqdn
            .keys()
            .filter_map(|ip| match ip {
                IpAddr::V4(ip) => Some(ip),
                _ => None,
            })
            .sorted()
            .rev()
            .next();

        match last_ip {
            Some(ip) => {
                let ip = u32::from(*ip);
                vec![
                    Ipv4Addr::from(ip + 1).into(),
                    Ipv4Addr::from(ip + 2).into(),
                    Ipv4Addr::from(ip + 3).into(),
                    Ipv4Addr::from(ip + 4).into(),
                ]
            }
            None => {
                vec![
                    "100.96.0.1".parse().unwrap(),
                    "100.96.0.2".parse().unwrap(),
                    "100.96.0.3".parse().unwrap(),
                    "100.96.0.4".parse().unwrap(),
                ]
            }
        }
    }

    fn next_proxy_ip6(&self) -> Vec<IpAddr> {
        let last_ip = self
            .proxy_ips_fqdn
            .keys()
            .filter_map(|ip| match ip {
                IpAddr::V6(ip) => Some(ip),
                _ => None,
            })
            .sorted()
            .rev()
            .next();

        match last_ip {
            Some(ip) => {
                let ip = u128::from(*ip);
                vec![
                    Ipv6Addr::from(ip + 1).into(),
                    Ipv6Addr::from(ip + 2).into(),
                    Ipv6Addr::from(ip + 3).into(),
                    Ipv6Addr::from(ip + 4).into(),
                ]
            }
            None => {
                vec![
                    "fd00:2021:1111:8000::".parse().unwrap(),
                    "fd00:2021:1111:8000::1".parse().unwrap(),
                    "fd00:2021:1111:8000::2".parse().unwrap(),
                    "fd00:2021:1111:8000::3".parse().unwrap(),
                ]
            }
        }
    }

    fn dns_query_to_dns_resource(&self) -> impl Strategy<Value = Transition> {
        (
            select(self.dns_client_resources.keys().cloned().collect_vec()),
            any::<sample::Index>(),
            any::<u16>(),
        )
            .prop_flat_map(|(name, idx, src_port)| match name.chars().next().unwrap() {
                '?' => any_with::<String>(r"([a-z]{1,10}\.)?".into())
                    .prop_map(move |prefix| {
                        let name = name.strip_prefix("?.").unwrap();
                        Transition::SendDnsQueryToResource {
                            qname: format!("{prefix}{name}"),
                            src_port,
                            dns_server_idx: idx,
                        }
                    })
                    .boxed(),
                '*' => any_with::<String>(r"([a-z]{1,10}\.){0,5}".into())
                    .prop_map(move |prefix| {
                        let name = name.strip_prefix("*.").unwrap();
                        Transition::SendDnsQueryToResource {
                            qname: format!("{prefix}{name}"),
                            src_port,
                            dns_server_idx: idx,
                        }
                    })
                    .boxed(),
                _ => Just(Transition::SendDnsQueryToResource {
                    qname: name.clone(),
                    src_port,
                    dns_server_idx: idx,
                })
                .boxed(),
            })
    }
}

impl TunnelTest {
    fn send_icmp_packet_client_to_gateway(
        &mut self,
        src: impl Into<IpAddr>,
        dst: impl Into<IpAddr>,
    ) {
        let _maybe_transmit = self.client.encapsulate(
            ip_packet::make::icmp_request_packet(src.into(), dst.into()),
            self.now,
        );

        // TODO: Handle transmit (send to relay / gateway)
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

fn interface_config() -> impl Strategy<Value = Interface> {
    (
        any::<Ipv4Addr>().prop_filter("muse have valid ip for source", |ip| {
            !ip.is_unspecified() && !ip.is_loopback() && !ip.is_broadcast()
        }),
        any::<Ipv6Addr>().prop_filter("must have valid ip for source", |ip| {
            !ip.is_unspecified() && !ip.is_loopback()
        }),
        collection::vec(any::<IpAddr>(), 0..=5).prop_filter("must have valid dns servers", |ip| {
            ip.iter()
                .all(|ip| !ip.is_unspecified() && !ip.is_loopback())
        }),
    )
        .prop_map(|(ipv4, ipv6, address)| Interface {
            ipv4,
            ipv6,
            upstream_dns: address
                .into_iter()
                .map(|ip| {
                    DnsServer::IpPort(IpDnsServer {
                        address: (ip, 53).into(),
                    })
                })
                .collect_vec(),
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
            any::<[u8; 32]>(),
            any::<[u8; 32]>(),
            Just(Instant::now()),
            Just(Utc::now()),
        )
            .prop_filter(
                "client and gateway priv key must be different",
                |(c, g, _, _)| c != g,
            )
            .prop_map(|(client_priv_key, gateway_priv_key, now, utc_now)| Self {
                now,
                utc_now,
                client_priv_key,
                gateway_priv_key,
                cidr_client_resources: IpNetworkTable::new(),
                dns_client_resources: Default::default(),
                client_new_events: Default::default(),
                last_connection_intents: Default::default(),
                proxy_ips_fqdn: Default::default(),
                interface_config: None,
                system_resolvers: vec![],
            })
            .boxed()
    }

    /// Defines the [`Strategy`] on how we can [transition](Transition) from the current [`ReferenceState`].
    ///
    /// This is invoked by proptest repeatedly to explore further state transitions.
    /// Here, we should only generate [`Transition`]s that make sense for the current state.
    fn transitions(state: &Self::State) -> proptest::prelude::BoxedStrategy<Self::Transition> {
        let add_cidr_resource = cidr_resource(8).prop_map(Transition::AddCidrResource);
        let add_dns_resource = dns_resource().prop_map(Transition::AddDnsResource);
        let update_interface = interface_config().prop_map(Transition::UpdateInterface);
        let update_system_resolvers = collection::vec(
            any::<IpAddr>().prop_filter("cant use invalid resolvers", |ip| {
                !ip.is_unspecified() && !ip.is_loopback()
            }),
            1..=3,
        )
        .prop_map(Transition::UpdateSystemResolver);
        let tick = (0..=1000u64).prop_map(|millis| Transition::Tick { millis });

        let strategies = Strategy::prop_union(add_cidr_resource.boxed(), add_dns_resource.boxed())
            .or(tick.boxed())
            .or(icmp_to_random_ip().boxed())
            .or(update_interface.boxed())
            .or(update_system_resolvers.boxed());

        let strategies = match state.cidr_client_resources.len() {
            (0, 0) => strategies,
            (0, _) => strategies.or(icmp_to_ipv6_cidr_resource().boxed()),
            (_, 0) => strategies.or(icmp_to_ipv4_cidr_resource().boxed()),
            (_, _) => strategies
                .or(icmp_to_ipv4_cidr_resource().boxed())
                .or(icmp_to_ipv6_cidr_resource().boxed()),
        };

        if state.dns_client_resources.len() > 0
            && !state.system_resolvers.is_empty()
            && state.interface_config.is_some()
        {
            strategies
                .or(state.dns_query_to_dns_resource().boxed())
                .boxed()
        } else {
            strategies.boxed()
        }
    }

    /// Apply the transition to our reference state.
    ///
    /// Here is where we implement the "expected" logic.
    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        state.client_new_events.clear();

        match transition {
            Transition::AddCidrResource(r) => {
                state.cidr_client_resources.insert(r.address, r.clone());
            }
            Transition::AddDnsResource(r) => {
                state
                    .dns_client_resources
                    .insert(r.address.clone(), r.clone());
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
            Transition::SendDnsQueryToResource { qname, .. } => {
                for ip in state.next_proxy_ip4() {
                    state.proxy_ips_fqdn.insert(ip, qname.clone());
                }

                for ip in state.next_proxy_ip6() {
                    state.proxy_ips_fqdn.insert(ip, qname.clone());
                }
            }
            Transition::Tick { millis } => state.now += Duration::from_millis(*millis),
            Transition::UpdateInterface(interface_config) => {
                state.interface_config = Some(interface_config.clone());
            }
            Transition::UpdateSystemResolver(system_resolvers) => {
                state.system_resolvers = system_resolvers.clone();
            }
        };

        state
    }

    /// Any additional checks on whether a particular [`Transition`] can be applied to a certain state.
    fn preconditions(state: &Self::State, transition: &Self::Transition) -> bool {
        match transition {
            Transition::AddCidrResource(_) => true,
            Transition::AddDnsResource(_) => true,
            Transition::SendDnsQueryToResource { .. } => true,
            Transition::Tick { .. } => true,
            Transition::SendICMPPacketToRandomIp { src, dst } => {
                src.is_ipv4() == dst.is_ipv4() && src != dst
            }
            Transition::SendICMPPacketToIp4Resource { src, r_idx } => {
                let dst = state.sample_ipv4_cidr_resource_dst(r_idx);

                src != &dst
            }
            Transition::SendICMPPacketToIp6Resource { src, r_idx } => {
                let dst = state.sample_ipv6_cidr_resource_dst(r_idx);

                src != &dst
            }

            Transition::UpdateInterface(_) => true,
            Transition::UpdateSystemResolver(_) => true,
        }
    }
}

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Add a new DNS resource to the client.
    AddDnsResource(ResourceDescriptionDns),
    /// Send a ICMP packet to random IP.
    SendICMPPacketToRandomIp { src: IpAddr, dst: IpAddr },
    /// Send a ICMP packet to an IPv4 resource.
    SendICMPPacketToIp4Resource { src: Ipv4Addr, r_idx: sample::Index },
    /// Send a ICMP packet to an IPv6 resource.
    SendICMPPacketToIp6Resource { src: Ipv6Addr, r_idx: sample::Index },
    /// Advance time by this many milliseconds.
    Tick { millis: u64 },
    /// Send DNS query
    SendDnsQueryToResource {
        qname: String,
        dns_server_idx: sample::Index,
        src_port: u16,
    },
    /// Update interface config
    UpdateInterface(Interface),
    /// Update system resolver
    UpdateSystemResolver(Vec<IpAddr>),
}
