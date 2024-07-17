use super::{
    sim_net::{any_ip_stack, any_port},
    strategies::*,
};
use connlib_shared::{
    messages::{
        client::{ResourceDescriptionCidr, ResourceDescriptionDns, Site},
        DnsServer, ResourceId,
    },
    proptest::*,
    DomainName,
};
use hickory_proto::rr::RecordType;
use proptest::{prelude::*, sample};
use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
};

/// The possible transitions of the state machine.
#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource { resource: ResourceDescriptionCidr },
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

    /// Add a new DNS resource to the client.
    AddDnsResource {
        resource: ResourceDescriptionDns,
        /// The DNS records to add together with the resource.
        records: HashMap<DomainName, HashSet<IpAddr>>,
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

    /// Advance time by this many milliseconds.
    Tick { millis: u64 },

    /// Remove a resource from the client.
    RemoveResource(ResourceId),

    /// Roam the client to a new pair of sockets.
    RoamClient {
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
        port: u16,
    },
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
        dns_server.prop_map(Into::into),
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

pub(crate) fn non_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = Transition> {
    (dns_resource(site.prop_map(|s| vec![s])), resolved_ips()).prop_map(
        |(resource, resolved_ips)| Transition::AddDnsResource {
            records: HashMap::from([(resource.address.parse().unwrap(), resolved_ips)]),
            resource,
        },
    )
}

pub(crate) fn star_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = Transition> {
    dns_resource(site.prop_map(|s| vec![s])).prop_flat_map(move |r| {
        let wildcard_address = format!("*.{}", r.address);

        let records = subdomain_records(r.address, domain_name(1..3));
        let resource = Just(ResourceDescriptionDns {
            address: wildcard_address,
            ..r
        });

        (resource, records)
            .prop_map(|(resource, records)| Transition::AddDnsResource { records, resource })
    })
}

pub(crate) fn question_mark_wildcard_dns_resource(
    site: impl Strategy<Value = Site>,
) -> impl Strategy<Value = Transition> {
    dns_resource(site.prop_map(|s| vec![s])).prop_flat_map(move |r| {
        let wildcard_address = format!("?.{}", r.address);

        let records = subdomain_records(r.address, domain_label());
        let resource = Just(ResourceDescriptionDns {
            address: wildcard_address,
            ..r
        });

        (resource, records)
            .prop_map(|(resource, records)| Transition::AddDnsResource { records, resource })
    })
}

pub(crate) fn roam_client() -> impl Strategy<Value = Transition> {
    (any_ip_stack(), any_port()).prop_map(move |(ip_stack, port)| Transition::RoamClient {
        ip4: ip_stack.as_v4().copied(),
        ip6: ip_stack.as_v6().copied(),
        port,
    })
}
