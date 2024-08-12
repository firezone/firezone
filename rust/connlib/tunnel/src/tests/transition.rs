use super::{
    sim_dns::RefDns,
    sim_net::{any_ip_stack, any_port, Host},
};
use connlib_shared::{
    messages::{client::ResourceDescription, DnsServer, RelayId, ResourceId},
    DomainName,
};
use domain::base::Rtype;
use proptest::{prelude::*, sample};
use std::{
    collections::{BTreeMap, HashSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
};

/// The possible transitions of the state machine.
#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum Transition {
    /// Activate a resource on the client.
    ActivateResource(ResourceDescription),
    /// Deactivate a resource on the client.
    DeactivateResource(ResourceId),
    /// Client-side disable resource
    DisableResources(HashSet<ResourceId>),
    /// Send an ICMP packet to non-resource IP.
    SendICMPPacketToNonResourceIp {
        src: IpAddr,
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a CIDR resource.
    SendICMPPacketToCidrResource {
        src: IpAddr,
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a DNS resource.
    SendICMPPacketToDnsResource {
        src: IpAddr,
        dst: DomainName,
        #[derivative(Debug = "ignore")]
        resolved_ip: sample::Selector,

        seq: u16,
        identifier: u16,
    },

    /// Send a DNS query.
    SendDnsQuery(DnsQuery),

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

    /// Idle connlib for a while, forcing connection to auto-close.
    Idle,
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
    )
        .prop_map(
            |(src, dst, seq, identifier)| Transition::SendICMPPacketToNonResourceIp {
                src,
                dst,
                seq,
                identifier,
            },
        )
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
    )
        .prop_map(
            |(dst, seq, identifier, src)| Transition::SendICMPPacketToCidrResource {
                src,
                dst,
                seq,
                identifier,
            },
        )
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
    )
        .prop_map(|(dst, seq, identifier, src, resolved_ip)| {
            Transition::SendICMPPacketToDnsResource {
                src,
                dst,
                resolved_ip,
                seq,
                identifier,
            }
        })
}

pub(crate) fn dns_query(
    domain: impl Strategy<Value = DomainName>,
    dns_server: impl Strategy<Value = SocketAddr>,
) -> impl Strategy<Value = DnsQuery> {
    (
        domain,
        dns_server,
        prop_oneof![Just(Rtype::A), Just(Rtype::AAAA)],
        any::<u16>(),
    )
        .prop_map(move |(domain, dns_server, r_type, query_id)| DnsQuery {
            domain,
            r_type,
            query_id,
            dns_server,
        })
}

pub(crate) fn roam_client() -> impl Strategy<Value = Transition> {
    (any_ip_stack(), any_port()).prop_map(move |(ip_stack, port)| Transition::RoamClient {
        ip4: ip_stack.as_v4().copied(),
        ip6: ip_stack.as_v6().copied(),
        port,
    })
}

pub(crate) fn update_system_dns_servers(
    dns_servers: Vec<Host<RefDns>>,
) -> impl Strategy<Value = Transition> {
    let max = dns_servers.len();

    sample::subsequence(dns_servers, ..=max).prop_map(|seq| {
        Transition::UpdateSystemDnsServers(
            seq.into_iter().map(|h| h.single_socket().ip()).collect(),
        )
    })
}

pub(crate) fn update_upstream_dns_servers(
    dns_servers: Vec<Host<RefDns>>,
) -> impl Strategy<Value = Transition> {
    let max = dns_servers.len();

    sample::subsequence(dns_servers, ..=max).prop_map(|seq| {
        Transition::UpdateUpstreamDnsServers(
            seq.into_iter().map(|h| h.single_socket().into()).collect(),
        )
    })
}
