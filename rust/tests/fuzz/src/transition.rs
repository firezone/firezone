use connlib_model::{ClientId, RelayId, ResourceId};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use tunnel_proto::{
    dns,
    messages::{UpstreamDo53, UpstreamDoH, client::DevicePoolMember},
};

use super::{
    probe::{FlowId, FlowRoute, ProbeId},
    reference::PrivateKey,
    resource::{
        CidrResourceEdit, CidrResourceValue, DnsResourceEdit, DnsResourceValue,
        DynamicDevicePoolResourceEdit, DynamicDevicePoolResourceValue, Resource, ResourceEdit,
        ResourceTypeEdit, StaticDevicePoolResourceEdit, StaticDevicePoolResourceValue,
    },
    resource_edit_path_coverage::ResourceEditPath,
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
    /// Returns the resource-edit path covered by this transition.
    pub fn resource_edit_path(&self) -> Option<ResourceEditPath> {
        let Transition::EditResource(edit) = self else {
            return None;
        };

        Some(edit.path())
    }

    /// Returns whether assertions should discard stale packets before applying this transition.
    pub fn should_clear_packets(&self) -> bool {
        match self {
            Transition::AddResource(_) => true,
            Transition::RemoveResource(_) => true,
            Transition::EditResource(edit) => resource_edit_effect(edit).should_clear_packets(),
            Transition::SetInternetResourceState { .. } => true,
            Transition::SendIcmpPacketOnNewFlow { .. } => false,
            Transition::SendIcmpPacketOnExistingFlow { .. } => false,
            Transition::SendUdpPacketOnNewFlow { .. } => false,
            Transition::SendUdpPacketOnExistingFlow { .. } => false,
            Transition::ConnectTcp { .. } => false,
            Transition::SendDnsQuery { .. } => false,
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
            Transition::UpdateDnsRecords { .. } => false,
        }
    }

    /// Returns whether a flow remains predictable across this transition.
    pub(crate) fn retains_flow(
        &self,
        client_id: ClientId,
        route: FlowRoute,
        iceless: bool,
    ) -> bool {
        match self {
            Transition::AddResource(_) => match route {
                FlowRoute::Resource { .. } => false,
                FlowRoute::Gateway(_) => true,
                FlowRoute::Peer(_) => true,
            },
            Transition::RemoveResource(resource) => match route {
                FlowRoute::Resource { resource: used, .. } => used != *resource,
                FlowRoute::Gateway(_) => false,
                FlowRoute::Peer(_) => false,
            },
            Transition::EditResource(edit) => resource_edit_effect(edit).retains_flow(route),
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
                FlowRoute::Resource { .. } => iceless || client_id != *changed,
                FlowRoute::Gateway(_) => iceless || client_id != *changed,
                FlowRoute::Peer(peer) => iceless || (client_id != *changed && peer != *changed),
            },
            Transition::ReconnectPortal { .. } => true,
            Transition::RestartClient {
                client_id: restarted,
                ..
            } => match route {
                FlowRoute::Resource { .. } => client_id != *restarted,
                FlowRoute::Gateway(_) => client_id != *restarted,
                FlowRoute::Peer(peer) => client_id != *restarted && peer != *restarted,
            },
            Transition::DeployNewRelays(_) => iceless,
            Transition::PartitionRelaysFromPortal => false,
            Transition::Idle => true,
            Transition::RebootRelaysWhilePartitioned(_) => false,
            Transition::DeauthorizeWhileGatewayIsPartitioned(resource) => match route {
                FlowRoute::Resource { resource: used, .. } => used != *resource,
                FlowRoute::Gateway(_) => false,
                FlowRoute::Peer(_) => false,
            },
            Transition::UpdateDnsRecords { .. } => true,
        }
    }
}

enum ResourceEditEffect<'a> {
    Metadata,
    GatewayResource {
        resource_id: ResourceId,
        affects_tcp: bool,
    },
    StaticPoolMembers {
        previous: &'a [DevicePoolMember],
        updated: &'a [DevicePoolMember],
    },
    DevicePoolRouting,
    Type {
        old: &'a Resource,
        new: &'a Resource,
    },
}

impl ResourceEditEffect<'_> {
    fn should_clear_packets(&self) -> bool {
        match self {
            ResourceEditEffect::Metadata => false,
            ResourceEditEffect::GatewayResource { affects_tcp, .. } => *affects_tcp,
            ResourceEditEffect::StaticPoolMembers { .. } => false,
            ResourceEditEffect::DevicePoolRouting => false,
            ResourceEditEffect::Type { old, .. } => match old {
                Resource::Dns(_) => true,
                Resource::Cidr(_) => false,
                Resource::Internet(_) => {
                    unreachable!("the Portal API does not allow editing the Internet Resource")
                }
                Resource::StaticDevicePool(_) => false,
                Resource::DynamicDevicePool(_) => false,
            },
        }
    }

    fn retains_flow(&self, route: FlowRoute) -> bool {
        match (self, route) {
            (ResourceEditEffect::Metadata, _) => true,
            (
                ResourceEditEffect::GatewayResource { resource_id, .. },
                FlowRoute::Resource { resource, .. },
            ) => resource != *resource_id,
            (ResourceEditEffect::GatewayResource { .. }, FlowRoute::Gateway(_)) => false,
            (ResourceEditEffect::GatewayResource { .. }, FlowRoute::Peer(_)) => true,
            (
                ResourceEditEffect::StaticPoolMembers { previous, updated },
                FlowRoute::Peer(peer),
            ) => previous
                .iter()
                .find(|member| member.id == peer)
                .is_none_or(|previous| {
                    updated
                        .iter()
                        .any(|member| member.id == peer && member == previous)
                }),
            (ResourceEditEffect::StaticPoolMembers { .. }, FlowRoute::Resource { .. }) => true,
            (ResourceEditEffect::StaticPoolMembers { .. }, FlowRoute::Gateway(_)) => true,
            (ResourceEditEffect::DevicePoolRouting, FlowRoute::Resource { .. }) => true,
            (ResourceEditEffect::DevicePoolRouting, FlowRoute::Gateway(_)) => true,
            (ResourceEditEffect::DevicePoolRouting, FlowRoute::Peer(_)) => false,
            (ResourceEditEffect::Type { old, .. }, FlowRoute::Resource { resource, .. }) => {
                resource != old.id()
            }
            (ResourceEditEffect::Type { .. }, FlowRoute::Gateway(_)) => false,
            (ResourceEditEffect::Type { old, new }, FlowRoute::Peer(_)) => {
                !is_device_pool(old) && !is_device_pool(new)
            }
        }
    }
}

fn resource_edit_effect(edit: &ResourceEdit) -> ResourceEditEffect<'_> {
    match edit {
        ResourceEdit::Dns(DnsResourceEdit {
            value: DnsResourceValue::Id(_),
            ..
        })
        | ResourceEdit::Cidr(CidrResourceEdit {
            value: CidrResourceValue::Id(_),
            ..
        })
        | ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
            value: StaticDevicePoolResourceValue::Id(_),
            ..
        })
        | ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit {
            value: DynamicDevicePoolResourceValue::Id(_),
            ..
        }) => unreachable!("resource identity is not editable"),
        ResourceEdit::Dns(DnsResourceEdit {
            value: DnsResourceValue::Name(_) | DnsResourceValue::AddressDescription(_),
            ..
        })
        | ResourceEdit::Cidr(CidrResourceEdit {
            value: CidrResourceValue::Name(_) | CidrResourceValue::AddressDescription(_),
            ..
        })
        | ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
            value: StaticDevicePoolResourceValue::Name(_),
            ..
        })
        | ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit {
            value: DynamicDevicePoolResourceValue::Name(_),
            ..
        }) => ResourceEditEffect::Metadata,
        ResourceEdit::Dns(DnsResourceEdit {
            resource,
            value:
                DnsResourceValue::Address(_)
                | DnsResourceValue::Sites(_)
                | DnsResourceValue::IpStack(_)
                | DnsResourceValue::Filters(_),
        }) => ResourceEditEffect::GatewayResource {
            resource_id: resource.id,
            affects_tcp: true,
        },
        ResourceEdit::Cidr(CidrResourceEdit {
            resource,
            value:
                CidrResourceValue::Address(_)
                | CidrResourceValue::Sites(_)
                | CidrResourceValue::Filters(_),
        }) => ResourceEditEffect::GatewayResource {
            resource_id: resource.id,
            affects_tcp: false,
        },
        ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
            resource,
            value: StaticDevicePoolResourceValue::Devices(updated),
        }) => ResourceEditEffect::StaticPoolMembers {
            previous: &resource.devices,
            updated,
        },
        ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
            value: StaticDevicePoolResourceValue::Filters(_),
            ..
        })
        | ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit {
            value:
                DynamicDevicePoolResourceValue::Address(_) | DynamicDevicePoolResourceValue::Filters(_),
            ..
        }) => ResourceEditEffect::DevicePoolRouting,
        ResourceEdit::Type(ResourceTypeEdit {
            old_resource,
            new_resource,
        }) => ResourceEditEffect::Type {
            old: old_resource,
            new: new_resource,
        },
    }
}

fn is_device_pool(resource: &Resource) -> bool {
    match resource {
        Resource::Dns(_) => false,
        Resource::Cidr(_) => false,
        Resource::Internet(_) => false,
        Resource::StaticDevicePool(_) => true,
        Resource::DynamicDevicePool(_) => true,
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
