use crate::{
    client::{Resource, IPV4_RESOURCES, IPV6_RESOURCES},
    proptest::{host_v4, host_v6},
};
use connlib_model::{GatewayId, RelayId};

use super::sim_net::{any_ip_stack, any_port, Host};
use crate::messages::DnsServer;
use connlib_model::{DomainName, ResourceId};
use domain::base::Rtype;
use prop::collection;
use proptest::{prelude::*, sample};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
};

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
pub(crate) enum Transition {
    /// Activate a resource on the client.
    ActivateResource(Resource),
    /// Deactivate a resource on the client.
    DeactivateResource(ResourceId),
    /// Client-side disable resource
    DisableResources(BTreeSet<ResourceId>),
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
    /// Send an TCP payload to destination (IP resource, DNS resource or IP non-resource).
    SendTcpPayload {
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        payload: u64,
    },

    /// Send a DNS query.
    SendDnsQueries(Vec<DnsQuery>),

    /// The system's DNS servers changed.
    UpdateSystemDnsServers(Vec<IpAddr>),
    /// The upstream DNS servers changed.
    UpdateUpstreamDnsServers(Vec<DnsServer>),

    /// Roam the client to a new pair of sockets.
    RoamClient {
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
        port: u16,
    },

    /// Reconnect to the portal.
    ReconnectPortal,

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

    /// Disconnect a gateway from the portal.
    ///
    /// A disconnected gateway is considered unroutable by the portal and new connections will fail over to another gateway in the same site.
    DisconnectGateway(GatewayId),
}

#[derive(Debug, Clone)]
pub(crate) struct DnsQuery {
    pub(crate) domain: DomainName,
    /// The type of DNS query we should send.
    pub(crate) r_type: Rtype,
    /// The DNS query ID.
    pub(crate) query_id: u16,
    pub(crate) dns_server: SocketAddr,
    pub(crate) transport: DnsTransport,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum DnsTransport {
    Udp,
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
        (SPort(self.1 .0), DPort(self.0 .0))
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

#[expect(private_bounds)]
pub(crate) fn tcp_packet<I, D>(
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
        .prop_map(|(src, dst, sport, dport, resolved_ip, payload)| {
            Transition::SendTcpPayload {
                src,
                dst: dst.into_destination(resolved_ip),
                sport: SPort(sport),
                dport: DPort(dport),
                payload,
            }
        })
}

fn non_dns_ports() -> impl Strategy<Value = u16> {
    any::<u16>().prop_filter(
        "avoid using port 53 for non-dns queries for simplicity",
        |p| *p != 53,
    )
}

/// Samples up to 5 DNS queries that will be sent concurrently into connlib.
pub(crate) fn dns_queries(
    domain: impl Strategy<Value = (DomainName, Vec<Rtype>)>,
    dns_server: impl Strategy<Value = SocketAddr>,
) -> impl Strategy<Value = Vec<DnsQuery>> {
    // Queries can be uniquely identified by the tuple of DNS server and query ID.
    let unique_queries = collection::btree_set((dns_server, any::<u16>()), 1..5);

    let domains = collection::btree_set(domain, 1..5);

    (unique_queries, domains).prop_flat_map(|(unique_queries, domains)| {
        let unique_queries = unique_queries.into_iter();
        let domains = domains.into_iter();

        // We may not necessarily have the same number of items in both but we don't care if we drop some.
        let zipped = unique_queries.zip(domains);

        zipped
            .map(move |((dns_server, query_id), (domain, existing_rtypes))| {
                (
                    Just(domain),
                    Just(dns_server),
                    maybe_available_response_rtypes(existing_rtypes),
                    Just(query_id),
                    ptr_query_ip(),
                    dns_transport(),
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
                            if matches!(r_type, Rtype::PTR) {
                                domain =
                                    DomainName::reverse_from_addr(maybe_reverse_record).unwrap();
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
            })
            .collect::<Vec<_>>()
    })
}

fn ptr_query_ip() -> impl Strategy<Value = IpAddr> {
    prop_oneof![
        host_v4(IPV4_RESOURCES).prop_map_into(),
        host_v6(IPV6_RESOURCES).prop_map_into(),
        any::<IpAddr>(),
    ]
}

fn dns_transport() -> impl Strategy<Value = DnsTransport> {
    prop_oneof![Just(DnsTransport::Udp), Just(DnsTransport::Tcp),]
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
    available_rtypes: Vec<Rtype>,
) -> impl Strategy<Value = Rtype> {
    if available_rtypes.contains(&Rtype::A) || available_rtypes.contains(&Rtype::AAAA) {
        sample::select(vec![Rtype::PTR, Rtype::MX, Rtype::A, Rtype::AAAA])
    } else {
        sample::select(available_rtypes)
    }
}

pub(crate) fn roam_client() -> impl Strategy<Value = Transition> {
    (any_ip_stack(), any_port()).prop_map(move |(ip_stack, port)| Transition::RoamClient {
        ip4: ip_stack.as_v4().copied(),
        ip6: ip_stack.as_v6().copied(),
        port,
    })
}
