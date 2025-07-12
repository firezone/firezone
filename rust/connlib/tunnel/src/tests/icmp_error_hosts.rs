use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
};

use proptest::{prelude::*, sample};

use super::dns_records::DnsRecords;

#[derive(Debug, Clone)]
pub(crate) struct IcmpErrorHosts {
    inner: BTreeMap<IpAddr, IcmpError>,
}

impl IcmpErrorHosts {
    pub(crate) fn icmp_error_for_ip(&self, ip: IpAddr) -> Option<IcmpError> {
        self.inner.get(&ip).copied()
    }

    pub(crate) fn is_unreachable(&self, ip: IpAddr) -> bool {
        self.inner.contains_key(&ip)
    }
}

/// Samples a subset of the provided DNS records which we will treat as "unreachable".
pub(crate) fn icmp_error_hosts(
    dns_resource_records: DnsRecords,
) -> impl Strategy<Value = IcmpErrorHosts> {
    // First, deduplicate all IPs.
    let unique_ips = dns_resource_records.ips_iter().collect::<BTreeSet<_>>();
    let ips = Vec::from_iter(unique_ips);

    Just(ips)
        .prop_shuffle() // `ips` are sorted within `BTreeSet`, so shuffle them first.
        .prop_flat_map(|ips| {
            let num_ips = ips.len();

            sample::subsequence(ips, 0..num_ips) // Pick a subset of the unreachable IPs.
        })
        .prop_flat_map(|ips| {
            ips.into_iter()
                .map(|ip| (Just(ip), icmp_error())) // Assign an ICMP error to each domain.
                .collect::<Vec<_>>()
        })
        .prop_map(BTreeMap::from_iter)
        .prop_map(|inner| IcmpErrorHosts { inner })
}

fn icmp_error() -> impl Strategy<Value = IcmpError> {
    prop_oneof![
        Just(IcmpError::Network),
        Just(IcmpError::Host),
        Just(IcmpError::Port),
        any::<u32>().prop_map(|mtu| IcmpError::PacketTooBig { mtu }),
        Just(IcmpError::TimeExceeded { code: 0 })
    ]
}

/// Enumerates all possible ICMP errors we may generate for IPs on a particular domain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IcmpError {
    Network,
    Host,
    Port,
    PacketTooBig { mtu: u32 },
    TimeExceeded { code: u8 },
}
