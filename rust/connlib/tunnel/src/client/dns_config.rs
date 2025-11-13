use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddr},
};

use ip_network::IpNetwork;
use url::Url;

use crate::{
    client::{DNS_SENTINELS_V4, DNS_SENTINELS_V6, IpProvider},
    dns::DNS_PORT,
};

#[derive(Debug, Default)]
pub(crate) struct DnsConfig {
    /// The DNS resolvers configured on the system outside of connlib.
    system_resolvers: Vec<IpAddr>,
    /// The Do53 resolvers configured in the portal.
    ///
    /// Has priority over system-configured DNS servers.
    upstream_do53: Vec<IpAddr>,
    /// The DoH resolvers configured in the portal.
    ///
    /// Has priority over system-configured DNS servers.
    upstream_doh: Vec<Url>,

    /// Maps from connlib-assigned IP of a DNS server back to the originally configured system DNS resolver.
    mapping: DnsMapping,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DnsMapping {
    inner: Vec<(IpAddr, SocketAddr)>,
}

impl DnsMapping {
    pub fn sentinel_ips(&self) -> Vec<IpAddr> {
        self.inner.iter().map(|(ip, _)| ip).copied().collect()
    }

    pub fn upstream_sockets(&self) -> Vec<SocketAddr> {
        self.inner
            .iter()
            .map(|(_, socket)| socket)
            .copied()
            .collect()
    }

    // Implementation note:
    //
    // These functions perform linear search instead of an O(1) map lookup.
    // Most users will only have a handful of DNS servers (like 1-3).
    // For such small numbers, linear search is usually more efficient.
    // Most importantly, it is much easier for us to retain the ordering of the DNS servers if we don't use a map.

    #[cfg(test)]
    pub(crate) fn sentinel_by_upstream(&self, upstream: SocketAddr) -> Option<IpAddr> {
        self.inner
            .iter()
            .find_map(|(sentinel, candidate)| (candidate == &upstream).then_some(*sentinel))
    }

    pub(crate) fn upstream_by_sentinel(&self, sentinel: IpAddr) -> Option<SocketAddr> {
        self.inner
            .iter()
            .find_map(|(candidate, upstream)| (candidate == &sentinel).then_some(*upstream))
    }
}

impl DnsConfig {
    #[must_use = "Check if the DNS mapping has changed"]
    pub(crate) fn update_system_resolvers(&mut self, servers: Vec<IpAddr>) -> bool {
        tracing::debug!(?servers, "Received system-defined DNS servers");

        self.system_resolvers = servers;

        self.update_dns_mapping()
    }

    #[must_use = "Check if the DNS mapping has changed"]
    pub(crate) fn update_upstream_do53_resolvers(&mut self, servers: Vec<IpAddr>) -> bool {
        tracing::debug!(?servers, "Received upstream-defined Do53 servers");

        self.upstream_do53 = servers;

        self.update_dns_mapping()
    }

    #[must_use = "Check if the DNS mapping has changed"]
    pub(crate) fn update_upstream_doh_resolvers(&mut self, servers: Vec<Url>) -> bool {
        tracing::debug!(?servers, "Received upstream-defined DoH servers");

        self.upstream_doh = servers;

        self.update_dns_mapping()
    }

    pub(crate) fn has_custom_upstream(&self) -> bool {
        !self.upstream_do53.is_empty()
    }

    pub(crate) fn mapping(&mut self) -> DnsMapping {
        self.mapping.clone()
    }

    fn update_dns_mapping(&mut self) -> bool {
        let effective_dns_servers =
            effective_dns_servers(self.upstream_do53.clone(), self.system_resolvers.clone());

        if HashSet::<SocketAddr>::from_iter(effective_dns_servers.clone())
            == HashSet::from_iter(self.mapping.upstream_sockets())
        {
            tracing::debug!(servers = ?effective_dns_servers, "Effective DNS servers are unchanged");

            return false;
        }

        self.mapping = sentinel_dns_mapping(&effective_dns_servers, self.mapping.sentinel_ips());

        true
    }
}

fn effective_dns_servers(
    upstream_do53: Vec<IpAddr>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<SocketAddr> {
    let mut upstream_dns = upstream_do53
        .into_iter()
        .filter_map(not_sentinel)
        .peekable();
    if upstream_dns.peek().is_some() {
        return upstream_dns
            .map(|ip| SocketAddr::new(ip, DNS_PORT))
            .collect();
    }

    let mut dns_servers = default_resolvers
        .into_iter()
        .filter_map(not_sentinel)
        .map(|ip| SocketAddr::new(ip, DNS_PORT))
        .peekable();

    if dns_servers.peek().is_none() {
        tracing::info!(
            "No system default DNS servers available! Can't initialize resolver. DNS resources won't work."
        );
        return Vec::new();
    }

    dns_servers.collect()
}

fn sentinel_dns_mapping(dns: &[SocketAddr], old_sentinels: Vec<IpAddr>) -> DnsMapping {
    let mut ip_provider = IpProvider::for_stub_dns_servers(old_sentinels);

    let mapping = dns
        .iter()
        .copied()
        .map(|i| {
            (
                ip_provider
                    .get_proxy_ip_for(&i.ip())
                    .expect("We only support up to 256 IPv4 DNS servers and 256 IPv6 DNS servers"),
                i,
            )
        })
        .collect();

    DnsMapping { inner: mapping }
}

fn not_sentinel(srv: IpAddr) -> Option<IpAddr> {
    let is_v4_dns = IpNetwork::V4(DNS_SENTINELS_V4).contains(srv);
    let is_v6_dns = IpNetwork::V6(DNS_SENTINELS_V6).contains(srv);

    (!is_v4_dns && !is_v6_dns).then_some(srv)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn sentinel_dns_works() {
        let servers = dns_list();
        let sentinel_dns = sentinel_dns_mapping(&servers, vec![]);

        for server in servers {
            assert!(
                sentinel_dns
                    .sentinel_by_upstream(server)
                    .is_some_and(|ip| sentinel_ranges().iter().any(|e| e.contains(ip)))
            )
        }
    }

    #[test]
    fn sentinel_dns_excludes_old_ones() {
        let servers = dns_list();
        let sentinel_dns_old = sentinel_dns_mapping(&servers, vec![]);
        let sentinel_dns_new = sentinel_dns_mapping(&servers, sentinel_dns_old.sentinel_ips());

        assert!(
            HashSet::<IpAddr>::from_iter(sentinel_dns_old.sentinel_ips())
                .is_disjoint(&HashSet::from_iter(sentinel_dns_new.sentinel_ips()))
        )
    }

    fn sentinel_ranges() -> Vec<IpNetwork> {
        vec![
            IpNetwork::V4(DNS_SENTINELS_V4),
            IpNetwork::V6(DNS_SENTINELS_V6),
        ]
    }

    fn dns_list() -> Vec<SocketAddr> {
        vec![
            dns("1.1.1.1:53"),
            dns("1.0.0.1:53"),
            dns("[2606:4700:4700::1111]:53"),
        ]
    }

    fn dns(address: &str) -> SocketAddr {
        address.parse().unwrap()
    }
}
