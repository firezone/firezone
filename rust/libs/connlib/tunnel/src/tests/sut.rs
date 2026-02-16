use super::buffered_transmits::BufferedTransmits;
use super::dns_records::DnsRecords;
use super::icmp_error_hosts::IcmpErrorHosts;
use super::reference::ReferenceState;
use super::sim_client::SimClient;
use super::sim_gateway::SimGateway;
use super::sim_net::{Host, HostId, RoutingTable};
use super::sim_relay::SimRelay;
use super::stub_portal::StubPortal;
use super::transition::{Destination, DnsQuery};
use crate::client;
use crate::dns::is_subdomain;
use crate::messages::gateway::{Client, Subject};
use crate::messages::{IceCredentials, Key, SecretKey};
use crate::tests::assertions::*;
use crate::tests::flux_capacitor::FluxCapacitor;
use crate::tests::transition::Transition;
use crate::{ClientEvent, GatewayEvent, dns, messages::Interface};
use bufferpool::BufferPool;
use connlib_model::{ClientId, GatewayId, PublicKey, RelayId};
use dns_types::ResponseCode;
use dns_types::prelude::*;
use ip_packet::Ecn;
use rand::SeedableRng;
use rand::distributions::DistString;
use sha2::Digest;
use snownet::{NoTurnServers, Transmit};
use std::collections::BTreeSet;
use std::iter;
use std::net::SocketAddr;
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

    clients: BTreeMap<ClientId, Host<SimClient>>,
    gateways: BTreeMap<GatewayId, Host<SimGateway>>,
    relays: BTreeMap<RelayId, Host<SimRelay>>,

    buffer_pool: BufferPool<Vec<u8>>,

    drop_direct_client_traffic: bool,
    network: RoutingTable,
}

impl TunnelTest {
    // Initialize the system under test from our reference state.
    pub(crate) fn init_test(ref_state: &ReferenceState, flux_capacitor: FluxCapacitor) -> Self {
        // Construct client, gateway and relay from the initial state.
        let mut clients = ref_state
            .clients
            .iter()
            .map(|(client_id, ref_client)| {
                let client = ref_client.map(
                    |ref_client, _, _| {
                        ref_client.init(
                            ref_state.portal.upstream_do53().to_vec(),
                            ref_state.portal.upstream_doh().to_vec(),
                            ref_state.portal.search_domain(),
                            flux_capacitor.now(),
                            flux_capacitor.now(),
                        )
                    },
                    debug_span!("client", cid = %client_id),
                );
                (*client_id, client)
            })
            .collect::<BTreeMap<_, _>>();

        let mut gateways = ref_state
            .gateways
            .iter()
            .map(|(gid, gateway)| {
                let gateway = gateway.map(
                    |ref_gateway, _, _| {
                        ref_gateway.init(
                            *gid,
                            ref_state
                                .tcp_resources
                                .values()
                                .flatten()
                                .copied()
                                .collect(),
                            flux_capacitor.now(),
                            flux_capacitor.now(),
                        )
                    },
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
        for client in clients.values_mut() {
            client
                .exec_mut(|c| c.update_relays(iter::empty(), relays.iter(), flux_capacitor.now()));
        }
        for gateway in gateways.values_mut() {
            gateway
                .exec_mut(|g| g.update_relays(iter::empty(), relays.iter(), flux_capacitor.now()));
        }

        let upstream_do53_servers = ref_state
            .portal
            .upstream_do53()
            .iter()
            .map(|u| SocketAddr::new(u.ip, 53))
            .collect::<Vec<_>>();

        for gateway in gateways.values_mut() {
            let upstream_do53_servers = upstream_do53_servers.clone();

            gateway
                .exec_mut(|g| g.deploy_new_dns_servers(upstream_do53_servers, flux_capacitor.now()))
        }

        let mut this = Self {
            flux_capacitor,
            network: ref_state.network.clone(),
            drop_direct_client_traffic: ref_state.drop_direct_client_traffic,
            clients,
            gateways,
            relays,
            buffer_pool: BufferPool::new(1024, "test"),
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
        let utc_now = state.flux_capacitor.now();

        // Act: Apply the transition
        match transition {
            Transition::AddResource(resource) => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|c| {
                        // Flush DNS.
                        match &resource {
                            client::Resource::Dns(r) => {
                                c.dns_records.retain(|domain, _| {
                                    if is_subdomain(domain, &r.address) {
                                        return false;
                                    }

                                    true
                                });
                            }
                            client::Resource::Cidr(_) => {}
                            client::Resource::Internet(_) => {}
                        }

                        c.sut.add_resource(resource.clone(), now);
                    });
                }
            }
            Transition::ChangeCidrResourceAddress {
                resource,
                new_address,
            } => {
                let new_resource = client::Resource::Cidr(client::CidrResource {
                    address: new_address,
                    ..resource
                });

                for (client_id, client) in &mut state.clients {
                    if let Some(gateway) = ref_state
                        .portal
                        .gateway_for_resource(new_resource.id())
                        .and_then(|gid| state.gateways.get_mut(gid))
                    {
                        gateway
                            .exec_mut(|g| g.sut.remove_access(client_id, &new_resource.id(), now))
                    }
                    client.exec_mut(|c| c.sut.add_resource(new_resource.clone(), now));
                }
            }
            Transition::MoveResourceToNewSite { resource, new_site } => {
                let new_resource = resource.with_new_site(new_site);

                for client in state.clients.values_mut() {
                    client.exec_mut(|c| c.sut.add_resource(new_resource.clone(), now));
                }
            }
            Transition::RemoveResource(rid) => {
                for (client_id, client) in &mut state.clients {
                    client.exec_mut(|c| c.sut.remove_resource(rid, now));

                    if let Some(gateway) = ref_state
                        .portal
                        .gateway_for_resource(rid)
                        .and_then(|gid| state.gateways.get_mut(gid))
                    {
                        gateway.exec_mut(|g| g.sut.remove_access(client_id, &rid, now));
                    }
                }
            }
            Transition::SetInternetResourceState { client_id, active } => {
                state
                    .clients
                    .get_mut(&client_id)
                    .unwrap()
                    .exec_mut(|c| c.sut.set_internet_resource_state(active, now));
            }
            Transition::SendIcmpPacket {
                client_id,
                src,
                dst,
                seq,
                identifier,
                payload,
                ..
            } => {
                let dst = address_from_destination(&dst, &state, &src, client_id);

                let packet = ip_packet::make::icmp_request_packet(
                    src,
                    dst,
                    seq.0,
                    identifier.0,
                    &payload.to_be_bytes(),
                )
                .unwrap();

                let client = state.clients.get_mut(&client_id).unwrap();
                let transmit = client.exec_mut(|sim| sim.encapsulate(packet, now));

                buffered_transmits.push_from(transmit, client, now);
            }
            Transition::SendUdpPacket {
                client_id,
                src,
                dst,
                sport,
                dport,
                payload,
            } => {
                let dst = address_from_destination(&dst, &state, &src, client_id);

                let packet = ip_packet::make::udp_packet(
                    src,
                    dst,
                    sport.0,
                    dport.0,
                    payload.to_be_bytes().to_vec(),
                )
                .unwrap();

                let client = state.clients.get_mut(&client_id).unwrap();
                let transmit = client.exec_mut(|sim| sim.encapsulate(packet, now));

                buffered_transmits.push_from(transmit, client, now);
            }
            Transition::ConnectTcp {
                client_id,
                src,
                dst,
                sport,
                dport,
            } => {
                let dst = address_from_destination(&dst, &state, &src, client_id);

                state
                    .clients
                    .get_mut(&client_id)
                    .unwrap()
                    .exec_mut(|sim| sim.connect_tcp(src, dst, sport, dport));
            }
            Transition::SendDnsQueries(queries) => {
                for (
                    client_id,
                    DnsQuery {
                        domain,
                        r_type,
                        dns_server,
                        query_id,
                        transport,
                    },
                ) in queries
                {
                    let client = state.clients.get_mut(&client_id).unwrap();
                    let transmit = client.exec_mut(|sim| {
                        sim.send_dns_query_for(domain, r_type, query_id, dns_server, transport, now)
                    });

                    buffered_transmits.push_from(transmit, client, now);
                }
            }
            Transition::UpdateSystemDnsServers { servers } => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|c| c.sut.update_system_resolvers(servers.clone()));
                }
            }
            Transition::UpdateUpstreamDo53Servers(upstream_do53) => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|c| {
                        c.sut.update_interface_config(Interface {
                            ipv4: c.sut.tunnel_ip_config().unwrap().v4,
                            ipv6: c.sut.tunnel_ip_config().unwrap().v6,
                            upstream_dns: vec![],
                            upstream_do53: upstream_do53.clone(),
                            search_domain: ref_state.portal.search_domain(),
                            upstream_doh: ref_state.portal.upstream_doh().to_vec(),
                        })
                    });
                }

                let upstream_do53_servers = upstream_do53
                    .into_iter()
                    .map(|u| SocketAddr::new(u.ip, 53))
                    .collect::<Vec<_>>();

                for gateway in state.gateways.values_mut() {
                    let upstream_do53_servers = upstream_do53_servers.clone();

                    gateway.exec_mut(|g| g.deploy_new_dns_servers(upstream_do53_servers, now))
                }
            }
            Transition::UpdateUpstreamDoHServers(upstream_doh) => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|c| {
                        c.sut.update_interface_config(Interface {
                            ipv4: c.sut.tunnel_ip_config().unwrap().v4,
                            ipv6: c.sut.tunnel_ip_config().unwrap().v6,
                            upstream_dns: vec![],
                            upstream_do53: ref_state.portal.upstream_do53().to_vec(),
                            search_domain: ref_state.portal.search_domain(),
                            upstream_doh: upstream_doh.clone(),
                        })
                    });
                }
            }
            Transition::UpdateUpstreamSearchDomain(search_domain) => {
                for client in state.clients.values_mut() {
                    client.exec_mut(|c| {
                        c.sut.update_interface_config(Interface {
                            ipv4: c.sut.tunnel_ip_config().unwrap().v4,
                            ipv6: c.sut.tunnel_ip_config().unwrap().v6,
                            upstream_dns: vec![],
                            upstream_do53: ref_state.portal.upstream_do53().to_vec(),
                            upstream_doh: ref_state.portal.upstream_doh().to_vec(),
                            search_domain: search_domain.clone(),
                        })
                    });
                }
            }
            Transition::RoamClient {
                client_id,
                ip4,
                ip6,
            } => {
                let client = state.clients.get_mut(&client_id).unwrap();
                let ref_client = ref_state.clients.get(&client_id).unwrap();
                state.network.remove_host(client);
                client.update_interface(ip4, ip6);
                debug_assert!(state.network.add_host(client_id, client));

                client.exec_mut(|c| {
                    c.sut.reset(now, "roam");

                    // In prod, we reconnect to the portal and receive a new `init` message.
                    c.update_relays(iter::empty(), state.relays.iter(), now);
                    c.sut.set_resources(ref_client.inner().all_resources(), now);
                });
            }

            Transition::ReconnectPortal { client_id } => {
                let client = state.clients.get_mut(&client_id).unwrap();
                let ref_client = ref_state.clients.get(&client_id).unwrap();
                let ipv4 = client.inner().sut.tunnel_ip_config().unwrap().v4;
                let ipv6 = client.inner().sut.tunnel_ip_config().unwrap().v6;
                let all_resources = ref_client.inner().all_resources();

                // Simulate receiving `init`.
                client.exec_mut(|c| {
                    c.sut.update_interface_config(Interface {
                        ipv4,
                        ipv6,
                        upstream_dns: Vec::new(),
                        upstream_do53: ref_state.portal.upstream_do53().to_vec(),
                        upstream_doh: ref_state.portal.upstream_doh().to_vec(),
                        search_domain: ref_state.portal.search_domain(),
                    });
                    c.update_relays(iter::empty(), state.relays.iter(), now);
                    c.sut.set_resources(all_resources, now);
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

                while state.flux_capacitor.now::<Instant>() <= cut_off {
                    state.flux_capacitor.tick(Duration::from_secs(5));
                    state.advance(ref_state, &mut buffered_transmits);
                }
            }
            Transition::PartitionRelaysFromPortal => {
                // 1. Disconnect all relays.
                for client in state.clients.values_mut() {
                    client.exec_mut(|c| {
                        c.update_relays(state.relays.keys().copied(), iter::empty(), now)
                    });
                }
                for gateway in state.gateways.values_mut() {
                    gateway.exec_mut(|g| {
                        g.update_relays(state.relays.keys().copied(), iter::empty(), now)
                    });
                }

                // 2. Advance state to ensure this is reflected.
                state.advance(ref_state, &mut buffered_transmits);

                let now = state.flux_capacitor.now();

                // 3. Reconnect all relays.
                for client in state.clients.values_mut() {
                    client.exec_mut(|c| c.update_relays(iter::empty(), state.relays.iter(), now));
                }
                for gateway in state.gateways.values_mut() {
                    gateway.exec_mut(|g| g.update_relays(iter::empty(), state.relays.iter(), now));
                }
            }
            Transition::RebootRelaysWhilePartitioned(new_relays) => {
                // If we are partitioned from the portal, we will only learn which relays to use, potentially replacing existing ones.
                let to_remove = Vec::default();

                state.deploy_new_relays(new_relays, now, to_remove);
            }
            Transition::DeauthorizeWhileGatewayIsPartitioned(rid) => {
                for (client_id, client) in &mut state.clients {
                    let ref_client = ref_state.clients.get(client_id).unwrap();
                    let new_authorized_resources = {
                        let mut all_resources =
                            BTreeSet::from_iter(ref_client.inner().all_resource_ids());
                        all_resources.remove(&rid);

                        all_resources
                    };

                    client.exec_mut(|c| c.sut.remove_resource(rid, now));

                    if let Some(gid) = ref_state.portal.gateway_for_resource(rid)
                        && let Some(g) = state.gateways.get_mut(gid)
                    {
                        g.exec_mut(|g| {
                            // This is partly an `init` message.
                            // The relays don't change so we don't bother setting them.
                            g.sut.retain_authorizations(BTreeMap::from([(
                                *client_id,
                                new_authorized_resources,
                            )]))
                        });
                    } else {
                        tracing::error!(%rid, "No gateway for resource");
                    }
                }
            }
            Transition::RestartClient { client_id, key } => {
                let client = state.clients.get_mut(&client_id).unwrap();
                let ref_client = ref_state.clients.get(&client_id).unwrap();

                // Copy current state that will be preserved.
                let ipv4 = client.inner().sut.tunnel_ip_config().unwrap().v4;
                let ipv6 = client.inner().sut.tunnel_ip_config().unwrap().v6;
                let system_dns = ref_client.inner().system_dns_resolvers();
                let all_resources = ref_client.inner().all_resources();
                let internet_resource_state = ref_client.inner().internet_resource_active;

                client.exec_mut(|c| {
                    c.restart(key, internet_resource_state, now, utc_now);

                    // Apply to new instance.
                    c.sut.update_interface_config(Interface {
                        ipv4,
                        ipv6,
                        upstream_dns: Vec::new(),
                        upstream_do53: ref_state.portal.upstream_do53().to_vec(),
                        upstream_doh: ref_state.portal.upstream_doh().to_vec(),
                        search_domain: ref_state.portal.search_domain(),
                    });
                    c.sut.update_system_resolvers(system_dns);
                    c.sut.set_resources(all_resources, now);

                    c.update_relays(iter::empty(), state.relays.iter(), now);
                })
            }
            Transition::UpdateDnsRecords { .. } => {}
        };
        state.advance(ref_state, &mut buffered_transmits);

        state
    }

    // Assert against the reference state machine.
    pub(crate) fn check_invariants(state: &Self, ref_state: &ReferenceState) {
        // Aggregate all clients for system-wide assertions
        let all_ref_clients = ref_state
            .clients
            .iter()
            .map(|(id, host)| (*id, host.inner()))
            .collect();
        let all_sim_clients = state
            .clients
            .iter()
            .map(|(id, host)| (*id, host.inner()))
            .collect();
        let sim_gateways = state
            .gateways
            .iter()
            .map(|(id, g)| (*id, g.inner()))
            .collect();

        // System-wide packet assertions
        assert_icmp_packets_properties(
            &all_ref_clients,
            &all_sim_clients,
            &sim_gateways,
            &ref_state.global_dns_records,
        );
        assert_udp_packets_properties(
            &all_ref_clients,
            &all_sim_clients,
            &sim_gateways,
            &ref_state.global_dns_records,
        );

        // Per-client assertions for client-specific state
        for (client_id, ref_client_host) in &ref_state.clients {
            let ref_client = ref_client_host.inner();
            let sut_client = state.clients.get(client_id).unwrap().inner();

            assert_tcp_connections(ref_client, sut_client);
            assert_udp_dns_packets_properties(ref_client, sut_client);
            assert_tcp_dns(ref_client, sut_client);
            assert_dns_servers_are_valid(ref_client, sut_client, &ref_state.portal);
            assert_search_domain_is_valid(&ref_state.portal, sut_client);
            assert_routes_are_valid(ref_client, sut_client);
            assert_resource_status(ref_client, sut_client);
        }
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
    /// At most, we will spend 20s of "simulation time" advancing the state.
    fn advance(&mut self, ref_state: &ReferenceState, buffered_transmits: &mut BufferedTransmits) {
        let cut_off = self.flux_capacitor.now::<Instant>() + Duration::from_secs(20);

        'outer: while self.flux_capacitor.now::<Instant>() < cut_off {
            let now = self.flux_capacitor.now();

            // `handle_timeout` needs to be called at the very top to advance state after we have made other modifications.
            self.handle_timeout(
                &ref_state.global_dns_records,
                &ref_state.icmp_error_hosts,
                buffered_transmits,
                now,
            );

            if let Some((next, reason)) = self.poll_timeout()
                && next < now
            {
                tracing::error!(?next, ?now, %reason, "State machine requested time in the past");
            }

            for (id, gateway) in self.gateways.iter_mut() {
                let Some(event) = gateway.exec_mut(|g| g.sut.poll_event()) else {
                    continue;
                };

                on_gateway_event(
                    *id,
                    event,
                    &mut self.clients,
                    gateway,
                    &ref_state.global_dns_records,
                    now,
                );
                continue 'outer;
            }

            // Collect client events first to avoid borrow checker issues
            let client_event = self.clients.iter_mut().find_map(|(client_id, client)| {
                client
                    .exec_mut(|c| c.sut.poll_event())
                    .map(|event| (*client_id, event))
            });

            if let Some((client_id, event)) = client_event {
                match self.on_client_event(client_id, event, &ref_state.portal) {
                    Ok(()) => {}
                    Err(AuthorizeFlowError::Client(e)) => {
                        tracing::debug!("Failed to handle ClientEvent: {e}");

                        // Simulate WebSocket reconnect ...
                        let client = self.clients.get_mut(&client_id).unwrap();
                        client.exec_mut(|c| {
                            c.update_relays(iter::empty(), self.relays.iter(), now);
                        });
                    }
                    Err(AuthorizeFlowError::Gateway(e)) => {
                        tracing::debug!("Failed to handle GatewayEvent: {e}");

                        // Simulate WebSocket reconnect ...
                        for gateway in self.gateways.values_mut() {
                            gateway.exec_mut(|g| {
                                g.update_relays(iter::empty(), self.relays.iter(), now)
                            })
                        }
                    }
                }
                continue;
            }

            // Collect DNS query first to avoid borrow checker issues
            let dns_query_result = self.clients.iter_mut().find_map(|(client_id, client)| {
                client
                    .exec_mut(|c| c.sut.poll_dns_queries())
                    .map(|query| (*client_id, query))
            });

            if let Some((client_id, query)) = dns_query_result {
                let server = query.server;
                let transport = query.transport;
                let query_message = query.message.clone();
                let local = query.local;
                let remote = query.remote;

                // DoH queries are always sent with an ID of 0, simulate that in the tests.
                let message = matches!(server, dns::Upstream::DoH { .. })
                    .then_some(query_message.clone().with_id(0))
                    .unwrap_or(query_message.clone());

                let response =
                    self.on_recursive_dns_query(&message, &ref_state.global_dns_records, now);
                let client = self.clients.get_mut(&client_id).unwrap();
                client.exec_mut(|c| {
                    c.sut.handle_dns_response(
                        dns::RecursiveResponse {
                            server,
                            query: query_message,
                            message: Ok(response), // TODO: Vary this?
                            transport,
                            local,
                            remote,
                        },
                        now,
                    )
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
                                payload: self.buffer_pool.pull_initialised(&payload),
                                ecn: Ecn::NonEct,
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
                    firezone_relay::Command::CreateChannelBinding { .. } => {}
                    firezone_relay::Command::DeleteChannelBinding { .. } => {}
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

            let mut found_transmit = false;
            for client in self.clients.values_mut() {
                if let Some(transmit) = client.exec_mut(|sim| sim.sut.poll_transmit()) {
                    buffered_transmits.push_from(transmit, client, now);
                    found_transmit = true;
                    break;
                }
            }
            if found_transmit {
                continue;
            }

            for client in self.clients.values_mut() {
                client.exec_mut(|sim| {
                    while let Some(packet) = sim.sut.poll_packets() {
                        sim.on_received_packet(packet)
                    }
                });
            }

            if let Some(transmit) = buffered_transmits.pop(now) {
                self.dispatch_transmit(transmit, now);
                continue;
            }

            if !buffered_transmits.is_empty() {
                self.flux_capacitor.small_tick(); // Small tick to get to the next transmit.
                continue;
            }

            let Some((time_to_next_action, _)) = self.poll_timeout() else {
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
        icmp_error_hosts: &IcmpErrorHosts,
        buffered_transmits: &mut BufferedTransmits,
        now: Instant,
    ) {
        // Handle the TCP DNS client, i.e. simulate applications making TCP DNS queries.
        for client in self.clients.values_mut() {
            client.exec_mut(|c| {
                while let Some(result) = c.tcp_dns_client.poll_query_result() {
                    match result.result {
                        Ok(message) => {
                            let upstream = c
                                .dns_mapping()
                                .upstream_by_sentinel(result.server.ip())
                                .unwrap();

                            c.received_tcp_dns_responses
                                .insert((upstream, result.query.id()));
                            c.handle_dns_response(&message)
                        }
                        Err(e) => {
                            tracing::error!("TCP DNS query failed: {e:#}");
                        }
                    }
                }
            });
        }
        for client in self.clients.values_mut() {
            while let Some(transmit) = client.exec_mut(|c| {
                let packet = c.poll_outbound()?;
                c.encapsulate(packet, now)
            }) {
                buffered_transmits.push_from(transmit, client, now)
            }
            client.exec_mut(|c| c.handle_timeout(now));

            // Handle the client's `Transmit`s.
            while let Some(transmit) = client.poll_inbox(now) {
                client.exec_mut(|c| c.receive(transmit, now))
            }
        }

        // Handle all gateway `Transmit`s and timeouts.
        for (_, gateway) in self.gateways.iter_mut() {
            for transmit in gateway.exec_mut(|g| g.advance_resources(global_dns_records, now)) {
                buffered_transmits.push_from(transmit, gateway, now);
            }

            while let Some(transmit) = gateway.poll_inbox(now) {
                let Some(reply) = gateway.exec_mut(|g| {
                    g.receive(transmit, icmp_error_hosts, now, self.flux_capacitor.now())
                }) else {
                    continue;
                };

                buffered_transmits.push_from(reply, gateway, now);
            }

            gateway.exec_mut(|g| {
                if g.sut.poll_timeout().is_some_and(|(t, _)| t <= now) {
                    g.sut.handle_timeout(now, self.flux_capacitor.now())
                }
            });
        }

        // Handle all relay `Transmit`s and timeouts.
        for (_, relay) in self.relays.iter_mut() {
            while let Some(transmit) = relay.poll_inbox(now) {
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

    fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            .chain(self.clients.values_mut().flat_map(|c| c.poll_timeout()))
            .chain(self.gateways.values_mut().flat_map(|g| g.poll_timeout()))
            .chain(self.relays.values_mut().flat_map(|r| r.poll_timeout()))
            .min_by_key(|(instant, _)| *instant)
    }

    /// Dispatches a [`Transmit`] to the correct host.
    ///
    /// This function is basically the "network layer" of our tests.
    /// It takes a [`Transmit`] and checks, which host accepts it, i.e. has configured the correct IP address.
    ///
    /// Currently, the network topology of our tests are a single subnet without NAT.
    fn dispatch_transmit(&mut self, transmit: Transmit, at: Instant) {
        let src = transmit
            .src
            .expect("`src` should always be set in these tests");
        let dst = transmit.dst;

        let Some(host) = self.network.host_by_ip(dst.ip()) else {
            tracing::error!("Unhandled packet: {src} -> {dst}");
            return;
        };

        match host {
            HostId::Client(client_id) => {
                if self.drop_direct_client_traffic
                    && self.gateways.values().any(|g| g.is_sender(src.ip()))
                {
                    tracing::trace!(%src, %dst, "Dropping direct traffic");

                    return;
                }

                self.clients
                    .get_mut(&client_id)
                    .unwrap()
                    .receive(transmit, at);
            }
            HostId::Gateway(id) => {
                if self.drop_direct_client_traffic
                    && self.clients.values().any(|c| c.is_sender(src.ip()))
                {
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

    fn on_client_event(
        &mut self,
        src: ClientId,
        event: ClientEvent,
        portal: &StubPortal,
    ) -> Result<(), AuthorizeFlowError> {
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
                });

                Ok(())
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
                });

                Ok(())
            }
            ClientEvent::ConnectionIntent {
                resource: resource_id,
                preferred_gateways,
            } => {
                let (gateway_id, site_id) =
                    portal.handle_connection_intent(resource_id, preferred_gateways);
                let gateway = self.gateways.get_mut(&gateway_id).expect("unknown gateway");
                let resource = portal.map_client_resource_to_gateway_resource(resource_id);

                let client = self.clients.get_mut(&src).unwrap();
                let client_key = client.inner().sut.public_key();
                let gateway_key = gateway.inner().sut.public_key();
                let (preshared_key, client_ice, gateway_ice) =
                    make_preshared_key_and_ice(client_key, gateway_key);

                gateway
                    .exec_mut(|g| {
                        g.sut.authorize_flow(
                            Client {
                                id: src,
                                public_key: client_key.into(),
                                preshared_key: preshared_key.clone(),
                                ipv4: client.inner().sut.tunnel_ip_config().unwrap().v4,
                                ipv6: client.inner().sut.tunnel_ip_config().unwrap().v6,
                                device_os_name: None,
                                device_serial: None,
                                device_uuid: None,
                                identifier_for_vendor: None,
                                firebase_installation_id: None,
                                version: None,
                                device_os_version: None,
                            },
                            Subject {
                                actor_name: None,
                                actor_email: None,
                                auth_provider_id: None,
                                actor_id: None,
                            },
                            client_ice.clone(),
                            gateway_ice.clone(),
                            None,
                            resource,
                            now,
                        )
                    })
                    .map_err(AuthorizeFlowError::Gateway)?;

                let client = self.clients.get_mut(&src).unwrap();
                client
                    .exec_mut(|c| {
                        c.sut.handle_flow_created(
                            resource_id,
                            gateway_id,
                            gateway_key,
                            gateway.inner().sut.tunnel_ip_config().unwrap(),
                            site_id,
                            preshared_key,
                            client_ice,
                            gateway_ice,
                            now,
                        )
                    })
                    .unwrap_or_else(|e| {
                        tracing::error!("{e:#}");

                        Ok(())
                    })
                    .map_err(AuthorizeFlowError::Client)?;

                Ok(())
            }
            ClientEvent::ResourcesChanged { resources } => {
                let client = self.clients.get_mut(&src).unwrap();
                client.exec_mut(|c| {
                    c.resource_status = resources
                        .into_iter()
                        .map(|r| (r.id(), r.status()))
                        .collect();
                });

                Ok(())
            }
            ClientEvent::TunInterfaceUpdated(config) => {
                let client = self.clients.get_mut(&src).unwrap();
                if client.inner().dns_mapping() == &config.dns_by_sentinel
                    && client.inner().routes == config.routes
                    && client.inner().search_domain == config.search_domain
                {
                    tracing::error!(
                        "Emitted `TunInterfaceUpdated` without changing DNS servers, routes or search domain"
                    );
                }

                client.exec_mut(|c| {
                    c.set_new_dns_servers(config.dns_by_sentinel);
                    c.routes = config.routes;
                    c.search_domain = config.search_domain;
                    c.tcp_dns_client
                        .set_source_interface(config.ip.v4, config.ip.v6);
                });

                Ok(())
            }
            ClientEvent::DnsRecordsChanged { records } => {
                let client = self.clients.get_mut(&src).unwrap();
                client.exec_mut(|c| c.dns_resource_record_cache = records);

                Ok(())
            }
            ClientEvent::Error(_) => unreachable!("ClientState never emits `TunnelError`"),
        }
    }

    fn on_recursive_dns_query(
        &self,
        query: &dns_types::Query,
        global_dns_records: &DnsRecords,
        now: Instant,
    ) -> dns_types::Response {
        const TTL: u32 = 1; // We deliberately chose a short TTL so we don't have to model the DNS cache in these tests.

        let qtype = query.qtype();
        let domain = query.domain();

        let response = dns_types::ResponseBuilder::for_query(query, ResponseCode::NOERROR)
            .with_records(
                global_dns_records
                    .domain_records_iter(&domain, now)
                    .filter(|record| qtype == record.rtype())
                    .map(|rdata| (domain.clone(), TTL, rdata)),
            )
            .build();

        tracing::debug!(%domain, %qtype, "Responding to DNS query");

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

        for client in self.clients.values_mut() {
            client.exec_mut(|c| {
                c.update_relays(to_remove.iter().copied(), online.iter(), now);
            });
        }
        for gateway in self.gateways.values_mut() {
            gateway.exec_mut(|g| g.update_relays(to_remove.iter().copied(), online.iter(), now));
        }
        self.relays = online; // Override all relays.
    }
}

enum AuthorizeFlowError {
    Client(NoTurnServers),
    Gateway(NoTurnServers),
}

fn address_from_destination(
    destination: &Destination,
    state: &TunnelTest,
    src: &IpAddr,
    client_id: ClientId,
) -> IpAddr {
    match destination {
        Destination::DomainName { resolved_ip, name } => {
            let available_ips = state
                .clients
                .get(&client_id)
                .unwrap()
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
    let secret_key =
        SecretKey::init_with(|| Key(hkdf("SECRET_KEY_DOMAIN_SEP", client_key, gateway_key)));
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
    clients: &mut BTreeMap<ClientId, Host<SimClient>>,
    gateway: &mut Host<SimGateway>,
    global_dns_records: &DnsRecords,
    now: Instant,
) {
    match event {
        GatewayEvent::AddedIceCandidates {
            conn_id,
            candidates,
        } => {
            let client = clients.get_mut(&conn_id).unwrap();
            client.exec_mut(|c| {
                for candidate in candidates {
                    c.sut.add_ice_candidate(src, candidate, now)
                }
            })
        }
        GatewayEvent::RemovedIceCandidates {
            conn_id,
            candidates,
        } => {
            let client = clients.get_mut(&conn_id).unwrap();
            client.exec_mut(|c| {
                for candidate in candidates {
                    c.sut.remove_ice_candidate(src, candidate, now)
                }
            })
        }
        GatewayEvent::ResolveDns(r) => {
            let resolved_ips = global_dns_records
                .domain_ips_iter(r.domain(), now)
                .collect();

            gateway.exec_mut(|g| {
                g.dns_query_timestamps
                    .entry(r.domain().clone())
                    .or_default()
                    .push(now);
                g.sut
                    .handle_domain_resolved(r, Ok(resolved_ips), now)
                    .unwrap()
            })
        }
        GatewayEvent::Error(_) => unreachable!("GatewayState never emits `TunnelError`"),
    }
}
