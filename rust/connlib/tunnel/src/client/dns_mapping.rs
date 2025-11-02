use std::net::IpAddr;

use bimap::BiMap;
use ip_network::IpNetwork;

use crate::{
    client::{DNS_SENTINELS_V4, DNS_SENTINELS_V6, IpProvider},
    dns::DNS_PORT,
    messages::{DnsServer, IpDnsServer},
};

pub(crate) fn effective_dns_servers(
    upstream_dns: Vec<DnsServer>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<DnsServer> {
    let mut upstream_dns = upstream_dns.into_iter().filter_map(not_sentinel).peekable();
    if upstream_dns.peek().is_some() {
        return upstream_dns.collect();
    }

    let mut dns_servers = default_resolvers
        .into_iter()
        .map(|ip| {
            DnsServer::IpPort(IpDnsServer {
                address: (ip, DNS_PORT).into(),
            })
        })
        .filter_map(not_sentinel)
        .peekable();

    if dns_servers.peek().is_none() {
        tracing::info!(
            "No system default DNS servers available! Can't initialize resolver. DNS resources won't work."
        );
        return Vec::new();
    }

    dns_servers.collect()
}

pub(crate) fn sentinel_dns_mapping(
    dns: &[DnsServer],
    old_sentinels: Vec<IpNetwork>,
) -> BiMap<IpAddr, DnsServer> {
    let mut ip_provider = IpProvider::for_stub_dns_servers(old_sentinels);

    dns.iter()
        .cloned()
        .map(|i| {
            (
                ip_provider
                    .get_proxy_ip_for(&i.ip())
                    .expect("We only support up to 256 IPv4 DNS servers and 256 IPv6 DNS servers"),
                i,
            )
        })
        .collect()
}

fn not_sentinel(srv: DnsServer) -> Option<DnsServer> {
    let is_v4_dns = IpNetwork::V4(DNS_SENTINELS_V4).contains(srv.ip());
    let is_v6_dns = IpNetwork::V6(DNS_SENTINELS_V6).contains(srv.ip());

    (!is_v4_dns && !is_v6_dns).then_some(srv)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use itertools::Itertools as _;

    use super::*;

    #[test]
    fn sentinel_dns_works() {
        let servers = dns_list();
        let sentinel_dns = sentinel_dns_mapping(&servers, vec![]);

        for server in servers {
            assert!(
                sentinel_dns
                    .get_by_right(&server)
                    .is_some_and(|s| sentinel_ranges().iter().any(|e| e.contains(*s)))
            )
        }
    }

    #[test]
    fn sentinel_dns_excludes_old_ones() {
        let servers = dns_list();
        let sentinel_dns_old = sentinel_dns_mapping(&servers, vec![]);
        let sentinel_dns_new = sentinel_dns_mapping(
            &servers,
            sentinel_dns_old
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        assert!(
            HashSet::<&IpAddr>::from_iter(sentinel_dns_old.left_values())
                .is_disjoint(&HashSet::from_iter(sentinel_dns_new.left_values()))
        )
    }

    fn sentinel_ranges() -> Vec<IpNetwork> {
        vec![
            IpNetwork::V4(DNS_SENTINELS_V4),
            IpNetwork::V6(DNS_SENTINELS_V6),
        ]
    }

    fn dns_list() -> Vec<DnsServer> {
        vec![
            dns("1.1.1.1:53"),
            dns("1.0.0.1:53"),
            dns("[2606:4700:4700::1111]:53"),
        ]
    }

    fn dns(address: &str) -> DnsServer {
        DnsServer::IpPort(IpDnsServer {
            address: address.parse().unwrap(),
        })
    }
}
