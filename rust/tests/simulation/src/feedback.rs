//! Adds domain-specific signals to coverage-guided fuzzing.
//!
//! Edge coverage tells AFL++ which control-flow paths an input reaches, but not
//! whether those paths occur in a meaningful combination of protocol states.
//! [`Recorder`] inspects the model and the real system after their
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
//! Recording needs the `ijon` feature and a build for discovery. Every other
//! build, replay included, evaluates the observations without recording feedback.

use std::{
    collections::{BTreeMap, BTreeSet},
    time::{Duration, Instant},
};

use connlib_model::{DeviceId, IpStack, ResourceId};
use itertools::Itertools as _;
use snownet::ConnectionPath;
use tunnel_proto::dns;

use crate::{
    fake_portal::FakePortal,
    network::{EdgeConfig, FilterMode, HostId, Mapping},
    probe::{
        Answer, DNS_NAT_SESSION_TTL, DnsNatObservation, DnsNatSessions, ExpectedOutcome,
        ExpectedProbe, FlowId, ProbeId, ProbeRequest, ReceivedRequest, RejectionRemote, Remote,
        Route, SubmittedRequest,
    },
    real_gateway::DnsResolution,
    real_tunnel_system::RealTunnelSystem,
    resource::{EditEffect, Resource, ResourceEdit, classify},
    site_network::RouteType,
    tunnel_model::TunnelModel,
    tunnel_transition::{Destination, DnsQuery, DnsTransport, Transition},
};

/// Records a numeric state category as feedback for the fuzzer.
///
/// Each call site records its values independently. The argument is a `u16`
/// evaluated once, including during replay. Prefer small enums or bounded buckets
/// over raw identifiers and counters. Annotations must run on a single thread.
macro_rules! record_value {
    ($value:expr $(,)?) => {{
        let value: u16 = $value;
        ::core::cfg_select! {
            all(fuzzing, feature = "ijon") => { ::afl::ijon_set!(u32::from(value)); }
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
    successful_resource_gateways: BTreeMap<ClientResource, DeviceId>,
    current_probe_on_idled_flow: Option<IdleFlowAttempt>,
    current_dns_queries: Vec<(DeviceId, DnsQuery)>,
    current_tcp_flow: Option<FlowId>,
    tcp_flows_opened: BTreeMap<FlowId, usize>,
}

impl Recorder {
    /// Logs changes whose recovery can be demonstrated by later traffic.
    pub fn observe(&mut self, transition: &Transition, model: &TunnelModel, now: Instant) {
        self.current_probe_on_idled_flow = None;
        self.current_dns_queries.clear();
        self.current_tcp_flow = None;

        match transition {
            Transition::EditResource(edit) => {
                let change = match classify(&edit.old, &edit.new) {
                    EditEffect::Metadata => Change::ResourceMetadataEdited,
                    EditEffect::Filters { .. } => Change::ResourceFiltersEdited,
                    EditEffect::Access { .. } if ip_stack_changed(edit) => {
                        Change::ResourceIpStackEdited
                    }
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
            Transition::SetInternetResourceState { client_id, .. } => {
                self.changes
                    .push((Scope::Client(*client_id), Change::InternetResourceToggled));
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
            Transition::ExhaustRelayPorts(_) => {
                self.changes
                    .push((Scope::Everything, Change::RelayPortsExhausted));
            }
            Transition::FreeRelayPorts(_) => {
                self.changes
                    .push((Scope::Everything, Change::RelayPortsFreed));
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
            Transition::ConnectTcp { flow_id, .. } | Transition::SendTcpData { flow_id, .. } => {
                self.current_tcp_flow = Some(*flow_id);
            }
            Transition::SendDnsQueries(queries) => {
                self.current_dns_queries.clone_from(queries);
            }
            Transition::Idle { duration } => {
                self.changes.push((Scope::Everything, Change::Idled));
                for flow in model.icmp_flows.keys().chain(model.udp_flows.keys()) {
                    *self.idled_flows.entry(*flow).or_default() += *duration;
                }
            }
            Transition::UpdateDnsRecords { .. } => {
                self.changes
                    .push((Scope::Everything, Change::DnsRecordsChanged));
            }
            Transition::CrashClient { client_id, .. } => {
                self.changes
                    .push((Scope::Client(*client_id), Change::Crashed));
            }
            Transition::CrashGateway { .. } => {
                self.changes
                    .push((Scope::Everything, Change::GatewayCrashed));
            }
            Transition::SpuriousPublicKeyChanged { .. } => {
                self.changes
                    .push((Scope::Everything, Change::SpuriousPublicKeyChanged));
            }
            Transition::UpdateSystemDnsServers { .. }
            | Transition::UpdateUpstreamDo53Servers(_)
            | Transition::UpdateUpstreamDoHServers(_) => {
                self.changes
                    .push((Scope::Everything, Change::DnsServersChanged));
            }
            Transition::SendIcmpPacketOnNewFlow {
                client_id,
                src,
                dst,
                identifier,
                probe_id,
                ..
            } => {
                let resumed = model.resumed_icmp_flow(*client_id, *src, dst, *identifier, now);
                self.observe_resumed_flow(resumed, *probe_id);
            }
            Transition::SendUdpPacketOnNewFlow {
                client_id,
                src,
                dst,
                sport,
                dport,
                probe_id,
                ..
            } => {
                let resumed = model.resumed_udp_flow(*client_id, *src, dst, (*sport, *dport), now);
                self.observe_resumed_flow(resumed, *probe_id);
            }
            Transition::AddResource(_)
            | Transition::RemoveResource(_)
            | Transition::SendDnsResourcePtrQuery { .. }
            | Transition::UpdateUpstreamSearchDomain(_) => {}
        }
    }

    fn observe_resumed_flow(&mut self, resumed: Option<FlowId>, probe: ProbeId) {
        if let Some(duration) = resumed.and_then(|flow_id| self.idled_flows.remove(&flow_id)) {
            self.current_probe_on_idled_flow = Some(IdleFlowAttempt { probe, duration });
        }
    }

    /// Records observed state combinations that should guide future fuzzing.
    pub fn record(&mut self, model: &TunnelModel, state: &RealTunnelSystem, portal: &FakePortal) {
        record_translated_icmp_error_feedback(model, state);
        record_site_network_feedback(model, state);
        record_dns_refresh_feedback(model, state);
        record_dns_proxy_ip_subset_feedback(state);
        record_shared_dns_resource_gateway_feedback(model);
        record_shared_nat_feedback(model);
        record_live_dns_flow_feedback(model, state);
        self.record_dns_query_feedback(model, state, portal);
        for _ in self
            .tcp_flows_opened
            .extract_if(.., |flow, _| !model.tcp_flows.contains_key(flow))
        {}

        for expected in model.expected_probes.values() {
            record_tcp_connect_outcome(model, state, expected);
            let Some(completed) = completed_round_trip(expected, state) else {
                continue;
            };
            let Some(path) =
                remote_path_feedback(model, state, expected.origin, completed.route.remote())
            else {
                continue;
            };

            if let Some(received) = completed.received {
                record_with_path!(path;
                    completed.is_udp(),
                    completed.submitted.packet.destination().is_ipv6(),
                    received.packet.destination().is_ipv6(),
                    completed.is_peer(),
                    matches!(expected.request.destination(), Destination::DomainName { .. }),
                );
            }
            self.record_recovery(model, expected.origin, completed.route, path);
            self.record_existing_flow_after_idle(&completed, path);
            self.record_gateway_failover(&completed, path);
            self.record_tcp_survival(model, &completed, path);
        }
    }

    /// Records the kinds of change a route has recovered from since it last carried traffic.
    fn record_recovery(
        &mut self,
        model: &TunnelModel,
        origin: DeviceId,
        route: Route,
        path: PathFeedback,
    ) {
        let route = RouteKey::new(origin, route);
        let since = self
            .recovered
            .insert(route, self.changes.len())
            .unwrap_or(0);
        let kinds = self.changes_since(since, route, model);

        for &kind in &kinds {
            record_value!((kind as u16) << 2 | path.code());
        }
        for [&first, &second] in kinds.iter().array_combinations() {
            record_value!((first as u16 * KINDS + second as u16) << 2 | path.code());
        }
        record_value!((kinds.len().min(7) as u16) << 2 | path.code());
    }

    fn changes_since(
        &self,
        since: usize,
        route: RouteKey,
        model: &TunnelModel,
    ) -> BTreeSet<Change> {
        self.changes[since..]
            .iter()
            .filter(|(scope, _)| scope.covers(route, model))
            .map(|(_, change)| *change)
            .collect()
    }

    /// Records the kinds of change a TCP connection has survived since it was opened.
    fn record_tcp_survival(
        &mut self,
        model: &TunnelModel,
        completed: &CompletedRoundTrip<'_>,
        path: PathFeedback,
    ) {
        let (Some(flow), ProbeRequest::Tcp { write_len, .. }) =
            (self.current_tcp_flow, &completed.expected.request)
        else {
            return;
        };
        if write_len.is_none() {
            self.tcp_flows_opened.insert(flow, self.changes.len());
            return;
        }
        let Some(&since) = self.tcp_flows_opened.get(&flow) else {
            return;
        };
        let route = RouteKey::new(completed.expected.origin, completed.route);
        for kind in self.changes_since(since, route, model) {
            record_value!((kind as u16) << 2 | path.code());
        }
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
        if let Some(received) = completed.received {
            record_with_path!(path;
                completed.is_udp(),
                completed.submitted.packet.destination().is_ipv6(),
                received.packet.destination().is_ipv6(),
                completed.is_peer(),
                matches!(
                    completed.expected.request.destination(),
                    Destination::DomainName { .. }
                ),
            );
        }
        record_with_path!(path;
            attempt.duration >= DNS_NAT_SESSION_TTL,
            matches!(
                completed.expected.request.destination(),
                Destination::DomainName { .. }
            ),
        );

        record_with_path!(path;
            attempt.duration >= path.origin.expiry.timeout,
            attempt.duration >= path.remote.expiry.timeout,
            path.origin.expiry.inbound_refreshes,
            path.remote.expiry.inbound_refreshes,
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
        let Some(received) = completed.received else {
            return;
        };
        record_with_path!(path;
            completed.is_udp(),
            completed.submitted.packet.destination().is_ipv6(),
            received.packet.destination().is_ipv6(),
            matches!(
                completed.expected.request.destination(),
                Destination::DomainName { .. }
            ),
            completed.submitted.packet.destination() != received.packet.destination(),
        );
    }

    fn record_dns_query_feedback(
        &self,
        model: &TunnelModel,
        state: &RealTunnelSystem,
        portal: &FakePortal,
    ) {
        for (client_id, query) in &self.current_dns_queries {
            let Some(model_client) = model.clients.get(client_id) else {
                continue;
            };
            let Some(simulated_client) = state.clients.get(client_id) else {
                continue;
            };
            let model_client = model_client.inner();
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

            let site_specific = model_client.is_site_specific_dns_query(query).is_some();
            let via_resource = site_specific
                || model_client
                    .dns_query_via_resource(query, portal.upstream_do53())
                    .is_some();
            let learned_records = model_client
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

            let matching = model_client.dns_resources_by_domain(&query.domain, |_| true, |_| true);
            let sites = matching
                .iter()
                .flat_map(|resource| &resource.sites)
                .map(|site| site.id)
                .unique()
                .count();
            record_value!(((matching.len().min(4) as u16) << 1) | u16::from(sites >= 2));
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Change {
    Roamed,
    Restarted,
    PortalReconnected,
    InternetResourceToggled,
    RelaysDeployed,
    RelaysPartitioned,
    RelaysRebooted,
    RelayPortsExhausted,
    RelayPortsFreed,
    GatewayAuthorizationRevoked,
    GatewayDeauthorizedWhilePartitioned,
    PeerRemovedFromPool,
    PeerAuthorizationExpired,
    PeerAuthorizationRevoked,
    ResourceMetadataEdited,
    ResourceFiltersEdited,
    ResourceAccessEdited,
    ResourceIpStackEdited,
    DevicePoolRoutingEdited,
    ResourceTypeEdited,
    Idled,
    DnsRecordsChanged,
    DnsServersChanged,
    Crashed,
    GatewayCrashed,
    SpuriousPublicKeyChanged,
}

const KINDS: u16 = 26;

#[derive(Clone, Copy)]
enum Scope {
    Client(DeviceId),
    Resource(ResourceId),
    Peers(DeviceId, DeviceId),
    Everything,
}

impl Scope {
    fn covers(self, route: RouteKey, model: &TunnelModel) -> bool {
        match (self, route) {
            (Scope::Client(client), RouteKey::Resource(origin, _)) => client == origin,
            (Scope::Client(client), RouteKey::Peer(origin, peer)) => {
                client == origin || client == peer
            }
            (Scope::Resource(resource), RouteKey::Resource(_, target)) => resource == target,
            (Scope::Resource(pool), RouteKey::Peer(origin, peer)) => {
                model.clients.get(&origin).is_some_and(|client| {
                    client
                        .inner()
                        .authorized_pools_towards(peer)
                        .contains(&pool)
                })
            }
            (Scope::Peers(..), RouteKey::Resource(..)) => false,
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
    Resource(DeviceId, ResourceId),
    Peer(DeviceId, DeviceId),
}

impl RouteKey {
    fn new(origin: DeviceId, route: Route) -> Self {
        match route {
            Route::Resource { resource, .. } => RouteKey::Resource(origin, resource),
            Route::Peer(peer) => RouteKey::Peer(origin, peer),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct ClientResource {
    client: DeviceId,
    resource: ResourceId,
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
    /// `None` for a TCP write, which the remote receives on an established connection.
    received: Option<&'a ReceivedRequest>,
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
    state: &'a RealTunnelSystem,
) -> Option<CompletedRoundTrip<'a>> {
    let ExpectedOutcome::RoundTripCompleted(route, _) = expected.outcome else {
        return None;
    };
    let trace = state.probe_trace(expected.id);
    let (submitted, received) = match (
        trace.submitted_requests.as_slice(),
        trace.received_requests.as_slice(),
        trace.received_responses.as_slice(),
        trace.completed_streams.as_slice(),
    ) {
        ([submitted], [received], [_response], []) => (*submitted, Some(*received)),
        ([submitted], [], [], [_completed]) => (*submitted, None),
        _ => return None,
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

fn remote_path_feedback(
    model: &TunnelModel,
    state: &RealTunnelSystem,
    origin: DeviceId,
    remote: Remote,
) -> Option<PathFeedback> {
    let peer = match remote {
        Remote::Gateway(gateway) => {
            return gateway_path_feedback(model, state, origin, gateway);
        }
        Remote::Client(peer) => peer,
    };
    let origin_edge = model.network.edge_config(HostId::Client(origin));
    let remote_edge = model.network.edge_config(HostId::Client(peer));
    let selected = state
        .clients
        .get(&origin)?
        .inner()
        .state()
        .connection_path(peer)?;

    Some(PathFeedback::new(origin_edge, remote_edge, selected))
}

fn gateway_path_feedback(
    model: &TunnelModel,
    state: &RealTunnelSystem,
    origin: DeviceId,
    gateway: DeviceId,
) -> Option<PathFeedback> {
    let origin_edge = model.network.edge_config(HostId::Client(origin));
    let gateway_edge = model.network.edge_config(HostId::Gateway(gateway));
    let selected = state
        .clients
        .get(&origin)?
        .inner()
        .state()
        .connection_path(gateway)?;
    Some(PathFeedback::new(origin_edge, gateway_edge, selected))
}

/// Records whether a TCP connect was answered by a SYN-ACK, a reset or an ICMP error.
fn record_tcp_connect_outcome(
    model: &TunnelModel,
    state: &RealTunnelSystem,
    expected: &ExpectedProbe,
) {
    let ProbeRequest::Tcp {
        write_len: None, ..
    } = expected.request
    else {
        return;
    };
    let trace = state.probe_trace(expected.id);
    let ([submitted], [_response, ..]) = (
        trace.submitted_requests.as_slice(),
        trace.received_responses.as_slice(),
    ) else {
        return;
    };
    let (reset, icmp_error) = match expected.outcome {
        ExpectedOutcome::Dropped => return,
        ExpectedOutcome::RoundTripCompleted(_, Answer::Reset) => (true, false),
        ExpectedOutcome::RoundTripCompleted(_, _) => (false, false),
        ExpectedOutcome::Rejected { .. } => (false, true),
    };
    let ipv6 = submitted.packet.destination().is_ipv6();
    match expected
        .outcome
        .remote()
        .and_then(|remote| remote_path_feedback(model, state, expected.origin, remote))
    {
        Some(path) => record_with_path!(path; reset, icmp_error, ipv6),
        None => record!(reset, icmp_error, ipv6),
    }
}

fn record_translated_icmp_error_feedback(model: &TunnelModel, state: &RealTunnelSystem) {
    for expected in model.expected_probes.values() {
        let Some(completed) = completed_round_trip(expected, state) else {
            continue;
        };
        let Some(received) = completed.received else {
            continue;
        };
        let remote = completed.route.remote();
        let Remote::Gateway(gateway) = remote else {
            continue;
        };
        let Some(path) = remote_path_feedback(model, state, expected.origin, remote) else {
            continue;
        };
        let destination_was_translated =
            completed.submitted.packet.destination() != received.packet.destination();
        if !destination_was_translated {
            continue;
        }

        let responds_with_icmp_error = matches!(
            model.gateways[&gateway]
                .inner()
                .routes
                .route(received.packet.destination()),
            RouteType::Unreachable(_)
        );
        record_with_path!(path;
            completed.submitted.packet.destination().is_ipv6(),
            received.packet.destination().is_ipv6(),
            matches!(expected.request, ProbeRequest::Udp { .. }),
            matches!(expected.request, ProbeRequest::Tcp { .. }),
            responds_with_icmp_error,
        );
    }
}

/// Records probes sent through a Gateway that cannot reach or resolve their destination.
fn record_site_network_feedback(model: &TunnelModel, state: &RealTunnelSystem) {
    for expected in model.expected_probes.values() {
        let gateway = match expected.outcome {
            ExpectedOutcome::RoundTripCompleted(Route::Resource { gateway, .. }, _) => gateway,
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Gateway(gateway),
                ..
            } => gateway,
            ExpectedOutcome::RoundTripCompleted(_, _)
            | ExpectedOutcome::Rejected { .. }
            | ExpectedOutcome::Dropped => continue,
        };
        let gateway = model.gateways[&gateway].inner();
        let resolves = match expected.request.destination() {
            Destination::DomainName { name, .. } => gateway
                .resolve(name, &model.global_dns_records)
                .next()
                .is_some(),
            Destination::IpAddr(_) => true,
        };
        let route = state
            .probe_trace(expected.id)
            .received_requests
            .first()
            .map(|received| gateway.routes.route(received.packet.destination()));

        record!(
            matches!(
                expected.request.destination(),
                Destination::DomainName { .. }
            ),
            resolves,
            matches!(route, Some(RouteType::Unreachable(_))),
            matches!(route, Some(RouteType::Blackhole)),
            matches!(expected.request, ProbeRequest::Udp { .. }),
            matches!(expected.request, ProbeRequest::Tcp { .. }),
        );
    }
}

fn record_live_dns_flow_feedback(model: &TunnelModel, state: &RealTunnelSystem) {
    for observation in state.dns_nat_observations() {
        if observation.response_received_at.is_none()
            || state.now().duration_since(observation.received.at) >= DNS_NAT_SESSION_TTL
            || !(model.udp_flows.contains_key(&observation.flow_id)
                || model.icmp_flows.contains_key(&observation.flow_id))
        {
            continue;
        }
        let Remote::Gateway(gateway) = observation.received.remote else {
            continue;
        };
        let Some(path) = gateway_path_feedback(model, state, observation.submitted.client, gateway)
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
        let addresses = model
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

fn record_dns_refresh_feedback(model: &TunnelModel, state: &RealTunnelSystem) {
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
            gateway_path_feedback(model, state, session.key.client, session.key.gateway)
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

/// Records the IP families of a domain's proxy IPs before and after a Client changes them.
fn record_dns_proxy_ip_subset_feedback(state: &RealTunnelSystem) {
    for gateway in state.gateways.values() {
        for (previous, next) in gateway
            .inner()
            .dns_resolutions
            .values()
            .flat_map(|resolutions| resolutions.iter().tuple_windows())
        {
            if previous.dns_nat_generation != next.dns_nat_generation {
                continue;
            }
            let previous = previous.proxy_ips.iter().collect::<BTreeSet<_>>();
            let next = next.proxy_ips.iter().collect::<BTreeSet<_>>();
            if previous == next {
                continue;
            }

            record!(
                previous.iter().any(|ip| ip.is_ipv4()),
                previous.iter().any(|ip| ip.is_ipv6()),
                next.iter().any(|ip| ip.is_ipv4()),
                next.iter().any(|ip| ip.is_ipv6()),
            );
        }
    }
}

/// Records the mode of each NAT device that two or more Clients share.
fn record_shared_nat_feedback(model: &TunnelModel) {
    for edge in model.network.edges_shared_by_clients() {
        let flags = pack(&[
            edge.mapping == Mapping::EndpointDependent,
            edge.filter == FilterMode::AddressRestricted,
            edge.filter == FilterMode::PortRestricted,
            edge.expiry.inbound_refreshes,
        ]);
        record_value!(flags | (edge.expiry.timeout.as_secs() as u16) << 4);
    }
}

/// Records the IP stacks of DNS resources sharing a Gateway for a domain the Client resolved.
fn record_shared_dns_resource_gateway_feedback(model: &TunnelModel) {
    for client in model.clients.values() {
        let client = client.inner();
        let resources = client
            .all_resources()
            .into_iter()
            .filter_map(Resource::into_dns)
            .filter_map(|resource| Some((client.gateway_for_resource(resource.id)?, resource)))
            .collect::<Vec<_>>();

        for domain in client.dns_records.keys() {
            let mut stacks_by_gateway = BTreeMap::<DeviceId, Vec<IpStack>>::new();
            for (gateway, resource) in &resources {
                if dns::is_subdomain(domain, &resource.address) {
                    stacks_by_gateway
                        .entry(*gateway)
                        .or_default()
                        .push(resource.ip_stack);
                }
            }

            for stacks in stacks_by_gateway
                .values()
                .filter(|stacks| stacks.len() >= 2)
            {
                record!(
                    stacks.contains(&IpStack::Dual),
                    stacks.contains(&IpStack::Ipv4Only),
                    stacks.contains(&IpStack::Ipv6Only),
                );
            }
        }
    }
}

fn ip_stack_changed(edit: &ResourceEdit) -> bool {
    let (Resource::Dns(old), Resource::Dns(new)) = (&edit.old, &edit.new) else {
        return false;
    };

    old.ip_stack != new.ip_stack
}
