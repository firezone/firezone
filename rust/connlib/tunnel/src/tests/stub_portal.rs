use connlib_shared::messages::{client, gateway, GatewayId, ResourceId};
use itertools::Itertools;
use proptest::sample::Selector;
use std::{
    collections::{HashMap, HashSet},
    net::IpAddr,
};

/// Stub implementation of the portal.
#[derive(Debug, Clone)]
pub(crate) struct StubPortal {
    gateways_by_site: HashMap<client::SiteId, HashSet<GatewayId>>,

    sites_by_resource: HashMap<ResourceId, client::SiteId>,
    cidr_resources: HashMap<ResourceId, client::ResourceDescriptionCidr>,
    dns_resources: HashMap<ResourceId, client::ResourceDescriptionDns>,

    gateway_selector: Selector,
}

impl StubPortal {
    pub(crate) fn new(
        gateways_by_site: HashMap<client::SiteId, HashSet<GatewayId>>,
        gateway_selector: Selector,
        cidr_resources: HashSet<client::ResourceDescriptionCidr>,
        dns_resources: HashSet<client::ResourceDescriptionDns>,
    ) -> Self {
        let cidr_resources = cidr_resources
            .into_iter()
            .map(|r| (r.id, r))
            .collect::<HashMap<_, _>>();
        let dns_resources = dns_resources
            .into_iter()
            .map(|r| (r.id, r))
            .collect::<HashMap<_, _>>();

        let cidr_sites = cidr_resources.iter().map(|(id, r)| {
            (
                *id,
                r.sites
                    .iter()
                    .exactly_one()
                    .expect("only single-site resources")
                    .id,
            )
        });
        let dns_sites = dns_resources.iter().map(|(id, r)| {
            (
                *id,
                r.sites
                    .iter()
                    .exactly_one()
                    .expect("only single-site resources")
                    .id,
            )
        });

        Self {
            gateways_by_site,
            gateway_selector,
            sites_by_resource: HashMap::from_iter(cidr_sites.chain(dns_sites)),
            cidr_resources,
            dns_resources,
        }
    }

    pub(crate) fn all_resources(&self) -> Vec<client::ResourceDescription> {
        self.cidr_resources
            .values()
            .cloned()
            .map(client::ResourceDescription::Cidr)
            .chain(
                self.dns_resources
                    .values()
                    .cloned()
                    .map(client::ResourceDescription::Dns),
            )
            .collect()
    }

    pub(crate) fn cidr_resources(
        &self,
    ) -> impl Iterator<Item = (&ResourceId, &ResourceDescriptionCidr)> + '_ {
        self.cidr_resources.iter()
    }

    /// Picks, which gateway and site we should connect to for the given resource.
    pub(crate) fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: HashSet<GatewayId>,
    ) -> (GatewayId, client::SiteId) {
        let site_id = self
            .sites_by_resource
            .get(&resource)
            .expect("resource to be known");

        let gateways = self.gateways_by_site.get(site_id).unwrap();
        let gateway = self.gateway_selector.select(gateways);

        (*gateway, *site_id)
    }

    pub(crate) fn map_client_resource_to_gateway_resource(
        &self,
        resolved_ips: Vec<IpAddr>,
        resource_id: ResourceId,
    ) -> gateway::ResourceDescription<gateway::ResolvedResourceDescriptionDns> {
        let cidr_resource = self.cidr_resources.iter().find_map(|(_, r)| {
            (r.id == resource_id).then_some(gateway::ResourceDescription::Cidr(
                gateway::ResourceDescriptionCidr {
                    id: r.id,
                    address: r.address,
                    name: r.name.clone(),
                    filters: Vec::new(),
                },
            ))
        });
        let dns_resource = self.dns_resources.get(&resource_id).map(|r| {
            gateway::ResourceDescription::Dns(gateway::ResolvedResourceDescriptionDns {
                id: r.id,
                name: r.name.clone(),
                filters: Vec::new(),
                domain: r.address.clone(),
                addresses: resolved_ips.clone(),
            })
        });

        cidr_resource
            .or(dns_resource)
            .expect("resource to be a known CIDR or DNS resource")
    }

    pub(crate) fn gateway_for_resource(&self, rid: ResourceId) -> Option<&GatewayId> {
        let cidr_site = self
            .cidr_resources
            .iter()
            .find_map(|(_, r)| (r.id == rid).then_some(r.sites.first()?.id));

        let dns_site = self
            .dns_resources
            .get(&rid)
            .and_then(|r| Some(r.sites.first()?.id));

        let sid = cidr_site.or(dns_site)?;
        let gateways = self.gateways_by_site.get(&sid)?;
        let gid = self.gateway_selector.try_select(gateways)?;

        Some(gid)
    }
}
