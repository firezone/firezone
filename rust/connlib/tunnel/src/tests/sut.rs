use super::reference::ReferenceState;
use super::sim_client::{RefClient, SimClient};
use super::sim_gateway::SimGateway;
use super::sim_net::{Host, HostId, RoutingTable};
use super::sim_portal::SimPortal;
use super::sim_relay::SimRelay;
use crate::tests::assertions::*;
use crate::tests::sim_relay::map_explode;
use crate::tests::transition::Transition;
use crate::{dns::DnsQuery, ClientEvent, GatewayEvent, Request};
use chrono::{DateTime, Utc};
use connlib_shared::messages::{Interface, RelayId};
use connlib_shared::{
    messages::{client::ResourceDescription, gateway, ClientId, GatewayId, ResourceId},
    DomainName,
};
use firezone_relay::IpStack;
use hickory_proto::{
    op::Query,
    rr::{RData, Record, RecordType},
};
use hickory_resolver::lookup::Lookup;
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use rand::SeedableRng as _;
use secrecy::ExposeSecret as _;
use snownet::Transmit;
use std::collections::BTreeMap;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::IpAddr,
    str::FromStr as _,
    sync::Arc,
    time::{Duration, Instant},
};
use tracing::debug_span;
use tracing::subscriber::DefaultGuard;
use tracing_subscriber::{util::SubscriberInitExt as _, EnvFilter};

/// The actual system-under-test.
///
/// [`proptest`] manipulates this using [`Transition`]s and we assert it against [`ReferenceState`].
pub(crate) struct TunnelTest {
    now: Instant,
    utc_now: DateTime<Utc>,

    pub(crate) client: Host<SimClient>,
    pub(crate) gateways: HashMap<GatewayId, Host<SimGateway>>,
    relays: HashMap<RelayId, Host<SimRelay>>,
    portal: SimPortal,

    network: RoutingTable,

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
            .map(|ref_client, _, _| ref_client.init(), debug_span!("client"));

        let mut gateways = ref_state
            .gateways
            .iter()
            .map(|(id, gateway)| {
                let gateway = gateway.map(
                    |ref_gateway, _, _| ref_gateway.init(),
                    debug_span!("gateway", gid = %id),
                );

                (*id, gateway)
            })
            .collect::<HashMap<_, _>>();

        let relays = ref_state
            .relays
            .iter()
            .map(|(id, relay)| {
                let relay = relay.map(
                    |seed, ip4, ip6| {
                        SimRelay::new(firezone_relay::Server::new(
                            IpStack::from((ip4, ip6)),
                            rand::rngs::StdRng::seed_from_u64(seed),
                            3478,
                            49152..=65535,
                        ))
                    },
                    debug_span!("relay", rid = %id),
                );

                (*id, relay)
            })
            .collect::<HashMap<_, _>>();

        // Configure client and gateway with the relays.
        client.exec_mut(|c| {
            c.sut.update_relays(
                HashSet::default(),
                HashSet::from_iter(map_explode(relays.iter(), "client")),
                ref_state.now,
            )
        });
        for (id, gateway) in &mut gateways {
            gateway.exec_mut(|g| {
                g.sut.update_relays(
                    HashSet::default(),
                    HashSet::from_iter(map_explode(relays.iter(), &format!("gateway_{id}"))),
                    ref_state.now,
                )
            });
        }

        let mut this = Self {
            now: ref_state.now,
            utc_now: ref_state.utc_now,
            network: ref_state.network.clone(),
            client,
            gateways,
            portal: SimPortal::new(),
            logger,
            relays,
        };

        let mut buffered_transmits = BufferedTransmits::default();
        this.advance(ref_state, &mut buffered_transmits); // Perform initial setup before we apply the first transition.

        debug_assert!(buffered_transmits.is_empty());

        this
    }

    /// Apply a generated state transition to our system under test.
    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        let mut buffered_transmits = BufferedTransmits::default();

        // Act: Apply the transition
        match transition {
            Transition::AddCidrResource { resource, gateway } => {
                for site in &resource.sites {
                    state.portal.register_site(site.id, gateway)
                }

                state
                    .client
                    .exec_mut(|c| c.sut.add_resources(&[ResourceDescription::Cidr(resource)]));
            }
            Transition::AddDnsResource {
                resource, gateway, ..
            } => {
                for site in &resource.sites {
                    state.portal.register_site(site.id, gateway)
                }

                state
                    .client
                    .exec_mut(|c| c.sut.add_resources(&[ResourceDescription::Dns(resource)]))
            }
            Transition::RemoveResource(id) => {
                state.client.exec_mut(|c| c.sut.remove_resources(&[id]))
            }
            Transition::SendICMPPacketToNonResourceIp {
                src,
                dst,
                seq,
                identifier,
            }
            | Transition::SendICMPPacketToCidrResource {
                src,
                dst,
                seq,
                identifier,
            } => {
                let packet = ip_packet::make::icmp_request_packet(src, dst, seq, identifier);

                let transmit = state
                    .client
                    .exec_mut(|sim| sim.encapsulate(packet, state.now));

                buffered_transmits.push(transmit, &state.client);
            }
            Transition::SendICMPPacketToDnsResource {
                src,
                dst,
                seq,
                identifier,
                resolved_ip,
            } => {
                let available_ips = state
                    .client
                    .inner()
                    .dns_records
                    .get(&dst)
                    .unwrap()
                    .iter()
                    .filter(|ip| match ip {
                        IpAddr::V4(_) => src.is_ipv4(),
                        IpAddr::V6(_) => src.is_ipv6(),
                    });
                let dst = *resolved_ip.select(available_ips);

                let packet = ip_packet::make::icmp_request_packet(src, dst, seq, identifier);

                let transmit = state
                    .client
                    .exec_mut(|sim| Some(sim.encapsulate(packet, state.now)?.into_owned()));

                buffered_transmits.push(transmit, &state.client);
            }
            Transition::SendDnsQuery {
                domain,
                r_type,
                query_id,
                dns_server,
            } => {
                let transmit = state.client.exec_mut(|sim| {
                    sim.send_dns_query_for(domain, r_type, query_id, dns_server, state.now)
                });

                buffered_transmits.push(transmit, &state.client);
            }
            Transition::Tick { millis } => {
                state.now += Duration::from_millis(millis);
            }
            Transition::UpdateSystemDnsServers { servers } => {
                state
                    .client
                    .exec_mut(|c| c.sut.update_system_resolvers(servers));
            }
            Transition::UpdateUpstreamDnsServers { servers } => {
                state.client.exec_mut(|c| {
                    c.sut.update_interface_config(Interface {
                        ipv4: c.sut.tunnel_ip4().unwrap(),
                        ipv6: c.sut.tunnel_ip6().unwrap(),
                        upstream_dns: servers,
                    })
                });
            }
            Transition::RoamClient { ip4, ip6, port } => {
                state.network.remove_host(&state.client);
                state.client.update_interface(ip4, ip6, port);
                debug_assert!(state
                    .network
                    .add_host(state.client.inner().id, &state.client));

                state.client.exec_mut(|c| {
                    c.sut.reset();

                    // In prod, we reconnect to the portal and receive a new `init` message.
                    c.sut.update_relays(
                        HashSet::default(),
                        HashSet::from_iter(map_explode(state.relays.iter(), "client")),
                        ref_state.now,
                    )
                });
            }
        };
        state.advance(ref_state, &mut buffered_transmits);
        assert!(buffered_transmits.is_empty()); // Sanity check to ensure we handled all packets.

        state
    }

    // Assert against the reference state machine.
    fn check_invariants(
        state: &Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
    ) {
        let ref_client = ref_state.client.inner();
        let sim_client = state.client.inner();
        let sim_gateways = state
            .gateways
            .iter()
            .map(|(id, g)| (*id, g.inner()))
            .collect();

        // Assert our properties: Check that our actual state is equivalent to our expectation (the reference state).
        assert_icmp_packets_properties(
            ref_client,
            sim_client,
            sim_gateways,
            &ref_state.global_dns_records,
        );
        assert_dns_packets_properties(ref_client, sim_client);
        assert_known_hosts_are_valid(ref_client, sim_client);
        assert_eq!(
            sim_client.effective_dns_servers(),
            ref_client.expected_dns_servers(),
            "Effective DNS servers should match either system or upstream DNS"
        );
    }
}

impl TunnelTest {
    /// Exhaustively advances all state machines (client, gateway & relay).
    ///
    /// For our tests to work properly, each [`Transition`] needs to advance the state as much as possible.
    /// For example, upon the first packet to a resource, we need to trigger the connection intent and fully establish a connection.
    /// Dispatching a [`Transmit`] (read: packet) to a host can trigger more packets, i.e. receiving a STUN request may trigger a STUN response.
    ///
    /// Consequently, this function needs to loop until no host can make progress at which point we consider the [`Transition`] complete.
    fn advance(&mut self, ref_state: &ReferenceState, buffered_transmits: &mut BufferedTransmits) {
        'outer: loop {
            if let Some(transmit) = buffered_transmits.pop() {
                self.dispatch_transmit(transmit, buffered_transmits, &ref_state.global_dns_records);
                continue;
            }

            if let Some(transmit) = self.client.exec_mut(|sim| sim.sut.poll_transmit()) {
                buffered_transmits.push(transmit, &self.client);
                continue;
            }
            if let Some(event) = self.client.exec_mut(|c| c.sut.poll_event()) {
                self.on_client_event(
                    self.client.inner().id,
                    event,
                    ref_state.client.inner(),
                    &ref_state.global_dns_records,
                );
                continue;
            }
            if let Some(query) = self.client.exec_mut(|client| client.sut.poll_dns_queries()) {
                self.on_forwarded_dns_query(query, ref_state);
                continue;
            }
            self.client.exec_mut(|sim| {
                while let Some(packet) = sim.sut.poll_packets() {
                    sim.on_received_packet(packet)
                }
            });

            for (_, gateway) in self.gateways.iter_mut() {
                if let Some(transmit) = gateway.exec_mut(|g| g.sut.poll_transmit()) {
                    buffered_transmits.push(transmit, gateway);
                    continue 'outer;
                }
            }

            for (id, gateway) in self.gateways.iter_mut() {
                let Some(event) = gateway.exec_mut(|g| g.sut.poll_event()) else {
                    continue;
                };

                on_gateway_event(*id, event, &mut self.client, self.now);
                continue 'outer;
            }

            for (_, relay) in self.relays.iter_mut() {
                let Some(message) = relay.exec_mut(|r| r.sut.next_command()) else {
                    continue;
                };

                match message {
                    firezone_relay::Command::SendMessage { payload, recipient } => {
                        let dst = recipient.into_socket();
                        let src = relay
                            .sending_socket_for(dst.ip())
                            .expect("relay to never emit packets without a matching socket");

                        buffered_transmits.push(
                            Transmit {
                                src: Some(src),
                                dst,
                                payload: payload.into(),
                            },
                            relay,
                        );
                    }

                    firezone_relay::Command::CreateAllocation { port, family } => {
                        relay.allocate_port(port.value(), family);
                        relay.exec_mut(|r| r.allocations.insert((family, port)));
                    }
                    firezone_relay::Command::FreeAllocation { port, family } => {
                        relay.deallocate_port(port.value(), family);
                        relay.exec_mut(|r| r.allocations.remove(&(family, port)));
                    }
                }

                continue 'outer;
            }

            if self.handle_timeout(self.now, self.utc_now) {
                continue;
            }

            break;
        }
    }

    /// Forwards time to the given instant iff the corresponding host would like that (i.e. returns a timestamp <= from `poll_timeout`).
    ///
    /// Tying the forwarding of time to the result of `poll_timeout` gives us better coverage because in production, we suspend until the value of `poll_timeout`.
    fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) -> bool {
        let mut any_advanced = false;

        if self
            .client
            .exec_mut(|c| c.sut.poll_timeout())
            .is_some_and(|t| t <= now)
        {
            any_advanced = true;

            self.client.exec_mut(|c| c.sut.handle_timeout(now));
        };

        for (_, gateway) in self.gateways.iter_mut() {
            if gateway
                .exec_mut(|g| g.sut.poll_timeout())
                .is_some_and(|t| t <= now)
            {
                any_advanced = true;

                gateway.exec_mut(|g| g.sut.handle_timeout(now, utc_now))
            };
        }

        for (_, relay) in self.relays.iter_mut() {
            if relay
                .exec_mut(|r| r.sut.poll_timeout())
                .is_some_and(|t| t <= now)
            {
                any_advanced = true;

                relay.exec_mut(|r| r.sut.handle_timeout(now))
            };
        }

        any_advanced
    }

    /// Dispatches a [`Transmit`] to the correct host.
    ///
    /// This function is basically the "network layer" of our tests.
    /// It takes a [`Transmit`] and checks, which host accepts it, i.e. has configured the correct IP address.
    ///
    /// Currently, the network topology of our tests are a single subnet without NAT.
    fn dispatch_transmit(
        &mut self,
        transmit: Transmit,
        buffered_transmits: &mut BufferedTransmits,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
    ) {
        let src = transmit
            .src
            .expect("`src` should always be set in these tests");
        let dst = transmit.dst;
        let payload = &transmit.payload;

        let Some(host) = self.network.host_by_ip(dst.ip()) else {
            panic!("Unhandled packet: {src} -> {dst}")
        };

        match host {
            HostId::Client(_) => {
                self.client
                    .exec_mut(|c| c.handle_packet(payload, src, dst, self.now));
            }
            HostId::Gateway(id) => {
                let gateway = self.gateways.get_mut(&id).expect("unknown gateway");

                let Some(transmit) = gateway
                    .exec_mut(|g| g.handle_packet(global_dns_records, payload, src, dst, self.now))
                else {
                    return;
                };

                buffered_transmits.push(transmit, gateway);
            }
            HostId::Relay(id) => {
                let relay = self.relays.get_mut(&id).expect("unknown relay");

                let Some(transmit) =
                    relay.exec_mut(|r| r.handle_packet(payload, src, dst, self.now))
                else {
                    return;
                };

                buffered_transmits.push(transmit, relay);
            }
            HostId::Stale => {
                tracing::debug!(%dst, "Dropping packet because host roamed away or is offline");
            }
        }
    }

    fn on_client_event(
        &mut self,
        src: ClientId,
        event: ClientEvent,
        client: &RefClient,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
    ) {
        match event {
            ClientEvent::AddedIceCandidates {
                candidates,
                conn_id,
            } => {
                let gateway = self.gateways.get_mut(&conn_id).expect("unknown gateway");

                gateway.exec_mut(|g| {
                    for candidate in candidates {
                        g.sut.add_ice_candidate(src, candidate, self.now)
                    }
                })
            }
            ClientEvent::RemovedIceCandidates {
                candidates,
                conn_id,
            } => {
                let gateway = self.gateways.get_mut(&conn_id).expect("unknown gateway");

                gateway.exec_mut(|g| {
                    for candidate in candidates {
                        g.sut.remove_ice_candidate(src, candidate)
                    }
                })
            }
            ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids,
            } => {
                let (gateway, site) =
                    self.portal
                        .handle_connection_intent(resource, connected_gateway_ids, client);

                let request = self
                    .client
                    .exec_mut(|c| c.sut.create_or_reuse_connection(resource, gateway, site))
                    .unwrap()
                    .unwrap();

                let resource_id = request.resource_id();

                // Resolve the domain name that we want to talk to to the IP that we generated as part of the Transition for sending a DNS query.
                let resolved_ips = request
                    .domain_name()
                    .into_iter()
                    .flat_map(|domain| global_dns_records.get(&domain).cloned())
                    .flatten()
                    .collect();

                let resource =
                    map_client_resource_to_gateway_resource(client, resolved_ips, resource_id);

                match request {
                    Request::NewConnection(new_connection) => {
                        let Some(gateway) = self.gateways.get_mut(&new_connection.gateway_id)
                        else {
                            tracing::error!("Unknown gateway");
                            return;
                        };

                        let answer = gateway
                            .exec_mut(|g| {
                                g.sut.accept(
                                    self.client.inner().id,
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
                                    self.client.inner().sut.public_key(),
                                    self.client.inner().sut.tunnel_ip4().unwrap(),
                                    self.client.inner().sut.tunnel_ip6().unwrap(),
                                    new_connection
                                        .client_payload
                                        .domain
                                        .map(|r| (r.name, r.proxy_ips)),
                                    None, // TODO: How to generate expiry?
                                    resource,
                                    self.now,
                                )
                            })
                            .unwrap();

                        self.client
                            .exec_mut(|c| {
                                c.sut.accept_answer(
                                    snownet::Answer {
                                        credentials: snownet::Credentials {
                                            username: answer.username,
                                            password: answer.password,
                                        },
                                    },
                                    resource_id,
                                    gateway.inner().sut.public_key(),
                                    self.now,
                                )
                            })
                            .unwrap();
                    }
                    Request::ReuseConnection(reuse_connection) => {
                        let gateway = self
                            .gateways
                            .get_mut(&reuse_connection.gateway_id)
                            .expect("unknown gateway");

                        gateway
                            .exec_mut(|g| {
                                g.sut.allow_access(
                                    resource,
                                    self.client.inner().id,
                                    None,
                                    reuse_connection.payload.map(|r| (r.name, r.proxy_ips)),
                                    self.now,
                                )
                            })
                            .unwrap();
                    }
                };
            }

            ClientEvent::SendProxyIps { connections } => {
                for reuse_connection in connections {
                    let gateway = self
                        .gateways
                        .get_mut(&reuse_connection.gateway_id)
                        .expect("unknown gateway");

                    let resolved_ips = reuse_connection
                        .payload
                        .as_ref()
                        .map(|r| r.name.clone())
                        .into_iter()
                        .flat_map(|domain| global_dns_records.get(&domain).cloned().into_iter())
                        .flatten()
                        .collect();

                    let resource = map_client_resource_to_gateway_resource(
                        client,
                        resolved_ips,
                        reuse_connection.resource_id,
                    );

                    gateway
                        .exec_mut(|g| {
                            g.sut.allow_access(
                                resource,
                                self.client.inner().id,
                                None,
                                reuse_connection.payload.map(|r| (r.name, r.proxy_ips)),
                                self.now,
                            )
                        })
                        .unwrap();
                }
            }
            ClientEvent::ResourcesChanged { .. } => {
                tracing::warn!("Unimplemented");
            }
            ClientEvent::DnsServersChanged { dns_by_sentinel } => {
                self.client
                    .exec_mut(|c| c.dns_by_sentinel = dns_by_sentinel);
            }
        }
    }

    // TODO: Should we vary the following things via proptests?
    // - Forwarded DNS query timing out?
    // - hickory error?
    // - TTL?
    fn on_forwarded_dns_query(&mut self, query: DnsQuery<'static>, ref_state: &ReferenceState) {
        let all_ips = &ref_state
            .global_dns_records
            .get(&query.name)
            .expect("Forwarded DNS query to be for known domain");

        let name = domain_to_hickory_name(query.name.clone());
        let requested_type = query.record_type;

        let record_data = all_ips
            .iter()
            .filter_map(|ip| match (requested_type, ip) {
                (RecordType::A, IpAddr::V4(v4)) => Some(RData::A((*v4).into())),
                (RecordType::AAAA, IpAddr::V6(v6)) => Some(RData::AAAA((*v6).into())),
                (RecordType::A, IpAddr::V6(_)) | (RecordType::AAAA, IpAddr::V4(_)) => None,
                _ => unreachable!(),
            })
            .map(|rdata| Record::from_rdata(name.clone(), 86400_u32, rdata))
            .collect::<Arc<_>>();

        self.client.exec_mut(|c| {
            c.sut.on_dns_result(
                query,
                Ok(Ok(Ok(Lookup::new_with_max_ttl(
                    Query::query(name, requested_type),
                    record_data,
                )))),
            )
        })
    }
}

fn on_gateway_event(
    src: GatewayId,
    event: GatewayEvent,
    client: &mut Host<SimClient>,
    now: Instant,
) {
    match event {
        GatewayEvent::AddedIceCandidates { candidates, .. } => client.exec_mut(|c| {
            for candidate in candidates {
                c.sut.add_ice_candidate(src, candidate, now)
            }
        }),
        GatewayEvent::RemovedIceCandidates { candidates, .. } => client.exec_mut(|c| {
            for candidate in candidates {
                c.sut.remove_ice_candidate(src, candidate)
            }
        }),
        GatewayEvent::RefreshDns { .. } => todo!(),
    }
}

fn map_client_resource_to_gateway_resource(
    client: &RefClient,
    resolved_ips: Vec<IpAddr>,
    resource_id: ResourceId,
) -> gateway::ResourceDescription<gateway::ResolvedResourceDescriptionDns> {
    let cidr_resource = client.cidr_resources.iter().find_map(|(_, r)| {
        (r.id == resource_id).then_some(gateway::ResourceDescription::Cidr(
            gateway::ResourceDescriptionCidr {
                id: r.id,
                address: r.address,
                name: r.name.clone(),
                filters: Vec::new(),
            },
        ))
    });
    let dns_resource = client.dns_resources.get(&resource_id).map(|r| {
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

pub(crate) fn hickory_name_to_domain(mut name: hickory_proto::rr::Name) -> DomainName {
    name.set_fqdn(false); // Hack to work around hickory always parsing as FQ
    let name = name.to_string();

    let domain = DomainName::from_chars(name.chars()).unwrap();
    debug_assert_eq!(name, domain.to_string());

    domain
}

pub(crate) fn domain_to_hickory_name(domain: DomainName) -> hickory_proto::rr::Name {
    let domain = domain.to_string();

    let name = hickory_proto::rr::Name::from_str(&domain).unwrap();
    debug_assert_eq!(name.to_string(), domain);

    name
}

#[derive(Debug, Default)]
struct BufferedTransmits {
    inner: VecDeque<Transmit<'static>>,
}

impl BufferedTransmits {
    fn push<T>(&mut self, transmit: impl Into<Option<Transmit<'static>>>, sending_host: &Host<T>) {
        let Some(transmit) = transmit.into() else {
            return;
        };

        if transmit.src.is_some() {
            self.inner.push_back(transmit);
            return;
        }

        // The `src` of a [`Transmit`] is empty if we want to send if via the default interface.
        // In production, the kernel does this for us.
        // In this test, we need to always set a `src` so that the remote peer knows where the packet is coming from.

        let Some(src) = sending_host.sending_socket_for(transmit.dst.ip()) else {
            tracing::debug!(dst = %transmit.dst, "No socket");

            return;
        };

        self.inner.push_back(Transmit {
            src: Some(src),
            ..transmit
        });
    }

    fn pop(&mut self) -> Option<Transmit<'static>> {
        self.inner.pop_front()
    }

    fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}
