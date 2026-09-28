//! Adds domain-specific signals to coverage-guided fuzzing.
//!
//! Edge coverage tells AFL++ which control-flow paths an input reaches, but not
//! whether those paths occur in a meaningful combination of protocol states.
//! [`Recorder`] inspects the reference and simulated states after their
//! invariants have been checked and records selected combinations as IJON set
//! features. It also remembers disruptions so successful connectivity after a
//! later transition can guide the fuzzer. A disruption by itself earns no
//! feedback. Each annotation site has its own feature space, and observing the
//! same value again does not make an input interesting.
//!
//! `prepare_runtime` enables the IJON map before discovery starts. Replay still
//! evaluates the observations, but does not record feedback.

use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, SocketAddr},
};

use connlib_model::{ClientId, GatewayId, ResourceId};
use itertools::Itertools as _;
use tunnel_proto::dns;

use crate::{
    probe::{
        DNS_NAT_SESSION_TTL, DnsNatObservation, DnsNatSessions, ExpectedOutcome, ExpectedProbe,
        FlowId, ProbeId, ProbeRequest, ReceivedRequest, Remote, Route, SubmittedRequest,
        remote_responds_with_icmp_error,
    },
    reference::ReferenceState,
    resource::{EditEffect, classify},
    sim_gateway::DnsResolution,
    sim_net::direct_path_possible,
    stub_portal::StubPortal,
    sut::TunnelTest,
    transition::{DPort, Destination, DnsQuery, DnsTransport, SPort, Transition},
};

const RELAYS_DEPLOYED: u8 = 1 << 0;
const RELAYS_PARTITIONED: u8 = 1 << 1;
const RELAYS_REBOOTED: u8 = 1 << 2;

const GATEWAY_AUTHORIZATION_REVOKED: u8 = 1 << 0;
const GATEWAY_DEAUTHORIZED_WHILE_PARTITIONED: u8 = 1 << 1;

const PEER_REMOVED_FROM_POOL: u8 = 1 << 0;
const PEER_AUTHORIZATION_EXPIRED: u8 = 1 << 1;
const PEER_AUTHORIZATION_REVOKED: u8 = 1 << 2;

const RESOURCE_METADATA_EDITED: u8 = 1 << 0;
const RESOURCE_FILTERS_EDITED: u8 = 1 << 1;
const RESOURCE_ACCESS_EDITED: u8 = 1 << 2;
const DEVICE_POOL_ROUTING_EDITED: u8 = 1 << 3;
const RESOURCE_TYPE_EDITED: u8 = 1 << 4;

// The AFL runtime defines this symbol weakly. Rust's IJON macros already emit
// the recording calls; this is the enable flag normally emitted by its LLVM pass.
#[cfg(fuzzing)]
#[used]
#[unsafe(no_mangle)]
static mut __afl_ijon_enabled: u32 = 1;

/// Prepares IJON before starting AFL's deferred forkserver.
#[cfg(fuzzing)]
pub fn prepare_runtime() {
    if std::env::var_os("__AFL_SHM_ID").is_none() {
        return;
    }

    unsafe extern "C" {
        static mut __afl_ijon_map_increased: u32;
    }

    // AFL++ 4.40c resets the negotiated map size after sanitizer coverage
    // initializes, but leaves this flag set. Rearm the expansion before
    // the deferred forkserver reports its map size.
    unsafe { __afl_ijon_map_increased = 0 };
}

/// Records a numeric state category as feedback for the fuzzer.
///
/// Each call site records its values independently. The argument is a `u16`
/// evaluated once, including during replay. Prefer small enums or bounded buckets
/// over raw identifiers and counters. Annotations must run on a single thread.
macro_rules! record_value {
    ($value:expr $(,)?) => {{
        let value: u16 = $value;
        ::core::cfg_select! {
            fuzzing => { ::afl::ijon_set!(u32::from(value)); }
            _ => { let _ = value; }
        }
    }};
}

/// Records a combination of boolean state predicates as feedback for the fuzzer.
///
/// Each call site records its combinations independently. Arguments are evaluated
/// once, in order, with the first argument in the lowest bit. At most 16 booleans
/// fit in AFL++'s IJON set bitmap. Annotations must run on a single thread.
/// Replay evaluates the predicates without recording feedback.
macro_rules! record {
    ($($flag:expr),+ $(,)?) => {{
        const {
            assert!(
                [$(stringify!($flag)),+].len() <= 16,
                "fuzzer feedback supports at most 16 booleans",
            );
        }
        let flags: &[bool] = &[$($flag),+];
        let value = flags.iter().enumerate().fold(0, |value, (bit, flag)| {
            value | (u16::from(*flag) << bit)
        });
        record_value!(value);
    }};
}

/// Records meaningful connectivity observed after earlier disruptions.
#[derive(Default)]
pub struct Recorder {
    roamed_clients: BTreeSet<ClientId>,
    restarted_clients: BTreeSet<ClientId>,
    relay_changes: u8,
    gateway_authorization_changes: BTreeMap<ResourceId, u8>,
    peer_authorization_changes: BTreeMap<ClientRoute, u8>,
    resource_edits: BTreeMap<ResourceId, u8>,
    idled_flows: BTreeSet<FlowId>,
    successful_resource_gateways: BTreeMap<ClientResource, GatewayId>,
    current_probe_on_idled_flow: Option<ProbeId>,
    current_dns_queries: Vec<(ClientId, DnsQuery)>,
    current_tcp_connection: Option<TcpConnectionAttempt>,
}

impl Recorder {
    /// Remembers disruptions whose recovery can be demonstrated by later traffic.
    pub fn observe(&mut self, transition: &Transition, reference: &ReferenceState) {
        self.current_probe_on_idled_flow = None;
        self.current_dns_queries.clear();
        self.current_tcp_connection = None;

        match transition {
            Transition::EditResource(edit) => {
                let change = match classify(&edit.old, &edit.new) {
                    EditEffect::Metadata => RESOURCE_METADATA_EDITED,
                    EditEffect::Filters { .. } => RESOURCE_FILTERS_EDITED,
                    EditEffect::Access { .. } => RESOURCE_ACCESS_EDITED,
                    EditEffect::DevicePoolRouting => DEVICE_POOL_ROUTING_EDITED,
                    EditEffect::Type { .. } => RESOURCE_TYPE_EDITED,
                };
                *self.resource_edits.entry(edit.old.id()).or_default() |= change;
            }
            Transition::RoamClient { client_id, .. } => {
                self.roamed_clients.insert(*client_id);
            }
            Transition::RestartClient { client_id, .. } => {
                self.restarted_clients.insert(*client_id);
            }
            Transition::DeployNewRelays(_) => self.relay_changes |= RELAYS_DEPLOYED,
            Transition::PartitionRelaysFromPortal => {
                self.relay_changes |= RELAYS_PARTITIONED;
            }
            Transition::RebootRelaysWhilePartitioned(_) => {
                self.relay_changes |= RELAYS_REBOOTED;
            }
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => {
                *self
                    .gateway_authorization_changes
                    .entry(*resource)
                    .or_default() |= GATEWAY_DEAUTHORIZED_WHILE_PARTITIONED;
            }
            Transition::RevokeGatewayAuthorization(resource) => {
                *self
                    .gateway_authorization_changes
                    .entry(*resource)
                    .or_default() |= GATEWAY_AUTHORIZATION_REVOKED;
            }
            Transition::UpdateDevicePoolMembers { revoked, .. } => {
                for authorization in revoked {
                    *self
                        .peer_authorization_changes
                        .entry(ClientRoute {
                            origin: authorization.initiator,
                            target: authorization.target,
                        })
                        .or_default() |= PEER_REMOVED_FROM_POOL;
                }
            }
            Transition::ExpirePeerAuthorizations { client, peer, .. } => {
                *self
                    .peer_authorization_changes
                    .entry(ClientRoute {
                        origin: *client,
                        target: *peer,
                    })
                    .or_default() |= PEER_AUTHORIZATION_EXPIRED;
            }
            Transition::RevokePeerAuthorization { client, peer, .. } => {
                *self
                    .peer_authorization_changes
                    .entry(ClientRoute {
                        origin: *client,
                        target: *peer,
                    })
                    .or_default() |= PEER_AUTHORIZATION_REVOKED;
            }
            Transition::SendIcmpPacketOnExistingFlow {
                flow_id, probe_id, ..
            } => {
                if self.idled_flows.contains(flow_id) {
                    self.current_probe_on_idled_flow = Some(*probe_id);
                }
            }
            Transition::SendUdpPacketOnExistingFlow { flow_id, probe_id } => {
                if self.idled_flows.contains(flow_id) {
                    self.current_probe_on_idled_flow = Some(*probe_id);
                }
            }
            Transition::ConnectTcp {
                client_id,
                src,
                dst,
                sport,
                dport,
            } => {
                self.current_tcp_connection = Some(TcpConnectionAttempt {
                    client: *client_id,
                    src: *src,
                    dst: dst.clone(),
                    sport: *sport,
                    dport: *dport,
                });
            }
            Transition::SendDnsQueries(queries) => {
                self.current_dns_queries.clone_from(queries);
            }
            Transition::Idle => {
                self.idled_flows.extend(reference.icmp_flows.keys());
                self.idled_flows.extend(reference.udp_flows.keys());
            }
            Transition::AddResource(_)
            | Transition::RemoveResource(_)
            | Transition::SetInternetResourceState { .. }
            | Transition::SendIcmpPacketOnNewFlow { .. }
            | Transition::SendUdpPacketOnNewFlow { .. }
            | Transition::SendDnsResourcePtrQuery { .. }
            | Transition::UpdateSystemDnsServers { .. }
            | Transition::UpdateUpstreamDo53Servers(_)
            | Transition::UpdateUpstreamDoHServers(_)
            | Transition::UpdateUpstreamSearchDomain(_)
            | Transition::ReconnectPortal { .. }
            | Transition::UpdateDnsRecords { .. } => {}
        }
    }

    /// Records observed state combinations that should guide future fuzzing.
    pub fn record(&mut self, reference: &ReferenceState, state: &TunnelTest, portal: &StubPortal) {
        record_translated_icmp_error_feedback(reference, state);
        record_dns_refresh_feedback(state);
        record_live_dns_flow_feedback(reference, state);
        self.record_dns_query_feedback(reference, state, portal);

        for expected in reference.expected_probes.values() {
            let Some(completed) = completed_round_trip(expected, state) else {
                continue;
            };

            self.record_connectivity_after_roam(&completed);
            self.record_connectivity_after_restart(&completed);
            self.record_connectivity_after_relay_change(reference, &completed);
            self.record_connectivity_after_gateway_authorization_change(&completed);
            self.record_connectivity_after_peer_authorization_change(&completed);
            self.record_existing_flow_after_idle(reference, &completed);
            self.record_connectivity_after_resource_edit(reference, &completed);
            self.record_gateway_failover(reference, &completed);
        }

        self.record_tcp_connectivity(reference, state);
    }

    fn record_connectivity_after_roam(&self, completed: &CompletedRoundTrip<'_>) {
        let origin_roamed = self.roamed_clients.contains(&completed.expected.origin);
        let remote_roamed = completed
            .remote_client()
            .is_some_and(|client| self.roamed_clients.contains(&client));
        if !origin_roamed && !remote_roamed {
            return;
        }

        record!(
            origin_roamed,
            remote_roamed,
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
            completed.is_peer(),
        );
    }

    fn record_connectivity_after_restart(&self, completed: &CompletedRoundTrip<'_>) {
        let origin_restarted = self.restarted_clients.contains(&completed.expected.origin);
        let remote_restarted = completed
            .remote_client()
            .is_some_and(|client| self.restarted_clients.contains(&client));
        if !origin_restarted && !remote_restarted {
            return;
        }

        record!(
            origin_restarted,
            remote_restarted,
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
            completed.is_peer(),
        );
    }

    fn record_connectivity_after_relay_change(
        &self,
        reference: &ReferenceState,
        completed: &CompletedRoundTrip<'_>,
    ) {
        if self.relay_changes == 0 {
            return;
        }
        let Some(requires_relay) = route_requires_relay(reference, completed) else {
            return;
        };

        record!(
            self.relay_changes & RELAYS_DEPLOYED != 0,
            self.relay_changes & RELAYS_PARTITIONED != 0,
            self.relay_changes & RELAYS_REBOOTED != 0,
            requires_relay,
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.is_peer(),
        );
    }

    fn record_connectivity_after_gateway_authorization_change(
        &self,
        completed: &CompletedRoundTrip<'_>,
    ) {
        let Route::Resource { resource, .. } = completed.route else {
            return;
        };
        let Some(change) = self.gateway_authorization_changes.get(&resource) else {
            return;
        };

        record!(
            change & GATEWAY_AUTHORIZATION_REVOKED != 0,
            change & GATEWAY_DEAUTHORIZED_WHILE_PARTITIONED != 0,
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
        );
    }

    fn record_connectivity_after_peer_authorization_change(
        &self,
        completed: &CompletedRoundTrip<'_>,
    ) {
        let Some(peer) = completed.remote_client() else {
            return;
        };
        let Some(change) = self.peer_authorization_changes.get(&ClientRoute {
            origin: completed.expected.origin,
            target: peer,
        }) else {
            return;
        };

        record!(
            change & PEER_REMOVED_FROM_POOL != 0,
            change & PEER_AUTHORIZATION_EXPIRED != 0,
            change & PEER_AUTHORIZATION_REVOKED != 0,
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
        );
    }

    fn record_existing_flow_after_idle(
        &self,
        reference: &ReferenceState,
        completed: &CompletedRoundTrip<'_>,
    ) {
        if self.current_probe_on_idled_flow != Some(completed.expected.id) {
            return;
        }
        let Some(requires_relay) = route_requires_relay(reference, completed) else {
            return;
        };

        record!(
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
            completed.is_peer(),
            requires_relay,
            matches!(
                completed.expected.request.destination(),
                Destination::DomainName { .. }
            ),
        );
    }

    fn record_connectivity_after_resource_edit(
        &self,
        reference: &ReferenceState,
        completed: &CompletedRoundTrip<'_>,
    ) {
        let change = match completed.route {
            Route::Resource { resource, .. } => self
                .resource_edits
                .get(&resource)
                .copied()
                .unwrap_or_default(),
            Route::Gateway(_) => 0,
            Route::Peer(peer) => {
                let Some(client) = reference.clients.get(&completed.expected.origin) else {
                    return;
                };

                client
                    .inner()
                    .authorized_pools_towards(peer)
                    .filter_map(|pool| self.resource_edits.get(&pool))
                    .fold(0, |changes, change| changes | change)
            }
        };
        if change == 0 {
            return;
        }

        record!(
            change & RESOURCE_METADATA_EDITED != 0,
            change & RESOURCE_FILTERS_EDITED != 0,
            change & RESOURCE_ACCESS_EDITED != 0,
            change & DEVICE_POOL_ROUTING_EDITED != 0,
            change & RESOURCE_TYPE_EDITED != 0,
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
            completed.is_peer(),
        );
    }

    fn record_gateway_failover(
        &mut self,
        reference: &ReferenceState,
        completed: &CompletedRoundTrip<'_>,
    ) {
        let Route::Resource { resource, gateway } = completed.route else {
            return;
        };
        let previous = self.successful_resource_gateways.insert(
            ClientResource {
                client: completed.expected.origin,
                resource,
            },
            gateway,
        );
        if previous.is_none_or(|previous| previous == gateway) {
            return;
        }
        let Some(requires_relay) = route_requires_relay(reference, completed) else {
            return;
        };

        record!(
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
            requires_relay,
            matches!(
                completed.expected.request.destination(),
                Destination::DomainName { .. }
            ),
            completed.submitted.packet.destination() != completed.received.packet.destination(),
        );
    }

    fn record_dns_query_feedback(
        &self,
        reference: &ReferenceState,
        state: &TunnelTest,
        portal: &StubPortal,
    ) {
        for (client_id, query) in &self.current_dns_queries {
            let Some(reference_client) = reference.clients.get(client_id) else {
                continue;
            };
            let Some(simulated_client) = state.clients.get(client_id) else {
                continue;
            };
            let reference_client = reference_client.inner();
            let simulated_client = simulated_client.inner();
            let response_received = match query.transport {
                DnsTransport::Udp { local_port } => simulated_client
                    .received_udp_dns_responses
                    .contains_key(&(query.dns_server.clone(), query.query_id, local_port)),
                DnsTransport::Tcp => simulated_client
                    .received_tcp_dns_responses
                    .contains(&(query.dns_server.clone(), query.query_id)),
            };
            if !response_received {
                continue;
            }

            let site_specific = reference_client.is_site_specific_dns_query(query).is_some();
            let via_resource = site_specific
                || reference_client
                    .dns_query_via_resource(query, portal.upstream_do53())
                    .is_some();
            let learned_records = reference_client
                .dns_records
                .get(&query.domain)
                .is_some_and(|types| types.contains(&query.r_type));
            let (doh, upstream_is_ipv6) = match &query.dns_server {
                dns::Upstream::Do53 { server } => (false, server.is_ipv6()),
                dns::Upstream::DoH { .. } => (true, false),
            };

            record!(
                matches!(query.transport, DnsTransport::Tcp),
                doh,
                upstream_is_ipv6,
                via_resource,
                site_specific,
                learned_records,
                matches!(query.r_type, dns_types::RecordType::A),
                matches!(query.r_type, dns_types::RecordType::AAAA),
                matches!(query.r_type, dns_types::RecordType::PTR),
            );
        }
    }

    fn record_tcp_connectivity(&self, reference: &ReferenceState, state: &TunnelTest) {
        let Some(attempt) = &self.current_tcp_connection else {
            return;
        };
        let Some(reference_client) = reference.clients.get(&attempt.client) else {
            return;
        };
        let reference_client = reference_client.inner();
        let Some(resource) = reference_client
            .expected_tcp_connections
            .get(&(
                attempt.src,
                attempt.dst.clone(),
                attempt.sport,
                attempt.dport,
            ))
            .copied()
        else {
            return;
        };
        let Some(simulated_client) = state.clients.get(&attempt.client) else {
            return;
        };
        let source = l3_tcp::IpEndpoint::from(SocketAddr::new(attempt.src, attempt.sport.0));
        let established = simulated_client
            .inner()
            .tcp_client
            .iter_sockets()
            .any(|socket| {
                socket.local_endpoint() == Some(source)
                    && socket
                        .remote_endpoint()
                        .is_some_and(|remote| remote.port == attempt.dport.0)
                    && socket.state() == l3_tcp::State::Established
            });
        if !established {
            return;
        }

        let roamed = self.roamed_clients.contains(&attempt.client);
        let restarted = self.restarted_clients.contains(&attempt.client);
        let relays_changed = self.relay_changes != 0;
        let gateway_authorization_changed =
            self.gateway_authorization_changes.contains_key(&resource);
        let resource_edited = self.resource_edits.contains_key(&resource);
        if !roamed
            && !restarted
            && !relays_changed
            && !gateway_authorization_changed
            && !resource_edited
        {
            return;
        }
        let Some(gateway) = reference_client.gateway_for_resource(resource) else {
            return;
        };
        let Some(requires_relay) = gateway_route_requires_relay(reference, attempt.client, gateway)
        else {
            return;
        };

        record!(
            roamed,
            restarted,
            relays_changed,
            gateway_authorization_changed,
            resource_edited,
            reference_client.internet_resource() == Some(resource),
            attempt.src.is_ipv6(),
            matches!(attempt.dst, Destination::DomainName { .. }),
            requires_relay,
        );
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct ClientRoute {
    origin: ClientId,
    target: ClientId,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct ClientResource {
    client: ClientId,
    resource: ResourceId,
}

struct TcpConnectionAttempt {
    client: ClientId,
    src: IpAddr,
    dst: Destination,
    sport: SPort,
    dport: DPort,
}

struct CompletedRoundTrip<'a> {
    expected: &'a ExpectedProbe,
    route: Route,
    submitted: &'a SubmittedRequest,
    received: &'a ReceivedRequest,
}

impl CompletedRoundTrip<'_> {
    fn is_udp(&self) -> bool {
        matches!(self.expected.request, ProbeRequest::Udp { .. })
    }

    fn is_peer(&self) -> bool {
        matches!(self.route, Route::Peer(_))
    }

    fn remote_client(&self) -> Option<ClientId> {
        let Route::Peer(client) = self.route else {
            return None;
        };

        Some(client)
    }
}

fn completed_round_trip<'a>(
    expected: &'a ExpectedProbe,
    state: &'a TunnelTest,
) -> Option<CompletedRoundTrip<'a>> {
    let ExpectedOutcome::RoundTripCompleted(route) = expected.outcome else {
        return None;
    };
    let trace = state.probe_trace(expected.id);
    let ([submitted], [received], [_response]) = (
        trace.submitted_requests.as_slice(),
        trace.received_requests.as_slice(),
        trace.received_responses.as_slice(),
    ) else {
        return None;
    };

    Some(CompletedRoundTrip {
        expected,
        route,
        submitted,
        received,
    })
}

fn route_requires_relay(
    reference: &ReferenceState,
    completed: &CompletedRoundTrip<'_>,
) -> Option<bool> {
    match completed.route {
        Route::Resource { gateway, .. } | Route::Gateway(gateway) => {
            gateway_route_requires_relay(reference, completed.expected.origin, gateway)
        }
        Route::Peer(peer) => {
            let origin = reference.clients.get(&completed.expected.origin)?;
            let peer = reference.clients.get(&peer)?;
            let direct = direct_path_possible(
                origin.edge_config(),
                peer.edge_config(),
                origin.ip4.is_some() && peer.ip4.is_some(),
                origin.ip6.is_some() && peer.ip6.is_some(),
            );

            Some(!direct)
        }
    }
}

fn gateway_route_requires_relay(
    reference: &ReferenceState,
    origin: ClientId,
    gateway: GatewayId,
) -> Option<bool> {
    let origin = reference.clients.get(&origin)?;
    let gateway = reference.gateways.get(&gateway)?;
    let direct = direct_path_possible(
        origin.edge_config(),
        gateway.edge_config(),
        origin.ip4.is_some() && gateway.ip4.is_some(),
        origin.ip6.is_some() && gateway.ip6.is_some(),
    );

    Some(!direct)
}

fn record_translated_icmp_error_feedback(reference: &ReferenceState, state: &TunnelTest) {
    for expected in reference.expected_probes.values() {
        let ExpectedOutcome::RoundTripCompleted(route) = expected.outcome else {
            continue;
        };
        let remote = route.remote();
        if !matches!(remote, Remote::Gateway(_)) {
            continue;
        }

        let trace = state.probe_trace(expected.id);
        let ([submitted_request], [received_request], [_received_response]) = (
            trace.submitted_requests.as_slice(),
            trace.received_requests.as_slice(),
            trace.received_responses.as_slice(),
        ) else {
            continue;
        };
        let destination_was_translated =
            submitted_request.packet.destination() != received_request.packet.destination();
        if !destination_was_translated {
            continue;
        }

        let responds_with_icmp_error = remote_responds_with_icmp_error(
            expected,
            received_request,
            remote,
            &reference.icmp_error_hosts,
        );
        record!(
            submitted_request.packet.destination().is_ipv6(),
            received_request.packet.destination().is_ipv6(),
            matches!(expected.request, ProbeRequest::Udp { .. }),
            responds_with_icmp_error,
        );
    }
}

fn record_live_dns_flow_feedback(reference: &ReferenceState, state: &TunnelTest) {
    for observation in state.dns_nat_observations() {
        if observation.response_received_at.is_none()
            || state.now().duration_since(observation.received.at) >= DNS_NAT_SESSION_TTL
            || !(reference.udp_flows.contains_key(&observation.flow_id)
                || reference.icmp_flows.contains_key(&observation.flow_id))
        {
            continue;
        }
        let Remote::Gateway(gateway) = observation.received.remote else {
            continue;
        };
        let Some(gateway) = state.gateway(gateway) else {
            continue;
        };
        if observation.received.dns_nat_generation
            != Some(gateway.dns_nat_generation(observation.submitted.client))
        {
            continue;
        }

        let ipv6 = observation.submitted.packet.destination().is_ipv6();
        let addresses = reference
            .global_dns_records
            .domain_ips_iter(&observation.domain)
            .filter(|ip| ip.is_ipv6() == ipv6)
            .collect::<BTreeSet<_>>();
        let answers_changed = addresses != observation.dns_addresses;
        let old_destination_absent =
            !addresses.contains(&observation.received.packet.destination());
        let udp = observation.submitted.packet.as_udp().is_some();
        record!(ipv6, udp, answers_changed, old_destination_absent);
    }
}

fn record_dns_refresh_feedback(state: &TunnelTest) {
    let sessions = DnsNatSessions::new(state.dns_nat_observations()).sessions;

    for session in sessions {
        let [first, ..] = session.observations.as_slice() else {
            continue;
        };
        let Some(order) = first.received.gateway_order else {
            continue;
        };
        let Some(gateway) = state.gateway(session.key.gateway) else {
            continue;
        };
        let Some(initial_resolution) = gateway.dns_resolution_before(
            session.key.client,
            &first.domain,
            first.received.at,
            order,
            session.key.dns_nat_generation,
            session.key.proxy,
        ) else {
            continue;
        };

        record_dns_refresh_session_feedback(
            &session.observations,
            gateway
                .dns_resolutions(
                    session.key.client,
                    &first.domain,
                    session.key.dns_nat_generation,
                    session.key.proxy,
                )
                .filter(|candidate| candidate.order >= initial_resolution.order),
        );
    }
}

fn record_dns_refresh_session_feedback<'a>(
    session: &[&DnsNatObservation],
    resolutions: impl Iterator<Item = &'a DnsResolution>,
) {
    for (previous, refreshed) in resolutions.tuple_windows() {
        for before in session {
            let Some(response_at) = before.response_received_at else {
                continue;
            };
            if response_at >= refreshed.at
                || refreshed.at.duration_since(before.received.at) >= DNS_NAT_SESSION_TTL
            {
                continue;
            }

            let ipv6 = before.submitted.packet.destination().is_ipv6();
            let previous_addresses = previous
                .addresses
                .iter()
                .filter(|ip| ip.is_ipv6() == ipv6)
                .collect::<BTreeSet<_>>();
            let refreshed_addresses = refreshed
                .addresses
                .iter()
                .filter(|ip| ip.is_ipv6() == ipv6)
                .collect::<BTreeSet<_>>();
            let answers_changed = previous_addresses != refreshed_addresses;
            let old_destination_absent = !refreshed
                .addresses
                .contains(&before.received.packet.destination());
            let udp = before.submitted.packet.as_udp().is_some();
            record!(ipv6, udp, answers_changed, old_destination_absent);

            let flow_exercised_after_refresh = session.iter().any(|after| {
                after.flow_id == before.flow_id
                    && after
                        .received
                        .gateway_order
                        .is_some_and(|order| order > refreshed.order)
                    && after.response_received_at.is_some()
            });
            if flow_exercised_after_refresh {
                record!(ipv6, udp, answers_changed, old_destination_absent);
            }
        }
    }
}
