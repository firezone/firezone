use super::buffered_transmits::BufferedTransmits;
use super::dns_records::DnsRecords;
use super::icmp_error_hosts::IcmpErrorHosts;
use super::reference::ReferenceState;
use super::sim_client::SimClient;
use super::sim_gateway::SimGateway;
use super::sim_net::{Host, HostId, RoutingTable};
use super::sim_relay::SimRelay;
use super::transition::{Destination, DnsQuery};
use crate::assertions::*;
use crate::flux_capacitor::FluxCapacitor;
use crate::probe::{DnsNatObservation, ProbeId, ProbeObservation, Remote, UdpFlowId};
use crate::resource as client;
use crate::transition::Transition;
use bufferpool::BufferPool;
use connlib_model::{ClientId, ClientOrGatewayId, GatewayId, PublicKey, RelayId};
use dns_types::ResponseCode;
use dns_types::prelude::*;
use ip_packet::Ecn;
use itertools::Itertools;
use rand::SeedableRng;
use rand::distr::SampleString;
use sha2::Digest;
use snownet::{NoTurnServers, Transmit};
use std::iter;
use std::net::SocketAddr;
use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
    time::{Duration, Instant},
};
use tracing::debug_span;
use tunnel_proto::dns::is_subdomain;
use tunnel_proto::messages::gateway::Client;
use tunnel_proto::messages::{IceCredentials, Key, SecretKey};
use tunnel_proto::{ClientEvent, GatewayEvent, dns, messages::Interface};

/// The actual system-under-test.
///
/// The fuzzer manipulates this using [`Transition`]s and we assert it against [`ReferenceState`].
pub struct TunnelTest {
    flux_capacitor: FluxCapacitor,

    clients: BTreeMap<ClientId, Host<SimClient>>,
    gateways: BTreeMap<GatewayId, Host<SimGateway>>,
    relays: BTreeMap<RelayId, Host<SimRelay>>,

    buffer_pool: BufferPool<Vec<u8>>,

    /// While set and `now` is before the deadline, this client's messages to the
    /// portal are dropped, simulating a client that has not yet reconnected to
    /// the portal after a roam.
    client_portal_offline_until: Option<(ClientId, Instant)>,
    network: RoutingTable,
    udp_flows: BTreeMap<UdpFlowId, ResolvedUdpFlow>,
    dns_nat_observations: Vec<DnsNatObservation>,
}

#[derive(Clone, Copy)]
struct ResolvedUdpFlow {
    client_id: ClientId,
    src: IpAddr,
    dst: IpAddr,
    sport: crate::transition::SPort,
    dport: crate::transition::DPort,
}

impl TunnelTest {
    // Initialize the system under test from our reference state.
    pub fn init_test(ref_state: &ReferenceState, flux_capacitor: FluxCapacitor) -> Self {
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

            gateway.exec_mut(|g| {
                g.deploy_new_dns_servers(upstream_do53_servers, &ref_state.icmp_error_hosts)
            })
        }

        let mut this = Self {
            flux_capacitor,
            network: ref_state.network.clone(),
            client_portal_offline_until: None,
            clients,
            gateways,
            relays,
            buffer_pool: BufferPool::new(1024, "test"),
            udp_flows: Default::default(),
            dns_nat_observations: Default::default(),
        };

        let mut buffered_transmits = BufferedTransmits::default();
        this.advance(ref_state, &mut buffered_transmits); // Perform initial setup before we apply the first transition.

        this
    }

    /// Apply a generated state transition to our system under test.
    pub fn apply(mut state: Self, ref_state: &ReferenceState, transition: Transition) -> Self {
        let mut buffered_transmits = BufferedTransmits::default();
        let now = state.flux_capacitor.now();
        let utc_now = state.flux_capacitor.now();
        let mut application_probe = None;

        state
            .udp_flows
            .extract_if(.., |flow_id, _| {
                !ref_state.udp_flows.contains_key(flow_id)
            })
            .for_each(drop);

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
                            client::Resource::Cidr(_)
                            | client::Resource::Internet(_)
                            | client::Resource::StaticDevicePool(_)
                            | client::Resource::DynamicDevicePool(_) => {}
                        }

                        c.sut.add_resource(resource.clone().into_description(), now);
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
                        gateway.exec_mut(|g| {
                            g.remove_access(client_id, &new_resource.id(), now)
                        });
                    }
                    client.exec_mut(|c| {
                        c.sut
                            .add_resource(new_resource.clone().into_description(), now)
                    });
                }
            }
            Transition::MoveResourceToNewSite { resource, new_site } => {
                let resource_id = resource.id();
                let new_resource = resource.with_new_site(new_site);

                for (client_id, client) in &mut state.clients {
                    for gateway in state.gateways.values_mut() {
                        gateway.exec_mut(|gateway| {
                            gateway.record_resource_disabled(*client_id, resource_id)
                        });
                    }
                    client.exec_mut(|c| {
                        c.sut
                            .add_resource(new_resource.clone().into_description(), now)
                    });
                }
            }
            Transition::ChangeFiltersOfResource {
                resource,
                new_filters,
            } => {
                let resource_id = resource.id();
                let new_resource = resource.with_new_filters(new_filters);

                for (client_id, client) in &mut state.clients {
                    for gateway in state.gateways.values_mut() {
                        gateway.exec_mut(|gateway| {
                            gateway.record_resource_disabled(*client_id, resource_id)
                        });
                    }
                    client.exec_mut(|c| {
                        c.sut
                            .add_resource(new_resource.clone().into_description(), now)
                    });
                }
            }
            Transition::ChangeResourceType {
                old_resource,
                new_resource,
            } => {
                debug_assert_eq!(old_resource.id(), new_resource.id());

                for (client_id, client) in &mut state.clients {
                    for gateway in state.gateways.values_mut() {
                        gateway.exec_mut(|gateway| {
                            gateway.remove_access(client_id, &old_resource.id(), now)
                        });
                    }

                    client.exec_mut(|client| {
                        if let client::Resource::Dns(resource) = &new_resource {
                            client
                                .dns_records
                                .retain(|domain, _| !is_subdomain(domain, &resource.address));
                        }

                        client
                            .sut
                            .add_resource(new_resource.clone().into_description(), now);
                    });
                }
            }
            Transition::UpdateStaticDevicePool {
                pool_id,
                new_devices,
            } => {
                let Some(existing) =
                    ref_state
                        .portal
                        .all_resources()
                        .into_iter()
                        .find_map(|r| match r {
                            client::Resource::StaticDevicePool(p) if p.id == pool_id => Some(p),
                            client::Resource::Dns(_) => None,
                            client::Resource::Cidr(_) => None,
                            client::Resource::Internet(_) => None,
                            client::Resource::DynamicDevicePool(_) => None,
                            client::Resource::StaticDevicePool(_) => None,
                        })
                else {
                    panic!("UpdateStaticDevicePool for unknown pool {pool_id}");
                };

                let resource =
                    client::Resource::StaticDevicePool(client::StaticDevicePoolResource {
                        devices: new_devices,
                        ..existing
                    });

                for client in state.clients.values_mut() {
                    client
                        .exec_mut(|c| c.sut.add_resource(resource.clone().into_description(), now));
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
                        gateway.exec_mut(|g| g.remove_access(client_id, &rid, now));
                    }
                }
            }
            Transition::SetInternetResourceState { client_id, active } => {
                if !active
                    && let Some(resource) = ref_state
                        .clients
                        .get(&client_id)
                        .unwrap()
                        .inner()
                        .internet_resource()
                {
                    for gateway in state.gateways.values_mut() {
                        gateway.exec_mut(|gateway| {
                            gateway.record_resource_disabled(client_id, resource)
                        });
                    }
                }

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
                probe_id,
            } => {
                let dst = address_from_destination(&dst, &state, &src, client_id);

                let packet = ip_packet::make::icmp_request_packet(
                    src,
                    dst,
                    seq.0,
                    identifier.0,
                    &probe_id.to_be_bytes(),
                )
                .unwrap();

                let client = state.clients.get_mut(&client_id).unwrap();
                let transmit = client.exec_mut(|sim| sim.encapsulate_probe(probe_id, packet, now));
                application_probe = Some((probe_id, None));

                buffered_transmits.push_from(transmit, client, now);
            }
            Transition::SendUdpPacket {
                flow_id,
                client_id,
                src,
                dst,
                sport,
                dport,
                probe_id,
            } => {
                let dst = address_from_destination(&dst, &state, &src, client_id);
                let flow = ResolvedUdpFlow {
                    client_id,
                    src,
                    dst,
                    sport,
                    dport,
                };
                let previous = state.udp_flows.insert(flow_id, flow);
                assert!(previous.is_none(), "UDP flow IDs must be unique");
                application_probe = Some((probe_id, Some(flow_id)));

                state.send_udp_probe(flow, probe_id, now, &mut buffered_transmits);
            }
            Transition::SendUdpPacketOnFlow { flow_id, probe_id } => {
                let flow = *state
                    .udp_flows
                    .get(&flow_id)
                    .expect("reused UDP flow must exist");
                application_probe = Some((probe_id, Some(flow_id)));

                state.send_udp_probe(flow, probe_id, now, &mut buffered_transmits);
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
            Transition::SendDnsQuery {
                client_id,
                query:
                    DnsQuery {
                        domain,
                        r_type,
                        dns_server,
                        query_id,
                        transport,
                    },
            } => {
                let client = state.clients.get_mut(&client_id).unwrap();
                let transmit = client.exec_mut(|sim| {
                    sim.send_dns_query_for(domain, r_type, query_id, dns_server, transport, now)
                });

                buffered_transmits.push_from(transmit, client, now);
            }
            Transition::SendDnsResourcePtrQuery {
                client_id,
                record_domain,
                family,
                address_index,
                query_id,
                dns_server,
                transport,
            } => {
                let client = state.clients.get_mut(&client_id).unwrap();
                let transmit = client.exec_mut(|sim| {
                    sim.send_dns_resource_ptr_query_for(
                        record_domain,
                        family,
                        address_index,
                        query_id,
                        dns_server,
                        transport,
                        now,
                    )
                });

                buffered_transmits.push_from(transmit, client, now);
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

                    gateway.exec_mut(|g| {
                        g.deploy_new_dns_servers(upstream_do53_servers, &ref_state.icmp_error_hosts)
                    })
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
                nat_ip4,
                dead_window,
                portal_window,
            } => {
                // A roam happens in three phases that we simulate one after
                // another.

                // 1. Dead-socket window: the old link is gone but the new one is
                //    not up yet. Unregister the client from the network so all
                //    traffic to it is dropped (as `HostId::Stale`) and advance
                //    simulated time.
                let client = state.clients.get_mut(&client_id).unwrap();
                state.network.remove_host(client);
                client.set_offline();

                let dead_until = now + dead_window;
                state.advance_to(ref_state, &mut buffered_transmits, dead_until);
                state.flux_capacitor.skip_to(dead_until);

                // 2. The new link comes up: assign the new IPs, re-register the
                //    client and reset the path-agent so it re-gathers candidates.
                //    The sockets now pass traffic, but the client has not
                //    reconnected to the portal yet, so any portal-bound message is
                //    dropped until the portal window elapses.
                let now = state.flux_capacitor.now::<Instant>();
                let client = state.clients.get_mut(&client_id).unwrap();
                client.update_interface(ip4, ip6);
                client.migrate_nat(nat_ip4);
                let added = state.network.add_host(client_id, client);
                debug_assert!(added);
                client.exec_mut(|c| {
                    c.sut.reset(now, "roam");
                    c.sut.set_portal_connected(false);
                });

                let portal_until = now + portal_window;
                state.client_portal_offline_until = Some((client_id, portal_until));
                state.advance_to(ref_state, &mut buffered_transmits, portal_until);
                state.flux_capacitor.skip_to(portal_until);
                state.client_portal_offline_until = None;

                // 3. Reconnect to the portal: in prod, we reconnect and receive a
                //    new `init` message.
                let now = state.flux_capacitor.now::<Instant>();
                let ref_client = ref_state.clients.get(&client_id).unwrap();
                let client = state.clients.get_mut(&client_id).unwrap();
                client.exec_mut(|c| {
                    c.sut.set_portal_connected(true);
                    c.update_relays(iter::empty(), state.relays.iter(), now);
                    c.sut
                        .set_resources(ref_client.inner().resource_descriptions(), now);
                });
            }

            Transition::ReconnectPortal { client_id } => {
                let client = state.clients.get_mut(&client_id).unwrap();
                let ref_client = ref_state.clients.get(&client_id).unwrap();
                let ipv4 = client.inner().sut.tunnel_ip_config().unwrap().v4;
                let ipv6 = client.inner().sut.tunnel_ip_config().unwrap().v6;
                let all_resources = ref_client.inner().resource_descriptions();

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
                state.deploy_new_relays(new_relays, now);
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
                state.reboot_relays_while_partitioned(new_relays, now);
            }
            Transition::DeauthorizeWhileGatewayIsPartitioned(rid) => {
                let authorizations = state
                    .clients
                    .iter_mut()
                    .map(|(client_id, client)| {
                        let ref_client = ref_state.clients.get(client_id).unwrap();
                        let resources = ref_client
                            .inner()
                            .all_resource_ids()
                            .into_iter()
                            .filter(|resource| *resource != rid)
                            .collect();

                        client.exec_mut(|c| c.sut.remove_resource(rid, now));

                        (*client_id, resources)
                    })
                    .collect();

                if let Some(gid) = ref_state.portal.gateway_for_resource(rid)
                    && let Some(gateway) = state.gateways.get_mut(gid)
                {
                    gateway.exec_mut(|gateway| gateway.retain_authorizations(authorizations));
                } else {
                    tracing::error!(%rid, "No gateway for resource");
                }
            }
            Transition::RestartClient { client_id, key } => {
                // Cleanly shut down the client.
                let client = state.clients.get_mut(&client_id).unwrap();
                client.exec_mut(|c| c.sut.shut_down(now));
                // Drain transmits so they don't get lost as part of the restart.
                state.drain_transmits(&mut buffered_transmits, now);
                for gateway in state.gateways.values_mut() {
                    gateway.exec_mut(|gateway| gateway.record_client_restart(client_id));
                }

                let client = state.clients.get_mut(&client_id).unwrap();
                let ref_client = ref_state.clients.get(&client_id).unwrap();

                // Copy current state that will be preserved.
                let ipv4 = client.inner().sut.tunnel_ip_config().unwrap().v4;
                let ipv6 = client.inner().sut.tunnel_ip_config().unwrap().v6;
                let system_dns = ref_client.inner().system_dns_resolvers();
                let all_resources = ref_client.inner().resource_descriptions();
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
                });
            }
            Transition::UpdateDnsRecords { .. } => {}
        };

        state.advance(ref_state, &mut buffered_transmits);

        if let Some((probe_id, udp_flow)) = application_probe {
            state.record_dns_nat_observation(ref_state, probe_id, udp_flow);
        }

        state
    }

    // Assert against the reference state machine.
    pub fn check_invariants(state: &Self, ref_state: &ReferenceState) {
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
        assert_probes(
            &ref_state.expected_probes,
            &all_ref_clients,
            &all_sim_clients,
            &sim_gateways,
            &ref_state.icmp_error_hosts,
        );
        assert_dns_nat(&state.dns_nat_observations, &sim_gateways);

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
            assert_resource_list(ref_client, sut_client);
        }
    }

    pub fn clear_packets(state: &mut TunnelTest) {
        for client in state.clients.values_mut() {
            client.exec_mut(|c| c.clear_packets());
        }
        for gateway in state.gateways.values_mut() {
            gateway.exec_mut(|g| g.clear_packets());
        }
    }

    pub fn clear_probe_observations(state: &mut TunnelTest) {
        for client in state.clients.values_mut() {
            client.exec_mut(|c| c.clear_probe_observations());
        }
        for gateway in state.gateways.values_mut() {
            gateway.exec_mut(|g| g.clear_probe_observations());
        }
    }

    fn send_udp_probe(
        &mut self,
        flow: ResolvedUdpFlow,
        probe_id: ProbeId,
        now: Instant,
        buffered_transmits: &mut BufferedTransmits,
    ) {
        let packet = ip_packet::make::udp_packet(
            flow.src,
            flow.dst,
            flow.sport.0,
            flow.dport.0,
            &probe_id.to_be_bytes(),
        )
        .unwrap();

        let client = self.clients.get_mut(&flow.client_id).unwrap();
        let transmit = client.exec_mut(|sim| sim.encapsulate_probe(probe_id, packet, now));

        buffered_transmits.push_from(transmit, client, now);
    }

    fn record_dns_nat_observation(
        &mut self,
        ref_state: &ReferenceState,
        probe_id: ProbeId,
        udp_flow: Option<UdpFlowId>,
    ) {
        let Some(expected) = ref_state.expected_probes.get(&probe_id) else {
            return;
        };
        let Destination::DomainName { name, .. } = expected.request.destination() else {
            return;
        };
        let observations = iter::empty()
            .chain(
                self.clients
                    .values()
                    .flat_map(|client| client.inner().probe_observations.iter()),
            )
            .chain(
                self.gateways
                    .values()
                    .flat_map(|gateway| gateway.inner().probe_observations.iter()),
            )
            .filter(|observation| observation.id() == probe_id)
            .cloned()
            .collect_vec();
        let submitted = observations
            .iter()
            .filter_map(ProbeObservation::as_submitted_request)
            .cloned()
            .collect_vec();
        let received = observations
            .iter()
            .filter_map(ProbeObservation::as_received_request)
            .cloned()
            .collect_vec();
        let ([submitted], [received]) = (submitted.as_slice(), received.as_slice()) else {
            return;
        };

        match received.remote {
            Remote::Gateway(_) => {}
            Remote::Client(_) => return,
        }

        self.dns_nat_observations.push(DnsNatObservation {
            domain: name.clone(),
            udp_flow,
            submitted: submitted.clone(),
            received: received.clone(),
        });
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
        self.advance_to(ref_state, buffered_transmits, cut_off);
    }

    /// Like [`TunnelTest::advance`] but advances at most until `cut_off`.
    fn advance_to(
        &mut self,
        ref_state: &ReferenceState,
        buffered_transmits: &mut BufferedTransmits,
        cut_off: Instant,
    ) {
        'outer: while self.flux_capacitor.now::<Instant>() < cut_off {
            let now = self.flux_capacitor.now();

            // Drive the network at the top so state changes from the previous
            // iteration are turned into packets before we look for more work.
            // Timeouts are not fired here; that happens once we run out of IO
            // progress below.
            self.drive_network(
                &ref_state.global_dns_records,
                &ref_state.icmp_error_hosts,
                buffered_transmits,
                now,
            );

            for (id, gateway) in self.gateways.iter_mut() {
                let Some(event) = gateway.exec_mut(|g| g.sut.poll_event()) else {
                    continue;
                };

                on_gateway_event(
                    *id,
                    event,
                    &mut self.clients,
                    gateway,
                    &self.relays,
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
                match self.on_client_event(client_id, event, ref_state) {
                    Ok(()) => {}
                    Err(ClientEventError::Client { id, error: e }) => {
                        tracing::debug!("Failed to handle ClientEvent: {e}");

                        let client = self.clients.get_mut(&id).unwrap();
                        client.exec_mut(|c| {
                            c.update_relays(iter::empty(), self.relays.iter(), now);
                        });
                    }
                    Err(ClientEventError::Gateway { id, error: e }) => {
                        tracing::debug!("Failed to handle GatewayEvent: {e}");

                        let gateway = self.gateways.get_mut(&id).unwrap();
                        gateway
                            .exec_mut(|g| g.update_relays(iter::empty(), self.relays.iter(), now))
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

                let response = self.on_recursive_dns_query(&message, &ref_state.global_dns_records);
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
                            started_at: now,
                            recursion: dns::Recursion::Local,
                        },
                        now,
                    )
                });

                continue;
            }

            for relay in self.relays.values_mut() {
                let Some(message) = relay.exec_mut(|r| r.sut.next_command()) else {
                    continue;
                };

                match message {
                    relay_proto::Command::SendMessage { payload, recipient } => {
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

                    relay_proto::Command::CreateAllocation { port, family } => {
                        relay.allocate_port(port.value(), family);
                        relay.exec_mut(|r| r.allocations.insert((family, port)));
                    }
                    relay_proto::Command::FreeAllocation { port, family } => {
                        relay.deallocate_port(port.value(), family);
                        relay.exec_mut(|r| r.allocations.remove(&(family, port)));
                    }
                    relay_proto::Command::CreateChannelBinding { .. }
                    | relay_proto::Command::DeleteChannelBinding { .. } => {}
                }

                continue 'outer;
            }

            for client in self.clients.values_mut() {
                let Some(packet) = client.exec_mut(|sim| sim.sut.poll_packets()) else {
                    continue;
                };

                let Some(transmit) = client.exec_mut(|sim| {
                    sim.on_received_packet(packet, &ref_state.icmp_error_hosts, now)
                }) else {
                    continue;
                };

                buffered_transmits.push_from(transmit, client, now);
                continue 'outer;
            }

            self.drain_transmits(buffered_transmits, now);

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

            // The buffer is empty here (see the `is_empty` guard above), so nothing
            // is in flight; jump to the next deadline and fire whatever is due.
            self.flux_capacitor.advance_until(time_to_next_action);
            self.handle_timeout(self.flux_capacitor.now());
        }

        for (transmit, at) in buffered_transmits.drain() {
            self.dispatch_transmit(transmit, at);
        }
    }

    fn drain_transmits(&mut self, buffered_transmits: &mut BufferedTransmits, now: Instant) {
        for gateway in self.gateways.values_mut() {
            while let Some(transmit) = gateway.exec_mut(|g| g.sut.poll_transmit()) {
                buffered_transmits.push_from(transmit, gateway, now);
            }
        }

        for client in self.clients.values_mut() {
            while let Some(transmit) = client.exec_mut(|g| g.sut.poll_transmit()) {
                buffered_transmits.push_from(transmit, client, now);
            }
        }
    }

    /// Drive the simulated network: drain every host's outbound/inbound packets
    /// and advance the simulated application TCP stacks.
    fn drive_network(
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

            // Handle the client's `Transmit`s.
            while let Some(transmit) = client.poll_inbox(now) {
                let Some(transmit) =
                    client.exec_mut(|c| c.receive(transmit, icmp_error_hosts, now))
                else {
                    continue;
                };

                buffered_transmits.push_from(transmit, client, now)
            }

            client.exec_mut(|c| c.drive_tcp(now));
        }

        // Handle all gateway `Transmit`s.
        for gateway in self.gateways.values_mut() {
            for transmit in gateway.exec_mut(|g| g.advance_resources(global_dns_records, now)) {
                buffered_transmits.push_from(transmit, gateway, now);
            }

            while let Some(transmit) = gateway.poll_inbox(now) {
                let Some(reply) = gateway.exec_mut(|g| g.receive(transmit, icmp_error_hosts, now))
                else {
                    continue;
                };

                buffered_transmits.push_from(reply, gateway, now);
            }
        }

        // Handle all relay `Transmit`s.
        for relay in self.relays.values_mut() {
            while let Some(transmit) = relay.poll_inbox(now) {
                let Some(reply) = relay.exec_mut(|r| r.receive(transmit, now)) else {
                    continue;
                };

                buffered_transmits.push_from(reply, relay, now);
            }
        }
    }

    fn handle_timeout(&mut self, now: Instant) {
        for client in self.clients.values_mut() {
            client.exec_mut(|c| c.handle_timeout(now));
        }

        for gateway in self.gateways.values_mut() {
            gateway.exec_mut(|g| g.handle_timeout(now));
        }

        for relay in self.relays.values_mut() {
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
    /// It routes by the wire destination and passes the packet through the
    /// receiving host's network edge, which may translate or drop it.
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
            HostId::Client(id) => {
                let client = self.clients.get_mut(&id).unwrap();

                match client.ingress(src, dst, at) {
                    Ok(local_dst) => client.receive(
                        Transmit {
                            dst: local_dst,
                            ..transmit
                        },
                        at,
                    ),
                    Err(e) => {
                        tracing::debug!(%src, %dst, "Client's edge dropped packet: {e:#}")
                    }
                }
            }
            HostId::Gateway(id) => {
                let gateway = self.gateways.get_mut(&id).expect("unknown gateway");

                match gateway.ingress(src, dst, at) {
                    Ok(local_dst) => gateway.receive(
                        Transmit {
                            dst: local_dst,
                            ..transmit
                        },
                        at,
                    ),
                    Err(e) => {
                        tracing::debug!(%src, %dst, "Gateway's edge dropped packet: {e:#}")
                    }
                }
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
        ref_state: &ReferenceState,
    ) -> Result<(), ClientEventError> {
        let portal = &ref_state.portal;
        let now = self.flux_capacitor.now();

        // Simulate a client that has not yet reconnected to the portal after a
        // roam: drop the portal-bound messages it emits. Local events (resource,
        // DNS and TUN interface updates) still flow so the harness state stays in
        // sync.
        let portal_unreachable = self
            .client_portal_offline_until
            .is_some_and(|(cid, until)| cid == src && now < until);
        let is_portal_bound = is_portal_bound_event(&event);
        if portal_unreachable && is_portal_bound {
            tracing::trace!(%src, ?event, "Dropping portal-bound client event during roam outage");

            return Ok(());
        }

        match event {
            ClientEvent::AddedIceCandidates {
                candidates,
                conn_id: ClientOrGatewayId::Gateway(conn_id),
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
                conn_id: ClientOrGatewayId::Gateway(conn_id),
            } => {
                let gateway = self.gateways.get_mut(&conn_id).expect("unknown gateway");

                gateway.exec_mut(|g| {
                    for candidate in candidates {
                        g.sut.remove_ice_candidate(src, candidate, now)
                    }
                });

                Ok(())
            }
            ClientEvent::AddedIceCandidates {
                conn_id: ClientOrGatewayId::Client(conn_id),
                candidates,
            } => {
                let client = self.clients.get_mut(&conn_id).expect("unknown client");

                client.exec_mut(|c| {
                    for candidate in candidates {
                        c.sut.add_ice_candidate(src, candidate, now);
                    }
                });

                Ok(())
            }
            ClientEvent::RemovedIceCandidates {
                conn_id: ClientOrGatewayId::Client(conn_id),
                candidates,
            } => {
                let client = self.clients.get_mut(&conn_id).expect("unknown client");

                client.exec_mut(|c| {
                    for candidate in candidates {
                        c.sut.remove_ice_candidate(src, candidate, now);
                    }
                });

                Ok(())
            }
            ClientEvent::ResourceConnectionIntent {
                resource: resource_id,
                preferred_gateways,
                ip: None,
            } => {
                let (gateway_id, site_id) =
                    portal.handle_connection_intent(resource_id, preferred_gateways);
                let gateway = self.gateways.get_mut(&gateway_id).expect("unknown gateway");
                let resource = portal.map_client_resource_to_gateway_resource(resource_id);

                let client = self.clients.get_mut(&src).unwrap();
                let client_key = client.inner().sut.public_key();
                let client_tun = client.inner().sut.tunnel_ip_config().unwrap();
                let gateway_key = gateway.inner().sut.public_key();
                let (preshared_key, client_ice, gateway_ice) =
                    make_preshared_key_and_ice(client_key, gateway_key);
                let use_iceless = portal.iceless();

                gateway
                    .exec_mut(|g| {
                        g.sut.create_authorization(
                            Client {
                                id: src,
                                public_key: client_key.into(),
                                preshared_key: preshared_key.clone(),
                                ipv4: client_tun.v4,
                                ipv6: client_tun.v6,
                            },
                            client_ice.clone(),
                            gateway_ice.clone(),
                            None,
                            resource,
                            use_iceless,
                            now,
                            test_ingest_token(),
                        )?;
                        g.record_authorization(
                            src,
                            resource_id,
                            [client_tun.v4.into(), client_tun.v6.into()],
                        );

                        Ok(())
                    })
                    .map_err(|error| ClientEventError::Gateway {
                        id: gateway_id,
                        error,
                    })?;

                // The gateway's candidates and the portal's `flow_created` reply travel
                // independently, so the client may receive them before it knows about
                // the connection.
                while let Some(event) = gateway.exec_mut(|g| g.sut.poll_event()) {
                    on_gateway_event(
                        gateway_id,
                        event,
                        &mut self.clients,
                        gateway,
                        &self.relays,
                        &ref_state.global_dns_records,
                        now,
                    );
                }

                let client = self.clients.get_mut(&src).unwrap();
                client
                    .exec_mut(|c| {
                        c.sut.handle_resource_access_authorized(
                            resource_id,
                            gateway_id,
                            gateway_key,
                            gateway.inner().sut.tunnel_ip_config().unwrap(),
                            site_id,
                            preshared_key,
                            client_ice,
                            gateway_ice,
                            use_iceless,
                            test_ingest_token(),
                            now,
                        )
                    })
                    .unwrap_or_else(|e| {
                        tracing::error!("{e:#}");

                        Ok(())
                    })
                    .map_err(|error| ClientEventError::Client { id: src, error })?;

                Ok(())
            }
            ClientEvent::ResourceConnectionIntent {
                resource: resource_id,
                ip: Some(ip),
                ..
            } => {
                let src_client = self.clients.get(&src).expect("unknown source client");

                let src_key = src_client.inner().sut.public_key();
                let src_tun = src_client.inner().sut.tunnel_ip_config().unwrap();

                let maybe_remote_client = self.clients.iter_mut().find(|(_, client)| {
                    client
                        .inner()
                        .sut
                        .tunnel_ip_config()
                        .is_some_and(|tun| match ip {
                            std::net::IpAddr::V4(v4) => tun.v4 == v4,
                            std::net::IpAddr::V6(v6) => tun.v6 == v6,
                        })
                });

                match maybe_remote_client {
                    Some((remote_id, remote_client)) => {
                        let remote_id = *remote_id;
                        let remote_tun = remote_client.inner().sut.tunnel_ip_config().unwrap();
                        let remote_key = remote_client.inner().sut.public_key();

                        let (preshared_key, local_client_ice, remote_client_ice) =
                            make_preshared_key_and_ice(src_key, remote_key);
                        let use_iceless = portal.iceless();

                        let pool_filters = portal
                            .static_device_pool_filters(resource_id)
                            .unwrap_or_default();

                        let remote_authorization =
                            tunnel_proto::messages::client::ResourceAuthorization {
                                resource_id,
                                filters: pool_filters,
                                expires_at: None,
                            };
                        remote_client.exec_mut(|c| {
                            c.sut
                                .handle_client_device_access_authorized(
                                    src,
                                    src_key,
                                    src_tun,
                                    preshared_key.clone(),
                                    remote_client_ice.clone(),
                                    local_client_ice.clone(),
                                    tunnel_proto::messages::IceRole::Controlled,
                                    use_iceless,
                                    "initiating client".to_owned(),
                                    Some(remote_authorization),
                                    test_ingest_token(),
                                    now,
                                )
                                .map_err(|error| ClientEventError::Client {
                                    id: remote_id,
                                    error,
                                })?;

                            Ok(())
                        })?;

                        let local_client =
                            self.clients.get_mut(&src).expect("unknown source client");

                        local_client.exec_mut(|c| {
                            c.sut
                                .handle_client_device_access_authorized(
                                    remote_id,
                                    remote_key,
                                    remote_tun,
                                    preshared_key,
                                    local_client_ice,
                                    remote_client_ice,
                                    tunnel_proto::messages::IceRole::Controlling,
                                    use_iceless,
                                    "target client".to_owned(),
                                    None,
                                    test_ingest_token(),
                                    now,
                                )
                                .map_err(|error| ClientEventError::Client { id: src, error })?;

                            Ok(())
                        })?;
                    }
                    None => {
                        unreachable!(
                            "device-connection intent for offline destination ip={ip} resource_id={resource_id}"
                        )
                    }
                }

                Ok(())
            }
            ClientEvent::ResourcesChanged { resources } => {
                let client = self.clients.get_mut(&src).unwrap();
                client.exec_mut(|c| {
                    c.observed_resource_list = resources;
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
            ClientEvent::NoRelays => {
                // Mimic the portal: reply with the current set of relays.
                let client = self.clients.get_mut(&src).unwrap();
                client.exec_mut(|c| c.update_relays(iter::empty(), self.relays.iter(), now));

                Ok(())
            }
            ClientEvent::DevicePoolDomainQueried {
                resource_id,
                domain,
            } => {
                let client = self.clients.get_mut(&src).unwrap();

                let result = portal
                    .resolve_device_pool_domain(&domain.to_string())
                    .ok_or(tunnel_proto::messages::client::FailReason::NotFound);
                client.exec_mut(|c| {
                    c.sut
                        .handle_device_pool_domain_resolved(resource_id, domain, result);
                });

                Ok(())
            }
        }
    }

    fn on_recursive_dns_query(
        &self,
        query: &dns_types::Query,
        global_dns_records: &DnsRecords,
    ) -> dns_types::Response {
        // Long enough that a query repeated within one `advance` window is served
        // from connlib's DNS cache, short enough that an `Idle` (minutes) expires
        // the entry — so the corpus exercises the cache hit and expiry paths. The
        // reference model is cache-agnostic (it expects a response per query
        // regardless of how it is produced), so activating the cache is
        // observationally transparent.
        const TTL: u32 = 30;

        let qtype = query.qtype();
        let domain = query.domain();

        let response = dns_types::ResponseBuilder::for_query(query, ResponseCode::NOERROR)
            .with_records(
                global_dns_records
                    .domain_records_iter(&domain)
                    .filter(|record| qtype == record.rtype())
                    .map(|rdata| (domain.clone(), TTL, rdata)),
            )
            .build();

        tracing::debug!(%domain, %qtype, "Responding to DNS query");

        response
    }

    fn deploy_new_relays(&mut self, new_relays: BTreeMap<RelayId, Host<u64>>, now: Instant) {
        let disconnected = self
            .relays
            .keys()
            .filter(|relay_id| !new_relays.contains_key(relay_id))
            .copied()
            .collect::<BTreeSet<_>>();
        let connected = new_relays
            .into_iter()
            .filter(|(relay_id, _)| !self.relays.contains_key(relay_id))
            .map(|(relay_id, relay)| {
                (
                    relay_id,
                    relay.map(SimRelay::new, debug_span!("relay", %relay_id)),
                )
            })
            .collect::<BTreeMap<_, _>>();

        for relay_id in &disconnected {
            let relay = self.relays.remove(relay_id).unwrap();
            self.network.remove_host(&relay);
        }

        for (relay_id, relay) in &connected {
            let added = self.network.add_host(*relay_id, relay);
            debug_assert!(added);
        }

        for client in self.clients.values_mut() {
            client.exec_mut(|c| {
                c.update_relays(disconnected.iter().copied(), connected.iter(), now);
            });
        }
        for gateway in self.gateways.values_mut() {
            gateway
                .exec_mut(|g| g.update_relays(disconnected.iter().copied(), connected.iter(), now));
        }

        self.relays.extend(connected);
    }

    fn reboot_relays_while_partitioned(
        &mut self,
        new_relays: BTreeMap<RelayId, Host<u64>>,
        now: Instant,
    ) {
        for relay in self.relays.values() {
            self.network.remove_host(relay);
        }

        let online = new_relays
            .into_iter()
            .map(|(rid, relay)| (rid, relay.map(SimRelay::new, debug_span!("relay", %rid))))
            .collect::<BTreeMap<_, _>>();

        for (rid, relay) in &online {
            let added = self.network.add_host(*rid, relay);
            debug_assert!(added);
        }

        for client in self.clients.values_mut() {
            client.exec_mut(|c| c.update_relays(iter::empty(), online.iter(), now));
        }
        for gateway in self.gateways.values_mut() {
            gateway.exec_mut(|g| g.update_relays(iter::empty(), online.iter(), now));
        }
        self.relays = online;
    }
}

enum ClientEventError {
    Client { id: ClientId, error: NoTurnServers },
    Gateway { id: GatewayId, error: NoTurnServers },
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
                })
                .copied()
                .collect::<Vec<_>>();

            // Select one candidate by index. The candidate set is only known here
            // (it is filtered by source address family at apply-time), so we index
            // with `% len`.
            available_ips[*resolved_ip as usize % available_ips.len()]
        }
        Destination::IpAddr(addr) => *addr,
    }
}

fn test_ingest_token() -> tunnel_proto::messages::IngestToken {
    serde_json::from_str(&format!("\"{}\"", flow_tracker::TEST_INGEST_TOKEN)).unwrap()
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
        username: rand::distr::Alphanumeric.sample_string(&mut rng, 4),
        password: rand::distr::Alphanumeric.sample_string(&mut rng, 12),
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
    relays: &BTreeMap<RelayId, Host<SimRelay>>,
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
            let client = r.client();
            let domain = r.domain().clone();
            let proxy_ips = r.proxy_ips().to_vec();
            let resolved_ips = global_dns_records
                .domain_ips_iter(&domain)
                .collect::<Vec<_>>();

            gateway.exec_mut(|g| {
                g.sut
                    .handle_domain_resolved(r, Ok(resolved_ips.clone()), now)
                    .unwrap();
                g.record_dns_resolution(client, domain, proxy_ips, resolved_ips, now);
            })
        }
        GatewayEvent::NoRelays => {
            // Mimic the portal: reply with the current set of relays.
            gateway.exec_mut(|g| g.update_relays(iter::empty(), relays.iter(), now));
        }
    }
}

#[allow(clippy::match_like_matches_macro)]
fn is_portal_bound_event(event: &ClientEvent) -> bool {
    match event {
        ClientEvent::AddedIceCandidates { .. } => true,
        ClientEvent::RemovedIceCandidates { .. } => true,
        ClientEvent::ResourceConnectionIntent { .. } => true,
        ClientEvent::DevicePoolDomainQueried { .. } => true,
        ClientEvent::ResourcesChanged { .. } => false,
        ClientEvent::DnsRecordsChanged { .. } => false,
        ClientEvent::TunInterfaceUpdated(_) => false,
        ClientEvent::NoRelays => true,
    }
}
