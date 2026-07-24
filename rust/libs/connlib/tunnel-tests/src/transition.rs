use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, Site};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use ip_network::IpNetwork;
use tunnel::{
    dns,
    messages::{Filter, UpstreamDo53, UpstreamDoH, client::DevicePoolMember},
};

use super::{
    reference::PrivateKey,
    resource::{CidrResource, Resource},
    sim_net::Host,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::Duration,
};

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
pub(crate) enum Transition {
    /// Add a resource on the client.
    AddResource(Resource),
    /// Remove a resource on the client.
    RemoveResource(ResourceId),
    /// Change the address of a CIDR resource.
    ChangeCidrResourceAddress {
        resource: CidrResource,
        new_address: IpNetwork,
    },
    /// Move a CIDR/DNS resource to a new site.
    MoveResourceToNewSite { resource: Resource, new_site: Site },
    /// Change the traffic filters of a resource.
    ChangeFiltersOfResource {
        resource: Resource,
        new_filters: Vec<Filter>,
    },
    /// Change a backend-managed resource to another editable resource type
    /// while retaining its ID.
    ChangeResourceType {
        old_resource: Resource,
        new_resource: Resource,
    },
    /// Replace the member list of an existing static device pool.
    ///
    /// Exercises the SUT's pool-member diff path, which short-circuits the
    /// generic remove-and-re-add flow when only pool membership changes.
    /// Filter changes go through `ChangeFiltersOfResource`.
    UpdateStaticDevicePool {
        pool_id: ResourceId,
        new_devices: Vec<DevicePoolMember>,
    },

    /// Toggle the Internet Resource on / off
    SetInternetResourceState { client_id: ClientId, active: bool },

    /// Send an ICMP packet to destination (IP resource, DNS resource or IP non-resource).
    SendIcmpPacket {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        expected_route: PacketRoute,
        seq: Seq,
        identifier: Identifier,
        payload: u64,
    },
    /// Send an UDP packet to destination (IP resource, DNS resource or IP non-resource).
    SendUdpPacket {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        expected_route: PacketRoute,
        sport: SPort,
        dport: DPort,
        payload: u64,
    },

    ConnectTcp {
        client_id: ClientId,
        src: IpAddr,
        dst: Destination,
        expected_route: PacketRoute,
        sport: SPort,
        dport: DPort,
    },

    /// Send a DNS query.
    SendDnsQuery {
        client_id: ClientId,
        query: DnsQuery,
    },

    /// The system's DNS servers changed.
    UpdateSystemDnsServers { servers: Vec<IpAddr> },
    /// The upstream Do53 servers changed.
    UpdateUpstreamDo53Servers(Vec<UpstreamDo53>),
    /// The upstream DoH servers changed.
    UpdateUpstreamDoHServers(Vec<UpstreamDoH>),
    /// The upstream search domain changed.
    UpdateUpstreamSearchDomain(Option<DomainName>),

    /// Roam the client to a new pair of sockets.
    RoamClient {
        client_id: ClientId,
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
        /// The public address of the new network's NAT; ignored for clients that are not behind one.
        nat_ip4: Ipv4Addr,
        /// How long the new sockets drop all packets after the roam.
        dead_window: Duration,
        /// How long after the dead window the client is still not reconnected to the portal.
        portal_window: Duration,
    },

    /// Reconnect to the portal.
    ReconnectPortal { client_id: ClientId },

    /// Restart the client.
    RestartClient {
        client_id: ClientId,
        key: PrivateKey,
    },

    /// Simulate deployment of new relays.
    DeployNewRelays(BTreeMap<RelayId, Host<u64>>),

    /// Simulate network partition of our relays.
    ///
    /// In our test, we need partition all relays because we don't know which we use for a connection.
    /// To avoid having to model that, we partition all of them but reconnect them within the same transition.
    PartitionRelaysFromPortal,

    /// Idle connlib for a while.
    Idle,

    /// Simulate all relays rebooting while we are network partitioned from the portal.
    ///
    /// In this case, we won't receive a `relays_presence` but instead we will receive relays with the same ID yet different credentials.
    RebootRelaysWhilePartitioned(BTreeMap<RelayId, Host<u64>>),

    /// De-authorize access to a resource whilst the Gateway is network-partitioned from the portal.
    DeauthorizeWhileGatewayIsPartitioned(ResourceId),

    /// De-authorize access to a resource whilst the Gateway is network-partitioned from the portal.
    UpdateDnsRecords {
        domain: DomainName,
        records: BTreeSet<OwnedRecordData>,
    },
}

impl Transition {
    /// Whether we should clear all packets / connections before this [`Transition`].
    ///
    /// Certain transitions, like adding or removing resources change the Client's state
    /// in a way that makes previously passing assertions fail. For example, a packet that
    /// was previously filtered out could now suddenly be allowed.
    ///
    /// To make our lives easier in the assertions, we clear all sent packets in certain cases.
    pub(crate) fn should_clear_packets(&self) -> bool {
        match self {
            Transition::AddResource(_)
            | Transition::RemoveResource(_)
            | Transition::ChangeCidrResourceAddress { .. }
            | Transition::MoveResourceToNewSite { .. }
            | Transition::DeauthorizeWhileGatewayIsPartitioned(_)
            | Transition::ChangeFiltersOfResource { .. }
            | Transition::ChangeResourceType { .. }
            | Transition::UpdateStaticDevicePool { .. }
            | Transition::SetInternetResourceState { .. } => true,
            Transition::SendIcmpPacket { .. }
            | Transition::SendUdpPacket { .. }
            | Transition::ConnectTcp { .. }
            | Transition::SendDnsQuery { .. }
            | Transition::UpdateSystemDnsServers { .. }
            | Transition::UpdateUpstreamDo53Servers(_)
            | Transition::UpdateUpstreamDoHServers(_)
            | Transition::UpdateUpstreamSearchDomain(_)
            | Transition::RoamClient { .. }
            | Transition::ReconnectPortal { .. }
            | Transition::RestartClient { .. }
            | Transition::DeployNewRelays(_)
            | Transition::PartitionRelaysFromPortal
            | Transition::Idle
            | Transition::RebootRelaysWhilePartitioned(_)
            | Transition::UpdateDnsRecords { .. } => false,
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct DnsQuery {
    pub(crate) domain: DomainName,
    /// The type of DNS query we should send.
    pub(crate) r_type: RecordType,
    /// The DNS query ID.
    pub(crate) query_id: u16,
    pub(crate) dns_server: dns::Upstream,
    pub(crate) transport: DnsTransport,
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

/// The semantic outcome expected from a packet transition.
///
/// The SUT only sees [`Destination`] and must derive this route itself. Carrying
/// the expected route on the transition keeps application of the reference
/// model mechanical and makes a failing scenario readable in a debug dump.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PacketRoute {
    /// No route exists, so the packet cannot leave the client.
    Drop,
    /// The packet should reach a resource through a gateway.
    Resource {
        resource: ResourceId,
        gateway: GatewayId,
    },
    /// The client's outbound filter should return ICMP prohibited.
    RejectedByClient,
    /// A malicious client bypasses its outbound filter, but the gateway's
    /// inbound filter should return ICMP prohibited.
    ResourceRejectedByGateway {
        resource: ResourceId,
        gateway: GatewayId,
    },
    /// The packet directly addresses a connected gateway's tunnel IP.
    Gateway(GatewayId),
    /// The packet should reach another client through a static device pool.
    Peer(ClientId),
    /// A malicious client bypasses its outbound filter, but the peer's inbound
    /// filter should return ICMP prohibited.
    PeerRejectedByPeer(ClientId),
}

#[derive(Clone, derive_more::Debug)]
pub(crate) enum Destination {
    DomainName {
        /// Index used to pick one of the (runtime-filtered) resolved IPs for `name`.
        ///
        /// The set of candidate IPs is only known at apply-time (it depends on the
        /// source address family and the current DNS records), so we store an index
        /// and select with `% len` over the materialized candidates.
        resolved_ip: u32,
        name: DomainName,
    },
    IpAddr(IpAddr),
}

impl Ord for Destination {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match (self, other) {
            (
                Destination::DomainName { name: left, .. },
                Destination::DomainName { name: right, .. },
            ) => left.cmp(right),
            (Destination::IpAddr(left), Destination::IpAddr(right)) => left.cmp(right),

            // These are according to variant order.
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

impl Destination {
    pub(crate) fn ip_addr(&self) -> Option<IpAddr> {
        match self {
            Destination::DomainName { .. } => None,
            Destination::IpAddr(addr) => Some(*addr),
        }
    }
}

pub(crate) trait ReplyTo {
    fn reply_to(self) -> Self;
}

impl ReplyTo for (SPort, DPort) {
    fn reply_to(self) -> Self {
        (SPort(self.1.0), DPort(self.0.0))
    }
}

impl ReplyTo for (Seq, Identifier) {
    fn reply_to(self) -> Self {
        self
    }
}
