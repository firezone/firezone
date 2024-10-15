use crate::{
    client::{Resource, IPV4_RESOURCES, IPV6_RESOURCES},
    proptest::{host_v4, host_v6},
};
use connlib_model::RelayId;

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
#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
#[expect(clippy::large_enum_variant)]
pub(crate) enum Transition {
    /// Activate a resource on the client.
    ActivateResource(Resource),
    /// Deactivate a resource on the client.
    DeactivateResource(ResourceId),
    /// Client-side disable resource
    DisableResources(BTreeSet<ResourceId>),
    /// Send an ICMP packet to non-resource IP.
    SendPacketToNonResourceIp {
        src: IpAddr,
        dst: IpAddr,
        protocol: TransitionProtocol,
        payload: u64,
    },
    /// Send an ICMP packet to a CIDR resource.
    SendPacketToCidrResource {
        src: IpAddr,
        dst: IpAddr,
        protocol: TransitionProtocol,
        payload: u64,
    },
    /// Send an ICMP packet to a DNS resource.
    SendPacketToDnsResource {
        src: IpAddr,
        dst: DomainName,
        #[derivative(Debug = "ignore")]
        resolved_ip: sample::Selector,

        protocol: TransitionProtocol,
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum TransitionProtocol {
    Tcp { src: u16, dst: u16 },
    Udp { src: u16, dst: u16 },
    Icmp { seq: u16, identifier: u16 },
}

impl Ord for TransitionProtocol {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match (self, other) {
            (
                TransitionProtocol::Tcp {
                    src: src_a,
                    dst: dst_a,
                },
                TransitionProtocol::Tcp {
                    src: src_b,
                    dst: dst_b,
                },
            )
            | (
                TransitionProtocol::Udp {
                    src: src_a,
                    dst: dst_a,
                },
                TransitionProtocol::Udp {
                    src: src_b,
                    dst: dst_b,
                },
            ) => {
                if src_a == src_b {
                    return dst_a.cmp(dst_b);
                }

                src_a.cmp(src_b)
            }
            (
                TransitionProtocol::Icmp {
                    seq: seq_a,
                    identifier: identifier_a,
                },
                TransitionProtocol::Icmp {
                    seq: seq_b,
                    identifier: identifier_b,
                },
            ) => {
                if identifier_a == identifier_b {
                    return seq_a.cmp(seq_b);
                }

                identifier_a.cmp(identifier_b)
            }
            (TransitionProtocol::Icmp { .. }, _) => std::cmp::Ordering::Less,
            (TransitionProtocol::Udp { .. }, _) => std::cmp::Ordering::Greater,
            (TransitionProtocol::Tcp { .. }, TransitionProtocol::Udp { .. }) => {
                std::cmp::Ordering::Less
            }
            (TransitionProtocol::Tcp { .. }, TransitionProtocol::Icmp { .. }) => {
                std::cmp::Ordering::Greater
            }
        }
    }
}

impl PartialOrd for TransitionProtocol {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug, Clone)]
pub(crate) struct DnsQuery {
    pub(crate) domain: DomainName,
    /// The type of DNS query we should send.
    pub(crate) r_type: Rtype,
    /// The DNS query ID.
    pub(crate) query_id: u16,
    pub(crate) dns_server: SocketAddr,
}

pub(crate) fn packet_to_random_ip<I>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = I>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
{
    (
        src.prop_map(Into::into),
        dst.prop_map(Into::into),
        transition_protocol(),
        any::<u64>(),
    )
        .prop_map(
            |(src, dst, protocol, payload)| Transition::SendPacketToNonResourceIp {
                src,
                dst,
                protocol,
                payload,
            },
        )
}

pub(crate) fn packet_to_cidr_resource<I>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = I>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
{
    (
        dst.prop_map(Into::into),
        transition_protocol(),
        src.prop_map(Into::into),
        any::<u64>(),
    )
        .prop_map(
            |(dst, protocol, src, payload)| Transition::SendPacketToCidrResource {
                src,
                dst,
                protocol,
                payload,
            },
        )
}

pub(crate) fn packet_to_dns_resource<I>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = DomainName>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
{
    (
        dst,
        transition_protocol(),
        src.prop_map(Into::into),
        any::<sample::Selector>(),
        any::<u64>(),
    )
        .prop_map(|(dst, protocol, src, resolved_ip, payload)| {
            Transition::SendPacketToDnsResource {
                src,
                dst,
                resolved_ip,
                protocol,
                payload,
            }
        })
}

/// Samples up to 5 DNS queries that will be sent concurrently into connlib.
pub(crate) fn dns_queries(
    domain: impl Strategy<Value = DomainName>,
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
            .map(move |((dns_server, query_id), domain)| {
                (
                    Just(domain),
                    Just(dns_server),
                    query_type(),
                    Just(query_id),
                    ptr_query_ip(),
                )
                    .prop_map(
                        |(mut domain, dns_server, r_type, query_id, maybe_reverse_record)| {
                            if matches!(r_type, Rtype::PTR) {
                                domain =
                                    DomainName::reverse_from_addr(maybe_reverse_record).unwrap();
                            }

                            DnsQuery {
                                domain,
                                r_type,
                                query_id,
                                dns_server,
                            }
                        },
                    )
            })
            .collect::<Vec<_>>()
    })
}

fn transition_protocol() -> impl Strategy<Value = TransitionProtocol> {
    (any::<u16>(), any::<u16>())
        .prop_filter(
            "We only use 53 for DNS to keep things simpler",
            |(p1, p2)| *p1 != 53 && *p2 != 53,
        )
        .prop_flat_map(|(p1, p2)| {
            prop_oneof![
                Just(TransitionProtocol::Icmp {
                    seq: p1,
                    identifier: p2
                }),
                Just(TransitionProtocol::Udp { src: p1, dst: p2 }),
                Just(TransitionProtocol::Tcp { src: p1, dst: p2 }),
            ]
        })
}

fn ptr_query_ip() -> impl Strategy<Value = IpAddr> {
    prop_oneof![
        host_v4(IPV4_RESOURCES).prop_map_into(),
        host_v6(IPV6_RESOURCES).prop_map_into(),
        any::<IpAddr>(),
    ]
}

pub(crate) fn query_type() -> impl Strategy<Value = Rtype> {
    prop_oneof![
        Just(Rtype::A),
        Just(Rtype::AAAA),
        Just(Rtype::MX),
        Just(Rtype::PTR),
    ]
}

pub(crate) fn roam_client() -> impl Strategy<Value = Transition> {
    (any_ip_stack(), any_port()).prop_map(move |(ip_stack, port)| Transition::RoamClient {
        ip4: ip_stack.as_v4().copied(),
        ip6: ip_stack.as_v6().copied(),
        port,
    })
}
