use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
    time::{Duration, Instant},
};

use connlib_model::{ClientId, GatewayId, ResourceId};
use ip_packet::{IpPacket, Protocol, UnsupportedProtocol};

use crate::icmp_error_hosts::IcmpErrorHosts;
use crate::transition::{DPort, Destination, Identifier, SPort, Seq};

pub(crate) const DNS_NAT_SESSION_TTL: Duration = Duration::from_secs(2 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct ProbeId(u64);

impl ProbeId {
    pub(crate) fn new(value: u64) -> Self {
        Self(value)
    }

    pub(crate) fn to_be_bytes(self) -> [u8; 8] {
        self.0.to_be_bytes()
    }

    pub(crate) fn from_payload(payload: &[u8]) -> Option<Self> {
        let bytes = payload.first_chunk()?;

        Some(Self(u64::from_be_bytes(*bytes)))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct FlowId(u64);

impl FlowId {
    pub(crate) fn new(value: u64) -> Self {
        Self(value)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum ProbeProtocol {
    Icmp { seq: Seq, identifier: Identifier },
    Udp { sport: SPort, dport: DPort },
}

#[derive(Debug, Clone)]
pub(crate) struct IcmpFlow {
    pub(crate) client_id: ClientId,
    pub(crate) src: IpAddr,
    pub(crate) dst: Destination,
    pub(crate) identifier: Identifier,
    pub(crate) next_seq: Seq,
    pub(crate) route: Route,
}

#[derive(Debug, Clone)]
pub(crate) struct UdpFlow {
    pub(crate) client_id: ClientId,
    pub(crate) src: IpAddr,
    pub(crate) dst: Destination,
    pub(crate) sport: SPort,
    pub(crate) dport: DPort,
    pub(crate) route: Route,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Route {
    Resource {
        resource: ResourceId,
        gateway: GatewayId,
    },
    Gateway(GatewayId),
    Peer(ClientId),
}

impl Route {
    pub(crate) fn remote(self) -> Remote {
        match self {
            Route::Resource { gateway, .. } => Remote::Gateway(gateway),
            Route::Gateway(gateway) => Remote::Gateway(gateway),
            Route::Peer(client) => Remote::Client(client),
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) enum ProbeRequest {
    Icmp {
        src: IpAddr,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
    },
    Udp {
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
    },
}

impl ProbeRequest {
    pub(crate) fn source(&self) -> IpAddr {
        match self {
            ProbeRequest::Icmp { src, .. } => *src,
            ProbeRequest::Udp { src, .. } => *src,
        }
    }

    pub(crate) fn destination(&self) -> &Destination {
        match self {
            ProbeRequest::Icmp { dst, .. } => dst,
            ProbeRequest::Udp { dst, .. } => dst,
        }
    }

    pub(crate) fn protocol(&self) -> Protocol {
        match self {
            ProbeRequest::Icmp { identifier, .. } => Protocol::IcmpEcho(identifier.0),
            ProbeRequest::Udp { dport, .. } => Protocol::Udp(dport.0),
        }
    }

    pub(crate) fn probe_protocol(&self) -> ProbeProtocol {
        match self {
            ProbeRequest::Icmp {
                seq, identifier, ..
            } => ProbeProtocol::Icmp {
                seq: *seq,
                identifier: *identifier,
            },
            ProbeRequest::Udp { sport, dport, .. } => ProbeProtocol::Udp {
                sport: *sport,
                dport: *dport,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Remote {
    Gateway(GatewayId),
    Client(ClientId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExpectedOutcome {
    Dropped,
    RoundTripCompleted(Route),
    Rejected {
        by: RejectionRemote,
        response: RejectionResponse,
    },
}

impl ExpectedOutcome {
    /// The remote the packet reached, if any.
    pub(crate) fn remote(self) -> Option<Remote> {
        match self {
            ExpectedOutcome::Dropped => None,
            ExpectedOutcome::RoundTripCompleted(route) => Some(route.remote()),
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Local,
                ..
            } => None,
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Gateway(gateway),
                ..
            } => Some(Remote::Gateway(gateway)),
            ExpectedOutcome::Rejected {
                by: RejectionRemote::Client(client),
                ..
            } => Some(Remote::Client(client)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RejectionRemote {
    Local,
    Gateway(GatewayId),
    Client(ClientId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RejectionResponse {
    Prohibited,
    Unreachable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TraceRequirement {
    Exact,
    ExactOrLoss(KnownLoss),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KnownLoss {
    ConnectionReset,
    WireGuardRekey,
}

#[derive(Debug, Clone)]
pub(crate) struct ExpectedProbe {
    pub(crate) id: ProbeId,
    pub(crate) origin: ClientId,
    pub(crate) sent_at: Instant,
    pub(crate) request: ProbeRequest,
    pub(crate) outcome: ExpectedOutcome,
    pub(crate) trace_requirement: TraceRequirement,
}

pub(crate) fn remote_responds_with_icmp_error(
    expected: &ExpectedProbe,
    received_request: &ReceivedRequest,
    remote: Remote,
    icmp_error_hosts: &IcmpErrorHosts,
) -> bool {
    let is_icmp_peer = match (&expected.request, remote) {
        (ProbeRequest::Icmp { .. }, Remote::Gateway(_)) => false,
        (ProbeRequest::Icmp { .. }, Remote::Client(_)) => true,
        (ProbeRequest::Udp { .. }, Remote::Gateway(_)) => false,
        (ProbeRequest::Udp { .. }, Remote::Client(_)) => false,
    };

    !is_icmp_peer
        && icmp_error_hosts
            .icmp_error_for_ip(received_request.packet.destination())
            .is_some()
}

#[derive(Debug, Clone)]
pub(crate) struct SubmittedRequest {
    pub(crate) id: ProbeId,
    pub(crate) at: Instant,
    pub(crate) client: ClientId,
    pub(crate) packet: IpPacket,
}

#[derive(Debug, Clone)]
pub(crate) struct ReceivedRequest {
    pub(crate) id: ProbeId,
    pub(crate) at: Instant,
    pub(crate) remote: Remote,
    pub(crate) gateway_order: Option<u64>,
    pub(crate) dns_nat_generation: Option<u64>,
    pub(crate) packet: IpPacket,
}

#[derive(Debug, Clone)]
pub(crate) struct ReceivedResponse {
    pub(crate) id: ProbeId,
    pub(crate) at: Instant,
    pub(crate) client: ClientId,
    pub(crate) packet: IpPacket,
}

#[derive(Debug, Clone)]
pub(crate) enum ProbeObservation {
    RequestSubmitted(SubmittedRequest),
    RequestReceived(ReceivedRequest),
    ResponseReceived(ReceivedResponse),
}

#[derive(Debug, Clone)]
pub(crate) struct DnsNatObservation {
    pub(crate) domain: dns_types::DomainName,
    pub(crate) flow_id: FlowId,
    pub(crate) submitted: SubmittedRequest,
    pub(crate) received: ReceivedRequest,
    pub(crate) response_received_at: Option<Instant>,
    pub(crate) dns_addresses: BTreeSet<IpAddr>,
}

#[derive(Debug)]
pub(crate) struct ProbeTrace<'a> {
    pub(crate) observations: Vec<&'a ProbeObservation>,
    pub(crate) submitted_requests: Vec<&'a SubmittedRequest>,
    pub(crate) received_requests: Vec<&'a ReceivedRequest>,
    pub(crate) received_responses: Vec<&'a ReceivedResponse>,
}

impl<'a> ProbeTrace<'a> {
    pub(crate) fn new(observations: impl Iterator<Item = &'a ProbeObservation>) -> Self {
        let observations = observations.collect::<Vec<_>>();
        let submitted_requests = observations
            .iter()
            .copied()
            .filter_map(ProbeObservation::as_submitted_request)
            .collect();
        let received_requests = observations
            .iter()
            .copied()
            .filter_map(ProbeObservation::as_received_request)
            .collect();
        let received_responses = observations
            .iter()
            .copied()
            .filter_map(ProbeObservation::as_received_response)
            .collect();

        Self {
            observations,
            submitted_requests,
            received_requests,
            received_responses,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct DnsNatKey {
    pub(crate) client: ClientId,
    pub(crate) gateway: GatewayId,
    pub(crate) dns_nat_generation: u64,
    pub(crate) proxy: IpAddr,
    pub(crate) protocol: Protocol,
}

#[derive(Debug)]
pub(crate) enum InvalidDnsNatObservation {
    RemoteIsClient(ClientId),
    Tcp(u16),
    UnsupportedProtocol(UnsupportedProtocol),
    MissingGeneration(GatewayId),
}

pub(crate) struct DnsNatSession<'a> {
    pub(crate) key: DnsNatKey,
    pub(crate) observations: Vec<&'a DnsNatObservation>,
}

pub(crate) struct DnsNatSessions<'a> {
    pub(crate) invalid: Vec<(&'a DnsNatObservation, InvalidDnsNatObservation)>,
    pub(crate) sessions: Vec<DnsNatSession<'a>>,
}

impl<'a> DnsNatSessions<'a> {
    pub(crate) fn new(observations: &'a [DnsNatObservation]) -> Self {
        let mut observations_by_nat_key = BTreeMap::<DnsNatKey, Vec<_>>::new();
        let mut invalid = Vec::new();

        for observation in observations {
            match observation.nat_key() {
                Ok(key) => observations_by_nat_key
                    .entry(key)
                    .or_default()
                    .push(observation),
                Err(error) => invalid.push((observation, error)),
            }
        }

        let sessions = observations_by_nat_key
            .into_iter()
            .flat_map(|(key, observations)| {
                observations
                    .chunk_by(|previous, current| {
                        current
                            .received
                            .at
                            .saturating_duration_since(previous.received.at)
                            < DNS_NAT_SESSION_TTL
                    })
                    .map(move |observations| DnsNatSession {
                        key,
                        observations: observations.to_vec(),
                    })
                    .collect::<Vec<_>>()
            })
            .collect();

        Self { invalid, sessions }
    }
}

impl DnsNatObservation {
    fn nat_key(&self) -> Result<DnsNatKey, InvalidDnsNatObservation> {
        let gateway = match self.received.remote {
            Remote::Gateway(gateway) => gateway,
            Remote::Client(client) => {
                return Err(InvalidDnsNatObservation::RemoteIsClient(client));
            }
        };
        let protocol = match self.submitted.packet.source_protocol() {
            Ok(Protocol::Udp(port)) => Protocol::Udp(port),
            Ok(Protocol::IcmpEcho(identifier)) => Protocol::IcmpEcho(identifier),
            Ok(Protocol::Tcp(port)) => return Err(InvalidDnsNatObservation::Tcp(port)),
            Err(error) => return Err(InvalidDnsNatObservation::UnsupportedProtocol(error)),
        };
        let Some(dns_nat_generation) = self.received.dns_nat_generation else {
            return Err(InvalidDnsNatObservation::MissingGeneration(gateway));
        };

        Ok(DnsNatKey {
            client: self.submitted.client,
            gateway,
            dns_nat_generation,
            proxy: self.submitted.packet.destination(),
            protocol,
        })
    }
}

impl ProbeObservation {
    pub(crate) fn id(&self) -> ProbeId {
        match self {
            ProbeObservation::RequestSubmitted(observation) => observation.id,
            ProbeObservation::RequestReceived(observation) => observation.id,
            ProbeObservation::ResponseReceived(observation) => observation.id,
        }
    }

    pub(crate) fn as_submitted_request(&self) -> Option<&SubmittedRequest> {
        match self {
            ProbeObservation::RequestSubmitted(submitted) => Some(submitted),
            ProbeObservation::RequestReceived(_) => None,
            ProbeObservation::ResponseReceived(_) => None,
        }
    }

    pub(crate) fn as_received_request(&self) -> Option<&ReceivedRequest> {
        match self {
            ProbeObservation::RequestSubmitted(_) => None,
            ProbeObservation::RequestReceived(received) => Some(received),
            ProbeObservation::ResponseReceived(_) => None,
        }
    }

    pub(crate) fn as_received_response(&self) -> Option<&ReceivedResponse> {
        match self {
            ProbeObservation::RequestSubmitted(_) => None,
            ProbeObservation::RequestReceived(_) => None,
            ProbeObservation::ResponseReceived(received) => Some(received),
        }
    }
}
