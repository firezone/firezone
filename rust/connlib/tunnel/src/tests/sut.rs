use super::buffered_transmits::BufferedTransmits;
use super::dns_records::DnsRecords;
use super::reference::ReferenceState;
use super::sim_client::SimClient;
use super::sim_gateway::SimGateway;
use super::sim_net::{Host, HostId, RoutingTable};
use super::sim_relay::SimRelay;
use super::stub_portal::StubPortal;
use super::transition::{Destination, DnsQuery};
use super::unreachable_hosts::UnreachableHosts;
use crate::client::Resource;
use crate::dns::is_subdomain;
use crate::messages::{IceCredentials, Key, SecretKey};
use crate::tests::assertions::*;
use crate::tests::flux_capacitor::FluxCapacitor;
use crate::tests::transition::Transition;
use crate::utils::earliest;
use crate::{dns, messages::Interface, ClientEvent, GatewayEvent};
use connlib_model::{ClientId, GatewayId, PublicKey, RelayId};
use domain::base::iana::{Class, Rcode};
use domain::base::{Message, MessageBuilder, Record, RecordData, ToName as _, Ttl};
use firezone_logging::anyhow_dyn_err;
use rand::distributions::DistString;
use rand::SeedableRng;
use sha2::Digest;
use snownet::Transmit;
use std::iter;
use std::{
    collections::BTreeMap,
    net::IpAddr,
    time::{Duration, Instant},
};
use tracing::debug_span;

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
}

impl TunnelTest {
    // Initialize the system under test from our reference state.
    pub(crate) fn init_test(ref_state: &ReferenceState, flux_capacitor: FluxCapacitor) -> Self {
        // Construct client, gateway and relay from the initial state.
        let mut client = ref_state.client.map(
            |ref_client, _, _| ref_client.init(flux_capacitor.now()),
            debug_span!("client"),
        );

        let mut gateways = ref_state
            .gateways
            .iter()
            .map(|(gid, gateway)| {
                let gateway = gateway.map(
                    |ref_gateway, _, _| ref_gateway.init(*gid, flux_capacitor.now()),
                    debug_span!("gateway", %gid),
                );

                (*gid, gateway)
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
        client.exec_mut(|c| c.update_relays(iter::empty(), relays.iter(), flux_capacitor.now()));
        for gateway in gateways.values_mut() {
            gateway
                .exec_mut(|g| g.update_relays(iter::empty(), relays.iter(), flux_capacitor.now()));
        }

        let mut this = Self {
            flux_capacitor: flux_capacitor.clone(),
            network: ref_state.network.clone(),
            drop_direct_client_traffic: ref_state.drop_direct_client_traffic,
            client,
            gateways,
            relays,
        };

        let mut buffered_transmits = BufferedTransmits::default();
        this.advance(ref_state, &mut buffered_transmits); // Perform initial setup before we apply the first transition.

        this
    }

    /// Apply a generated state transition to our system under test.
    pub(crate) fn apply(
        mut state: Self,
        ref_state: &ReferenceState,
        transition: Transition,
    ) -> Self {
        let mut buffered_transmits = BufferedTransmits::default();
        let now = state.flux_capacitor.now();

        // Act: Apply the transition
        match transition {
            Transition::ActivateResource(resource) => {
                state.client.exec_mut(|c| {
                    // Flush DNS.
                    match &resource {
                        Resource::Dns(r) => {
                            c.dns_records.retain(|domain, _| {
                                if is_subdomain(domain, &r.address) {
                                    return false;
                                }

                                true
                            });
                        }
                        Resource::Cidr(_) => {}
                        Resource::Internet(_) => {}
                    }

                    c.sut.add_resource(resource);
                });
            }
            Transition::DeactivateResource(id) => {
                state.client.exec_mut(|c| c.sut.remove_resource(id))
            }
            Transition::DisableResources(resources) => state
                .client
                .exec_mut(|c| c.sut.set_disabled_resources(resources)),
            Transition::SendIcmpPacket {
                src,
                dst,
                seq,
                identifier,
                payload,
                ..
            } => {
                let dst = address_from_destination(&dst, &state, &src);

                let packet = ip_packet::make::icmp_request_packet(
                    src,
                    dst,
                    seq.0,
                    identifier.0,
                    &payload.to_be_bytes(),
                )
                .unwrap();

                let transmit = state
                    .client
                    .exec_mut(|sim| Some(sim.encapsulate(packet, now)?.into_owned()));

                buffered_transmits.push_from(transmit, &state.client, now);
            }
            Transition::SendUdpPacket {
                src,
                dst,
                sport,
                dport,
                payload,
            } => {
                let dst = address_from_destination(&dst, &state, &src);

                let packet = ip_packet::make::udp_packet(
                    src,
                    dst,
                    sport.0,
                    dport.0,
                    payload.to_be_bytes().to_vec(),
                )
                .unwrap();

                let transmit = state
                    .client
                    .exec_mut(|sim| Some(sim.encapsulate(packet, now)?.into_owned()));

                buffered_transmits.push_from(transmit, &state.client, now);
            }
            Transition::SendTcpPayload {
                src,
                dst,
                sport,
                dport,
                payload,
            } => {
                let dst = address_from_destination(&dst, &state, &src);

                let packet = ip_packet::make::tcp_packet(
                    src,
                    dst,
                    sport.0,
                    dport.0,
                    payload.to_be_bytes().to_vec(),
                )
                .unwrap();

                let transmit = state
                    .client
                    .exec_mut(|sim| Some(sim.encapsulate(packet, now)?.into_owned()));

                buffered_transmits.push_from(transmit, &state.client, now);
            }
            Transition::SendDnsQueries(queries) => {
                for DnsQuery {
                    domain,
                    r_type,
                    dns_server,
                    query_id,
                    transport,
                } in queries
                {
                    let transmit = state.client.exec_mut(|sim| {
                        sim.send_dns_query_for(domain, r_type, query_id, dns_server, transport, now)
                    });

                    buffered_transmits.push_from(transmit, &state.client, now);
                }
            }
            Transition::UpdateSystemDnsServers(servers) => {
                state
                    .client
                    .exec_mut(|c| c.sut.update_system_resolvers(servers));
            }
            Transition::UpdateUpstreamDnsServers(servers) => {
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
                    c.sut.reset(now);

                    // In prod, we reconnect to the portal and receive a new `init` message.
                    c.update_relays(iter::empty(), state.relays.iter(), now);
                    c.sut
                        .set_resources(ref_state.client.inner().all_resources());
                });
            }
            Transition::ReconnectPortal => {
                let ipv4 = state.client.inner().sut.tunnel_ip4().unwrap();
                let ipv6 = state.client.inner().sut.tunnel_ip6().unwrap();
                let upstream_dns = ref_state.client.inner().upstream_dns_resolvers();
                let all_resources = ref_state.client.inner().all_resources();

                // Simulate receiving `init`.
                state.client.exec_mut(|c| {
                    c.sut.update_interface_config(Interface {
                        ipv4,
                        ipv6,
                        upstream_dns,
                    });
                    c.update_relays(iter::empty(), state.relays.iter(), now);
                    c.sut.set_resources(all_resources);
                });
            }
            Transition::DeployNewRelays(new_relays) => {
                // If we are connected to the portal, we will learn, which ones went down, i.e. `relays_presence`.
                let to_remove = state.relays.keys().copied().collect();

                state.deploy_new_relays(new_relays, now, to_remove);
            }
            Transition::Idle => {
                const IDLE_DURATION: Duration = Duration::from_secs(6 * 60); // Ensure idling twice in a row puts us in the 10-15 minute window where TURN data channels are cooling down.
                let cut_off = state.flux_capacitor.now::<Instant>() + IDLE_DURATION;

                debug_assert_eq!(buffered_transmits.packet_counter(), 0);

                while state.flux_capacitor.now::<Instant>() <= cut_off {
                    state.flux_capacitor.tick(Duration::from_secs(5));
                    state.advance(ref_state, &mut buffered_transmits);
                }

                let num_packets = buffered_transmits.packet_counter() as f64;
                let num_connections = state.client.inner().sut.num_connections() as f64 + 1.0; // +1 because we may have 0 connections.
                let num_seconds = IDLE_DURATION.as_secs() as f64;

                let packets_per_sec = num_packets / num_seconds / num_connections;

                // This has been chosen through experimentation. It primarily serves as a regression tool to ensure our idle-traffic doesn't suddenly spike.
                const THRESHOLD: f64 = 2.0;

                if packets_per_sec > THRESHOLD {
                    tracing::error!("Expected at most {THRESHOLD} packets / sec in the network while idling. Got: {packets_per_sec}");
                }
            }
            Transition::PartitionRelaysFromPortal => {
                // 1. Disconnect all relays.
                state.client.exec_mut(|c| {
                    c.update_relays(state.relays.keys().copied(), iter::empty(), now)
                });
                for gateway in state.gateways.values_mut() {
                    gateway.exec_mut(|g| {
                        g.update_relays(state.relays.keys().copied(), iter::empty(), now)
                    });
                }

                // 2. Advance state to ensure this is reflected.
                state.advance(ref_state, &mut buffered_transmits);

                let now = state.flux_capacitor.now();

                // 3. Reconnect all relays.
                state
                    .client
                    .exec_mut(|c| c.update_relays(iter::empty(), state.relays.iter(), now));
                for gateway in state.gateways.values_mut() {
                    gateway.exec_mut(|g| g.update_relays(iter::empty(), state.relays.iter(), now));
                }
            }
            Transition::RebootRelaysWhilePartitioned(new_relays) => {
                // If we are partitioned from the portal, we will only learn which relays to use, potentially replacing existing ones.
                let to_remove = Vec::default();

                state.deploy_new_relays(new_relays, now, to_remove);
            }
        };
        state.advance(ref_state, &mut buffered_transmits);

        state
    }

    // Assert against the reference state machine.
    pub(crate) fn check_invariants(state: &Self, ref_state: &ReferenceState) {
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
            &sim_gateways,
            &ref_state.global_dns_records,
        );
        assert_udp_packets_properties(
            ref_client,
            sim_client,
            &sim_gateways,
            &ref_state.global_dns_records,
        );
        assert_tcp_packets_properties(
            ref_client,
            sim_client,
            &sim_gateways,
            &ref_state.global_dns_records,
        );
        assert_udp_dns_packets_properties(ref_client, sim_client);
        assert_tcp_dns(ref_client, sim_client);
        assert_known_hosts_are_valid(ref_client, sim_client);
        assert_dns_servers_are_valid(ref_client, sim_client);
        assert_routes_are_valid(ref_client, sim_client);
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
            // `handle_timeout` needs to be called at the very top to advance state after we have made other modifications.
            self.handle_timeout(
                &ref_state.global_dns_records,
                &ref_state.unreachable_hosts,
                buffered_transmits,
            );
            let now = self.flux_capacitor.now();

            for (id, gateway) in self.gateways.iter_mut() {
                let Some(event) = gateway.exec_mut(|g| g.sut.poll_event()) else {
                    continue;
                };

                on_gateway_event(
                    *id,
                    event,
                    &mut self.client,
                    gateway,
                    &ref_state.global_dns_records,
                    now,
                );
                continue 'outer;
            }

            if let Some(event) = self.client.exec_mut(|c| c.sut.poll_event()) {
                self.on_client_event(self.client.inner().id, event, &ref_state.portal);
                continue;
            }
            if let Some(query) = self.client.exec_mut(|c| c.sut.poll_dns_queries()) {
                let server = query.server;
                let transport = query.transport;

                let response = self.on_recursive_dns_query(
                    query.message.for_slice_ref(),
                    &ref_state.global_dns_records,
                );
                self.client.exec_mut(|c| {
                    c.sut.handle_dns_response(dns::RecursiveResponse {
                        server,
                        query: query.message,
                        message: Ok(response), // TODO: Vary this?
                        transport,
                    })
                });

                continue;
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

            if let Some(transmit) = self.client.exec_mut(|sim| sim.sut.poll_transmit()) {
                buffered_transmits.push_from(transmit, &self.client, now);
                continue;
            }

            self.client.exec_mut(|sim| {
                while let Some(packet) = sim.sut.poll_packets() {
                    sim.on_received_packet(packet)
                }
            });

            if let Some(transmit) = buffered_transmits.pop(now) {
                self.dispatch_transmit(transmit, now);
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

        for (transmit, at) in buffered_transmits.drain() {
            self.dispatch_transmit(transmit, at);
        }
    }

    fn handle_timeout(
        &mut self,
        global_dns_records: &DnsRecords,
        unreachable_hosts: &UnreachableHosts,
        buffered_transmits: &mut BufferedTransmits,
    ) {
        let now = self.flux_capacitor.now();

        // Handle the TCP DNS client, i.e. simulate applications making TCP DNS queries.
        self.client.exec_mut(|c| {
            c.tcp_dns_client.handle_timeout(now);

            while let Some(result) = c.tcp_dns_client.poll_query_result() {
                match result.result {
                    Ok(message) => {
                        let upstream = c.dns_mapping().get_by_left(&result.server.ip()).unwrap();

                        c.received_tcp_dns_responses
                            .insert((*upstream, result.query.header().id()));
                        c.handle_dns_response(message.for_slice())
                    }
                    Err(e) => {
                        tracing::error!(error = anyhow_dyn_err(&e), "TCP DNS query failed");
                    }
                }
            }
        });
        while let Some(transmit) = self.client.exec_mut(|c| {
            let packet = c.tcp_dns_client.poll_outbound()?;
            c.encapsulate(packet, now)
        }) {
            buffered_transmits.push_from(transmit, &self.client, now)
        }

        // Handle the client's `Transmit`s and timeout.
        while let Some(transmit) = self.client.poll_transmit(now) {
            self.client.exec_mut(|c| c.receive(transmit, now))
        }
        self.client.exec_mut(|c| {
            if c.sut.poll_timeout().is_some_and(|t| t <= now) {
                c.sut.handle_timeout(now)
            }
        });

        // Handle all gateway `Transmit`s and timeouts.
        for (_, gateway) in self.gateways.iter_mut() {
            for transmit in gateway.exec_mut(|g| g.advance_resources(global_dns_records, now)) {
                buffered_transmits.push_from(transmit, gateway, now);
            }

            while let Some(transmit) = gateway.poll_transmit(now) {
                let Some(reply) = gateway.exec_mut(|g| {
                    g.receive(transmit, unreachable_hosts, now, self.flux_capacitor.now())
                }) else {
                    continue;
                };

                buffered_transmits.push_from(reply, gateway, now);
            }

            gateway.exec_mut(|g| {
                if g.sut.poll_timeout().is_some_and(|t| t <= now) {
                    g.sut.handle_timeout(now, self.flux_capacitor.now())
                }
            });
        }

        // Handle all relay `Transmit`s and timeouts.
        for (_, relay) in self.relays.iter_mut() {
            while let Some(transmit) = relay.poll_transmit(now) {
                let Some(reply) = relay.exec_mut(|r| r.receive(transmit, now)) else {
                    continue;
                };

                buffered_transmits.push_from(reply, relay, now);
            }

            relay.exec_mut(|r| {
                if r.sut.poll_timeout().is_some_and(|t| t <= now) {
                    r.sut.handle_timeout(now)
                }
            })
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
    fn dispatch_transmit(&mut self, transmit: Transmit<'static>, at: Instant) {
        let src = transmit
            .src
            .expect("`src` should always be set in these tests");
        let dst = transmit.dst;

        let Some(host) = self.network.host_by_ip(dst.ip()) else {
            tracing::error!("Unhandled packet: {src} -> {dst}");
            return;
        };

        match host {
            HostId::Client(_) => {
                if self.drop_direct_client_traffic
                    && self.gateways.values().any(|g| g.is_sender(src.ip()))
                {
                    tracing::trace!(%src, %dst, "Dropping direct traffic");

                    return;
                }

                self.client.receive(transmit, at);
            }
            HostId::Gateway(id) => {
                if self.drop_direct_client_traffic && self.client.is_sender(src.ip()) {
                    tracing::trace!(%src, %dst, "Dropping direct traffic");

                    return;
                }

                self.gateways
                    .get_mut(&id)
                    .expect("unknown gateway")
                    .receive(transmit, at);
            }
            HostId::Relay(id) => {
                self.relays
                    .get_mut(&id)
                    .expect("unknown relay")
                    .receive(transmit, at);
            }
            HostId::Stale => {
                tracing::debug!(%dst, "Dropping packet because host roamed away or is offline");
            }
        }
    }

    fn on_client_event(&mut self, src: ClientId, event: ClientEvent, portal: &StubPortal) {
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
                        g.sut.remove_ice_candidate(src, candidate, now)
                    }
                })
            }
            ClientEvent::ConnectionIntent {
                resource: resource_id,
                connected_gateway_ids,
            } => {
                let (gateway_id, site_id) =
                    portal.handle_connection_intent(resource_id, connected_gateway_ids);
                let gateway = self.gateways.get_mut(&gateway_id).expect("unknown gateway");
                let resource = portal.map_client_resource_to_gateway_resource(resource_id);

                let client_key = self.client.inner().sut.public_key();
                let gateway_key = gateway.inner().sut.public_key();
                let (preshared_key, client_ice, gateway_ice) =
                    make_preshared_key_and_ice(client_key, gateway_key);

                gateway
                    .exec_mut(|g| {
                        g.sut.authorize_flow(
                            src,
                            client_key,
                            preshared_key.clone(),
                            client_ice.clone(),
                            gateway_ice.clone(),
                            self.client.inner().sut.tunnel_ip4().unwrap(),
                            self.client.inner().sut.tunnel_ip6().unwrap(),
                            None,
                            resource,
                            now,
                        )
                    })
                    .unwrap();
                if let Err(e) = self.client.exec_mut(|c| {
                    c.sut.handle_flow_created(
                        resource_id,
                        gateway_id,
                        gateway_key,
                        site_id,
                        preshared_key,
                        client_ice,
                        gateway_ice,
                        now,
                    )
                }) {
                    tracing::error!("{e:#}")
                };
            }

            ClientEvent::ResourcesChanged { .. } => {
                tracing::warn!("Unimplemented");
            }
            ClientEvent::TunInterfaceUpdated(config) => {
                if self.client.inner().dns_mapping() == &config.dns_by_sentinel
                    && self.client.inner().ipv4_routes == config.ipv4_routes
                    && self.client.inner().ipv6_routes == config.ipv6_routes
                {
                    tracing::error!(
                        "Emitted `TunInterfaceUpdated` without changing DNS servers or routes"
                    );
                }

                if self.client.inner().dns_mapping() != &config.dns_by_sentinel {
                    for gateway in self.gateways.values_mut() {
                        gateway.exec_mut(|g| {
                            g.deploy_new_dns_servers(
                                config.dns_by_sentinel.right_values().copied(),
                                now,
                            )
                        })
                    }
                }

                self.client.exec_mut(|c| {
                    c.set_new_dns_servers(config.dns_by_sentinel);
                    c.ipv4_routes = config.ipv4_routes;
                    c.ipv6_routes = config.ipv6_routes;
                });
            }
        }
    }

    fn on_recursive_dns_query(
        &self,
        query: Message<&[u8]>,
        global_dns_records: &DnsRecords,
    ) -> Message<Vec<u8>> {
        let response = MessageBuilder::new_vec();
        let mut answers = response.start_answer(&query, Rcode::NOERROR).unwrap();

        let query = query.sole_question().unwrap();
        let name = query.qname().to_vec();
        let qtype = query.qtype();

        let records = global_dns_records
            .domain_records_iter(&name)
            .filter(|record| qtype == record.rtype())
            .map(|rdata| Record::new(name.clone(), Class::IN, Ttl::from_days(1), rdata));

        for record in records {
            answers.push(record).unwrap();
        }

        let response = answers.into_message();

        tracing::debug!(%name, %qtype, "Responding to DNS query");

        response
    }

    fn deploy_new_relays(
        &mut self,
        new_relays: BTreeMap<RelayId, Host<u64>>,
        now: Instant,
        to_remove: Vec<RelayId>,
    ) {
        for relay in self.relays.values() {
            self.network.remove_host(relay);
        }

        let online = new_relays
            .into_iter()
            .map(|(rid, relay)| (rid, relay.map(SimRelay::new, debug_span!("relay", %rid))))
            .collect::<BTreeMap<_, _>>();

        for (rid, relay) in &online {
            debug_assert!(self.network.add_host(*rid, relay));
        }

        self.client.exec_mut(|c| {
            c.update_relays(to_remove.iter().copied(), online.iter(), now);
        });
        for gateway in self.gateways.values_mut() {
            gateway.exec_mut(|g| g.update_relays(to_remove.iter().copied(), online.iter(), now));
        }
        self.relays = online; // Override all relays.
    }
}

fn address_from_destination(destination: &Destination, state: &TunnelTest, src: &IpAddr) -> IpAddr {
    match destination {
        Destination::DomainName { resolved_ip, name } => {
            let available_ips = state
                .client
                .inner()
                .dns_records
                .get(name)
                .unwrap()
                .iter()
                .filter(|ip| match ip {
                    IpAddr::V4(_) => src.is_ipv4(),
                    IpAddr::V6(_) => src.is_ipv6(),
                });
            *resolved_ip.select(available_ips)
        }
        Destination::IpAddr(addr) => *addr,
    }
}

fn make_preshared_key_and_ice(
    client_key: PublicKey,
    gateway_key: PublicKey,
) -> (SecretKey, IceCredentials, IceCredentials) {
    let secret_key = SecretKey::new(Key(hkdf("SECRET_KEY_DOMAIN_SEP", client_key, gateway_key)));
    let client_ice = ice_creds("CLIENT_ICE_DOMAIN_SEP", client_key, gateway_key);
    let gateway_ice = ice_creds("GATEWAY_ICE_DOMAIN_SEP", client_key, gateway_key);

    (secret_key, client_ice, gateway_ice)
}

fn ice_creds(domain: &str, client_key: PublicKey, gateway_key: PublicKey) -> IceCredentials {
    let mut rng = rand::rngs::StdRng::from_seed(hkdf(domain, client_key, gateway_key));

    IceCredentials {
        username: rand::distributions::Alphanumeric.sample_string(&mut rng, 4),
        password: rand::distributions::Alphanumeric.sample_string(&mut rng, 12),
    }
}

fn hkdf(domain: &str, client_key: PublicKey, gateway_key: PublicKey) -> [u8; 32] {
    sha2::Sha256::default()
        .chain_update(domain)
        .chain_update(client_key.as_bytes())
        .chain_update(gateway_key.as_bytes())
        .finalize()
        .into()
}

fn on_gateway_event(
    src: GatewayId,
    event: GatewayEvent,
    client: &mut Host<SimClient>,
    gateway: &mut Host<SimGateway>,
    global_dns_records: &DnsRecords,
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
                c.sut.remove_ice_candidate(src, candidate, now)
            }
        }),
        GatewayEvent::ResolveDns(r) => {
            let resolved_ips = global_dns_records.domain_ips_iter(r.domain()).collect();

            gateway.exec_mut(|g| {
                g.sut
                    .handle_domain_resolved(r, Ok(resolved_ips), now)
                    .unwrap()
            })
        }
    }
}
