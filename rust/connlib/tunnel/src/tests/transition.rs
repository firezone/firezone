use super::{
    sim_net::{any_ip_stack, any_port, Host},
    strategies::relays,
};
use connlib_shared::{
    messages::{client::ResourceDescription, DnsServer, RelayId, ResourceId},
    DomainName,
};
use hickory_proto::rr::RecordType;
use proptest::{prelude::*, sample};
use std::{
    collections::{BTreeMap, BTreeSet},
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
    SendDnsQuery {
        domain: DomainName,
        /// The type of DNS query we should send.
        r_type: RecordType,
        /// The DNS query ID.
        query_id: u16,
        dns_server: SocketAddr,
    },

    /// The system's DNS servers changed.
    UpdateSystemDnsServers { servers: Vec<IpAddr> },
    /// The upstream DNS servers changed.
    UpdateUpstreamDnsServers { servers: Vec<DnsServer> },

    /// Roam the client to a new pair of sockets.
    RoamClient {
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
        port: u16,
    },

    /// Reconnect to the portal.
    ReconnectPortal,

    /// Simulate deployment of new relays.
    RelaysPresence {
        disconnected: BTreeSet<RelayId>,
        online: BTreeMap<RelayId, Host<u64>>,
    },

    /// Idle connlib for a while, forcing connection to auto-close.
    Idle,
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

pub(crate) fn dns_query<S>(
    domain: impl Strategy<Value = DomainName>,
    dns_server: impl Strategy<Value = S>,
) -> impl Strategy<Value = Transition>
where
    S: Into<SocketAddr>,
{
    (
        domain,
        dns_server.prop_map_into(),
        prop_oneof![Just(RecordType::A), Just(RecordType::AAAA)],
        any::<u16>(),
    )
        .prop_map(
            move |(domain, dns_server, r_type, query_id)| Transition::SendDnsQuery {
                domain,
                r_type,
                query_id,
                dns_server,
            },
        )
}

pub(crate) fn roam_client() -> impl Strategy<Value = Transition> {
    (any_ip_stack(), any_port()).prop_map(move |(ip_stack, port)| Transition::RoamClient {
        ip4: ip_stack.as_v4().copied(),
        ip6: ip_stack.as_v6().copied(),
        port,
    })
}

pub(crate) fn migrate_relays(
    disconnected: impl Strategy<Value = BTreeSet<RelayId>>,
) -> impl Strategy<Value = Transition> {
    (disconnected, relays()).prop_map(|(disconnected, online)| Transition::RelaysPresence {
        disconnected,
        online,
    })
}
