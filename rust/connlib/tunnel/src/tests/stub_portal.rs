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
    sites: HashMap<client::SiteId, client::Site>,

    sites_by_resource: HashMap<ResourceId, client::SiteId>,
    cidr_resources: HashMap<ResourceId, client::ResourceDescriptionCidr>,
    dns_resources: HashMap<ResourceId, client::ResourceDescriptionDns>,

    gateway_selector: Selector,
}

impl StubPortal {
    pub(crate) fn new(
        gateways_by_site: HashMap<client::SiteId, HashSet<GatewayId>>,
        sites: HashMap<client::SiteId, client::Site>,
        gateway_selector: Selector,
    ) -> Self {
        Self {
            gateways_by_site,
            sites,
            gateway_selector,
            sites_by_resource: Default::default(),
            cidr_resources: Default::default(),
            dns_resources: Default::default(),
        }
    }

    pub(crate) fn all_sites(&self) -> Vec<client::Site> {
        self.sites.values().cloned().collect()
    }

    pub(crate) fn add_resource(&mut self, resource: client::ResourceDescription) {
        let site = resource
            .sites()
            .into_iter()
            .exactly_one()
            .expect("only single-site resources are supported");

        self.sites_by_resource.insert(resource.id(), site.id);

        match resource {
            client::ResourceDescription::Dns(dns) => {
                self.dns_resources.insert(dns.id, dns);
            }
            client::ResourceDescription::Cidr(cidr) => {
                self.cidr_resources.insert(cidr.id, cidr);
            }
        }
    }

    pub(crate) fn remove_resource(&mut self, resource: ResourceId) {
        self.sites_by_resource.remove(&resource);
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
