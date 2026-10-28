use super::dns_records::DnsRecords;
use super::probe::{
    Answer, DNS_NAT_SESSION_TTL, ExpectedOutcome, ExpectedProbe, FlowId, IcmpFlow, KnownLoss,
    ProbeId, ProbeRequest, RejectionRemote, RejectionResponse, Remote, Route, TcpFlow,
    TraceRequirement, UdpFlow,
};
use super::{ref_client::*, ref_gateway::*, sim_net::*, stub_portal::StubPortal, transition::*};
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, StaticSecret};
use dns_types::{DomainName, RecordType, prelude::*};
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

// TODO: Remove with classic ICE.
const MIN_IDLE_FOR_REKEY_DROP: Duration = Duration::from_secs(180 - 10);

/// How long after a relay frees up its ports until no node ignores it anymore: how long a node
/// ignores a relay that failed its allocation, plus a margin.
const RELAY_RECOVERY: Duration = Duration::from_secs(60 + 5);

/// How far from its expiry we keep the state of an idle UDP or ICMP flow out of doubt: the Gateway
/// and the peers count from packets that may reach them later than the reference sends them.
const FLOW_EXPIRY_MARGIN: Duration = Duration::from_secs(10);

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
#[derive(Debug, Clone)]
pub struct ReferenceState {
    pub(crate) clients: BTreeMap<ClientId, Host<RefClient>>,
    pub(crate) gateways: BTreeMap<GatewayId, Host<RefGateway>>,
    pub(crate) relays: BTreeMap<RelayId, Host<u64>>,
    /// Relays that answer new allocations with `508 Insufficient Capacity`.
    pub(crate) exhausted_relays: BTreeSet<RelayId>,
    /// Relays that accept allocations again while nodes may still ignore them, and since when.
    pub(crate) recovering_relays: BTreeMap<RelayId, Instant>,
    /// Whether a node may have no relay left because every relay it tried rejected its allocation.
    pub(crate) node_may_lack_relays: bool,

    /// All IP addresses a domain resolves to in our test.
    ///
    /// This is used to e.g. mock DNS resolution on the gateway.
    pub(crate) global_dns_records: DnsRecords,
    /// The names that DNS resource addresses, records and queried domains are derived from.
    pub(crate) domain_tree: Vec<DomainName>,

    /// The ports each DNS Resource domain serves TCP on.
    pub(crate) tcp_services: BTreeMap<DomainName, BTreeSet<u16>>,

    pub(crate) network: RoutingTable,

    pub(crate) expected_probes: BTreeMap<ProbeId, ExpectedProbe>,

    pub(crate) icmp_flows: BTreeMap<FlowId, IcmpFlow>,
    pub(crate) udp_flows: BTreeMap<FlowId, UdpFlow>,
    pub(crate) tcp_flows: BTreeMap<FlowId, TcpFlow>,
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
        domain_tree: Vec<DomainName>,
        tcp_services: BTreeMap<DomainName, BTreeSet<u16>>,
        network: RoutingTable,
    ) -> Self {
        Self {
            clients,
            gateways,
            relays,
            exhausted_relays: Default::default(),
            recovering_relays: Default::default(),
            node_may_lack_relays: false,
            global_dns_records,
            domain_tree,
            tcp_services,
            network,
            expected_probes: Default::default(),
            icmp_flows: Default::default(),
            udp_flows: Default::default(),
            tcp_flows: Default::default(),
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

        // TODO: Remove with classic ICE.
        let iceless = portal.iceless();
        for _ in self.icmp_flows.extract_if(.., |_, flow| {
            !transition.retains_flow(flow.client_id, flow.route, iceless)
        }) {}
        for _ in self.udp_flows.extract_if(.., |_, flow| {
            !transition.retains_flow(flow.client_id, flow.route, iceless)
        }) {}
        for _ in self
            .tcp_flows
            .extract_if(.., |_, flow| !transition.retains_tcp_flow(flow, iceless))
        {}
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
                let gateways = &self.gateways;
                let resolve = |gateway: Option<GatewayId>, domain: &DomainName| match gateway {
                    Some(gateway) => gateways[&gateway]
                        .inner()
                        .resolve(domain, global_dns_records)
                        .map(|record| record.rtype())
                        .collect(),
                    None => global_dns_records.domain_rtypes(domain),
                };

                for (client_id, query) in queries {
                    let client = self.clients[client_id].inner();
                    let gateway = client
                        .is_site_specific_dns_query(query)
                        .or_else(|| client.dns_query_via_resource(query, upstream_do53))
                        .and_then(|resource| self.select_gateway(portal, *client_id, resource));
                    let routes = gateway.map(|gid| &gateways[&gid].inner().routes);
                    let listing = is_device_listing_query(query).then(|| {
                        portal.browse_device_domain(&query.domain, &client.device_pool_ids())
                    });

                    self.clients.get_mut(client_id).unwrap().exec_mut(|c| {
                        c.on_dns_query(query, gateway, upstream_do53, resolve, routes);

                        if let Some(listing) = listing {
                            c.expect_device_listing(query, listing);
                        }
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
                if let Some(resumed) =
                    self.resumed_icmp_flow(*client_id, *src, dst, *identifier, now)
                {
                    tracing::debug!(flow = ?resumed, "Resuming expired flow");
                    self.icmp_flows.remove(&resumed);
                }

                let request = ProbeRequest::Icmp {
                    src: *src,
                    dst: dst.clone(),
                    seq: *seq,
                    identifier: *identifier,
                };
                let (outcome, authorization) = self.verdict(portal, *client_id, &request, None);
                self.record_probe(
                    portal,
                    *probe_id,
                    *client_id,
                    request,
                    now,
                    outcome,
                    authorization,
                );

                match outcome {
                    ExpectedOutcome::RoundTripCompleted(route, _) => {
                        let flow = IcmpFlow {
                            client_id: *client_id,
                            src: *src,
                            dst: dst.clone(),
                            identifier: *identifier,
                            next_seq: Seq(seq.0.wrapping_add(1)),
                            route,
                            last_round_trip: now,
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

                let request = ProbeRequest::Icmp {
                    src: flow.src,
                    dst: flow.dst,
                    seq: *seq,
                    identifier: flow.identifier,
                };

                match self.record_flow_probe(
                    portal,
                    *probe_id,
                    flow.client_id,
                    flow.route,
                    request,
                    now,
                ) {
                    ExpectedOutcome::RoundTripCompleted { .. } => {
                        if let Some(flow) = self.icmp_flows.get_mut(flow_id) {
                            flow.last_round_trip = now;
                        }
                    }
                    ExpectedOutcome::Dropped => {
                        panic!("reused ICMP route must complete a round trip")
                    }
                    ExpectedOutcome::Rejected {
                        by: RejectionRemote::Gateway(_),
                        ..
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
                if let Some(resumed) =
                    self.resumed_udp_flow(*client_id, *src, dst, (*sport, *dport), now)
                {
                    tracing::debug!(flow = ?resumed, "Resuming expired flow");
                    self.udp_flows.remove(&resumed);
                }

                let request = ProbeRequest::Udp {
                    src: *src,
                    dst: dst.clone(),
                    sport: *sport,
                    dport: *dport,
                };
                let (outcome, authorization) = self.verdict(portal, *client_id, &request, None);
                self.record_probe(
                    portal,
                    *probe_id,
                    *client_id,
                    request,
                    now,
                    outcome,
                    authorization,
                );

                match outcome {
                    ExpectedOutcome::RoundTripCompleted(route, _) => {
                        let flow = UdpFlow {
                            client_id: *client_id,
                            src: *src,
                            dst: dst.clone(),
                            sport: *sport,
                            dport: *dport,
                            route,
                            last_round_trip: now,
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

                let request = ProbeRequest::Udp {
                    src: flow.src,
                    dst: flow.dst,
                    sport: flow.sport,
                    dport: flow.dport,
                };

                match self.record_flow_probe(
                    portal,
                    *probe_id,
                    flow.client_id,
                    flow.route,
                    request,
                    now,
                ) {
                    ExpectedOutcome::RoundTripCompleted { .. } => {
                        if let Some(flow) = self.udp_flows.get_mut(flow_id) {
                            flow.last_round_trip = now;
                        }
                    }
                    ExpectedOutcome::Dropped => {
                        panic!("reused UDP route must complete a round trip")
                    }
                    ExpectedOutcome::Rejected {
                        by: RejectionRemote::Gateway(_),
                        ..
                    } => {}
                    ExpectedOutcome::Rejected { .. } => {
                        panic!("reused UDP route must complete a round trip")
                    }
                }
            }
            Transition::ConnectTcp {
                flow_id,
                client_id,
                src,
                dst,
                sport,
                dport,
                probe_id,
            } => {
                let request = ProbeRequest::Tcp {
                    src: *src,
                    dst: dst.clone(),
                    sport: *sport,
                    dport: *dport,
                    write_len: None,
                };
                let (outcome, authorization) = self.verdict(portal, *client_id, &request, None);
                let outcome = match outcome {
                    ExpectedOutcome::RoundTripCompleted(route, _)
                        if self.serves_tcp(dst, *dport) =>
                    {
                        let flow = TcpFlow {
                            client_id: *client_id,
                            src: *src,
                            dst: dst.clone(),
                            sport: *sport,
                            dport: *dport,
                            route,
                        };
                        let previous = self.tcp_flows.insert(*flow_id, flow);
                        assert!(previous.is_none(), "TCP flow IDs must be unique");

                        outcome
                    }
                    ExpectedOutcome::RoundTripCompleted(route, _) => {
                        ExpectedOutcome::RoundTripCompleted(route, Answer::Reset)
                    }
                    ExpectedOutcome::Dropped => outcome,
                    ExpectedOutcome::Rejected { .. } => outcome,
                };
                self.record_probe(
                    portal,
                    *probe_id,
                    *client_id,
                    request,
                    now,
                    outcome,
                    authorization,
                );
            }
            Transition::SendTcpData {
                flow_id,
                len,
                probe_id,
                ..
            } => {
                let flow = self
                    .tcp_flows
                    .remove(flow_id)
                    .expect("written TCP flow must exist");
                let request = ProbeRequest::Tcp {
                    src: flow.src,
                    dst: flow.dst.clone(),
                    sport: flow.sport,
                    dport: flow.dport,
                    write_len: Some(*len),
                };
                let (outcome, authorization) =
                    self.verdict(portal, flow.client_id, &request, Some(flow.route));
                let outcome = match outcome {
                    ExpectedOutcome::RoundTripCompleted(route, _)
                        if route.remote() == flow.route.remote() =>
                    {
                        self.tcp_flows.insert(
                            *flow_id,
                            TcpFlow {
                                route,
                                ..flow.clone()
                            },
                        );

                        ExpectedOutcome::RoundTripCompleted(route, Answer::WriteEchoed)
                    }
                    ExpectedOutcome::RoundTripCompleted(route, _) => {
                        ExpectedOutcome::RoundTripCompleted(route, Answer::WriteReset)
                    }
                    ExpectedOutcome::Dropped => outcome,
                    ExpectedOutcome::Rejected { .. } => outcome,
                };
                self.record_probe(
                    portal,
                    *probe_id,
                    flow.client_id,
                    request,
                    now,
                    outcome,
                    authorization,
                );
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
                self.node_may_lack_relays |= self.no_relay_accepts_allocations();

                // TODO: Remove with classic ICE: a roam then never resets connections.
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
                    // TODO: Remove with classic ICE; the instant only anchors the loss window.
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
                self.reboot_relays_while_partitioned(new_relays, now)
            }
            Transition::ExhaustRelayPorts(relay) => {
                self.exhausted_relays.insert(*relay);
                self.recovering_relays.remove(relay);
            }
            Transition::FreeRelayPorts(relay) => {
                self.exhausted_relays.remove(relay);
                self.recovering_relays.insert(*relay, now);
            }
            Transition::Idle { duration } => {
                for _ in self.recovering_relays.extract_if(.., |_, freed_at| {
                    now + *duration >= *freed_at + RELAY_RECOVERY
                }) {}
            }
            Transition::PartitionRelaysFromPortal => {
                self.node_may_lack_relays = !self.has_healthy_relay();

                // TODO: Remove with classic ICE.
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
                            c.fail_connections_to_gateways(&unreachable_gateways, now);
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
                self.node_may_lack_relays |= self.no_relay_accepts_allocations();

                self.clients
                    .get_mut(client_id)
                    .unwrap()
                    .exec_mut(|c| c.restart(*key, now));

                for (_, peer) in self.clients.iter_mut().filter(|(id, _)| *id != client_id) {
                    peer.exec_mut(|c| c.forget_peer_authorizations(*client_id));
                }
            }
            Transition::UpdateDnsRecords { domain, records } => {
                self.global_dns_records
                    .replace(domain.clone(), records.clone());
            }
            Transition::CrashClient { client_id, key } => {
                self.node_may_lack_relays |= self.no_relay_accepts_allocations();

                // Applications resolve their domains again once the cached records are gone.
                self.clients.get_mut(client_id).unwrap().exec_mut(|c| {
                    c.restart(*key, now);
                    c.dns_records.clear();
                });

                // Without a `goodbye`, the peers lose their connections to the crashed client, and
                // their authorizations towards it with them.
                for (_, peer) in self.clients.iter_mut().filter(|(id, _)| *id != client_id) {
                    peer.exec_mut(|c| c.forget_peer_authorizations(*client_id));
                }
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
            for _ in self.tcp_flows.extract_if(.., |_, flow| {
                flow.client_id == closed.client
                    && flow.route.remote() == Remote::Gateway(closed.gateway)
            }) {}
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

    /// Follows a packet on a flow the client keeps sending on, bound to the route it took
    /// when it was created.
    fn record_flow_probe(
        &mut self,
        portal: &StubPortal,
        id: ProbeId,
        origin: ClientId,
        route: Route,
        request: ProbeRequest,
        sent_at: Instant,
    ) -> ExpectedOutcome {
        let (outcome, authorization) = match route {
            Route::Resource { resource, gateway } => self.resource_verdict(
                portal,
                origin,
                resource,
                gateway,
                request.source(),
                request.destination(),
                request.protocol(),
                true,
            ),
            Route::Gateway(_) => (
                ExpectedOutcome::RoundTripCompleted(route, Answer::Echo),
                None,
            ),
            // A retained flow completes its round trip; asking the portal again only refreshes
            // the authorization a peer that reconnected since took from us.
            Route::Peer(peer) => {
                let authorization =
                    match self.pool_towards_peer(portal, origin, peer, request.protocol()) {
                        Ok(PoolTowardsPeer::Granted(pool)) => {
                            Some(Authorization::Peer { peer, pool })
                        }
                        Ok(PoolTowardsPeer::Held(_)) => None,
                        Err(_) => None,
                    };

                (
                    ExpectedOutcome::RoundTripCompleted(route, Answer::Echo),
                    authorization,
                )
            }
        };
        self.record_probe(portal, id, origin, request, sent_at, outcome, authorization);

        outcome
    }

    /// Records that `origin` sent `request`, the authorization it holds afterwards and the
    /// outcome to expect.
    fn record_probe(
        &mut self,
        portal: &StubPortal,
        id: ProbeId,
        origin: ClientId,
        request: ProbeRequest,
        sent_at: Instant,
        outcome: ExpectedOutcome,
        authorization: Option<Authorization>,
    ) {
        self.record_authorization(origin, authorization);
        self.clients
            .get_mut(&origin)
            .unwrap()
            .exec_mut(|client| client.note_sent(outcome.remote(), sent_at));

        let trace_requirement = self.trace_requirement(portal, origin, outcome, sent_at);
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
    }

    fn serves_tcp(&self, dst: &Destination, dport: DPort) -> bool {
        match dst {
            Destination::DomainName { name, .. } => self
                .tcp_services
                .get(name)
                .is_some_and(|ports| ports.contains(&dport.0)),
            Destination::IpAddr(_) => false,
        }
    }

    /// Follows a packet from `origin` to its destination: the client picks where it goes,
    /// the portal supplies the gateway or pool, and the remote end accepts or rejects it.
    ///
    /// `established` is the route of the TCP flow the packet belongs to, if any.
    fn verdict(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        request: &ProbeRequest,
        established: Option<Route>,
    ) -> (ExpectedOutcome, Option<Authorization>) {
        let client = self.clients[&origin].inner();
        let (src, dst, protocol) = (request.source(), request.destination(), request.protocol());

        if dst.ip_addr().is_some_and(|ip| ip.is_multicast()) {
            return (ExpectedOutcome::Dropped, None);
        }
        if dst
            .ip_addr()
            .is_some_and(|ip| client.tunnel_ip_for(ip) == ip)
        {
            return (ExpectedOutcome::Dropped, None);
        }
        if let Some(ip) = dst.ip_addr().filter(|ip| tunnel_proto::is_peer(*ip)) {
            let connected_gateway = portal.gateway_by_ip(ip).filter(|gateway| {
                client
                    .connected_resources()
                    .any(|resource| client.gateway_for_resource(resource) == Some(*gateway))
            });
            if let Some(gateway) = connected_gateway {
                return (
                    ExpectedOutcome::RoundTripCompleted(Route::Gateway(gateway), Answer::Echo),
                    None,
                );
            }

            return self.peer_verdict(portal, origin, ip, protocol);
        }

        let Some(resource) = client.resource_by_dst(src, dst, protocol) else {
            return (ExpectedOutcome::Dropped, None);
        };
        if !client.strict_resource_filter_allows(resource, protocol)
            && !client.malicious_behaviour.ignore_resource_filters
        {
            return (
                ExpectedOutcome::Rejected {
                    by: RejectionRemote::Local,
                    response: RejectionResponse::Prohibited,
                },
                None,
            );
        }
        let Some(gateway) = self.select_gateway(portal, origin, resource) else {
            return (ExpectedOutcome::Dropped, None);
        };

        let established = established == Some(Route::Resource { resource, gateway });

        self.resource_verdict(
            portal,
            origin,
            resource,
            gateway,
            src,
            dst,
            protocol,
            established,
        )
    }

    /// Whether `origin` reaches the peer client at `ip`, which takes an authorization on both
    /// sides.
    fn peer_verdict(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        ip: IpAddr,
        protocol: Protocol,
    ) -> (ExpectedOutcome, Option<Authorization>) {
        let client = self.clients[&origin].inner();

        // The portal answers a request for a tunnel IP that no client holds with "not
        // found", and connlib turns that into an ICMP error. It sends the same error
        // without asking when none of its pools permits the protocol, and has no route
        // at all without a pool.
        let Some(peer) = self.client_ip_to_id().get(&ip).copied() else {
            if client.device_pool_ids().is_empty() {
                return (ExpectedOutcome::Dropped, None);
            }

            return (
                ExpectedOutcome::Rejected {
                    by: RejectionRemote::Local,
                    response: RejectionResponse::Prohibited,
                },
                None,
            );
        };
        let (pool, granted) = match self.pool_towards_peer(portal, origin, peer, protocol) {
            Ok(PoolTowardsPeer::Held(pool)) => (pool, false),
            Ok(PoolTowardsPeer::Granted(pool)) => (pool, true),
            Err(outcome) => return (outcome, None),
        };
        let authorization = Authorization::Peer { peer, pool };

        // The receiver judges the packet by the inbound authorizations it holds once the
        // granted one is installed.
        let receiver = self.clients[&peer].inner();
        let inbound_allows = receiver.inbound_peer_filter_allows(origin, protocol)
            || (granted && receiver.strict_resource_filter_allows(pool, protocol));
        if inbound_allows {
            return (
                ExpectedOutcome::RoundTripCompleted(Route::Peer(peer), Answer::Echo),
                granted.then_some(authorization),
            );
        }

        let no_authorization = !receiver.has_inbound_peer_authorization(origin)
            || receiver.rejected_inbound_peer_filter_allows(origin, protocol);
        let requests_authorization = granted
            || (no_authorization && !client.malicious_behaviour.ignore_no_authorization_events);

        (
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Client(peer),
                response: RejectionResponse::Prohibited,
            },
            requests_authorization.then_some(authorization),
        )
    }

    /// The Gateway's verdict for a packet to `resource` through `gateway`, which the client
    /// holds access to afterwards either way.
    fn resource_verdict(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        resource: ResourceId,
        gateway: GatewayId,
        src: IpAddr,
        dst: &Destination,
        protocol: Protocol,
        established: bool,
    ) -> (ExpectedOutcome, Option<Authorization>) {
        let resolutions = match dst {
            Destination::DomainName { .. } => {
                let resolver = self.gateways[&gateway].inner();
                let records = &self.global_dns_records;

                self.clients[&origin]
                    .inner()
                    .dns_resource_resolutions_on_connect(resource, |domain| {
                        resolver
                            .resolve(domain, records)
                            .map(|record| record.rtype())
                            .collect()
                    })
            }
            Destination::IpAddr(_) => BTreeMap::new(),
        };
        let rejection = self.gateway_verdict(
            portal,
            origin,
            gateway,
            resource,
            src,
            dst,
            protocol,
            &resolutions,
            established,
        );
        let outcome = match rejection {
            Some(response) => ExpectedOutcome::Rejected {
                by: RejectionRemote::Gateway(gateway),
                response,
            },
            None => ExpectedOutcome::RoundTripCompleted(
                Route::Resource { resource, gateway },
                Answer::Echo,
            ),
        };

        let authorization = Authorization::Resource {
            resource,
            gateway,
            resolutions,
        };

        (outcome, Some(authorization))
    }

    /// Records the authorization `origin` holds after its packet.
    fn record_authorization(&mut self, origin: ClientId, authorization: Option<Authorization>) {
        match authorization {
            Some(Authorization::Resource {
                resource,
                gateway,
                resolutions,
            }) => {
                self.clients.get_mut(&origin).unwrap().exec_mut(|client| {
                    client.add_dns_resource_resolutions(resource, resolutions);
                    client.connect_to_resource(resource, gateway);
                });
            }
            Some(Authorization::Peer { peer, pool }) => {
                self.clients
                    .get_mut(&origin)
                    .unwrap()
                    .exec_mut(|client| client.record_outbound_peer_authorization(peer, pool));
                self.clients
                    .get_mut(&peer)
                    .unwrap()
                    .exec_mut(|receiver| receiver.add_inbound_peer_pool(origin, pool));
            }
            None => {}
        }
    }

    /// The Gateway the portal hands `origin` for `resource`.
    fn select_gateway(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        resource: ResourceId,
    ) -> Option<GatewayId> {
        let site = portal.site_for_resource(resource)?;
        let gateway = self.clients[&origin]
            .inner()
            .preferred_gateway(site)
            .unwrap_or_else(|| portal.load_balanced_gateway(origin, site));

        Some(gateway)
    }

    /// Why `gateway` rejects a packet from `origin` for `resource`, if it does.
    ///
    /// `resolutions` are the records the Gateway resolves the resource's domains to as the
    /// client connects, ahead of the ones the client already holds.
    ///
    /// An `established` flow keeps translating through the NAT session the Gateway created for
    /// it, whatever the domain resolves to since.
    fn gateway_verdict(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        gateway: GatewayId,
        resource: ResourceId,
        src: IpAddr,
        dst: &Destination,
        protocol: Protocol,
        resolutions: &BTreeMap<DomainName, BTreeSet<RecordType>>,
        established: bool,
    ) -> Option<RejectionResponse> {
        let client = self.clients[&origin].inner();

        // The gateway checks every CIDR route it still authorizes for the client, so another
        // CIDR resource on the same gateway can permit traffic the selected resource does not.
        let allowed_by_another_cidr = dst.ip_addr().is_some_and(|ip| {
            portal.gateway_cidr_authorization_allows(origin, gateway, ip, protocol)
        });

        // The Gateway lost its authorization while the client still believes it holds one:
        // it rejects this packet and tells the client to request a new authorization.
        if client.connected_resources().contains(&resource)
            && !portal.holds_gateway_authorization(origin, resource)
            && !allowed_by_another_cidr
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

        if !client.strict_resource_filter_allows(resource, protocol) && !allowed_by_another_cidr {
            return Some(RejectionResponse::Prohibited);
        }

        let Destination::DomainName { name, .. } = dst else {
            return None;
        };
        if established {
            return None;
        }
        let resolves_for_source = resolutions
            .get(name)
            .or_else(|| client.dns_resource_resolution(resource, name))
            .is_some_and(|records| records.contains(&address_record_type(src)));

        (!resolves_for_source).then_some(RejectionResponse::Unreachable)
    }

    /// The pool a packet from `origin` to `peer` travels through, which the portal grants
    /// when the client holds none that fits.
    fn pool_towards_peer(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        peer: ClientId,
        protocol: Protocol,
    ) -> Result<PoolTowardsPeer, ExpectedOutcome> {
        let client = self.clients[&origin].inner();
        let authorized = client.authorized_pools_towards(peer).collect::<Vec<_>>();
        if authorized.is_empty() && client.device_pool_ids().is_empty() {
            return Err(ExpectedOutcome::Dropped);
        }

        let candidates = client.candidate_pools(protocol);
        if let Some(pool) = candidates.iter().find(|pool| authorized.contains(pool)) {
            return Ok(PoolTowardsPeer::Held(*pool));
        }

        let Some(pool) = portal.pick_device_pool(&candidates, peer) else {
            return Err(ExpectedOutcome::Rejected {
                by: RejectionRemote::Local,
                response: RejectionResponse::Prohibited,
            });
        };

        Ok(PoolTowardsPeer::Granted(pool))
    }

    // TODO: Remove with classic ICE: every trace is then exact.
    fn trace_requirement(
        &self,
        portal: &StubPortal,
        origin: ClientId,
        outcome: ExpectedOutcome,
        sent_at: Instant,
    ) -> TraceRequirement {
        if portal.iceless() {
            return TraceRequirement::Exact;
        }

        let Some(remote) = outcome.remote() else {
            return TraceRequirement::Exact;
        };
        let known_loss = match remote {
            Remote::Client(client)
                if self.clients[&client]
                    .inner()
                    .has_reset_connections_within_ice_timeout(sent_at) =>
            {
                Some(KnownLoss::ConnectionReset)
            }
            Remote::Client(_) => self
                .can_drop_during_rekey(origin, remote, sent_at)
                .then_some(KnownLoss::WireGuardRekey),
            Remote::Gateway(_) => self
                .can_drop_during_rekey(origin, remote, sent_at)
                .then_some(KnownLoss::WireGuardRekey),
        };

        match known_loss {
            Some(loss) => TraceRequirement::ExactOrLoss(loss),
            None => TraceRequirement::Exact,
        }
    }

    // TODO: Remove with classic ICE.
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

    pub(crate) fn deauthorizable_resource_ids(&self, portal: &StubPortal) -> Vec<ResourceId> {
        self.all_resource_ids()
            .into_iter()
            .filter(|resource| portal.site_for_resource(*resource).is_some())
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

    /// The ICMP flows whose state the Gateway and the peers still hold.
    pub(crate) fn icmp_flows(&self, now: Instant) -> Vec<(FlowId, Seq)> {
        self.icmp_flows
            .iter()
            .filter(|(_, flow)| is_held(flow.last_round_trip, now))
            .map(|(id, flow)| (*id, flow.next_seq))
            .collect()
    }

    /// The UDP flows whose state the Gateway and the peers still hold.
    pub(crate) fn udp_flows(&self, now: Instant) -> Vec<FlowId> {
        self.udp_flows
            .iter()
            .filter(|(_, flow)| is_held(flow.last_round_trip, now))
            .map(|(id, _)| *id)
            .collect()
    }

    /// The ICMP flows whose state the Gateway and the peers dropped, which a new flow can resume.
    pub(crate) fn expired_icmp_flows(&self, now: Instant) -> Vec<&IcmpFlow> {
        self.icmp_flows
            .values()
            .filter(|flow| has_expired(flow.last_round_trip, now))
            .filter(|flow| self.can_send(flow.client_id, flow.src, &flow.dst))
            .collect()
    }

    /// The UDP flows whose state the Gateway and the peers dropped, which a new flow can resume.
    pub(crate) fn expired_udp_flows(&self, now: Instant) -> Vec<&UdpFlow> {
        self.udp_flows
            .values()
            .filter(|flow| has_expired(flow.last_round_trip, now))
            .filter(|flow| self.can_send(flow.client_id, flow.src, &flow.dst))
            .collect()
    }

    /// The expired ICMP flow that a new ICMP flow with this identity resumes.
    pub(crate) fn resumed_icmp_flow(
        &self,
        client_id: ClientId,
        src: IpAddr,
        dst: &Destination,
        identifier: Identifier,
        now: Instant,
    ) -> Option<FlowId> {
        self.icmp_flows.iter().find_map(|(id, flow)| {
            (flow.client_id == client_id
                && flow.src == src
                && flow.dst == *dst
                && flow.identifier == identifier
                && has_expired(flow.last_round_trip, now))
            .then_some(*id)
        })
    }

    /// The expired UDP flow that a new UDP flow with this identity resumes.
    pub(crate) fn resumed_udp_flow(
        &self,
        client_id: ClientId,
        src: IpAddr,
        dst: &Destination,
        (sport, dport): (SPort, DPort),
        now: Instant,
    ) -> Option<FlowId> {
        self.udp_flows.iter().find_map(|(id, flow)| {
            (flow.client_id == client_id
                && flow.src == src
                && flow.dst == *dst
                && (flow.sport, flow.dport) == (sport, dport)
                && has_expired(flow.last_round_trip, now))
            .then_some(*id)
        })
    }

    /// Whether the client still sends from `src` and knows where `dst` points.
    fn can_send(&self, client_id: ClientId, src: IpAddr, dst: &Destination) -> bool {
        let client = self.clients[&client_id].inner();
        let resolved_domains = match src {
            IpAddr::V4(ip) if ip == client.tunnel_ip4 => client.resolved_v4_domains(),
            IpAddr::V6(ip) if ip == client.tunnel_ip6 => client.resolved_v6_domains(),
            IpAddr::V4(_) | IpAddr::V6(_) => return false,
        };

        match dst {
            Destination::DomainName { name, .. } => {
                resolved_domains.iter().any(|(domain, _)| domain == name)
            }
            Destination::IpAddr(_) => true,
        }
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
                            .is_none_or(|resource| portal.site_for_resource(resource).is_some())
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

    pub(crate) fn connected_gateway_ipv4_ips(&self) -> Vec<(ClientId, Ipv4Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = client.inner().gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(&gateway)?;

                        Some((*id, gateway_host.inner().tunnel_ip4.into()))
                    })
                    .unique()
            })
            .collect()
    }

    pub(crate) fn connected_gateway_ipv6_ips(&self) -> Vec<(ClientId, Ipv6Network)> {
        self.clients
            .iter()
            .flat_map(|(id, client)| {
                client
                    .inner()
                    .connected_resources()
                    .filter_map(|r| {
                        let gateway = client.inner().gateway_for_resource(r)?;
                        let gateway_host = self.gateways.get(&gateway)?;

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

    fn no_relay_accepts_allocations(&self) -> bool {
        self.relays
            .keys()
            .all(|relay| self.exhausted_relays.contains(relay))
    }

    /// Whether a relay accepts allocations and no node ignores it.
    fn has_healthy_relay(&self) -> bool {
        self.relays.keys().any(|relay| {
            !self.exhausted_relays.contains(relay) && !self.recovering_relays.contains_key(relay)
        })
    }

    fn deploy_new_relays(&mut self, new_relays: &BTreeMap<RelayId, Host<u64>>) {
        for (_, relay) in self
            .relays
            .extract_if(.., |relay_id, _| !new_relays.contains_key(relay_id))
        {
            self.network.remove_host(&relay);
        }
        for _ in self
            .exhausted_relays
            .extract_if(.., |relay| !new_relays.contains_key(relay))
        {}
        for _ in self
            .recovering_relays
            .extract_if(.., |relay, _| !new_relays.contains_key(relay))
        {}

        for (rid, new_relay) in new_relays {
            if self.relays.contains_key(rid) {
                continue;
            }

            self.relays.insert(*rid, new_relay.clone());
            let added = self.network.add_host(*rid, new_relay);
            debug_assert!(added);
            self.node_may_lack_relays = false;
        }
    }

    fn reboot_relays_while_partitioned(
        &mut self,
        new_relays: &BTreeMap<RelayId, Host<u64>>,
        now: Instant,
    ) {
        for relay in self.relays.values() {
            self.network.remove_host(relay);
        }
        self.relays.clear();
        // Nodes keep ignoring the relays that failed them before the reboot.
        for relay in std::mem::take(&mut self.exhausted_relays) {
            self.recovering_relays.insert(relay, now);
        }

        for (rid, new_relay) in new_relays {
            self.relays.insert(*rid, new_relay.clone());
            let added = self.network.add_host(*rid, new_relay);
            debug_assert!(added);
        }
    }
}

/// The portal's grant that a packet leaves its sender holding.
#[derive(Debug)]
enum Authorization {
    /// Access to `resource` through `gateway`.
    Resource {
        resource: ResourceId,
        gateway: GatewayId,
        /// The records `gateway` resolves the resource's domains to as the client connects.
        resolutions: BTreeMap<DomainName, BTreeSet<RecordType>>,
    },
    /// Access to `peer` through `pool`, recorded by the sender and installed on the receiver.
    Peer { peer: ClientId, pool: ResourceId },
}

/// The pool a packet to a peer travels through.
#[derive(Debug)]
enum PoolTowardsPeer {
    /// A pool the client already holds an authorization through.
    Held(ResourceId),
    /// The pool the portal grants because the client holds none that fits.
    Granted(ResourceId),
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct PrivateKey(pub [u8; 32]);

impl From<PrivateKey> for StaticSecret {
    fn from(key: PrivateKey) -> Self {
        StaticSecret::from(zeroize::Zeroizing::new(key.0))
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

/// The outcome of a TCP segment that the remote end of `route` has no connection for.
/// The type of the records that hold the addresses a packet from `src` can go to.
fn address_record_type(src: IpAddr) -> RecordType {
    if src.is_ipv4() {
        RecordType::A
    } else {
        RecordType::AAAA
    }
}

/// Whether the Gateway and the peers certainly still hold the state of a UDP or ICMP flow.
fn is_held(last_round_trip: Instant, now: Instant) -> bool {
    now + FLOW_EXPIRY_MARGIN < last_round_trip + DNS_NAT_SESSION_TTL
}

/// Whether the Gateway and the peers certainly dropped the state of a UDP or ICMP flow.
fn has_expired(last_round_trip: Instant, now: Instant) -> bool {
    now >= last_round_trip + DNS_NAT_SESSION_TTL + FLOW_EXPIRY_MARGIN
}
