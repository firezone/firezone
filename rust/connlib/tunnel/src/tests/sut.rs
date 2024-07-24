use super::buffered_transmits::BufferedTransmits;
use super::reference::ReferenceState;
use super::sim_client::SimClient;
use super::sim_gateway::SimGateway;
use super::sim_net::{Host, HostId, RoutingTable};
use super::sim_relay::SimRelay;
use super::stub_portal::StubPortal;
use crate::dns::is_subdomain;
use crate::tests::assertions::*;
use crate::tests::flux_capacitor::FluxCapacitor;
use crate::tests::sim_relay::map_explode;
use crate::tests::transition::Transition;
use crate::utils::earliest;
use crate::{dns::DnsQuery, ClientEvent, GatewayEvent, Request};
use connlib_shared::messages::client::ResourceDescription;
use connlib_shared::{
    messages::{ClientId, GatewayId, Interface, RelayId},
    DomainName,
};
use hickory_proto::{
    op::Query,
    rr::{RData, Record, RecordType},
};
use hickory_resolver::lookup::Lookup;
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use secrecy::ExposeSecret as _;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    net::IpAddr,
    sync::Arc,
    time::{Duration, Instant},
};
use tracing::debug_span;
use tracing::subscriber::DefaultGuard;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::Layer as _;
use tracing_subscriber::{util::SubscriberInitExt as _, EnvFilter};

/// The actual system-under-test.
///
/// [`proptest`] manipulates this using [`Transition`]s and we assert it against [`ReferenceState`].
pub(crate) struct TunnelTest {
    flux_capacitor: FluxCapacitor,

    client: Host<SimClient>,
    gateways: BTreeMap<GatewayId, Host<SimGateway>>,
    relays: BTreeMap<RelayId, Host<SimRelay>>,

    drop_direct_client_traffic: bool,
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
        let flux_capacitor = FluxCapacitor::default();

        let logger = tracing_subscriber::fmt()
            .with_test_writer()
            // .with_writer(crate::tests::run_count_appender::appender()) // Useful for diffing logs between runs.
            .with_timer(flux_capacitor.clone())
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
            .collect::<BTreeMap<_, _>>();

        let relays = ref_state
            .relays
            .iter()
            .map(|(rid, relay)| {
                let relay = relay.map(SimRelay::new, debug_span!("relay", %rid));

                (*rid, relay)
            })
            .collect::<BTreeMap<_, _>>();

        // Configure client and gateway with the relays.
        client.exec_mut(|c| {
            c.sut.update_relays(
                BTreeSet::default(),
                BTreeSet::from_iter(map_explode(relays.iter(), "client")),
                flux_capacitor.now(),
            )
        });
        for (id, gateway) in &mut gateways {
            gateway.exec_mut(|g| {
                g.sut.update_relays(
                    BTreeSet::default(),
                    BTreeSet::from_iter(map_explode(relays.iter(), &format!("gateway_{id}"))),
                    flux_capacitor.now(),
                )
            });
        }

        let mut this = Self {
            flux_capacitor,
            network: ref_state.network.clone(),
            drop_direct_client_traffic: ref_state.drop_direct_client_traffic,
            client,
            gateways,
            logger,
            relays,
        };

        let mut buffered_transmits = BufferedTransmits::default();
        this.advance(ref_state, &mut buffered_transmits); // Perform initial setup before we apply the first transition.

        this
    }

    /// Apply a generated state transition to our system under test.
    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        let mut buffered_transmits = BufferedTransmits::default();
        let now = state.flux_capacitor.now();

        // Act: Apply the transition
        match transition {
            Transition::ActivateResource(resource) => {
                state.client.exec_mut(|c| {
                    // Flush DNS.
                    match &resource {
                        ResourceDescription::Dns(r) => {
                            c.dns_records.retain(|domain, _| {
                                if is_subdomain(domain, &r.address) {
                                    return false;
                                }

                                true
                            });
                        }
                        ResourceDescription::Cidr(_) => {}
                        ResourceDescription::Internet(_) => {}
                    }

                    c.sut.add_resource(resource);
                });
            }
            Transition::DeactivateResource(id) => {
                state.client.exec_mut(|c| c.sut.remove_resource(id))
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
                ..
            } => {
                let packet = ip_packet::make::icmp_request_packet(src, dst, seq, identifier);

                let transmit = state.client.exec_mut(|sim| sim.encapsulate(packet, now));

                buffered_transmits.push_from(transmit, &state.client, now);
            }
            Transition::SendICMPPacketToDnsResource {
                src,
                dst,
                seq,
                identifier,
                resolved_ip,
                ..
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
                    .exec_mut(|sim| Some(sim.encapsulate(packet, now)?.into_owned()));

                buffered_transmits.push_from(transmit, &state.client, now);
            }
            Transition::SendDnsQuery {
                domain,
                r_type,
                query_id,
                dns_server,
            } => {
                let transmit = state.client.exec_mut(|sim| {
                    sim.send_dns_query_for(domain, r_type, query_id, dns_server, now)
                });

                buffered_transmits.push_from(transmit, &state.client, now);
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
                        BTreeSet::default(),
                        BTreeSet::from_iter(map_explode(state.relays.iter(), "client")),
                        now,
                    );
                    c.sut
                        .set_resources(ref_state.client.inner().all_resources());
                });
            }
            Transition::ReconnectPortal => {
                let ipv4 = state.client.inner().sut.tunnel_ip4().unwrap();
                let ipv6 = state.client.inner().sut.tunnel_ip6().unwrap();
                let upstream_dns = ref_state.client.inner().upstream_dns_resolvers.clone();
                let relays = BTreeSet::from_iter(map_explode(state.relays.iter(), "client"));
                let all_resources = ref_state.client.inner().all_resources();

                // Simulate receiving `init`.
                state.client.exec_mut(|c| {
                    let _ = c.sut.update_interface_config(Interface {
                        ipv4,
                        ipv6,
                        upstream_dns,
                    });
                    c.sut.update_relays(BTreeSet::default(), relays, now);
                    c.sut.set_resources(all_resources);
                });
            }
            Transition::Idle => {
                const IDLE_DURATION: Duration = Duration::from_secs(5 * 60);
                let cut_off = state.flux_capacitor.now::<Instant>() + IDLE_DURATION;

                while state.flux_capacitor.now::<Instant>() <= cut_off {
                    state.flux_capacitor.tick(Duration::from_secs(5));
                    state.advance(ref_state, &mut buffered_transmits);
                }
            }
        };
        state.advance(ref_state, &mut buffered_transmits);

        state
    }

    // Assert against the reference state machine.
    fn check_invariants(
        state: &Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
    ) {
        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_test_writer()
                    .with_timer(state.flux_capacitor.clone())
                    .with_filter(EnvFilter::from_default_env()),
            )
            .with(PanicOnErrorEvents::default()) // Temporarily install a layer that panics when `_guard` goes out of scope if any of our assertions emitted an error.
            .set_default();

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
    ///
    /// At most, we will spend 10s of "simulation time" advancing the state.
    fn advance(&mut self, ref_state: &ReferenceState, buffered_transmits: &mut BufferedTransmits) {
        let cut_off = self.flux_capacitor.now::<Instant>() + Duration::from_secs(10);

        'outer: while self.flux_capacitor.now::<Instant>() < cut_off {
            self.handle_timeout(&ref_state.global_dns_records, buffered_transmits);
            let now = self.flux_capacitor.now();

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

                        buffered_transmits.push_from(
                            Transmit {
                                src: Some(src),
                                dst,
                                payload: payload.into(),
                            },
                            relay,
                            now,
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

            for (_, gateway) in self.gateways.iter_mut() {
                let Some(transmit) = gateway.exec_mut(|g| g.sut.poll_transmit()) else {
                    continue;
                };

                buffered_transmits.push_from(transmit, gateway, now);
                continue 'outer;
            }

            for (id, gateway) in self.gateways.iter_mut() {
                let Some(event) = gateway.exec_mut(|g| g.sut.poll_event()) else {
                    continue;
                };

                on_gateway_event(*id, event, &mut self.client, now);
                continue 'outer;
            }

            if let Some(transmit) = self.client.exec_mut(|sim| sim.sut.poll_transmit()) {
                buffered_transmits.push_from(transmit, &self.client, now);
                continue;
            }
            if let Some(event) = self.client.exec_mut(|c| c.sut.poll_event()) {
                self.on_client_event(
                    self.client.inner().id,
                    event,
                    &ref_state.portal,
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

            if let Some(transmit) = buffered_transmits.pop(now) {
                self.dispatch_transmit(transmit);
                continue;
            }

            if !buffered_transmits.is_empty() {
                self.flux_capacitor.small_tick(); // Small tick to get to the next transmit.
                continue;
            }

            let Some(time_to_next_action) = self.poll_timeout() else {
                break; // Nothing to do.
            };

            if time_to_next_action > cut_off {
                break; // Nothing to do before cut-off.
            }

            self.flux_capacitor.large_tick(); // Large tick to more quickly advance to potential next timeout.
        }
    }

    fn handle_timeout(
        &mut self,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
        buffered_transmits: &mut BufferedTransmits,
    ) {
        let now = self.flux_capacitor.now();

        while let Some(transmit) = self.client.poll_transmit(now) {
            self.client.exec_mut(|c| c.receive(transmit, now))
        }
        self.client.exec_mut(|c| c.sut.handle_timeout(now));

        for (_, gateway) in self.gateways.iter_mut() {
            while let Some(transmit) = gateway.poll_transmit(now) {
                let Some(reply) =
                    gateway.exec_mut(|g| g.receive(global_dns_records, transmit, now))
                else {
                    continue;
                };

                buffered_transmits.push_from(reply, gateway, now);
            }

            gateway.exec_mut(|g| g.sut.handle_timeout(now, self.flux_capacitor.now()));
        }

        for (_, relay) in self.relays.iter_mut() {
            while let Some(transmit) = relay.poll_transmit(now) {
                let Some(reply) = relay.exec_mut(|g| g.receive(transmit, now)) else {
                    continue;
                };

                buffered_transmits.push_from(reply, relay, now);
            }

            relay.exec_mut(|r| r.sut.handle_timeout(now))
        }
    }

    fn poll_timeout(&mut self) -> Option<Instant> {
        let client = self.client.exec_mut(|c| c.sut.poll_timeout());
        let gateway = self
            .gateways
            .values_mut()
            .flat_map(|g| g.exec_mut(|g| g.sut.poll_timeout()))
            .min();
        let relay = self
            .relays
            .values_mut()
            .flat_map(|r| r.exec_mut(|r| r.sut.poll_timeout()))
            .min();

        earliest(client, earliest(gateway, relay))
    }

    /// Dispatches a [`Transmit`] to the correct host.
    ///
    /// This function is basically the "network layer" of our tests.
    /// It takes a [`Transmit`] and checks, which host accepts it, i.e. has configured the correct IP address.
    ///
    /// Currently, the network topology of our tests are a single subnet without NAT.
    fn dispatch_transmit(&mut self, transmit: Transmit<'static>) {
        let src = transmit
            .src
            .expect("`src` should always be set in these tests");
        let dst = transmit.dst;
        let now = self.flux_capacitor.now();

        let Some(host) = self.network.host_by_ip(dst.ip()) else {
            panic!("Unhandled packet: {src} -> {dst}")
        };

        match host {
            HostId::Client(_) => {
                if self.drop_direct_client_traffic
                    && self.gateways.values().any(|g| g.is_sender(src.ip()))
                {
                    tracing::trace!(%src, %dst, "Dropping direct traffic");

                    return;
                }

                self.client.receive(transmit, now);
            }
            HostId::Gateway(id) => {
                if self.drop_direct_client_traffic && self.client.is_sender(src.ip()) {
                    tracing::trace!(%src, %dst, "Dropping direct traffic");

                    return;
                }

                self.gateways
                    .get_mut(&id)
                    .expect("unknown gateway")
                    .receive(transmit, now);
            }
            HostId::Relay(id) => {
                self.relays
                    .get_mut(&id)
                    .expect("unknown relay")
                    .receive(transmit, now);
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
        portal: &StubPortal,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
    ) {
        let now = self.flux_capacitor.now();

        match event {
            ClientEvent::AddedIceCandidates {
                candidates,
                conn_id,
            } => {
                let gateway = self.gateways.get_mut(&conn_id).expect("unknown gateway");

                gateway.exec_mut(|g| {
                    for candidate in candidates {
                        g.sut.add_ice_candidate(src, candidate, now)
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
                    portal.handle_connection_intent(resource, connected_gateway_ids);

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
                    portal.map_client_resource_to_gateway_resource(resolved_ips, resource_id);

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
                                    now,
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
                                    now,
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
                                    now,
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

                    let resource = portal.map_client_resource_to_gateway_resource(
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
                                now,
                            )
                        })
                        .unwrap();
                }
            }
            ClientEvent::ResourcesChanged { .. } => {
                tracing::warn!("Unimplemented");
            }
            ClientEvent::TunInterfaceUpdated {
                dns_by_sentinel, ..
            } => {
                self.client
                    .exec_mut(|c| c.dns_by_sentinel = dns_by_sentinel);
            }
            ClientEvent::TunRoutesUpdated { .. } => {}
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

        let name = query.name.clone();
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
