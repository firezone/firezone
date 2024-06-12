use super::{strategies::*, PacketSource};
use connlib_shared::{
    messages::{
        client::{ResourceDescriptionCidr, ResourceDescriptionDns},
        DnsServer,
    },
    proptest::*,
    DomainName,
};
use hickory_proto::rr::RecordType;
use proptest::{prelude::*, sample};
use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, SocketAddr, SocketAddrV4, SocketAddrV6},
};

/// The possible transitions of the state machine.
#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Send an ICMP packet to non-resource IP.
    SendICMPPacketToNonResourceIp {
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a CIDR resource.
    SendICMPPacketToCidrResource {
        src: PacketSource,
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a DNS resource.
    SendICMPPacketToDnsResource {
        src: PacketSource,
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
}

#[derive(Debug, Clone)]
pub(crate) enum ResourceDst {
    Cidr(IpAddr),
    Dns(DomainName),
}

pub(crate) fn ping_random_ip(
    ip: impl Strategy<Value = IpAddr>,
) -> impl Strategy<Value = Transition> {
    (ip, any::<u16>(), any::<u16>()).prop_map(|(dst, seq, identifier)| {
        Transition::SendICMPPacketToNonResourceIp {
            dst,
            seq,
            identifier,
        }
    })
}

pub(crate) fn icmp_to_cidr_resource(
    src: impl Strategy<Value = PacketSource>,
    dst: impl Strategy<Value = IpAddr>,
) -> impl Strategy<Value = Transition> {
    (dst, any::<u16>(), any::<u16>(), src).prop_map(|(dst, seq, identifier, src)| {
        Transition::SendICMPPacketToCidrResource {
            src,
            dst,
            seq,
            identifier,
        }
    })
}

pub(crate) fn icmp_to_dns_resource(
    src: impl Strategy<Value = PacketSource>,
    dst: impl Strategy<Value = DomainName>,
) -> impl Strategy<Value = Transition> {
    (
        dst,
        any::<u16>(),
        any::<u16>(),
        src,
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

pub(crate) fn add_dns_resource() -> impl Strategy<Value = Transition> {
    prop_oneof![
        non_wildcard_dns_resource(),
        star_wildcard_dns_resource(),
        question_mark_wildcard_dns_resource(),
    ]
}

fn non_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    (dns_resource(), resolved_ips()).prop_map(|(resource, resolved_ips)| {
        Transition::AddDnsResource {
            records: HashMap::from([(resource.address.parse().unwrap(), resolved_ips)]),
            resource,
        }
    })
}

fn star_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    (dns_resource()).prop_flat_map(move |r| {
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

fn question_mark_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    dns_resource().prop_flat_map(move |r| {
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

pub(crate) fn dns_query_to_v4_server(
    domains: Vec<DomainName>,
    dns_servers: Vec<SocketAddrV4>,
) -> impl Strategy<Value = Transition> {
    dns_query(
        sample::select(domains),
        sample::select(dns_servers).prop_map(SocketAddr::V4),
    )
}

pub(crate) fn dns_query_to_v6_server(
    domains: Vec<DomainName>,
    dns_servers: Vec<SocketAddrV6>,
) -> impl Strategy<Value = Transition> {
    dns_query(
        sample::select(domains),
        sample::select(dns_servers).prop_map(SocketAddr::V6),
    )
}

fn dns_query(
    domain: impl Strategy<Value = DomainName>,
    dns_server: impl Strategy<Value = SocketAddr>,
) -> impl Strategy<Value = Transition> {
    (
        domain,
        dns_server,
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
