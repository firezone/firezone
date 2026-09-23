use super::dns_records::DnsRecords;
use super::icmp_error_hosts::IcmpErrorHosts;
use super::probe::{
    ExpectedOutcome, ExpectedProbe, FlowId, IcmpFlow, KnownLoss, ProbeId, ProbeRequest,
    RejectionRemote, RejectionResponse, Remote, Route, TraceRequirement, UdpFlow,
};
use super::{ref_client::*, ref_gateway::*, sim_net::*, stub_portal::StubPortal, transition::*};
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, StaticSecret};
use dns_types::{DomainName, RecordType};
use ip_network::{Ipv4Network, Ipv6Network};
use ip_packet::Protocol;
use itertools::Itertools;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::{Duration, Instant};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt, iter,
    net::{IpAddr, SocketAddr},
};
use tunnel_proto::dns;
use tunnel_proto::dns::is_subdomain;
use tunnel_proto::messages::Filter;

use crate::resource as client;

const MIN_IDLE_FOR_REKEY_DROP: Duration = Duration::from_secs(180 - 10);

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Debug, Clone)]
pub struct ReferenceState {
    pub(crate) clients: BTreeMap<ClientId, Host<RefClient>>,
    pub(crate) gateways: BTreeMap<GatewayId, Host<RefGateway>>,
    pub(crate) relays: BTreeMap<RelayId, Host<u64>>,

    /// All IP addresses a domain resolves to in our test.
    ///
    /// This is used to e.g. mock DNS resolution on the gateway.
    pub(crate) global_dns_records: DnsRecords,

    /// DNS Resources that listen for TCP connections.
    pub(crate) tcp_resources: BTreeMap<DomainName, BTreeSet<SocketAddr>>,

    /// A subset of all DNS resource records that have been selected to produce an ICMP error.
    pub(crate) icmp_error_hosts: IcmpErrorHosts,

    pub(crate) network: RoutingTable,

    pub(crate) expected_probes: BTreeMap<ProbeId, ExpectedProbe>,

    pub(crate) icmp_flows: BTreeMap<FlowId, IcmpFlow>,
    pub(crate) udp_flows: BTreeMap<FlowId, UdpFlow>,
}

/// Implementation of our reference state machine.
///
/// The logic in here represents what we expect the [`ClientState`](tunnel_proto::ClientState) & [`GatewayState`](tunnel_proto::GatewayState) to do.
/// Care has to be taken that we don't implement things in a buggy way here.
/// After all, if your test has bugs, it won't catch any in the actual implementation.
impl ReferenceState {
    /// Assemble a [`ReferenceState`] from already-generated parts.
    ///
    /// Used by the structured generator after it has built each component.
    pub(crate) fn from_parts(
        clients: BTreeMap<ClientId, Host<RefClient>>,
        gateways: BTreeMap<GatewayId, Host<RefGateway>>,
        relays: BTreeMap<RelayId, Host<u64>>,
        global_dns_records: DnsRecords,
        tcp_resources: BTreeMap<DomainName, BTreeSet<SocketAddr>>,
        icmp_error_hosts: IcmpErrorHosts,
        network: RoutingTable,
    ) -> Self {
        Self {
            clients,
            gateways,
            relays,
            global_dns_records,
            tcp_resources,
            icmp_error_hosts,
            network,
            expected_probes: Default::default(),
            icmp_flows: Default::default(),
            udp_flows: Default::default(),
        }
    }

    /// Drops the bookkeeping that `transition` makes stale before it is applied.
    pub fn invalidate(&mut self, transition: &Transition, portal: &StubPortal) {
        self.expected_probes.clear();

        if transition.clears_packets() {
            for client in self.clients.values_mut() {
                client.exec_mut(|c| c.clear_packets())
            }
        }

        let iceless = portal.iceless();
        for _ in self.icmp_flows.extract_if(.., |_, flow| {
            !transition.retains_flow(flow.client_id, flow.route, iceless)
        }) {}
        for _ in self.udp_flows.extract_if(.., |_, flow| {
            !transition.retains_flow(flow.client_id, flow.route, iceless)
        }) {}
    }

    /// Applies the transition to the reference state.
    ///
    /// Here is where we implement the "expected" logic.
    pub fn apply(mut self, transition: &Transition, portal: &StubPortal, now: Instant) -> Self {
        match transition {
            Transition::AddResource(resource) => {
                for client in self.clients.values_mut() {
                    client.exec_mut(|client| match resource {
                        client::Resource::Dns(r) => {
                            client.add_dns_resource(r.clone());

                            // TODO: PRODUCTION CODE CANNOT DO THIS.
                            // Remove all prior DNS records.
                            client.dns_records.retain(|domain, _| {
                                if is_subdomain(domain, &r.address) {
                                    return false;
                                }

                                true
                            });
                        }
                        client::Resource::Cidr(r) => client.add_cidr_resource(r.clone()),
                        client::Resource::Internet(r) => client.add_internet_resource(r.clone()),
                        client::Resource::DevicePool(r) => {
                            client.add_device_pool_resource(r.clone());
                        }
                    });
                }
            }
            Transition::RemoveResource(id) => {
                for client in self.clients.values_mut() {
                    client.exec_mut(|client| client.remove_resource(id));
                }
                self.expect_gateway_connections_closed(portal, *id);
            }
            Transition::EditResource(edit) => {
                self.apply_resource_edit(edit);
                self.expect_gateway_connections_closed(portal, edit.new.id());
            }
            Transition::UpdateDevicePoolMembers {
                pool_id: _,
                members: _,
                revoked,
            } => {
                for authorization in revoked {
                    let filters = portal
                        .device_pool_filters(authorization.pool)
                        .unwrap_or_default();
                    if let Some(client) = self.clients.get_mut(&authorization.initiator) {
                        client.exec_mut(|client| {
                            client.reject_peer_pool(
                                authorization.target,
                                authorization.pool,
                                filters.clone(),
                            )
                        });
                    }
                    if let Some(client) = self.clients.get_mut(&authorization.target) {
                        client.exec_mut(|client| {
                            client.reject_peer_pool(
                                authorization.initiator,
                                authorization.pool,
                                filters,
                            )
                        });
                    }
                }
            }
            Transition::SetInternetResourceState {
                client_id: client,
                active,
            } => self.clients.get_mut(client).unwrap().exec_mut(|client| {
                client.set_internet_resource_state(*active);
            }),
            Transition::SendDnsQueries(queries) => {
                let upstream_do53 = portal.upstream_do53();
                let global_dns_records = &self.global_dns_records;
                let icmp_error_hosts = &self.icmp_error_hosts;

                for (client_id, query) in queries {
                    self.clients.get_mut(client_id).unwrap().exec_mut(|c| {
                        c.on_dns_query(query, upstream_do53, global_dns_records, icmp_error_hosts);
                    });
                }
            }
            Transition::SendDnsResourcePtrQuery {
                client_id,
                query_id,
                dns_server,
                transport,
                ..
            } => {
                self.clients.get_mut(client_id).unwrap().exec_mut(|c| {
                    c.on_dns_resource_ptr_query(dns_server, *query_id, *transport);
                });
            }
            Transition::SendIcmpPacketOnNewFlow {
                flow_id,
                client_id,
                src,
                dst,
                seq,
                identifier,
                probe_id,
            } => {
                let outcome = self.record_probe(
                    portal,
                    *probe_id,
                    *client_id,
                    ProbeRequest::Icmp {
                        src: *src,
                        dst: dst.clone(),
                        seq: *seq,
                        identifier: *identifier,
                    },
                    now,
                );

                match outcome {
                    ExpectedOutcome::RoundTripCompleted(route) => {
                        let flow = IcmpFlow {
                            client_id: *client_id,
                            src: *src,
                            dst: dst.clone(),
                            identifier: *identifier,
                            next_seq: Seq(seq.0.wrapping_add(1)),
                            route,
                        };
                        let previous = self.icmp_flows.insert(*flow_id, flow);
                        assert!(previous.is_none(), "ICMP flow IDs must be unique");
                    }
                    ExpectedOutcome::Dropped => {}
                    ExpectedOutcome::Rejected { .. } => {}
                }
            }
            Transition::SendIcmpPacketOnExistingFlow {
                flow_id,
                seq,
                probe_id,
            } => {
                let flow = {
                    let flow = self
                        .icmp_flows
                        .get_mut(flow_id)
                        .expect("reused ICMP flow must exist");
                    assert_eq!(flow.next_seq, *seq, "reused ICMP sequence must be next");
                    flow.next_seq = Seq(seq.0.wrapping_add(1));

                    flow.clone()
                };

                match self.record_icmp_probe(portal, *probe_id, &flow, *seq, now) {
                    ExpectedOutcome::RoundTripCompleted { .. } => {}
                    ExpectedOutcome::Dropped => {
                        panic!("reused ICMP route must complete a round trip")
                    }
                    ExpectedOutcome::Rejected {
                        by: RejectionRemote::Gateway(_),
                        response: RejectionResponse::Unreachable,
                    } => {}
                    ExpectedOutcome::Rejected { .. } => {
                        panic!("reused ICMP route must complete a round trip")
                    }
                }
            }
            Transition::SendUdpPacketOnNewFlow {
                flow_id,
                client_id,
                src,
                dst,
                sport,
                dport,
                probe_id,
            } => {
                let outcome = self.record_probe(
                    portal,
                    *probe_id,
                    *client_id,
                    ProbeRequest::Udp {
                        src: *src,
                        dst: dst.clone(),
                        sport: *sport,
                        dport: *dport,
                    },
                    now,
                );

                match outcome {
                    ExpectedOutcome::RoundTripCompleted(route) => {
                        let flow = UdpFlow {
                            client_id: *client_id,
                            src: *src,
                            dst: dst.clone(),
                            sport: *sport,
                            dport: *dport,
                            route,
                        };
                        let previous = self.udp_flows.insert(*flow_id, flow);
                        assert!(previous.is_none(), "UDP flow IDs must be unique");
                    }
                    ExpectedOutcome::Dropped => {}
                    ExpectedOutcome::Rejected { .. } => {}
                }
            }
            Transition::SendUdpPacketOnExistingFlow { flow_id, probe_id } => {
                let flow = self
                    .udp_flows
                    .get(flow_id)
                    .expect("reused UDP flow must exist")
                    .clone();

                match self.record_udp_probe(portal, *probe_id, &flow, now) {
                    ExpectedOutcome::RoundTripCompleted { .. } => {}
                    ExpectedOutcome::Dropped => {
                        panic!("reused UDP route must complete a round trip")
                    }
                    ExpectedOutcome::Rejected {
                        by: RejectionRemote::Gateway(_),
                        response: RejectionResponse::Unreachable,
                    } => {}
                    ExpectedOutcome::Rejected { .. } => {
                        panic!("reused UDP route must complete a round trip")
                    }
                }
            }
            Transition::ConnectTcp {
                client_id,
                src,
                dst,
                sport,
                dport,
            } => {
                let outcome = self.dispatch(portal, *client_id, *src, dst, Protocol::Tcp(dport.0));

                self.clients.get_mut(client_id).unwrap().exec_mut(|client| {
                    client.expect_tcp_outcome(*src, dst.clone(), *sport, *dport, outcome);
                });
            }
            Transition::UpdateSystemDnsServers { servers } => {
                for client in self.clients.values_mut() {
                    client.exec_mut(|client| client.set_system_dns_resolvers(servers));
                }
            }
            Transition::UpdateUpstreamDo53Servers(_) => {}
            Transition::UpdateUpstreamDoHServers(_) => {}
            Transition::UpdateUpstreamSearchDomain(_) => {}
            Transition::RoamClient {
                client_id,
                ip4,
                ip6,
                nat_ip4,
                dead_window,
                portal_window,
            } => {
                // With ICE-less connections, a roam re-keys in place and keeps
                // the connection alive, so we only reset when the portal hands
                // out classic ICE flows.
                let all_iceless = portal.iceless();

                let client = self.clients.get_mut(client_id).unwrap();
                self.network.remove_host(client);
                client.ip4.clone_from(ip4);
                client.ip6.clone_from(ip6);
                client.migrate_nat(*nat_ip4);
                let added = self.network.add_host(*client_id, client);
                debug_assert!(added);

                // When roaming, we are not connected to any resource and wait for the next packet to re-establish a connection.
                client.exec_mut(|client| {
                    if !all_iceless {
                        // Reconnecting needs the portal, so recovery can only
                        // start once the portal connection is back.
                        client.reset_connections(now + *dead_window + *portal_window);
                    }
                    client.readd_all_resources();
                });

                // The peers lose their connections to the roaming client, and their authorizations
                // towards it with them.
                if !all_iceless {
                    for (id, peer) in &mut self.clients {
                        if id != client_id {
                            peer.exec_mut(|peer| peer.forget_peer_authorizations(*client_id));
                        }
                    }
                }
            }
            Transition::ReconnectPortal { client_id } => {
                // Reconnecting to the portal should have no noticeable impact on the data plane.
                // We do re-add all resources though so depending on the order they are added in, overlapping CIDR resources may change.
                self.clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|c| c.readd_all_resources());
            }
            Transition::DeployNewRelays(new_relays) => self.deploy_new_relays(new_relays),
            Transition::RebootRelaysWhilePartitioned(new_relays) => {
                self.reboot_relays_while_partitioned(new_relays)
            }
            Transition::Idle => {}
            Transition::PartitionRelaysFromPortal => {
                // With ICE-less connections, losing all relays does not fail
                // the connection: the WG session idles until the relays return
                // and probes revive the path. Classic ICE flows disconnect for
                // every pairing that cannot fall back to a direct path.
                if !portal.iceless() {
                    let gateway_edges = self
                        .gateways
                        .iter()
                        .map(|(id, g)| (*id, (g.edge_config(), g.ip4.is_some(), g.ip6.is_some())))
                        .collect::<BTreeMap<_, _>>();
                    let client_edges = self
                        .clients
                        .iter()
                        .map(|(id, c)| (*id, (c.edge_config(), c.ip4.is_some(), c.ip6.is_some())))
                        .collect::<BTreeMap<_, _>>();

                    for (client_id, client) in self.clients.iter_mut() {
                        let client_edge = client.edge_config();
                        let client_has_ip4 = client.ip4.is_some();
                        let client_has_ip6 = client.ip6.is_some();
                        let unreachable_gateways = gateway_edges
                            .iter()
                            .filter(|(_, (gateway_edge, gateway_has_ip4, gateway_has_ip6))| {
                                !direct_path_possible(
                                    client_edge,
                                    *gateway_edge,
                                    client_has_ip4 && *gateway_has_ip4,
                                    client_has_ip6 && *gateway_has_ip6,
                                )
                            })
                            .map(|(id, _)| *id)
                            .collect::<BTreeSet<_>>();

                        let unreachable_clients = client_edges
                            .iter()
                            .filter(|(id, (peer_edge, peer_has_ip4, peer_has_ip6))| {
                                *id != client_id
                                    && !direct_path_possible(
                                        client_edge,
                                        *peer_edge,
                                        client_has_ip4 && *peer_has_ip4,
                                        client_has_ip6 && *peer_has_ip6,
                                    )
                            })
                            .map(|(id, _)| *id);

                        client.exec_mut(|c| {
                            c.reset_connections_to_gateways(
                                &unreachable_gateways,
                                |rid| portal.gateway_for_resource(rid).copied(),
                                now,
                            );
                            for peer in unreachable_clients {
                                c.forget_peer_authorizations(peer);
                            }
                        });
                    }
                }
            }
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => {
                for client in self.clients.values_mut() {
                    client.exec_mut(|client| client.remove_resource(resource));
                }
                self.expect_gateway_connections_closed(portal, *resource);
            }
            Transition::ExpirePeerAuthorizations {
                client,
                peer,
                pools,
            } => {
                self.clients.get_mut(peer).unwrap().exec_mut(|receiver| {
                    for pool in pools {
                        let filters = portal.device_pool_filters(*pool).unwrap_or_default();
                        receiver.revoke_inbound_peer_pool(*client, *pool, filters);
                    }
                });
            }
            Transition::RevokePeerAuthorization { client, peer, pool } => {
                let filters = portal.device_pool_filters(*pool).unwrap_or_default();
                self.clients.get_mut(peer).unwrap().exec_mut(|receiver| {
                    receiver.reject_peer_pool(*client, *pool, filters);
                });
            }
            Transition::RevokeGatewayAuthorization(resource) => {
                self.expect_gateway_connections_closed(portal, *resource);
            }
            Transition::RestartClient { client_id, key } => {
                for (id, client) in &mut self.clients {
                    if id == client_id {
                        client.exec_mut(|c| c.restart(*key, now));
                    } else {
                        client.exec_mut(|c| c.forget_peer_authorizations(*client_id));
                    }
                }
            }
            Transition::UpdateDnsRecords { domain, records } => {
                self.global_dns_records
                    .replace(domain.clone(), records.clone());
            }
        };

        self
    }

    /// A Gateway that revoking `resource` left with nothing closes the connection with a
    /// `goodbye`, so we expect the Client to reset its state for that Gateway.
    fn expect_gateway_connections_closed(&mut self, portal: &StubPortal, resource: ResourceId) {
        for closed in portal.gateway_connections_closed_by(resource) {
            let Some(client) = self.clients.get_mut(&closed.client) else {
                continue;
            };

            client.exec_mut(|c| c.close_gateway_connection(closed.gateway, &closed.resources));
        }
    }

    fn apply_resource_edit(&mut self, edit: &client::ResourceEdit) {
        let effect = client::classify(&edit.old, &edit.new);
        let updated = &edit.new;

        for client in self.clients.values_mut() {
            client.exec_mut(|client| {
                let forgets_dns_records_under = match effect {
                    client::EditEffect::Metadata => {
                        client.update_resource_metadata(updated.clone());
                        return;
                    }
                    client::EditEffect::Filters { .. } => None,
                    client::EditEffect::Access {
                        forgets_dns_records_under,
                        ..
                    } => forgets_dns_records_under,
                    client::EditEffect::DevicePoolRouting => None,
                    client::EditEffect::Type {
                        forgets_dns_records_under,
                        ..
                    } => {
                        client.remove_resource(&updated.id());

                        forgets_dns_records_under
                    }
                };

                if let Some(address) = forgets_dns_records_under {
                    for _ in client
                        .dns_records
                        .extract_if(.., |domain, _| is_subdomain(domain, address))
                    {
                    }
                }

                match updated {
                    client::Resource::Dns(resource) => client.add_dns_resource(resource.clone()),
                    client::Resource::Cidr(resource) => client.add_cidr_resource(resource.clone()),
                    client::Resource::Internet(resource) => {
                        client.add_internet_resource(resource.clone())
                    }
                    client::Resource::DevicePool(resource) => {
                        client.add_device_pool_resource(resource.clone())
                    }
                }
            });
        }
    }

    fn record_icmp_probe(
        &mut self,
        portal: &StubPortal,
        id: ProbeId,
        flow: &IcmpFlow,
        seq: Seq,
        sent_at: Instant,
    ) -> ExpectedOutcome {
        let request = ProbeRequest::Icmp {
            src: flow.src,
            dst: flow.dst.clone(),
            seq,
            identifier: flow.identifier,
        };

        self.record_flow_probe(portal, id, flow.client_id, flow.route, request, sent_at)
    }

    fn record_udp_probe(
        &mut self,
        portal: &StubPortal,
        id: ProbeId,
        flow: &UdpFlow,
        sent_at: Instant,
    ) -> ExpectedOutcome {
        let request = ProbeRequest::Udp {
            src: flow.src,
            dst: flow.dst.clone(),
            sport: flow.sport,
            dport: flow.dport,
        };

        self.record_flow_probe(portal, id, flow.client_id, flow.route, request, sent_at)
    }

    fn record_flow_probe(
        &mut self,
        portal: &StubPortal,
        id: ProbeId,
        origin: ClientId,
        route: Route,
        request: ProbeRequest,
        sent_at: Instant,
    ) -> ExpectedOutcome {
        // A retained flow completes its round trip; asking the portal again only refreshes
        // the authorization a peer that reconnected since took from us.
        if let Route::Peer(peer) = route {
            let _ = self.pool_towards_peer(portal, origin, peer, request.protocol());
        }

        self.clients.get_mut(&origin).unwrap().exec_mut(|client| {
            if let Route::Resource { resource, .. } = route {
                client.connect_to_resource(resource, request.destination().clone());
            }
            client.note_sent(Some(route.remote()), sent_at);
        });

        self.record_expected_probe(
            id,
            origin,
            request,
            sent_at,
            ExpectedOutcome::RoundTripCompleted(route),
        )
    }

    fn record_probe(
        &mut self,
        portal: &StubPortal,
        id: ProbeId,
        origin: ClientId,
        request: ProbeRequest,
        sent_at: Instant,
    ) -> ExpectedOutcome {
        let outcome = self.dispatch(
            portal,
            origin,
            request.source(),
            request.destination(),
            request.protocol(),
        );
        self.clients
            .get_mut(&origin)
            .unwrap()
            .exec_mut(|client| client.note_sent(outcome.remote(), sent_at));

        self.record_expected_probe(id, origin, request, sent_at, outcome)
    }

    fn record_expected_probe(
        &mut self,
        id: ProbeId,
        origin: ClientId,
        request: ProbeRequest,
        sent_at: Instant,
        outcome: ExpectedOutcome,
    ) -> ExpectedOutcome {
        let trace_requirement = self.trace_requirement(origin, outcome, sent_at);
        let previous = self.expected_probes.insert(
            id,
            ExpectedProbe {
                id,
                origin,
                sent_at,
                request,
                outcome,
                trace_requirement,
            },
        );

        assert!(previous.is_none(), "probe IDs must be unique");

        outcome
    }

    /// Follows a packet from `origin` to its destination: the client picks where it goes,
    /// the portal supplies the gateway or pool, and the remote end accepts or rejects it.
    fn dispatch(
        &mut self,
        portal: &StubPortal,
        origin: ClientId,
        src: IpAddr,
        dst: &Destination,
        protocol: Protocol,
    ) -> ExpectedOutcome {
        if dst.ip_addr().is_some_and(|ip| ip.is_multicast()) {
            return ExpectedOutcome::Dropped;
        }

        if let Some(ip) = dst.ip_addr().filter(|ip| tunnel_proto::is_peer(*ip)) {
            let connected_gateway = portal.gateway_by_ip(ip).filter(|gateway| {
                self.clients[&origin]
                    .inner()
                    .connected_resources()
                    .any(|resource| self.deployed_gateway_for(portal, resource) == Some(*gateway))
            });
            if let Some(gateway) = connected_gateway {
                return ExpectedOutcome::RoundTripCompleted(Route::Gateway(gateway));
            }

            // The portal answers a request for a tunnel IP that no client holds with "not
            // found", and connlib turns that into an ICMP error. It sends the same error
            // without asking when none of its pools permits the protocol, and has no route
            // at all without a pool.
            let Some(peer) = self.client_ip_to_id().get(&ip).copied() else {
                if self.clients[&origin].inner().device_pool_ids().is_empty() {
                    return ExpectedOutcome::Dropped;
                }

                return ExpectedOutcome::Rejected {
                    by: RejectionRemote::Local,
                    response: RejectionResponse::Prohibited,
                };
            };

            let pool = match self.pool_towards_peer(portal, origin, peer, protocol) {
                Ok(pool) => pool,
                Err(outcome) => return outcome,
            };
            if !self.clients[&peer]
                .inner()
                .inbound_peer_filter_allows(origin, protocol)
            {
                let receiver = self.clients[&peer].inner();
                let no_authorization = !receiver.has_inbound_peer_authorization(origin)
                    || receiver.rejected_inbound_peer_filter_allows(origin, protocol);
                if no_authorization
                    && !self.clients[&origin]
                        .inner()
                        .malicious_behaviour
                        .ignore_no_authorization_events
                {
                    self.apply_peer_authorization(origin, peer, pool);
                }

                return ExpectedOutcome::Rejected {
                    by: RejectionRemote::Client(peer),
                    response: RejectionResponse::Prohibited,
                };
            }

            return ExpectedOutcome::RoundTripCompleted(Route::Peer(peer));
        }

        let (resource, gateway) = match self.select_resource(portal, origin, src, dst, protocol) {
            Ok(selected) => selected,
            Err(outcome) => return outcome,
        };
        if let Destination::DomainName { .. } = dst {
            self.clients.get_mut(&origin).unwrap().exec_mut(|client| {
                client.prepare_dns_resource_connection(resource, &self.global_dns_records)
            });
        }
        let rejection = self.gateway_verdict(portal, origin, gateway, resource, src, dst, protocol);

        self.clients
            .get_mut(&origin)
            .unwrap()
            .exec_mut(|client| client.connect_to_resource(resource, dst.clone()));

        match rejection {
            Some(response) => ExpectedOutcome::Rejected {
                by: RejectionRemote::Gateway(gateway),
                response,
            },
            None => ExpectedOutcome::RoundTripCompleted(Route::Resource { resource, gateway }),
        }
    }

    /// The resource `origin` sends a packet through and the gateway serving it.
    fn select_resource(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        src: IpAddr,
        dst: &Destination,
        protocol: Protocol,
    ) -> Result<(ResourceId, GatewayId), ExpectedOutcome> {
        let client = self.clients[&origin].inner();

        let Some(resource) = client.resource_by_dst(src, dst, protocol) else {
            return Err(ExpectedOutcome::Dropped);
        };
        if !client.strict_resource_filter_allows(resource, protocol)
            && !client.malicious_behaviour.ignore_resource_filters
        {
            return Err(ExpectedOutcome::Rejected {
                by: RejectionRemote::Local,
                response: RejectionResponse::Prohibited,
            });
        }
        let Some(gateway) = self.deployed_gateway_for(portal, resource) else {
            return Err(ExpectedOutcome::Dropped);
        };

        Ok((resource, gateway))
    }

    /// Why `gateway` rejects a packet from `origin` for `resource`, if it does.
    fn gateway_verdict(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        gateway: GatewayId,
        resource: ResourceId,
        src: IpAddr,
        dst: &Destination,
        protocol: Protocol,
    ) -> Option<RejectionResponse> {
        let client = self.clients[&origin].inner();

        // The Gateway lost its authorization while the client still believes it holds one:
        // it rejects this packet and tells the client to request a new authorization.
        if client.connected_resources().contains(&resource)
            && !portal.holds_gateway_authorization(origin, resource)
        {
            return Some(RejectionResponse::Prohibited);
        }

        let is_internet_resource = client.internet_resource() == Some(resource);

        if is_internet_resource && dst.ip_addr().is_some_and(is_resource_proxy) {
            return Some(RejectionResponse::Prohibited);
        }
        if is_internet_resource && dst.ip_addr().is_some_and(internet_resource_rejects) {
            return Some(RejectionResponse::Unreachable);
        }

        // Only a client that ignores resource filters sends traffic the selected resource
        // rejects. The gateway checks every route it authorized for the client instead, so
        // a broader CIDR resource on the same gateway can still permit it.
        let allowed_by_another_cidr = dst.ip_addr().is_some_and(|ip| {
            client
                .connected_cidr_resources_allowing(ip, protocol)
                .any(|cidr| self.deployed_gateway_for(portal, cidr) == Some(gateway))
        });
        if !client.strict_resource_filter_allows(resource, protocol) && !allowed_by_another_cidr {
            return Some(RejectionResponse::Prohibited);
        }

        let Destination::DomainName { name, .. } = dst else {
            return None;
        };
        let required_record = if src.is_ipv4() {
            RecordType::A
        } else {
            RecordType::AAAA
        };
        let resolves_for_source = client
            .dns_resource_resolution(resource, name)
            .is_some_and(|records| records.contains(&required_record));

        (!resolves_for_source).then_some(RejectionResponse::Unreachable)
    }

    /// The pool a packet from `origin` to `peer` travels through, asking the portal for an
    /// authorization when none fits.
    fn pool_towards_peer(
        &mut self,
        portal: &StubPortal,
        origin: ClientId,
        peer: ClientId,
        protocol: Protocol,
    ) -> Result<ResourceId, ExpectedOutcome> {
        let client = self.clients[&origin].inner();
        let authorized = client.authorized_pools_towards(peer).collect::<Vec<_>>();
        if authorized.is_empty() && client.device_pool_ids().is_empty() {
            return Err(ExpectedOutcome::Dropped);
        }

        let candidates = client.candidate_pools(protocol);
        if let Some(pool) = candidates.iter().find(|pool| authorized.contains(pool)) {
            return Ok(*pool);
        }

        let Some(pool) = portal.pick_device_pool(&candidates, peer) else {
            return Err(ExpectedOutcome::Rejected {
                by: RejectionRemote::Local,
                response: RejectionResponse::Prohibited,
            });
        };

        self.clients
            .get_mut(&origin)
            .unwrap()
            .exec_mut(|client| client.record_outbound_peer_authorization(peer, pool));
        self.apply_peer_authorization(origin, peer, pool);

        Ok(pool)
    }

    /// Installs the inbound half of a peer authorization on `peer`.
    fn apply_peer_authorization(&mut self, origin: ClientId, peer: ClientId, pool: ResourceId) {
        self.clients.get_mut(&peer).unwrap().exec_mut(|peer| {
            peer.add_inbound_peer_pool(origin, pool);
        });
    }

    fn trace_requirement(
        &self,
        origin: ClientId,
        outcome: ExpectedOutcome,
        sent_at: Instant,
    ) -> TraceRequirement {
        let known_loss = match outcome {
            ExpectedOutcome::Dropped => None,
            ExpectedOutcome::RoundTripCompleted(Route::Peer(client))
                if self.clients[&client]
                    .inner()
                    .has_reset_connections_within_ice_timeout(sent_at) =>
            {
                Some(KnownLoss::ConnectionReset)
            }
            ExpectedOutcome::RoundTripCompleted(route) => self
                .can_drop_during_rekey(origin, route.remote(), sent_at)
                .then_some(KnownLoss::WireGuardRekey),
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Local,
                ..
            } => None,
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Gateway(gateway),
                ..
            } => self
                .can_drop_during_rekey(origin, Remote::Gateway(gateway), sent_at)
                .then_some(KnownLoss::WireGuardRekey),
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Client(client),
                ..
            } => self
                .can_drop_during_rekey(origin, Remote::Client(client), sent_at)
                .then_some(KnownLoss::WireGuardRekey),
        };

        match known_loss {
            Some(loss) => TraceRequirement::ExactOrLoss(loss),
            None => TraceRequirement::Exact,
        }
    }

    fn can_drop_during_rekey(&self, origin: ClientId, remote: Remote, sent_at: Instant) -> bool {
        let client = self.clients[&origin].inner();

        match remote {
            Remote::Gateway(gateway) => client
                .last_packet_sent_to_gateway_before(gateway, sent_at)
                .is_none_or(|previous| sent_at.duration_since(previous) >= MIN_IDLE_FOR_REKEY_DROP),
            Remote::Client(remote) => client
                .last_packet_sent_to_client_before(remote, sent_at)
                .is_some_and(|previous| {
                    sent_at.duration_since(previous) >= MIN_IDLE_FOR_REKEY_DROP
                }),
        }
    }
}

/// Several helper functions to make the reference state more readable.
impl ReferenceState {
    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        self.clients
            .values()
            .flat_map(|c| c.inner().all_resource_ids())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    pub(crate) fn removable_resource_ids(&self) -> Vec<ResourceId> {
        self.all_resource_ids()
            .into_iter()
            .filter(|resource| {
                self.clients.values().all(|client| {
                    client
                        .inner()
                        .tcp_connection_tuple_to_resource(*resource)
                        .is_none()
                })
            })
            .collect()
    }

    pub(crate) fn deauthorizable_resource_ids(&self, portal: &StubPortal) -> Vec<ResourceId> {
        self.removable_resource_ids()
            .into_iter()
            .filter(|resource| {
                portal
                    .gateway_for_resource(*resource)
                    .is_some_and(|gateway| self.gateways.contains_key(gateway))
            })
            .collect()
    }

    /// Peer authorizations a receiving client can expire while the sender keeps its own.
    pub(crate) fn expirable_peer_authorizations(
        &self,
    ) -> Vec<(ClientId, ClientId, BTreeSet<ResourceId>)> {
        let mut expirable = Vec::new();

        for (peer, state) in &self.clients {
            for (client, pools) in state.inner().inbound_peer_pools() {
                let pools = pools
                    .into_iter()
                    .filter(|pool| {
                        self.clients[&client]
                            .inner()
                            .authorized_pools_towards(*peer)
                            .any(|authorized| authorized == *pool)
                    })
                    .collect::<BTreeSet<_>>();

                if pools.is_empty() {
                    continue;
                }

                expirable.push((client, *peer, pools));
            }
        }

        expirable
    }

    /// Resources a Gateway currently holds an authorization for.
    pub(crate) fn revocable_resource_ids(&self, portal: &StubPortal) -> Vec<ResourceId> {
        let authorized = portal.authorized_resources();

        self.deauthorizable_resource_ids(portal)
            .into_iter()
            .filter(|resource| authorized.contains(resource))
            .collect()
    }

    fn deployed_gateway_for(&self, portal: &StubPortal, resource: ResourceId) -> Option<GatewayId> {
        portal
            .gateway_for_resource(resource)
            .copied()
            .filter(|gateway| self.gateways.contains_key(gateway))
    }

    pub(crate) fn icmp_flows(&self) -> Vec<(FlowId, Seq)> {
        self.icmp_flows
            .iter()
            .map(|(id, flow)| (*id, flow.next_seq))
            .collect()
    }

    pub(crate) fn udp_flows(&self) -> Vec<FlowId> {
        self.udp_flows.keys().copied().collect()
    }

    pub(crate) fn ipv4_cidr_resource_dsts(&self) -> Vec<(ClientId, Ipv4Network, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .ipv4_cidr_resource_dsts()
                    .into_iter()
                    .map(|(ip, filters)| (*id, ip, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_v4_domains(&self) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_v4_domains()
                    .into_iter()
                    .map(|(domain, filters)| (*id, domain, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<(ClientId, Ipv4Addr)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_ip4_for_non_resources(global_dns_records)
                    .into_iter()
                    .map(|ip| (*id, ip))
            })
            .collect()
    }

    pub(crate) fn ipv6_cidr_resource_dsts(&self) -> Vec<(ClientId, Ipv6Network, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .ipv6_cidr_resource_dsts()
                    .into_iter()
                    .map(|(ip, filters)| (*id, ip, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains(&self) -> Vec<(ClientId, DomainName, Vec<Filter>)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_v6_domains()
                    .into_iter()
                    .map(|(domain, filters)| (*id, domain, filters))
            })
            .collect()
    }

    pub(crate) fn resolved_ip6_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
    ) -> Vec<(ClientId, Ipv6Addr)> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                c.inner()
                    .resolved_ip6_for_non_resources(global_dns_records)
                    .into_iter()
                    .map(|ip| (*id, ip))
            })
            .collect()
    }

    pub(crate) fn dns_resource_domains(&self) -> Vec<DomainName> {
        // We may have multiple gateways in a site, so we need to dedup.
        let unique_domains = self
            .gateways
            .values()
            .flat_map(|gateway| gateway.inner().dns_records().domains_iter())
            .chain(self.global_dns_records.domains_iter())
            .chain(
                self.clients
                    .values()
                    .flat_map(|client| client.inner().dns_records.keys().cloned()),
            )
            .filter(|domain| {
                self.clients.values().any(|client| {
                    client
                        .inner()
                        .dns_resource_by_domain(domain, |_| true, |_| true)
                        .is_some()
                })
            })
            .collect::<BTreeSet<_>>();

        Vec::from_iter(unique_domains)
    }

    pub(crate) fn reachable_dns_servers(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, dns::Upstream)> {
        let upstream_do53 = portal.upstream_do53();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                client
                    .inner()
                    .expected_dns_servers(portal.upstream_do53(), portal.upstream_doh())
                    .into_iter()
                    .filter(|s| match s {
                        tunnel_proto::dns::Upstream::Do53 {
                            server: SocketAddr::V4(_),
                        } => client.ip4.is_some(),
                        tunnel_proto::dns::Upstream::Do53 {
                            server: SocketAddr::V6(_),
                        } => client.ip6.is_some(),
                        tunnel_proto::dns::Upstream::DoH { .. } => true,
                    })
                    .filter(|server| {
                        if upstream_do53.is_empty() {
                            return true;
                        }

                        client
                            .inner()
                            .upstream_dns_server_via_resource(server)
                            .is_none_or(|resource| {
                                portal
                                    .gateway_for_resource(resource)
                                    .is_some_and(|gateway| self.gateways.contains_key(gateway))
                            })
                    })
                    .map(move |server| (*client_id, server))
            })
            .collect()
    }

    pub(crate) fn all_domains(&self) -> Vec<(ClientId, DomainName, Vec<RecordType>)> {
        fn domains_and_rtypes(
            records: &DnsRecords,
        ) -> impl Iterator<Item = (DomainName, Vec<RecordType>)> {
            records
                .domains_iter()
                .map(move |d| (d.clone(), records.domain_rtypes(&d).into_iter().collect()))
        }

        self.clients
            .iter()
            .flat_map(move |(client_id, client)| {
                // Get domains from all gateways that this client can reach
                let mut unique_domains = iter::empty()
                    .chain(
                        self.gateways
                            .values()
                            .flat_map(|g| domains_and_rtypes(g.inner().dns_records())),
                    )
                    .chain(domains_and_rtypes(&self.global_dns_records))
                    .collect::<BTreeMap<_, _>>();

                // Add domains from client's own dns_records
                for (domain, rtypes) in &client.inner().dns_records {
                    unique_domains
                        .entry(domain.clone())
                        .or_default()
                        .extend(rtypes.iter().copied());
                }

                unique_domains
                    .into_iter()
                    .filter(|(_, rtypes)| !rtypes.is_empty())
                    .map(move |(domain, rtypes)| (*client_id, domain, rtypes))
            })
            .collect()
    }

    pub(crate) fn resources_unknown_to_all_clients(
        &self,
        portal: &StubPortal,
    ) -> Vec<client::Resource> {
        portal
            .all_resources()
            .into_iter()
            .filter(|resource| {
                self.clients
                    .values()
                    .all(|client| !client.inner().has_resource(resource.id()))
            })
            .collect()
    }

    pub(crate) fn editable_resources_on_any_client(
        &self,
        portal: &StubPortal,
    ) -> Vec<client::Resource> {
        portal
            .all_resources()
            .into_iter()
            .filter(|resource| {
                let is_editable = match resource {
                    client::Resource::Cidr(_) => true,
                    client::Resource::Dns(_) => true,
                    client::Resource::DevicePool(_) => true,
                    client::Resource::Internet(_) => false,
                };

                is_editable
                    && self
                        .clients
                        .values()
                        .any(|client| client.inner().has_resource(resource.id()))
            })
            .collect()
    }

    pub(crate) fn dns_resources_on_any_client(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, client::DnsResource)> {
        let dns_resources = portal
            .all_resources()
            .into_iter()
            .filter_map(|r| match r {
                client::Resource::Dns(r) => Some(r),
                client::Resource::Cidr(_) => None,
                client::Resource::Internet(_) => None,
                client::Resource::DevicePool(_) => None,
            })
            .collect::<Vec<_>>();

        self.clients
            .iter()
            .flat_map(|(client_id, client)| {
                dns_resources
                    .iter()
                    .filter(|r| client.inner().has_resource(r.id))
                    .map(move |r| (*client_id, r.clone()))
            })
            .collect()
    }

    pub(crate) fn connected_gateway_ipv4_ips(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, Ipv4Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = portal.gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(gateway)?;

                        Some((*id, gateway_host.inner().tunnel_ip4.into()))
                    })
                    .unique()
            })
            .collect()
    }

    pub(crate) fn connected_gateway_ipv6_ips(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, Ipv6Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = portal.gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(gateway)?;

                        Some((*id, gateway_host.inner().tunnel_ip6.into()))
                    })
                    .unique()
            })
            .collect()
    }

    pub(crate) fn all_client_ids(&self) -> Vec<ClientId> {
        self.clients.keys().copied().collect()
    }

    /// Returns every listed pool that some client holds.
    pub(crate) fn listed_device_pool_ids_on_any_client(
        &self,
        portal: &StubPortal,
    ) -> Vec<ResourceId> {
        portal
            .listed_pool_ids()
            .into_iter()
            .filter(|pool| self.clients.values().any(|c| c.inner().has_resource(*pool)))
            .collect()
    }

    /// Generates `(src_client_id, dst_ip)` tuples for both tunnel IP families of every online
    /// client `src_client_id` may reach through a device pool it holds, paired with the
    /// pool filters that authorize the route.
    pub(crate) fn pool_routed_other_client_tun_ips(
        &self,
        portal: &StubPortal,
    ) -> Vec<(ClientId, IpAddr, Vec<Filter>)> {
        let online_ips_by_id = self
            .clients
            .iter()
            .map(|(id, c)| {
                let inner = c.inner();
                (
                    *id,
                    (IpAddr::V4(inner.tunnel_ip4), IpAddr::V6(inner.tunnel_ip6)),
                )
            })
            .collect::<BTreeMap<_, _>>();

        self.clients
            .iter()
            .flat_map(|(src_id, src_client)| {
                let src_id = *src_id;
                let online_ips_by_id = &online_ips_by_id;

                src_client
                    .inner()
                    .all_resources()
                    .into_iter()
                    .filter_map(|r| match r {
                        client::Resource::DevicePool(p) => Some((p.id, p.filters)),
                        client::Resource::Dns(_) => None,
                        client::Resource::Cidr(_) => None,
                        client::Resource::Internet(_) => None,
                    })
                    .filter(|(_, filters)| pool_filters_allow_icmp_or_udp(filters))
                    .flat_map(move |(pool, filters)| {
                        portal
                            .pool_members(pool)
                            .into_iter()
                            .filter(move |member| *member != src_id)
                            .filter_map(move |member| online_ips_by_id.get(&member).copied())
                            .flat_map(|(v4, v6)| [v4, v6])
                            .map(move |ip| (src_id, ip, filters.clone()))
                    })
            })
            .collect()
    }

    /// Returns every client's tunnel IPs mapped to its identifier.
    fn client_ip_to_id(&self) -> BTreeMap<IpAddr, ClientId> {
        self.clients
            .iter()
            .flat_map(|(id, c)| {
                let ip4 = IpAddr::V4(c.inner().tunnel_ip4);
                let ip6 = IpAddr::V6(c.inner().tunnel_ip6);
                [(ip4, *id), (ip6, *id)]
            })
            .collect()
    }

    fn deploy_new_relays(&mut self, new_relays: &BTreeMap<RelayId, Host<u64>>) {
        for (_, relay) in self
            .relays
            .extract_if(.., |relay_id, _| !new_relays.contains_key(relay_id))
        {
            self.network.remove_host(&relay);
        }

        for (rid, new_relay) in new_relays {
            if self.relays.contains_key(rid) {
                continue;
            }

            self.relays.insert(*rid, new_relay.clone());
            let added = self.network.add_host(*rid, new_relay);
            debug_assert!(added);
        }
    }

    fn reboot_relays_while_partitioned(&mut self, new_relays: &BTreeMap<RelayId, Host<u64>>) {
        for relay in self.relays.values() {
            self.network.remove_host(relay);
        }
        self.relays.clear();

        for (rid, new_relay) in new_relays {
            self.relays.insert(*rid, new_relay.clone());
            let added = self.network.add_host(*rid, new_relay);
            debug_assert!(added);
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct PrivateKey(pub [u8; 32]);

impl From<PrivateKey> for StaticSecret {
    fn from(key: PrivateKey) -> Self {
        StaticSecret::from(key.0)
    }
}

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("PrivateKey")
            .field(&hex::encode(self.0))
            .finish()
    }
}

fn pool_filters_allow_icmp_or_udp(filters: &[Filter]) -> bool {
    filters.is_empty()
        || filters.iter().any(|filter| match filter {
            Filter::Icmp => true,
            Filter::Udp(_) => true,
            Filter::Tcp(_) => false,
        })
}
