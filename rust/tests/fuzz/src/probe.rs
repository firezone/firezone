use std::{net::IpAddr, time::Instant};

use connlib_model::{ClientId, GatewayId, ResourceId};
use ip_packet::{IpPacket, Protocol};

use crate::transition::{DPort, Destination, Identifier, SPort, Seq};

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum ProbeProtocol {
    Icmp { seq: Seq, identifier: Identifier },
    Udp { sport: SPort, dport: DPort },
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
pub(crate) enum PacketRoute {
    Drop,
    Resource {
        resource: ResourceId,
        gateway: GatewayId,
    },
    RejectedByClient,
    ResourceRejectedByGateway {
        resource: ResourceId,
        gateway: GatewayId,
    },
    ResourceUnreachableByGateway {
        resource: ResourceId,
        gateway: GatewayId,
    },
    Gateway(GatewayId),
    Peer(ClientId),
    PeerRejectedByPeer(ClientId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Remote {
    Gateway(GatewayId),
    Client(ClientId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExpectedOutcome {
    Dropped,
    RoundTripCompleted {
        remote: Remote,
        resource: Option<ResourceId>,
    },
    Rejected {
        by: RejectionRemote,
        response: RejectionResponse,
    },
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
    ExactOrSubmissionOnly(KnownLoss),
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

impl ProbeObservation {
    pub(crate) fn id(&self) -> ProbeId {
        match self {
            ProbeObservation::RequestSubmitted(observation) => observation.id,
            ProbeObservation::RequestReceived(observation) => observation.id,
            ProbeObservation::ResponseReceived(observation) => observation.id,
        }
    }
}
