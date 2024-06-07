use super::strategies::*;
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
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
pub(crate) enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Send an ICMP packet to non-resource IP.
    SendICMPPacketToNonResourceIp {
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to an IP we resolved via DNS but is not a resource.
    SendICMPPacketToResolvedNonResourceIp {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a resource.
    SendICMPPacketToResource {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
        src: PacketSource,
    },

    /// Add a new DNS resource to the client.
    AddDnsResource {
        resource: ResourceDescriptionDns,
        /// The DNS records to add together with the resource.
        records: HashMap<DomainName, HashSet<IpAddr>>,
    },
    /// Send a DNS query.
    SendDnsQuery {
        /// The index into the list of global DNS names (includes all DNS resources).
        r_idx: sample::Index,
        /// The type of DNS query we should send.
        r_type: RecordType,
        /// The DNS query ID.
        query_id: u16,
        /// The index into our list of DNS servers.
        dns_server_idx: sample::Index,
    },

    /// The system's DNS servers changed.
    UpdateSystemDnsServers { servers: Vec<IpAddr> },
    /// The upstream DNS servers changed.
    UpdateUpstreamDnsServers { servers: Vec<DnsServer> },

    /// Advance time by this many milliseconds.
    Tick { millis: u64 },
}

/// The source of the packet that should be sent through the tunnel.
///
/// In normal operation, this will always be either the tunnel's IPv4 or IPv6 address.
/// A malicious client could send packets with a mangled IP but those must be dropped by gateway.
/// To test this case, we also sometimes send packest from a different IP.
#[derive(Debug, Clone, Copy)]
pub(crate) enum PacketSource {
    TunnelIp4,
    TunnelIp6,
    Other(IpAddr),
}

impl PacketSource {
    pub(crate) fn into_ip(self, tunnel_v4: Ipv4Addr, tunnel_v6: Ipv6Addr) -> IpAddr {
        match self {
            PacketSource::TunnelIp4 => tunnel_v4.into(),
            PacketSource::TunnelIp6 => tunnel_v6.into(),
            PacketSource::Other(ip) => ip,
        }
    }

    pub(crate) fn originates_from_client(&self) -> bool {
        matches!(self, PacketSource::TunnelIp4 | PacketSource::TunnelIp6)
    }

    pub(crate) fn is_ipv4(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp4 | PacketSource::Other(IpAddr::V4(_))
        )
    }

    pub(crate) fn is_ipv6(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp6 | PacketSource::Other(IpAddr::V6(_))
        )
    }
}

#[derive(Debug, Clone)]
pub(crate) enum ResourceDst {
    Cidr(IpAddr),
    Dns(DomainName),
}

impl ResourceDst {
    /// Translates a randomly sampled [`ResourceDst`] into the [`IpAddr`] to be used for the packet.
    ///
    /// For CIDR resources, we use the IP directly.
    /// For DNS resources, we need to pick any of the proxy IPs that connlib gave us for the domain name.
    pub(crate) fn into_actual_packet_dst(
        self,
        idx: sample::Index,
        src: PacketSource,
        client_dns_records: &HashMap<DomainName, Vec<IpAddr>>,
    ) -> IpAddr {
        match self {
            ResourceDst::Cidr(ip) => ip,
            ResourceDst::Dns(domain) => {
                let mut ips = client_dns_records
                    .get(&domain)
                    .expect("DNS records to contain domain name")
                    .clone();

                ips.retain(|ip| ip.is_ipv4() == src.is_ipv4());

                *idx.get(&ips)
            }
        }
    }
}

/// Sample a random [`PacketSource`].
///
/// Packets from random source addresses are tested less frequently.
/// Those are dropped by the gateway so this transition only ensures we have this safe-guard.
pub(crate) fn packet_source() -> impl Strategy<Value = PacketSource> {
    prop_oneof![
        10 => Just(PacketSource::TunnelIp4),
        10 => Just(PacketSource::TunnelIp6),
        1 => any::<IpAddr>().prop_map(PacketSource::Other)
    ]
}

/// Generates a [`Transition`] that sends an ICMP packet to a random IP.
///
/// By chance, it could be that we pick a resource IP here.
/// That is okay as our reference state machine checks separately whether we are pinging a resource here.
pub(crate) fn icmp_to_random_ip() -> impl Strategy<Value = Transition> {
    (any::<IpAddr>(), any::<u16>(), any::<u16>()).prop_map(|(dst, seq, identifier)| {
        Transition::SendICMPPacketToNonResourceIp {
            dst,
            seq,
            identifier,
        }
    })
}

pub(crate) fn icmp_to_cidr_resource() -> impl Strategy<Value = Transition> {
    (
        any::<sample::Index>(),
        any::<u16>(),
        any::<u16>(),
        packet_source(),
    )
        .prop_map(
            move |(r_idx, seq, identifier, src)| Transition::SendICMPPacketToResource {
                idx: r_idx,
                seq,
                identifier,
                src,
            },
        )
}

pub(crate) fn icmp_to_resolved_non_resource() -> impl Strategy<Value = Transition> {
    (any::<sample::Index>(), any::<u16>(), any::<u16>()).prop_map(move |(idx, seq, identifier)| {
        Transition::SendICMPPacketToResolvedNonResourceIp {
            idx,
            seq,
            identifier,
        }
    })
}

pub(crate) fn non_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    (dns_resource(), resolved_ips()).prop_map(|(resource, resolved_ips)| {
        Transition::AddDnsResource {
            records: HashMap::from([(resource.address.parse().unwrap(), resolved_ips)]),
            resource,
        }
    })
}

pub(crate) fn star_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    dns_resource().prop_flat_map(|r| {
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

pub(crate) fn question_mark_wildcard_dns_resource() -> impl Strategy<Value = Transition> {
    dns_resource().prop_flat_map(|r| {
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

pub(crate) fn dns_query() -> impl Strategy<Value = Transition> {
    (
        any::<sample::Index>(),
        any::<sample::Index>(),
        prop_oneof![Just(RecordType::A), Just(RecordType::AAAA)],
        any::<u16>(),
    )
        .prop_map(
            move |(r_idx, dns_server_idx, r_type, query_id)| Transition::SendDnsQuery {
                r_idx,
                r_type,
                query_id,
                dns_server_idx,
            },
        )
}
