use connlib_model::{ClientId, RelayId, ResourceId};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use tunnel_proto::{
    dns,
    messages::{UpstreamDo53, UpstreamDoH},
};

use super::{
    probe::{FlowId, ProbeId, Route},
    reference::PrivateKey,
    resource::{EditEffect, Resource, ResourceEdit, classify},
    sim_net::Host,
    stub_portal::PeerAuthorization,
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
    /// Replaces the member list of a pool that lists its members; `revoked` are the
    /// portal's peer authorizations through it towards a client that left.
    UpdateDevicePoolMembers {
        pool_id: ResourceId,
        members: BTreeSet<ClientId>,
        revoked: Vec<PeerAuthorization>,
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
    SendDnsQueries(Vec<(ClientId, DnsQuery)>),
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
    /// Revokes the authorization for a resource on the Gateway only, without informing the Client.
    ///
    /// Models an authorization expiring on the Gateway or the portal's `reject_access` message.
    /// The Client recovers through the Gateway's `no_authorization` p2p control event.
    RevokeGatewayAuthorization(ResourceId),
    /// Expires inbound authorizations at the receiving client while the sender retains its own.
    ExpirePeerAuthorizations {
        client: ClientId,
        peer: ClientId,
        pools: BTreeSet<ResourceId>,
    },
    /// Revokes one of several peer authorizations on the receiver while the sender retains its own.
    RevokePeerAuthorization {
        client: ClientId,
        peer: ClientId,
        pool: ResourceId,
    },
    UpdateDnsRecords {
        domain: DomainName,
        records: BTreeSet<OwnedRecordData>,
    },
}

impl Transition {
    /// Whether the packet-level expectations that accumulate across transitions (DNS
    /// queries and responses, TCP connections and rejections) are stale once this
    /// transition is applied.
    pub fn clears_packets(&self) -> bool {
        match self {
            Transition::AddResource(_) => true,
            Transition::RemoveResource(_) => true,
            Transition::EditResource(edit) => classify(&edit.old, &edit.new).clears_packets(),
            Transition::UpdateDevicePoolMembers { .. } => true,
            Transition::SetInternetResourceState { .. } => true,
            Transition::SendIcmpPacketOnNewFlow { .. } => false,
            Transition::SendIcmpPacketOnExistingFlow { .. } => false,
            Transition::SendUdpPacketOnNewFlow { .. } => false,
            Transition::SendUdpPacketOnExistingFlow { .. } => false,
            Transition::ConnectTcp { .. } => false,
            Transition::SendDnsQueries(_) => false,
            Transition::SendDnsResourcePtrQuery { .. } => false,
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
            Transition::RevokeGatewayAuthorization(_) => true,
            Transition::ExpirePeerAuthorizations { .. } => true,
            Transition::RevokePeerAuthorization { .. } => true,
            Transition::UpdateDnsRecords { .. } => false,
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
            Transition::EditResource(edit) => classify(&edit.old, &edit.new).retains_flow(route),
            Transition::UpdateDevicePoolMembers { revoked, .. } => match route {
                Route::Resource { .. } => true,
                Route::Gateway(_) => true,
                Route::Peer(peer) => !revoked.iter().any(|authorization| {
                    let parties = (authorization.initiator, authorization.target);

                    parties == (client_id, peer) || parties == (peer, client_id)
                }),
            },
            Transition::SetInternetResourceState {
                client_id: changed, ..
            } => client_id != *changed,
            Transition::SendIcmpPacketOnNewFlow { .. } => true,
            Transition::SendIcmpPacketOnExistingFlow { .. } => true,
            Transition::SendUdpPacketOnNewFlow { .. } => true,
            Transition::SendUdpPacketOnExistingFlow { .. } => true,
            Transition::ConnectTcp { .. } => true,
            Transition::SendDnsQueries(_) => true,
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
            Transition::RevokeGatewayAuthorization(resource) => match route {
                Route::Resource { resource: used, .. } => used != *resource,
                Route::Gateway(_) => false,
                Route::Peer(_) => true,
            },
            Transition::ExpirePeerAuthorizations { client, peer, .. } => match route {
                Route::Peer(remote) => {
                    !((client_id == *client && remote == *peer)
                        || (client_id == *peer && remote == *client))
                }
                Route::Resource { .. } => true,
                Route::Gateway(_) => true,
            },
            Transition::RevokePeerAuthorization { client, peer, .. } => match route {
                Route::Peer(remote) => {
                    !((client_id == *client && remote == *peer)
                        || (client_id == *peer && remote == *client))
                }
                Route::Resource { .. } => true,
                Route::Gateway(_) => true,
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

impl EditEffect<'_> {
    fn clears_packets(&self) -> bool {
        match self {
            EditEffect::Metadata => false,
            EditEffect::Filters { affects_tcp, .. } => *affects_tcp,
            EditEffect::Access { affects_tcp, .. } => *affects_tcp,
            EditEffect::DevicePoolRouting => false,
            EditEffect::Type { old, .. } => match old {
                Resource::Dns(_) => true,
                Resource::Cidr(_) => false,
                Resource::Internet(_) => false,
                Resource::DevicePool(_) => false,
            },
        }
    }

    fn retains_flow(&self, route: Route) -> bool {
        match (self, route) {
            (EditEffect::Metadata, _) => true,
            (
                EditEffect::Filters { resource_id, .. } | EditEffect::Access { resource_id, .. },
                Route::Resource { resource, .. },
            ) => resource != *resource_id,
            (EditEffect::Filters { .. } | EditEffect::Access { .. }, Route::Gateway(_)) => false,
            (EditEffect::Filters { .. } | EditEffect::Access { .. }, Route::Peer(_)) => true,
            (EditEffect::DevicePoolRouting, Route::Resource { .. }) => true,
            (EditEffect::DevicePoolRouting, Route::Gateway(_)) => true,
            (EditEffect::DevicePoolRouting, Route::Peer(_)) => false,
            (EditEffect::Type { old, .. }, Route::Resource { resource, .. }) => {
                resource != old.id()
            }
            (EditEffect::Type { .. }, Route::Gateway(_)) => false,
            (EditEffect::Type { old, new, .. }, Route::Peer(_)) => {
                !is_device_pool(old) && !is_device_pool(new)
            }
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
