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
    SendICMPPacketToNonResourceIp {
        src: IpAddr,
        dst: IpAddr,
        seq: u16,
        identifier: u16,
        payload: u64,
    },
    /// Send an ICMP packet to a CIDR resource.
    SendICMPPacketToCidrResource {
        src: IpAddr,
        dst: IpAddr,
        seq: u16,
        identifier: u16,
        payload: u64,
    },
    /// Send an ICMP packet to a DNS resource.
    SendICMPPacketToDnsResource {
        src: IpAddr,
        dst: DomainName,
        #[derivative(Debug = "ignore")]
        resolved_ip: sample::Selector,

        seq: u16,
        identifier: u16,
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

pub(crate) fn ping_random_ip<I>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = I>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
{
    (
        src.prop_map(Into::into),
        dst.prop_map(Into::into),
        any::<u16>(),
        any::<u16>(),
        any::<u64>(),
    )
        .prop_map(|(src, dst, seq, identifier, payload)| {
            Transition::SendICMPPacketToNonResourceIp {
                src,
                dst,
                seq,
                identifier,
                payload,
            }
        })
}

pub(crate) fn icmp_to_cidr_resource<I>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = I>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
{
    (
        dst.prop_map(Into::into),
        any::<u16>(),
        any::<u16>(),
        src.prop_map(Into::into),
        any::<u64>(),
    )
        .prop_map(|(dst, seq, identifier, src, payload)| {
            Transition::SendICMPPacketToCidrResource {
                src,
                dst,
                seq,
                identifier,
                payload,
            }
        })
}

pub(crate) fn icmp_to_dns_resource<I>(
    src: impl Strategy<Value = I>,
    dst: impl Strategy<Value = DomainName>,
) -> impl Strategy<Value = Transition>
where
    I: Into<IpAddr>,
{
    (
        dst,
        any::<u16>(),
        any::<u16>(),
        src.prop_map(Into::into),
        any::<sample::Selector>(),
        any::<u64>(),
    )
        .prop_map(|(dst, seq, identifier, src, resolved_ip, payload)| {
            Transition::SendICMPPacketToDnsResource {
                src,
                dst,
                resolved_ip,
                seq,
                identifier,
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
