use super::{
    dns_records::DnsRecords,
    network::ExecMutScope,
    real_gateway::RealGateway,
    site_network::{Routes, SiteNetwork},
    tunnel_model::PrivateKey,
};
use connlib_model::GatewayId;
use dns_types::{DomainName, OwnedRecordData};
use jiff::Timestamp;
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{Ipv4Addr, Ipv6Addr},
    time::{Duration, Instant},
};
use tunnel_proto::{GatewayState, IpConfig};

/// Model of a particular gateway.
#[derive(Debug, Clone)]
pub struct ModelGateway {
    pub(crate) key: PrivateKey,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,
    /// The routes of the network behind the Gateway.
    pub(crate) routes: Routes,

    site_specific_dns_records: DnsRecords,
    /// Names the Gateway's upstream resolver does not resolve.
    unresolvable_names: BTreeSet<DomainName>,
    max_dns_domains_per_client: Option<usize>,
}

impl ModelGateway {
    /// Construct a [`ModelGateway`] from generated parts.
    pub(crate) fn from_parts(
        key: PrivateKey,
        tunnel_ip4: Ipv4Addr,
        tunnel_ip6: Ipv6Addr,
        routes: Routes,
        site_specific_dns_records: DnsRecords,
        unresolvable_names: BTreeSet<DomainName>,
        max_dns_domains_per_client: Option<usize>,
    ) -> Self {
        Self {
            key,
            tunnel_ip4,
            tunnel_ip6,
            routes,
            site_specific_dns_records,
            unresolvable_names,
            max_dns_domains_per_client,
        }
    }

    /// Initialize the [`GatewayState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(
        self,
        id: GatewayId,
        tcp_services: BTreeMap<DomainName, BTreeSet<u16>>,
        listen_port: u16,
        now: Instant,
        utc_now: Timestamp,
    ) -> RealGateway {
        let mut state = GatewayState::new(
            self.key.0,
            now,
            Duration::try_from(utc_now.as_duration()).unwrap(),
        ); // Cheating a bit here by reusing the key as seed.
        if let Some(max) = self.max_dns_domains_per_client {
            state.set_max_dns_domains_per_client(max);
        }
        state.update_tun_device(IpConfig {
            v4: self.tunnel_ip4,
            v6: self.tunnel_ip6,
        });

        let network = SiteNetwork::new(self.routes, tcp_services, now);

        RealGateway::new(
            id,
            state,
            network,
            self.site_specific_dns_records,
            self.max_dns_domains_per_client,
            listen_port,
        )
    }

    pub fn dns_records(&self) -> &DnsRecords {
        &self.site_specific_dns_records
    }

    /// The records the Gateway's upstream resolver returns for `domain`.
    pub(crate) fn resolve<'a>(
        &self,
        domain: &DomainName,
        global_dns_records: &'a DnsRecords,
    ) -> impl Iterator<Item = OwnedRecordData> + 'a {
        let resolves = !self.unresolvable_names.contains(domain);

        global_dns_records
            .domain_records_iter(domain)
            .filter(move |_| resolves)
    }
}

impl ExecMutScope for ModelGateway {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}
