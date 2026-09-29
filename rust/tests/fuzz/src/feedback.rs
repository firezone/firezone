//! Adds domain-specific signals to coverage-guided fuzzing.
//!
//! Edge coverage tells AFL++ which control-flow paths an input reaches, but not
//! whether those paths occur in a meaningful combination of protocol states.
//! [`Recorder`] inspects the reference and simulated states after their
//! invariants have been checked and records selected combinations as IJON set
//! features. It also logs each change a transition makes with the routes it
//! affects. Whenever a route carries traffic, each kind of change it has
//! recovered from since it last did, each pair of those kinds and their number
//! become features of the selected connection path. A small number of bounded
//! stepping stones reward state needed to reach especially difficult DNS
//! scenarios. IJON mixes each annotation site's source location into its
//! features, and observing the same value at the same site again does not make
//! an input interesting.
//!
//! `prepare_runtime` enables the IJON map before discovery starts. Replay still
//! evaluates the observations, but does not record feedback.

use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, SocketAddr},
    time::Duration,
};

use connlib_model::{ClientId, ClientOrGatewayId, GatewayId, ResourceId};
use itertools::Itertools as _;
use snownet::ConnectionPath;
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
    sim_net::EdgeConfig,
    stub_portal::StubPortal,
    sut::TunnelTest,
    transition::{DPort, Destination, DnsQuery, DnsTransport, SPort, Transition},
};

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
    // the deferred forkserver reports its map size. See the corresponding
    // runtime code at https://github.com/AFLplusplus/AFLplusplus/blob/e5a8ba39ecf97d05e286fdd4e01da96554dbf64f/instrumentation/afl-compiler-rt.o.c#L2312-L2340.
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
        record_value!(pack(&[$($flag),+]));
    }};
}

/// Records a logical outcome together with the selected network path.
///
/// The path uses two bits for direct, one-sided relay, and two-sided relay
/// connections. Logical outcomes remain limited to eight predicates to keep each
/// annotation site's feature space bounded.
macro_rules! record_with_path {
    ($path:expr; $($flag:expr),+ $(,)?) => {{
        const {
            assert!(
                [$(stringify!($flag)),+].len() <= 8,
                "path feedback supports at most 8 boolean predicates",
            );
        }
        let path: PathFeedback = $path;
        let flags: &[bool] = &[$($flag),+];
        let value = pack(flags) | (path.code() << flags.len());
        record_value!(value);
    }};
}

fn pack(flags: &[bool]) -> u16 {
    flags
        .iter()
        .enumerate()
        .fold(0, |value, (bit, flag)| value | (u16::from(*flag) << bit))
}

/// Records meaningful connectivity observed after earlier changes.
#[derive(Default)]
pub struct Recorder {
    changes: Vec<(Scope, Change)>,
    recovered: BTreeMap<RouteKey, usize>,
    idled_flows: BTreeMap<FlowId, Duration>,
    successful_resource_gateways: BTreeMap<ClientResource, GatewayId>,
    current_probe_on_idled_flow: Option<IdleFlowAttempt>,
    current_dns_queries: Vec<(ClientId, DnsQuery)>,
    current_tcp_connection: Option<TcpConnectionAttempt>,
}

impl Recorder {
    /// Logs changes whose recovery can be demonstrated by later traffic.
    pub fn observe(&mut self, transition: &Transition, reference: &ReferenceState) {
        self.current_probe_on_idled_flow = None;
        self.current_dns_queries.clear();
        self.current_tcp_connection = None;

        match transition {
            Transition::EditResource(edit) => {
                let change = match classify(&edit.old, &edit.new) {
                    EditEffect::Metadata => Change::ResourceMetadataEdited,
                    EditEffect::Filters { .. } => Change::ResourceFiltersEdited,
                    EditEffect::Access { .. } => Change::ResourceAccessEdited,
                    EditEffect::DevicePoolRouting => Change::DevicePoolRoutingEdited,
                    EditEffect::Type { .. } => Change::ResourceTypeEdited,
                };
                self.changes.push((Scope::Resource(edit.old.id()), change));
            }
            Transition::RoamClient { client_id, .. } => {
                self.changes
                    .push((Scope::Client(*client_id), Change::Roamed));
            }
            Transition::RestartClient { client_id, .. } => {
                self.changes
                    .push((Scope::Client(*client_id), Change::Restarted));
            }
            Transition::ReconnectPortal { client_id } => {
                self.changes
                    .push((Scope::Client(*client_id), Change::PortalReconnected));
            }
            Transition::DeployNewRelays(_) => {
                self.changes
                    .push((Scope::Everything, Change::RelaysDeployed));
            }
            Transition::PartitionRelaysFromPortal => {
                self.changes
                    .push((Scope::Everything, Change::RelaysPartitioned));
            }
            Transition::RebootRelaysWhilePartitioned(_) => {
                self.changes
                    .push((Scope::Everything, Change::RelaysRebooted));
            }
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => {
                self.changes.push((
                    Scope::Resource(*resource),
                    Change::GatewayDeauthorizedWhilePartitioned,
                ));
            }
            Transition::RevokeGatewayAuthorization(resource) => {
                self.changes.push((
                    Scope::Resource(*resource),
                    Change::GatewayAuthorizationRevoked,
                ));
            }
            Transition::UpdateDevicePoolMembers { revoked, .. } => {
                for authorization in revoked {
                    self.changes.push((
                        Scope::Peers(authorization.initiator, authorization.target),
                        Change::PeerRemovedFromPool,
                    ));
                }
            }
            Transition::ExpirePeerAuthorizations { client, peer, .. } => {
                self.changes.push((
                    Scope::Peers(*client, *peer),
                    Change::PeerAuthorizationExpired,
                ));
            }
            Transition::RevokePeerAuthorization { client, peer, .. } => {
                self.changes.push((
                    Scope::Peers(*client, *peer),
                    Change::PeerAuthorizationRevoked,
                ));
            }
            Transition::SendIcmpPacketOnExistingFlow {
                flow_id, probe_id, ..
            } => {
                if let Some(duration) = self.idled_flows.remove(flow_id) {
                    self.current_probe_on_idled_flow = Some(IdleFlowAttempt {
                        probe: *probe_id,
                        duration,
                    });
                }
            }
            Transition::SendUdpPacketOnExistingFlow { flow_id, probe_id } => {
                if let Some(duration) = self.idled_flows.remove(flow_id) {
                    self.current_probe_on_idled_flow = Some(IdleFlowAttempt {
                        probe: *probe_id,
                        duration,
                    });
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
            Transition::Idle { duration } => {
                self.changes.push((Scope::Everything, Change::Idled));
                for flow in reference
                    .icmp_flows
                    .keys()
                    .chain(reference.udp_flows.keys())
                {
                    *self.idled_flows.entry(*flow).or_default() += *duration;
                }
            }
            Transition::UpdateDnsRecords { .. } => {
                self.changes
                    .push((Scope::Everything, Change::DnsRecordsChanged));
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
            | Transition::UpdateUpstreamSearchDomain(_) => {}
        }
    }

    /// Records observed state combinations that should guide future fuzzing.
    pub fn record(&mut self, reference: &ReferenceState, state: &TunnelTest, portal: &StubPortal) {
        record_translated_icmp_error_feedback(reference, state);
        record_dns_refresh_feedback(reference, state);
        record_live_dns_flow_feedback(reference, state);
        self.record_dns_query_feedback(reference, state, portal);

        for expected in reference.expected_probes.values() {
            let Some(completed) = completed_round_trip(expected, state) else {
                continue;
            };
            let Some(path) = route_path_feedback(reference, state, &completed) else {
                continue;
            };

            record_with_path!(path;
                completed.is_udp(),
                completed.submitted.packet.destination().is_ipv6(),
                completed.received.packet.destination().is_ipv6(),
                completed.is_peer(),
                matches!(expected.request.destination(), Destination::DomainName { .. }),
            );
            self.record_recovery(reference, expected.origin, completed.route, path);
            self.record_existing_flow_after_idle(&completed, path);
            self.record_gateway_failover(&completed, path);
        }

        self.record_tcp_connectivity(reference, state);
    }

    /// Records the kinds of change a route has recovered from since it last carried traffic.
    fn record_recovery(
        &mut self,
        reference: &ReferenceState,
        origin: ClientId,
        route: Route,
        path: PathFeedback,
    ) {
        let route = match route {
            Route::Resource { resource, .. } => RouteKey::Resource(origin, resource),
            Route::Gateway(gateway) => RouteKey::Gateway(origin, gateway),
            Route::Peer(peer) => RouteKey::Peer(origin, peer),
        };
        let since = self
            .recovered
            .insert(route, self.changes.len())
            .unwrap_or(0);
        let kinds = self.changes[since..]
            .iter()
            .filter(|(scope, _)| scope.covers(route, reference))
            .map(|(_, change)| *change)
            .collect::<BTreeSet<_>>();

        for &kind in &kinds {
            record_value!((kind as u16) << 2 | path.code());
        }
        for [&first, &second] in kinds.iter().array_combinations() {
            record_value!((first as u16 * KINDS + second as u16) << 2 | path.code());
        }
        record_value!((kinds.len().min(7) as u16) << 2 | path.code());
    }

    fn record_existing_flow_after_idle(
        &self,
        completed: &CompletedRoundTrip<'_>,
        path: PathFeedback,
    ) {
        let Some(attempt) = self.current_probe_on_idled_flow else {
            return;
        };
        if attempt.probe != completed.expected.id {
            return;
        }
        record_with_path!(path;
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
            completed.is_peer(),
            matches!(
                completed.expected.request.destination(),
                Destination::DomainName { .. }
            ),
        );
        record_with_path!(path;
            attempt.duration >= DNS_NAT_SESSION_TTL,
            matches!(
                completed.expected.request.destination(),
                Destination::DomainName { .. }
            ),
        );

        let origin = nat_feedback(path.origin, attempt.duration);
        let remote = nat_feedback(path.remote, attempt.duration);
        if !origin.behind_nat && !remote.behind_nat {
            return;
        }

        record_with_path!(path;
            origin.expiry_elapsed,
            remote.expiry_elapsed,
            origin.inbound_refreshes,
            remote.inbound_refreshes,
        );
    }

    fn record_gateway_failover(&mut self, completed: &CompletedRoundTrip<'_>, path: PathFeedback) {
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
        record_with_path!(path;
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
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

    fn record_tcp_connectivity(&mut self, reference: &ReferenceState, state: &TunnelTest) {
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

        let Some(gateway) = reference_client.gateway_for_resource(resource) else {
            return;
        };
        let Some(path) = gateway_path_feedback(reference, state, attempt.client, gateway) else {
            return;
        };

        record_with_path!(path;
            attempt.src.is_ipv6(),
            matches!(attempt.dst, Destination::DomainName { .. }),
            reference_client.internet_resource() == Some(resource),
        );
        self.record_recovery(
            reference,
            attempt.client,
            Route::Resource { resource, gateway },
            path,
        );
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Change {
    Roamed,
    Restarted,
    PortalReconnected,
    RelaysDeployed,
    RelaysPartitioned,
    RelaysRebooted,
    GatewayAuthorizationRevoked,
    GatewayDeauthorizedWhilePartitioned,
    PeerRemovedFromPool,
    PeerAuthorizationExpired,
    PeerAuthorizationRevoked,
    ResourceMetadataEdited,
    ResourceFiltersEdited,
    ResourceAccessEdited,
    DevicePoolRoutingEdited,
    ResourceTypeEdited,
    Idled,
    DnsRecordsChanged,
}

const KINDS: u16 = 18;

#[derive(Clone, Copy)]
enum Scope {
    Client(ClientId),
    Resource(ResourceId),
    Peers(ClientId, ClientId),
    Everything,
}

impl Scope {
    fn covers(self, route: RouteKey, reference: &ReferenceState) -> bool {
        match (self, route) {
            (Scope::Client(client), RouteKey::Resource(origin, _)) => client == origin,
            (Scope::Client(client), RouteKey::Gateway(origin, _)) => client == origin,
            (Scope::Client(client), RouteKey::Peer(origin, peer)) => {
                client == origin || client == peer
            }
            (Scope::Resource(resource), RouteKey::Resource(_, target)) => resource == target,
            (Scope::Resource(_), RouteKey::Gateway(..)) => false,
            (Scope::Resource(pool), RouteKey::Peer(origin, peer)) => {
                reference.clients.get(&origin).is_some_and(|client| {
                    client
                        .inner()
                        .authorized_pools_towards(peer)
                        .contains(&pool)
                })
            }
            (Scope::Peers(..), RouteKey::Resource(..)) => false,
            (Scope::Peers(..), RouteKey::Gateway(..)) => false,
            (Scope::Peers(client, peer), RouteKey::Peer(origin, target)) => {
                client == origin && peer == target
            }
            (Scope::Everything, _) => true,
        }
    }
}

/// Keys resource routes by resource rather than gateway, so failing over does not reset them.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum RouteKey {
    Resource(ClientId, ResourceId),
    Gateway(ClientId, GatewayId),
    Peer(ClientId, ClientId),
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

#[derive(Clone, Copy)]
struct IdleFlowAttempt {
    probe: ProbeId,
    duration: Duration,
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

#[derive(Clone, Copy)]
struct PathFeedback {
    origin: EdgeConfig,
    remote: EdgeConfig,
    selected: ConnectionPath,
}

impl PathFeedback {
    fn new(origin: EdgeConfig, remote: EdgeConfig, selected: ConnectionPath) -> Self {
        Self {
            origin,
            remote,
            selected,
        }
    }

    fn code(self) -> u16 {
        self.selected.index() as u16
    }
}

fn route_path_feedback(
    reference: &ReferenceState,
    state: &TunnelTest,
    completed: &CompletedRoundTrip<'_>,
) -> Option<PathFeedback> {
    let origin = completed.expected.origin;
    let peer = match completed.route {
        Route::Resource { gateway, .. } | Route::Gateway(gateway) => {
            return gateway_path_feedback(reference, state, origin, gateway);
        }
        Route::Peer(peer) => peer,
    };
    let origin_edge = reference.clients.get(&origin)?.edge_config();
    let remote_edge = reference.clients.get(&peer)?.edge_config();
    let selected = state
        .clients
        .get(&origin)?
        .inner()
        .sut
        .connection_path(ClientOrGatewayId::Client(peer))?;

    Some(PathFeedback::new(origin_edge, remote_edge, selected))
}

struct NatFeedback {
    behind_nat: bool,
    inbound_refreshes: bool,
    expiry_elapsed: bool,
}

fn nat_feedback(edge: EdgeConfig, idle: Duration) -> NatFeedback {
    let EdgeConfig::Nat(_, _, expiry) = edge else {
        return NatFeedback {
            behind_nat: false,
            inbound_refreshes: false,
            expiry_elapsed: false,
        };
    };

    NatFeedback {
        behind_nat: true,
        inbound_refreshes: expiry.inbound_refreshes,
        expiry_elapsed: idle >= expiry.timeout,
    }
}

fn gateway_path_feedback(
    reference: &ReferenceState,
    state: &TunnelTest,
    origin: ClientId,
    gateway: GatewayId,
) -> Option<PathFeedback> {
    let origin_edge = reference.clients.get(&origin)?.edge_config();
    let gateway_edge = reference.gateways.get(&gateway)?.edge_config();
    let selected = state
        .clients
        .get(&origin)?
        .inner()
        .sut
        .connection_path(ClientOrGatewayId::Gateway(gateway))?;
    Some(PathFeedback::new(origin_edge, gateway_edge, selected))
}

fn record_translated_icmp_error_feedback(reference: &ReferenceState, state: &TunnelTest) {
    for expected in reference.expected_probes.values() {
        let Some(completed) = completed_round_trip(expected, state) else {
            continue;
        };
        let remote = completed.route.remote();
        if !matches!(remote, Remote::Gateway(_)) {
            continue;
        }
        let Some(path) = route_path_feedback(reference, state, &completed) else {
            continue;
        };
        let destination_was_translated =
            completed.submitted.packet.destination() != completed.received.packet.destination();
        if !destination_was_translated {
            continue;
        }

        let responds_with_icmp_error = remote_responds_with_icmp_error(
            expected,
            completed.received,
            remote,
            &reference.icmp_error_hosts,
        );
        record_with_path!(path;
            completed.submitted.packet.destination().is_ipv6(),
            completed.received.packet.destination().is_ipv6(),
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
        let Some(path) =
            gateway_path_feedback(reference, state, observation.submitted.client, gateway)
        else {
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
        record_with_path!(path;
            ipv6,
            udp,
            answers_changed,
            old_destination_absent,
        );
    }
}

fn record_dns_refresh_feedback(reference: &ReferenceState, state: &TunnelTest) {
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
        let Some(path) =
            gateway_path_feedback(reference, state, session.key.client, session.key.gateway)
        else {
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
            path,
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
    path: PathFeedback,
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
            record_with_path!(path;
                ipv6,
                udp,
                answers_changed,
                old_destination_absent,
            );

            let flow_exercised_after_refresh = session.iter().any(|after| {
                after.flow_id == before.flow_id
                    && after
                        .received
                        .gateway_order
                        .is_some_and(|order| order > refreshed.order)
                    && after.response_received_at.is_some()
            });
            if flow_exercised_after_refresh {
                record_with_path!(path;
                    ipv6,
                    udp,
                    answers_changed,
                    old_destination_absent,
                );
            }
        }
    }
}
