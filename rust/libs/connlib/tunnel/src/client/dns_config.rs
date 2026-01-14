use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddr},
};

use dns_types::DoHUrl;
use ip_network::IpNetwork;

use crate::{
    client::DNS_SENTINELS,
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

    /// Maps from connlib-assigned IP of a DNS server back to the originally configured system DNS resolver.
    mapping: DnsMapping,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Hash)]
pub struct DnsMapping {
    inner: Vec<(IpAddr, dns::Upstream)>,
}

impl DnsMapping {
    /// Returns the custom DNS servers operated by connlib.
    ///
    /// This is only relevant if DoH is active or there are account-wide custom DNS servers.
    /// When the system-defined DNS servers are used, this returns an empty list.
    pub fn custom_dns_servers(&self) -> Vec<IpAddr> {
        self.inner
            .iter()
            .filter_map(|(ip, u)| match u {
                dns::Upstream::CustomDo53 { .. } | dns::Upstream::DoH { .. } => Some(ip),
                dns::Upstream::LocalDo53 { .. } => None,
            })
            .copied()
            .collect()
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

        if sanitized == self.upstream_do53 {
            tracing::debug!(
                ?servers,
                "Ignoring system resolvers equal to custom upstreams"
            );
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

    pub(crate) fn has_custom_upstream(&self) -> bool {
        !self.upstream_do53.is_empty() || !self.upstream_doh.is_empty()
    }

    pub fn internal_dns_servers(&self) -> Vec<IpAddr> {
        self.mapping
            .inner
            .iter()
            .map(|(ip, _)| ip)
            .copied()
            .collect()
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
        );

        if HashSet::<dns::Upstream>::from_iter(effective_dns_servers.clone())
            == HashSet::from_iter(self.mapping.upstream_servers())
        {
            tracing::debug!(servers = ?effective_dns_servers, "Effective DNS servers are unchanged");

            return false;
        }

        self.mapping = sentinel_dns_mapping(&effective_dns_servers, self.internal_dns_servers());

        true
    }
}

fn effective_dns_servers(
    upstream_do53: Vec<IpAddr>,
    upstream_doh: Vec<DoHUrl>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<dns::Upstream> {
    if !upstream_do53.is_empty() {
        return upstream_do53
            .into_iter()
            .map(|ip| dns::Upstream::CustomDo53 {
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

    if default_resolvers.is_empty() {
        tracing::info!(
            "No system default DNS servers available! Can't initialize resolver. DNS resources won't work."
        );
        return Vec::new();
    }

    default_resolvers
        .into_iter()
        .map(|ip| dns::Upstream::LocalDo53 {
            server: SocketAddr::new(ip, DNS_PORT),
        })
        .collect()
}

fn sentinel_dns_mapping(dns: &[dns::Upstream], old_sentinels: Vec<IpAddr>) -> DnsMapping {
    let mut doh_sentinels = DNS_SENTINELS
        .hosts()
        .filter(move |ip| !old_sentinels.iter().any(|e| e == ip));

    let mapping = dns
        .iter()
        .map(|u| {
            let ip = match u {
                dns::Upstream::LocalDo53 { server } | dns::Upstream::CustomDo53 { server } => {
                    server.ip()
                }
                dns::Upstream::DoH { .. } => doh_sentinels
                    .next()
                    .expect("Only 256 concurrent DoH servers are supported")
                    .into(),
            };

            (ip, u.clone())
        })
        .collect();

    DnsMapping { inner: mapping }
}

fn without_sentinel_ips(servers: &[IpAddr]) -> Vec<IpAddr> {
    servers.iter().copied().filter_map(not_sentinel).collect()
}

fn not_sentinel(srv: IpAddr) -> Option<IpAddr> {
    let is_v4_dns = IpNetwork::V4(DNS_SENTINELS).contains(srv);

    (!is_v4_dns).then_some(srv)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_resolvers() {
        let mut config = DnsConfig::default();

        let changed = config.update_system_resolvers(vec![
            ip("1.1.1.1"),
            ip("1.0.0.1"),
            ip("2606:4700:4700::1111"),
        ]);
        assert!(changed);

        assert_eq!(
            config.internal_dns_servers().len(),
            3,
            "all IPs should be listed as internal resolvers"
        );
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![
                local_do53("1.1.1.1:53"),
                local_do53("1.0.0.1:53"),
                local_do53("[2606:4700:4700::1111]:53")
            ],
            "all IPs should be upstream servers"
        );
        assert_eq!(
            config.system_dns_resolvers(),
            vec![ip("1.1.1.1"), ip("1.0.0.1"), ip("2606:4700:4700::1111")]
        );
    }

    #[test]
    fn prefers_upstream_do53_over_system_resolvers() {
        let mut config = DnsConfig::default();

        let changed = config.update_system_resolvers(vec![ip("1.1.1.1")]);
        assert!(changed);
        let changed = config.update_upstream_do53_resolvers(vec![ip("1.0.0.1")]);
        assert!(changed);

        assert_eq!(config.internal_dns_servers().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![custom_do53("1.0.0.1:53"),]
        );
    }

    #[test]
    fn filters_sentinel_ips_from_system() {
        let mut config = DnsConfig::default();

        let changed = config.update_system_resolvers(vec![ip("1.1.1.1"), ip("100.100.111.1")]);
        assert!(changed);

        assert_eq!(config.internal_dns_servers().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![local_do53("1.1.1.1:53"),]
        );
        assert_eq!(config.system_dns_resolvers(), vec![ip("1.1.1.1")]);
    }

    // When we set custom upstream servers, those will be reported as the system resolvers.
    // We have to ignore those and retain the old ones.
    #[test]
    fn filters_custom_upstream_ips_from_system() {
        let mut config = DnsConfig::default();

        let _ = config.update_system_resolvers(vec![ip("192.168.0.1")]);
        let _ = config.update_upstream_do53_resolvers(vec![ip("1.1.1.1")]);
        let _ = config.update_system_resolvers(vec![ip("1.1.1.1")]);

        assert_eq!(config.internal_dns_servers().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![local_do53("1.1.1.1:53"),]
        );
        assert_eq!(config.system_dns_resolvers(), vec![ip("192.168.0.1")]);
    }

    #[test]
    fn filters_sentinel_ips_from_upstream() {
        let mut config = DnsConfig::default();

        let changed =
            config.update_upstream_do53_resolvers(vec![ip("1.1.1.1"), ip("100.100.111.1")]);
        assert!(changed);

        assert_eq!(config.internal_dns_servers().len(), 1);
        assert_eq!(
            config.mapping().upstream_servers(),
            vec![custom_do53("1.1.1.1:53"),]
        );
    }

    fn ip(address: &str) -> IpAddr {
        address.parse().unwrap()
    }

    fn local_do53(socket: &str) -> dns::Upstream {
        dns::Upstream::LocalDo53 {
            server: socket.parse().unwrap(),
        }
    }

    fn custom_do53(socket: &str) -> dns::Upstream {
        dns::Upstream::CustomDo53 {
            server: socket.parse().unwrap(),
        }
    }
}
