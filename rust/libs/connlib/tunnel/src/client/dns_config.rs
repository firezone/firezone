use std::{
    collections::HashSet,
    net::{IpAddr, Ipv4Addr, SocketAddr},
};

use dns_types::DoHUrl;
use ip_network::IpNetwork;

use crate::{
    client::{DNS_SENTINELS_V4, DNS_SENTINELS_V6, IpProvider},
    dns::{self, DNS_PORT},
};

#[derive(Debug, Default)]
pub(crate) struct DnsConfig {
    /// The DNS resolvers configured on the system outside of connlib.
    system_resolvers: Vec<IpAddr>,
    /// The Do53 resolvers configured in the portal.
    ///
    /// Has priority over system-configured DNS servers.
    /// Has priority over DoH resolvers.
    upstream_do53: Vec<IpAddr>,
    /// The DoH resolvers configured in the portal.
    ///
    /// Has priority over system-configured DNS servers.
    upstream_doh: Vec<DoHUrl>,
    /// The Do53 fallback resolvers in case nothing else is available.
    fallback_do53: Vec<IpAddr>,

    /// Maps from connlib-assigned IP of a DNS server back to the originally configured system DNS resolver.
    mapping: DnsMapping,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Hash)]
pub struct DnsMapping {
    inner: Vec<(IpAddr, dns::Upstream)>,
}

impl DnsMapping {
    pub fn sentinel_ips(&self) -> Vec<IpAddr> {
        self.inner.iter().map(|(ip, _)| ip).copied().collect()
    }

    pub fn upstream_servers(&self) -> Vec<dns::Upstream> {
        self.inner
            .iter()
            .map(|(_, upstream)| upstream)
            .cloned()
            .collect()
    }

    // Implementation note:
    //
    // These functions perform linear search instead of an O(1) map lookup.
    // Most users will only have a handful of DNS servers (like 1-3).
    // For such small numbers, linear search is usually more efficient.
    // Most importantly, it is much easier for us to retain the ordering of the DNS servers if we don't use a map.

    #[cfg(test)]
    pub(crate) fn sentinel_by_upstream(&self, upstream: &dns::Upstream) -> Option<IpAddr> {
        self.inner
            .iter()
            .find_map(|(sentinel, candidate)| (candidate == upstream).then_some(*sentinel))
    }

    pub(crate) fn upstream_by_sentinel(&self, sentinel: IpAddr) -> Option<dns::Upstream> {
        self.inner
            .iter()
            .find_map(|(candidate, upstream)| (candidate == &sentinel).then_some(upstream.clone()))
    }
}

impl DnsConfig {
    #[must_use = "Check if the DNS mapping has changed"]
    pub(crate) fn update_system_resolvers(&mut self, servers: Vec<IpAddr>) -> bool {
        let sanitized = without_sentinel_ips(&servers);

        tracing::debug!(?servers, ?sanitized, "Received system-defined DNS servers");

        if servers == self.fallback_do53 {
            return false;
        }

        self.system_resolvers = sanitized;

        self.update_dns_mapping()
    }

    #[must_use = "Check if the DNS mapping has changed"]
    pub(crate) fn update_upstream_do53_resolvers(&mut self, servers: Vec<IpAddr>) -> bool {
        let sanitized = without_sentinel_ips(&servers);

        tracing::debug!(
            ?servers,
            ?sanitized,
            "Received upstream-defined DNS servers"
        );

        self.upstream_do53 = sanitized;

        self.update_dns_mapping()
    }

    #[must_use = "Check if the DNS mapping has changed"]
    pub(crate) fn update_upstream_doh_resolvers(&mut self, servers: Vec<DoHUrl>) -> bool {
        tracing::debug!(?servers, "Received upstream-defined DoH servers");

        self.upstream_doh = servers;

        self.update_dns_mapping()
    }

    #[must_use = "Check if the DNS mapping has changed"]
    pub(crate) fn update_fallback_do53_resolvers(&mut self, servers: Vec<IpAddr>) -> bool {
        tracing::debug!(?servers, "Received fallback DNS servers");

        self.fallback_do53 = servers;

        self.update_dns_mapping()
    }

    pub(crate) fn has_custom_upstream(&self) -> bool {
        !self.upstream_do53.is_empty() || !self.upstream_doh.is_empty()
    }

    pub(crate) fn mapping(&mut self) -> DnsMapping {
        self.mapping.clone()
    }

    pub(crate) fn system_dns_resolvers(&self) -> Vec<IpAddr> {
        self.system_resolvers.clone()
    }

    fn update_dns_mapping(&mut self) -> bool {
        let effective_dns_servers = effective_dns_servers(
            self.upstream_do53.clone(),
            self.upstream_doh.clone(),
            self.system_resolvers.clone(),
            self.fallback_do53.clone(),
        );

        if HashSet::<dns::Upstream>::from_iter(effective_dns_servers.clone())
            == HashSet::from_iter(self.mapping.upstream_servers())
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
    upstream_doh: Vec<DoHUrl>,
    system_resolvers: Vec<IpAddr>,
    fallback_resolvers: Vec<IpAddr>,
) -> Vec<dns::Upstream> {
    if !upstream_do53.is_empty() {
        return upstream_do53
            .into_iter()
            .map(|ip| dns::Upstream::Do53 {
                server: SocketAddr::new(ip, DNS_PORT),
            })
            .collect();
    }

    if !upstream_doh.is_empty() {
        return upstream_doh
            .into_iter()
            .map(|server| dns::Upstream::DoH { server })
            .collect();
    }

    if !system_resolvers.is_empty() {
        return system_resolvers
            .into_iter()
            .map(|ip| dns::Upstream::Do53 {
                server: SocketAddr::new(ip, DNS_PORT),
            })
            .collect();
    }

    fallback_resolvers
        .into_iter()
        .map(|ip| dns::Upstream::Do53 {
            server: SocketAddr::new(ip, DNS_PORT),
        })
        .collect()
}

fn sentinel_dns_mapping(dns: &[dns::Upstream], old_sentinels: Vec<IpAddr>) -> DnsMapping {
    let mut ip_provider = IpProvider::for_stub_dns_servers(old_sentinels);

    let mapping = dns
        .iter()
        .map(|u| {
            let ip_addr = match u {
                dns::Upstream::Do53 { server } => server.ip(),
                dns::Upstream::DoH { .. } => IpAddr::V4(Ipv4Addr::UNSPECIFIED), // DoH servers are always mapped to IPv4 servers.
            };

            (
                ip_provider
                    .get_proxy_ip_for(&ip_addr)
                    .expect("We only support up to 256 IPv4 DNS servers and 256 IPv6 DNS servers"),
                u.clone(),
            )
        })
        .collect();

    DnsMapping { inner: mapping }
}

fn without_sentinel_ips(servers: &[IpAddr]) -> Vec<IpAddr> {
    servers.iter().copied().filter_map(not_sentinel).collect()
}

fn not_sentinel(srv: IpAddr) -> Option<IpAddr> {
    let is_v4_dns = IpNetwork::V4(DNS_SENTINELS_V4).contains(srv);
    let is_v6_dns = IpNetwork::V6(DNS_SENTINELS_V6).contains(srv);

    (!is_v4_dns && !is_v6_dns).then_some(srv)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_system_resolvers_to_sentinel_ips() {
        let mut config = DnsConfig::default();

        let changed = config.update_system_resolvers(vec![
            ip("1.1.1.1"),
            ip("1.0.0.1"),
            ip("2606:4700:4700::1111"),
        ]);
        assert!(changed);

        assert_eq!(config.mapping().sentinel_ips().len(), 3);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![
                do53("1.1.1.1:53"),
                do53("1.0.0.1:53"),
                do53("[2606:4700:4700::1111]:53"),
            ]
        );
    }

    #[test]
    fn prefers_upstream_do53_over_system_resolvers() {
        let mut config = DnsConfig::default();

        let changed = config.update_system_resolvers(vec![ip("1.1.1.1")]);
        assert!(changed);
        let changed = config.update_upstream_do53_resolvers(vec![ip("1.0.0.1")]);
        assert!(changed);

        assert_eq!(config.mapping().sentinel_ips().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![do53("1.0.0.1:53"),]
        );
    }

    #[test]
    fn filters_sentinel_ips_from_system() {
        let mut config = DnsConfig::default();

        let changed = config.update_system_resolvers(vec![ip("1.1.1.1"), ip("100.100.111.1")]);
        assert!(changed);

        assert_eq!(config.mapping().sentinel_ips().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![do53("1.1.1.1:53"),]
        );
    }

    #[test]
    fn filters_fallback_ips_from_system() {
        let mut config = DnsConfig::default();

        let _ = config.update_fallback_do53_resolvers(vec![ip("9.9.9.9")]);
        let _ = config.update_system_resolvers(vec![ip("9.9.9.9")]);

        assert_eq!(config.mapping().sentinel_ips().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![do53("9.9.9.9:53"),]
        );
        assert_eq!(config.system_dns_resolvers(), Vec::<IpAddr>::default());
    }

    #[test]
    fn prefers_system_over_fallback() {
        let mut config = DnsConfig::default();

        let _ = config.update_system_resolvers(vec![ip("1.1.1.1")]);
        let _ = config.update_fallback_do53_resolvers(vec![ip("9.9.9.9")]);

        assert_eq!(config.mapping().sentinel_ips().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![do53("1.1.1.1:53"),]
        );
    }

    #[test]
    fn prefers_upstream_over_fallback() {
        let mut config = DnsConfig::default();

        let _ = config.update_upstream_do53_resolvers(vec![ip("1.1.1.1")]);
        let _ = config.update_fallback_do53_resolvers(vec![ip("9.9.9.9")]);

        assert_eq!(config.mapping().sentinel_ips().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![do53("1.1.1.1:53"),]
        );
    }

    #[test]
    fn filters_sentinel_ips_from_upstream() {
        let mut config = DnsConfig::default();

        let changed =
            config.update_upstream_do53_resolvers(vec![ip("1.1.1.1"), ip("100.100.111.1")]);
        assert!(changed);

        assert_eq!(config.mapping().sentinel_ips().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![do53("1.1.1.1:53"),]
        );
    }

    fn ip(address: &str) -> IpAddr {
        address.parse().unwrap()
    }

    fn do53(socket: &str) -> dns::Upstream {
        dns::Upstream::Do53 {
            server: socket.parse().unwrap(),
        }
    }
}
