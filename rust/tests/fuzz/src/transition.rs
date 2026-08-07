use connlib_model::{ClientId, GatewayId, RelayId, ResourceId};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use tunnel_proto::{
    dns,
    messages::{UpstreamDo53, UpstreamDoH},
};

use super::{
    network_input::MalformedNetworkDatagramInput,
    packet_input::UnroutablePacketInput,
    probe::{ProbeId, TcpFlow, UdpFlow},
    reference::PrivateKey,
    resource::{Resource, ResourceEdit},
    sim_net::Host,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::Duration,
};

#[allow(private_interfaces)]
#[derive(Clone, Debug)]
pub enum Transition {
    AddResource(Resource),
    RemoveResource(ResourceId),
    EditResource(ResourceEdit),
    SetInternetResourceState {
        client_id: ClientId,
        active: bool,
    },
    SendIcmpPacket {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        probe_id: ProbeId,
    },
    SendIcmpPacketWithGatewayDnsResolutionFailure {
        client_id: ClientId,
        gateway_id: GatewayId,
        src: IpAddr,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        probe_id: ProbeId,
    },
    RefreshGatewayDnsResolutionWithFailure {
        client_id: ClientId,
        gateway_id: GatewayId,
        query: DnsQuery,
    },
    SendUdpPacket {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        probe_id: ProbeId,
    },
    SendUdpPacketOnFlow {
        flow: UdpFlow,
        probe_id: ProbeId,
    },
    ReceiveMalformedNetworkDatagram(MalformedNetworkDatagramInput),
    SendUnroutablePacket(UnroutablePacketInput),
    ConnectTcp {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
    },
    SendTcpDataOnFlow {
        flow: TcpFlow,
        probe_id: ProbeId,
    },
    SendDnsQuery {
        client_id: ClientId,
        query: DnsQuery,
    },
    SendDnsResourcePtrQuery {
        client_id: ClientId,
        record_domain: DomainName,
        family: IpFamily,
        address_index: u32,
        query_id: u16,
        dns_server: dns::Upstream,
        transport: DnsTransport,
    },
    SendTruncatedUdpDnsQuery {
        client_id: ClientId,
        query: TruncatedDnsQuery,
    },
    UpdateSystemDnsServers {
        servers: Vec<IpAddr>,
    },
    UpdateUpstreamDo53Servers(Vec<UpstreamDo53>),
    UpdateUpstreamDoHServers(Vec<UpstreamDoH>),
    UpdateUpstreamSearchDomain(Option<DomainName>),
    RoamClient {
        client_id: ClientId,
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
        nat_ip4: Ipv4Addr,
        dead_window: Duration,
        portal_window: Duration,
    },
    RebindClientNat {
        client_id: ClientId,
    },
    ReconnectPortal {
        client_id: ClientId,
    },
    RestartClient {
        client_id: ClientId,
        key: PrivateKey,
    },
    DeployNewRelays(BTreeMap<RelayId, Host<u64>>),
    UpdateRelayPresence {
        disconnected: BTreeSet<RelayId>,
        connected: BTreeMap<RelayId, Host<u64>>,
    },
    PartitionRelaysFromPortal,
    DropNextWirePacket,
    Idle,
    RebootRelaysWhilePartitioned(BTreeMap<RelayId, Host<u64>>),
    DeauthorizeWhileGatewayIsPartitioned(ResourceId),
    ExpireGatewayAuthorization {
        client_id: ClientId,
        resource_id: ResourceId,
    },
    UpdateDnsRecords {
        domain: DomainName,
        records: BTreeSet<OwnedRecordData>,
    },
}

impl Transition {
    /// Returns whether assertions should discard stale packets before applying this transition.
    pub fn should_clear_packets(&self) -> bool {
        match self {
            Transition::AddResource(_) => true,
            Transition::RemoveResource(_) => true,
            Transition::EditResource(_) => true,
            Transition::SetInternetResourceState { .. } => true,
            Transition::SendIcmpPacket { .. } => false,
            Transition::SendIcmpPacketWithGatewayDnsResolutionFailure { .. } => false,
            Transition::RefreshGatewayDnsResolutionWithFailure { .. } => false,
            Transition::SendUdpPacket { .. } => false,
            Transition::SendUdpPacketOnFlow { .. } => false,
            Transition::ReceiveMalformedNetworkDatagram(_) => false,
            Transition::SendUnroutablePacket(_) => false,
            Transition::ConnectTcp { .. } => false,
            Transition::SendTcpDataOnFlow { .. } => false,
            Transition::SendDnsQuery { .. } => false,
            Transition::SendDnsResourcePtrQuery { .. } => false,
            Transition::SendTruncatedUdpDnsQuery { .. } => false,
            Transition::UpdateSystemDnsServers { .. } => false,
            Transition::UpdateUpstreamDo53Servers(_) => false,
            Transition::UpdateUpstreamDoHServers(_) => false,
            Transition::UpdateUpstreamSearchDomain(_) => false,
            Transition::RoamClient { .. } => false,
            Transition::RebindClientNat { .. } => false,
            Transition::ReconnectPortal { .. } => false,
            Transition::RestartClient { .. } => false,
            Transition::DeployNewRelays(_) => false,
            Transition::UpdateRelayPresence { .. } => false,
            Transition::PartitionRelaysFromPortal => false,
            Transition::DropNextWirePacket => false,
            Transition::Idle => false,
            Transition::RebootRelaysWhilePartitioned(_) => false,
            Transition::DeauthorizeWhileGatewayIsPartitioned(_) => true,
            Transition::ExpireGatewayAuthorization { .. } => true,
            Transition::UpdateDnsRecords { .. } => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct TruncatedDnsQuery {
    pub(crate) dns_server: dns::Upstream,
    pub(crate) local_port: u16,
    payload: Vec<u8>,
}

impl TruncatedDnsQuery {
    pub(crate) const DNS_HEADER_LEN: usize = 12;

    pub(crate) fn new(dns_server: dns::Upstream, local_port: u16, payload: Vec<u8>) -> Self {
        assert!(payload.len() < Self::DNS_HEADER_LEN);

        Self {
            dns_server,
            local_port,
            payload,
        }
    }

    pub(crate) fn payload(&self) -> &[u8] {
        &self.payload
    }
}

#[derive(Debug, Clone)]
pub(crate) struct DnsQuery {
    pub(crate) domain: DomainName,
    pub(crate) r_type: RecordType,
    pub(crate) query_id: u16,
    pub(crate) dns_server: dns::Upstream,
    pub(crate) transport: DnsTransport,
    pub(crate) client_resolution: ClientDnsResolution,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum ClientDnsResolution {
    Succeeded,
    Failed,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum IpFamily {
    Ipv4,
    Ipv6,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum DnsTransport {
    Udp { local_port: u16 },
    Tcp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct Seq(pub u16);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct Identifier(pub u16);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct SPort(pub u16);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct DPort(pub u16);

#[derive(Clone, derive_more::Debug)]
pub(crate) enum Destination {
    DomainName { resolved_ip: u32, name: DomainName },
    IpAddr(IpAddr),
}

impl Destination {
    pub(crate) fn ip_addr(&self) -> Option<IpAddr> {
        match self {
            Destination::DomainName { .. } => None,
            Destination::IpAddr(addr) => Some(*addr),
        }
    }
}

impl Ord for Destination {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match (self, other) {
            (
                Destination::DomainName { name: left, .. },
                Destination::DomainName { name: right, .. },
            ) => left.cmp(right),
            (Destination::IpAddr(left), Destination::IpAddr(right)) => left.cmp(right),
            (Destination::DomainName { .. }, Destination::IpAddr(_)) => std::cmp::Ordering::Less,
            (Destination::IpAddr(_), Destination::DomainName { .. }) => std::cmp::Ordering::Greater,
        }
    }
}

impl PartialOrd for Destination {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Eq for Destination {}

impl std::hash::Hash for Destination {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        match self {
            Destination::DomainName { name, .. } => name.hash(state),
            Destination::IpAddr(ip_addr) => ip_addr.hash(state),
        }
    }
}

impl PartialEq for Destination {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::DomainName { name: l_name, .. }, Self::DomainName { name: r_name, .. }) => {
                l_name == r_name
            }
            (Self::IpAddr(l0), Self::IpAddr(r0)) => l0 == r0,
            _ => false,
        }
    }
}
