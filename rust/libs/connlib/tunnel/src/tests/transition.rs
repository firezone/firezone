use crate::{
    client::{CidrResource, EXTERNAL_IPV4_RESOURCES, IPV6_RESOURCES, Resource},
    dns,
    messages::{UpstreamDo53, UpstreamDoH},
    proptest::{host_v4, host_v6},
};
use connlib_model::{RelayId, ResourceId, Site};
use dns_types::{DomainName, OwnedRecordData, RecordType};
use ip_network::IpNetwork;

use super::{
    reference::PrivateKey,
    sim_net::{Host, any_ip_stack},
};
use prop::collection;
use proptest::{prelude::*, sample};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    num::NonZeroU16,
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

    /// Toggle the Internet Resource on / off
    SetInternetResourceState(bool),

    /// Send an ICMP packet to destination (IP resource, DNS resource or IP non-resource).
    SendIcmpPacket {
        src: IpAddr,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        payload: u64,
    },
    /// Send an UDP packet to destination (IP resource, DNS resource or IP non-resource).
    SendUdpPacket {
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        payload: u64,
    },

    ConnectTcp {
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
    },

    /// Send a DNS query.
    SendDnsQueries(Vec<DnsQuery>),

    /// The system's DNS servers changed.
    UpdateSystemDnsServers(Vec<IpAddr>),
    /// The upstream Do53 servers changed.
    UpdateUpstreamDo53Servers(Vec<UpstreamDo53>),
    /// The upstream DoH servers changed.
    UpdateUpstreamDoHServers(Vec<UpstreamDoH>),
    /// The upstream search domain changed.
    UpdateUpstreamSearchDomain(Option<DomainName>),

    /// Roam the client to a new pair of sockets.
    RoamClient {
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
    },

    /// Reconnect to the portal.
    ReconnectPortal,

    /// Restart the client.
    RestartClient(PrivateKey),

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

#[derive(Clone, derive_more::Debug)]
#[expect(clippy::large_enum_variant)]
pub(crate) enum Destination {
    DomainName {
        #[debug(skip)]
        resolved_ip: sample::Selector,
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

/// Helper enum
#[derive(Debug, Clone)]
enum PacketDestination {
    DomainName(DomainName),
    IpAddr(IpAddr),
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

impl From<DomainName> for PacketDestination {
    fn from(name: DomainName) -> Self {
        PacketDestination::DomainName(name)
    }
}

impl From<Ipv4Addr> for PacketDestination {
    fn from(addr: Ipv4Addr) -> Self {
        PacketDestination::IpAddr(addr.into())
    }
}

impl From<Ipv6Addr> for PacketDestination {
    fn from(addr: Ipv6Addr) -> Self {
        PacketDestination::IpAddr(addr.into())
    }
}

impl From<IpAddr> for PacketDestination {
    fn from(addr: IpAddr) -> Self {
        PacketDestination::IpAddr(addr)
    }
}

impl PacketDestination {
    fn into_destination(self, resolved_ip: sample::Selector) -> Destination {
        match self {
            PacketDestination::DomainName(name) => Destination::DomainName { resolved_ip, name },
            PacketDestination::IpAddr(addr) => Destination::IpAddr(addr),
        }
    }
}

#[expect(private_bounds)]
pub(crate) fn icmp_packet<I, D>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = D>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
    D: Into<PacketDestination>,
{
    (
        src.prop_map(Into::into),
        dst.prop_map(Into::into),
        any::<u16>(),
        any::<u16>(),
        any::<sample::Selector>(),
        any::<u64>(),
    )
        .prop_map(|(src, dst, seq, identifier, resolved_ip, payload)| {
            Transition::SendIcmpPacket {
                src,
                dst: dst.into_destination(resolved_ip),
                seq: Seq(seq),
                identifier: Identifier(identifier),
                payload,
            }
        })
}

#[expect(private_bounds)]
pub(crate) fn udp_packet<I, D>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = D>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
    D: Into<PacketDestination>,
{
    (
        src.prop_map(Into::into),
        dst.prop_map(Into::into),
        any::<u16>(),
        non_dns_ports(),
        any::<sample::Selector>(),
        any::<u64>(),
    )
        .prop_map(
            |(src, dst, sport, dport, resolved_ip, payload)| Transition::SendUdpPacket {
                src,
                dst: dst.into_destination(resolved_ip),
                sport: SPort(sport),
                dport: DPort(dport),
                payload,
            },
        )
}

pub(crate) fn connect_tcp<I>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = DomainName>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
{
    (
        src.prop_map(Into::into),
        dst,
        any::<NonZeroU16>().prop_map(|p| p.get()),
        non_dns_ports().prop_filter("avoid zero port", |p| *p != 0),
        any::<sample::Selector>(),
    )
        .prop_map(
            |(src, name, sport, dport, resolved_ip)| Transition::ConnectTcp {
                src,
                dst: Destination::DomainName { resolved_ip, name },
                sport: SPort(sport),
                dport: DPort(dport),
            },
        )
}

fn non_dns_ports() -> impl Strategy<Value = u16> {
    any::<u16>().prop_filter(
        "avoid using port 53 for non-dns queries for simplicity",
        |p| *p != 53 && *p != 53535,
    )
}

/// Samples up to 5 DNS queries that will be sent concurrently into connlib.
pub(crate) fn dns_queries(
    domain: impl Strategy<Value = (DomainName, Vec<RecordType>)>,
    dns_server: impl Strategy<Value = dns::Upstream>,
) -> impl Strategy<Value = Vec<DnsQuery>> {
    // Queries can be uniquely identified by the tuple of DNS server, transport and query ID.
    let unique_queries = collection::btree_set((dns_server, dns_transport(), dns_query_id()), 1..5);

    let domains = collection::btree_set(domain, 1..5);

    (unique_queries, domains).prop_flat_map(|(unique_queries, domains)| {
        let unique_queries = unique_queries.into_iter();
        let domains = domains.into_iter();

        // We may not necessarily have the same number of items in both but we don't care if we drop some.
        let zipped = unique_queries.zip(domains);

        zipped
            .map(
                move |((dns_server, transport, query_id), (domain, existing_rtypes))| {
                    (
                        Just(domain),
                        Just(dns_server),
                        maybe_available_response_rtypes(existing_rtypes),
                        Just(query_id),
                        ptr_query_ip(),
                        Just(transport),
                    )
                        .prop_map(
                            |(
                                mut domain,
                                dns_server,
                                r_type,
                                query_id,
                                maybe_reverse_record,
                                transport,
                            )| {
                                if matches!(r_type, RecordType::PTR) {
                                    domain = DomainName::reverse_from_addr(maybe_reverse_record)
                                        .unwrap();
                                }

                                DnsQuery {
                                    domain,
                                    r_type,
                                    query_id,
                                    dns_server,
                                    transport,
                                }
                            },
                        )
                },
            )
            .collect::<Vec<_>>()
    })
}

fn ptr_query_ip() -> impl Strategy<Value = IpAddr> {
    prop_oneof![
        host_v4(EXTERNAL_IPV4_RESOURCES).prop_map_into(),
        host_v6(IPV6_RESOURCES).prop_map_into(),
        any::<IpAddr>(),
    ]
}

fn dns_transport() -> impl Strategy<Value = DnsTransport> {
    prop_oneof![
        any::<u16>().prop_map(|local_port| DnsTransport::Udp { local_port }),
        Just(DnsTransport::Tcp),
    ]
}

fn dns_query_id() -> impl Strategy<Value = u16> {
    prop_oneof![
        any::<u16>(), // Ensure we test all possible query IDs
        Just(33333)   // Static ID to also test reuse of IDs
    ]
}

/// To make it more likely that sent queries have any response from the server we try to only querty for IP records
/// when there is any IP record available in the server.
///
/// This will probably not happen with TXT records.
///
/// We still want to send MX and PTR queries when there is no available record in the server because we neve those before-hand
/// but we do them inflight.
///
/// Similarrly to trigger NAT64 and NAT46 we need to query for A when only AAAA is available and vice versa.
pub(crate) fn maybe_available_response_rtypes(
    available_rtypes: Vec<RecordType>,
) -> impl Strategy<Value = RecordType> {
    if available_rtypes.contains(&RecordType::A) || available_rtypes.contains(&RecordType::AAAA) {
        sample::select(vec![
            RecordType::PTR,
            RecordType::MX,
            RecordType::A,
            RecordType::AAAA,
        ])
    } else {
        sample::select(available_rtypes)
    }
}

pub(crate) fn roam_client() -> impl Strategy<Value = Transition> {
    (any_ip_stack()).prop_map(move |ip_stack| Transition::RoamClient {
        ip4: ip_stack.as_v4().copied(),
        ip6: ip_stack.as_v6().copied(),
    })
}
