use super::{
    dns_records::DnsRecords,
    reference::PrivateKey,
    sim_gateway::SimGateway,
    sim_net::ExecMutScope,
    site_network::{Routes, SiteNetwork},
};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, GatewayId, ResourceId};
use dns_types::{DomainName, OwnedRecordData};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{Ipv4Addr, Ipv6Addr},
    time::Instant,
};
use tunnel_proto::{GatewayState, IpConfig};

/// Reference state for a particular gateway.
#[derive(Debug, Clone)]
pub struct RefGateway {
    pub(crate) key: PrivateKey,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,
    /// The routes of the network behind the Gateway.
    pub(crate) routes: Routes,

    site_specific_dns_records: DnsRecords,
    /// Names the Gateway's upstream resolver does not resolve.
    unresolvable_names: BTreeSet<DomainName>,
    max_dns_domains_per_client: Option<usize>,

    /// The resources each Client is authorized to reach through the Gateway.
    authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,
}

impl RefGateway {
    /// Construct a [`RefGateway`] from generated parts.
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
            authorizations: Default::default(),
        }
    }

    /// Initialize the [`GatewayState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(
        self,
        id: GatewayId,
        tcp_services: BTreeMap<DomainName, BTreeSet<u16>>,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> SimGateway {
        let mut sut = GatewayState::new(
            self.key.0,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        ); // Cheating a bit here by reusing the key as seed.
        if let Some(max) = self.max_dns_domains_per_client {
            sut.set_max_dns_domains_per_client(max);
        }
        sut.update_tun_device(IpConfig {
            v4: self.tunnel_ip4,
            v6: self.tunnel_ip6,
        });

        let network = SiteNetwork::new(self.routes, tcp_services, now);

        SimGateway::new(
            id,
            sut,
            network,
            self.site_specific_dns_records,
            self.max_dns_domains_per_client,
        )
    }

    pub(crate) fn authorize(&mut self, client: ClientId, resource: ResourceId) {
        self.authorizations
            .entry(client)
            .or_default()
            .insert(resource);
    }

    /// Drops every authorization for `resource` and returns the Clients left with none.
    pub(crate) fn revoke(&mut self, resource: ResourceId) -> Vec<ClientId> {
        for resources in self.authorizations.values_mut() {
            resources.remove(&resource);
        }

        self.authorizations
            .extract_if(.., |_, resources| resources.is_empty())
            .map(|(client, _)| client)
            .collect()
    }

    pub(crate) fn forget_client(&mut self, client: ClientId) {
        self.authorizations.remove(&client);
    }

    pub(crate) fn forget_all_clients(&mut self) {
        self.authorizations.clear();
    }

    pub(crate) fn is_authorized(&self, client: ClientId, resource: ResourceId) -> bool {
        self.authorizations
            .get(&client)
            .is_some_and(|resources| resources.contains(&resource))
    }

    pub(crate) fn authorized_resources(&self) -> impl Iterator<Item = ResourceId> + '_ {
        self.authorizations.values().flatten().copied()
    }

    pub(crate) fn authorized_clients(&self) -> BTreeSet<ClientId> {
        self.authorizations.keys().copied().collect()
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

impl ExecMutScope for RefGateway {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}
