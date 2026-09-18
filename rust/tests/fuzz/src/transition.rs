use connlib_model::{ClientId, RelayId, ResourceId, Site};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use ip_network::IpNetwork;
use tunnel_proto::{
    dns,
    messages::{Filter, UpstreamDo53, UpstreamDoH},
};

use super::{
    probe::{FlowId, ProbeId, Route},
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
    /// Replaces the member list of a pool that lists its members; `removed` are the
    /// clients that were listed before and are not any more.
    UpdateDevicePoolMembers {
        pool_id: ResourceId,
        members: BTreeSet<ClientId>,
        removed: BTreeSet<ClientId>,
    },
    SetInternetResourceState {
        client_id: ClientId,
        active: bool,
    },
    SendIcmpPacketOnNewFlow {
        flow_id: FlowId,
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        probe_id: ProbeId,
    },
    SendIcmpPacketOnExistingFlow {
        flow_id: FlowId,
        seq: Seq,
        probe_id: ProbeId,
    },
    SendUdpPacketOnNewFlow {
        flow_id: FlowId,
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        probe_id: ProbeId,
    },
    SendUdpPacketOnExistingFlow {
        flow_id: FlowId,
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
    /// Bookkeeping that is stale once this transition is applied.
    pub fn invalidates(&self) -> Invalidates {
        match self {
            Transition::AddResource(_) => Invalidates::PROBES | Invalidates::PACKETS,
            Transition::RemoveResource(_) => Invalidates::PROBES | Invalidates::PACKETS,
            Transition::ChangeCidrResourceAddress { .. } => {
                Invalidates::PROBES | Invalidates::PACKETS
            }
            Transition::MoveResourceToNewSite { .. } => Invalidates::PROBES | Invalidates::PACKETS,
            Transition::ChangeFiltersOfResource { .. } => {
                Invalidates::PROBES | Invalidates::PACKETS
            }
            Transition::ChangeResourceType { .. } => Invalidates::PROBES | Invalidates::PACKETS,
            Transition::UpdateDevicePoolMembers { .. } => {
                Invalidates::PROBES | Invalidates::PACKETS
            }
            Transition::SetInternetResourceState { .. } => {
                Invalidates::PROBES | Invalidates::PACKETS
            }
            Transition::SendIcmpPacketOnNewFlow { .. } => Invalidates::PROBES,
            Transition::SendIcmpPacketOnExistingFlow { .. } => Invalidates::PROBES,
            Transition::SendUdpPacketOnNewFlow { .. } => Invalidates::PROBES,
            Transition::SendUdpPacketOnExistingFlow { .. } => Invalidates::PROBES,
            Transition::ConnectTcp { .. } => Invalidates::PROBES,
            Transition::SendDnsQuery { .. } => Invalidates::PROBES,
            Transition::SendDnsResourcePtrQuery { .. } => Invalidates::PROBES,
            Transition::UpdateSystemDnsServers { .. } => Invalidates::PROBES,
            Transition::UpdateUpstreamDo53Servers(_) => Invalidates::PROBES,
            Transition::UpdateUpstreamDoHServers(_) => Invalidates::PROBES,
            Transition::UpdateUpstreamSearchDomain(_) => Invalidates::PROBES,
            Transition::RoamClient { .. } => Invalidates::PROBES,
            Transition::ReconnectPortal { .. } => Invalidates::PROBES,
            Transition::RestartClient { .. } => Invalidates::PROBES,
            Transition::DeployNewRelays(_) => Invalidates::PROBES,
            Transition::PartitionRelaysFromPortal => Invalidates::PROBES,
            Transition::Idle => Invalidates::PROBES,
            Transition::RebootRelaysWhilePartitioned(_) => Invalidates::PROBES,
            Transition::DeauthorizeWhileGatewayIsPartitioned(_) => {
                Invalidates::PROBES | Invalidates::PACKETS
            }
            Transition::UpdateDnsRecords { .. } => Invalidates::PROBES,
        }
    }

    /// Returns whether a flow remains predictable across this transition.
    pub(crate) fn retains_flow(&self, client_id: ClientId, route: Route, iceless: bool) -> bool {
        match self {
            Transition::AddResource(_) => match route {
                Route::Resource { .. } => false,
                Route::Gateway(_) => true,
                Route::Peer(_) => true,
            },
            Transition::RemoveResource(resource) => match route {
                Route::Resource { resource: used, .. } => used != *resource,
                Route::Gateway(_) => false,
                Route::Peer(_) => false,
            },
            Transition::ChangeCidrResourceAddress { .. } => match route {
                Route::Resource { .. } => false,
                Route::Gateway(_) => false,
                Route::Peer(_) => true,
            },
            Transition::MoveResourceToNewSite { resource, .. } => match route {
                Route::Resource { resource: used, .. } => used != resource.id(),
                Route::Gateway(_) => false,
                Route::Peer(_) => true,
            },
            Transition::ChangeFiltersOfResource { resource, .. } => match route {
                Route::Resource { .. } => false,
                Route::Gateway(_) => false,
                Route::Peer(_) => !is_device_pool(resource),
            },
            Transition::ChangeResourceType {
                old_resource,
                new_resource,
            } => match route {
                Route::Resource { .. } => false,
                Route::Gateway(_) => false,
                Route::Peer(_) => !is_device_pool(old_resource) && !is_device_pool(new_resource),
            },
            Transition::UpdateDevicePoolMembers { removed, .. } => match route {
                Route::Resource { .. } => true,
                Route::Gateway(_) => true,
                Route::Peer(peer) => !removed.contains(&peer) && !removed.contains(&client_id),
            },
            Transition::SetInternetResourceState {
                client_id: changed, ..
            } => client_id != *changed,
            Transition::SendIcmpPacketOnNewFlow { .. } => true,
            Transition::SendIcmpPacketOnExistingFlow { .. } => true,
            Transition::SendUdpPacketOnNewFlow { .. } => true,
            Transition::SendUdpPacketOnExistingFlow { .. } => true,
            Transition::ConnectTcp { .. } => true,
            Transition::SendDnsQuery { .. } => true,
            Transition::SendDnsResourcePtrQuery { .. } => true,
            Transition::UpdateSystemDnsServers { .. } => true,
            Transition::UpdateUpstreamDo53Servers(_) => true,
            Transition::UpdateUpstreamDoHServers(_) => true,
            Transition::UpdateUpstreamSearchDomain(_) => true,
            Transition::RoamClient {
                client_id: changed, ..
            } => match route {
                Route::Resource { .. } => iceless || client_id != *changed,
                Route::Gateway(_) => iceless || client_id != *changed,
                Route::Peer(peer) => iceless || (client_id != *changed && peer != *changed),
            },
            Transition::ReconnectPortal { .. } => true,
            Transition::RestartClient {
                client_id: restarted,
                ..
            } => match route {
                Route::Resource { .. } => client_id != *restarted,
                Route::Gateway(_) => client_id != *restarted,
                Route::Peer(peer) => client_id != *restarted && peer != *restarted,
            },
            Transition::DeployNewRelays(_) => iceless,
            Transition::PartitionRelaysFromPortal => false,
            Transition::Idle => true,
            Transition::RebootRelaysWhilePartitioned(_) => false,
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => match route {
                Route::Resource { resource: used, .. } => used != *resource,
                Route::Gateway(_) => false,
                Route::Peer(_) => false,
            },
            Transition::UpdateDnsRecords { .. } => true,
        }
    }
}

fn is_device_pool(resource: &Resource) -> bool {
    match resource {
        Resource::Dns(_) => false,
        Resource::Cidr(_) => false,
        Resource::Internet(_) => false,
        Resource::DevicePool(_) => true,
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

/// Bookkeeping recorded by the reference model and the system under test that a
/// [`Transition`] makes stale.
#[derive(Debug, Clone, Copy)]
pub struct Invalidates(u8);

impl Invalidates {
    /// The probes recorded for the previous transition and their observations.
    pub const PROBES: Self = Self(1 << 0);
    /// Packet-level expectations that accumulate across transitions: DNS queries
    /// and responses, TCP connections and rejections.
    pub const PACKETS: Self = Self(1 << 1);

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

impl std::ops::BitOr for Invalidates {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}
