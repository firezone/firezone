use std::{
    collections::{HashSet, VecDeque},
    net::{IpAddr, SocketAddr},
};

use anyhow::{Context as _, Result};
use bimap::BiMap;
use ip_network::IpNetwork;
use itertools::Itertools as _;

use crate::{
    client::{DNS_SENTINELS_V4, DNS_SENTINELS_V6, IpProvider},
    dns::DNS_PORT,
    messages::{DnsServer, IpDnsServer},
};

#[derive(Debug, Default)]
pub(crate) struct DnsConfig {
    /// The DNS resolvers configured on the system outside of connlib.
    system_resolvers: Vec<IpAddr>,
    /// The DNS resolvers configured in the portal.
    ///
    /// Has priority over system-configured DNS servers.
    upstream_dns: Vec<DnsServer>,

    /// Maps from connlib-assigned IP of a DNS server back to the originally configured system DNS resolver.
    mapping: BiMap<IpAddr, DnsServer>,

    pending_events: VecDeque<Event>,
}

impl DnsConfig {
    pub(crate) fn get_sentinel_by_upstream(&self, upstream: SocketAddr) -> Result<IpAddr> {
        let ip_addr = self
            .mapping
            .get_by_right(&DnsServer::from(upstream))
            .context("Unknown DNS server")?;

        Ok(*ip_addr)
    }

    pub(crate) fn get_upstream_by_sentinel(&self, sentinel: IpAddr) -> Result<SocketAddr> {
        let upstream = self
            .mapping
            .get_by_left(&sentinel)
            .context("Unknown DNS server")?;

        Ok(upstream.address())
    }

    pub(crate) fn sentinel_servers(&self) -> Vec<SocketAddr> {
        self.mapping
            .left_values()
            .map(|ip| SocketAddr::new(*ip, DNS_PORT))
            .collect()
    }

    pub(crate) fn update_system_resolvers(&mut self, servers: Vec<IpAddr>) {
        tracing::debug!(?servers, "Received system-defined DNS servers");

        self.system_resolvers = servers;

        self.update_dns_mapping()
    }

    pub(crate) fn update_upstream_resolvers(&mut self, servers: Vec<DnsServer>) {
        tracing::debug!(?servers, "Received upstream-defined DNS servers");

        self.upstream_dns = servers;

        self.update_dns_mapping()
    }

    pub(crate) fn has_custom_upstream(&self) -> bool {
        !self.upstream_dns.is_empty()
    }

    pub(crate) fn poll_event(&mut self) -> Option<Event> {
        self.pending_events.pop_front()
    }

    pub(crate) fn mapping(&mut self) -> BiMap<IpAddr, SocketAddr> {
        self.mapping
            .iter()
            .map(|(sentinel_dns, effective_dns)| (*sentinel_dns, effective_dns.address()))
            .collect::<BiMap<_, _>>()
    }

    fn update_dns_mapping(&mut self) {
        let effective_dns_servers =
            effective_dns_servers(self.upstream_dns.clone(), self.system_resolvers.clone());

        if HashSet::<&DnsServer>::from_iter(effective_dns_servers.iter())
            == HashSet::from_iter(self.mapping.right_values())
        {
            tracing::debug!(servers = ?effective_dns_servers, "Effective DNS servers are unchanged");

            return;
        }

        self.mapping = sentinel_dns_mapping(
            &effective_dns_servers,
            self.mapping
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        self.pending_events.push_back(Event::DnsServersUpdated);
    }
}

#[derive(Debug)]
pub(crate) enum Event {
    DnsServersUpdated,
}

fn effective_dns_servers(
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

fn sentinel_dns_mapping(
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
