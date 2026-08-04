use connlib_model::{ClientId, RelayId, ResourceId, Site};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use ip_network::IpNetwork;
use tunnel_proto::{
    dns,
    messages::{Filter, UpstreamDo53, UpstreamDoH, client::DevicePoolMember},
};

use super::{
    probe::ProbeId,
    reference::PrivateKey,
    resource::{CidrResource, Resource},
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
    ChangeCidrResourceAddress {
        resource: CidrResource,
        new_address: IpNetwork,
    },
    MoveResourceToNewSite {
        resource: Resource,
        new_site: Site,
    },
    ChangeFiltersOfResource {
        resource: Resource,
        new_filters: Vec<Filter>,
    },
    ChangeResourceType {
        old_resource: Resource,
        new_resource: Resource,
    },
    UpdateStaticDevicePool {
        pool_id: ResourceId,
        new_devices: Vec<DevicePoolMember>,
    },
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
    SendUdpPacket {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        probe_id: ProbeId,
    },
    ConnectTcp {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
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
    SendMalformedDnsQuery {
        client_id: ClientId,
        kind: MalformedDnsQuery,
        query_id: u16,
        dns_server: dns::Upstream,
        local_port: u16,
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
    ReconnectPortal {
        client_id: ClientId,
    },
    RestartClient {
        client_id: ClientId,
        key: PrivateKey,
    },
    DeployNewRelays(BTreeMap<RelayId, Host<u64>>),
    PartitionRelaysFromPortal,
    Idle,
    RebootRelaysWhilePartitioned(BTreeMap<RelayId, Host<u64>>),
    DeauthorizeWhileGatewayIsPartitioned(ResourceId),
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
            Transition::ChangeCidrResourceAddress { .. } => true,
            Transition::MoveResourceToNewSite { .. } => true,
            Transition::ChangeFiltersOfResource { .. } => true,
            Transition::ChangeResourceType { .. } => true,
            Transition::UpdateStaticDevicePool { .. } => true,
            Transition::SetInternetResourceState { .. } => true,
            Transition::SendIcmpPacket { .. } => false,
            Transition::SendUdpPacket { .. } => false,
            Transition::ConnectTcp { .. } => false,
            Transition::SendDnsQuery { .. } => false,
            Transition::SendDnsResourcePtrQuery { .. } => false,
            Transition::SendMalformedDnsQuery { .. } => false,
            Transition::UpdateSystemDnsServers { .. } => false,
            Transition::UpdateUpstreamDo53Servers(_) => false,
            Transition::UpdateUpstreamDoHServers(_) => false,
            Transition::UpdateUpstreamSearchDomain(_) => false,
            Transition::RoamClient { .. } => false,
            Transition::ReconnectPortal { .. } => false,
            Transition::RestartClient { .. } => false,
            Transition::DeployNewRelays(_) => false,
            Transition::PartitionRelaysFromPortal => false,
            Transition::Idle => false,
            Transition::RebootRelaysWhilePartitioned(_) => false,
            Transition::DeauthorizeWhileGatewayIsPartitioned(_) => true,
            Transition::UpdateDnsRecords { .. } => false,
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct DnsQuery {
    pub(crate) domain: DomainName,
    pub(crate) r_type: RecordType,
    pub(crate) query_id: u16,
    pub(crate) dns_server: dns::Upstream,
    pub(crate) transport: DnsTransport,
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

/// The ways in which a DNS query can be structurally invalid.
///
/// The client must drop all of these without emitting a response.
#[derive(Debug, Clone, Copy)]
pub(crate) enum MalformedDnsQuery {
    /// The QR bit claims the message is a response.
    QrBitSet,
    /// The message does not contain a question.
    NoQuestion,
    /// The message contains two questions.
    TwoQuestions,
    /// The message is shorter than a DNS header.
    TruncatedHeader,
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
