use super::sim_client::RefClient;
use connlib_shared::messages::{client::SiteId, GatewayId, ResourceId};
use std::collections::{HashMap, HashSet};

/// Stub implementation of the portal.
///
/// Currently, we only simulate a connection between a single client and a single gateway on a single site.
#[derive(Debug, Clone)]
pub(crate) struct SimPortal {
    gateways_by_site: HashMap<SiteId, GatewayId>, // TODO: Technically, this is wrong because a site has multiple gateways but not the other way round.
}

impl SimPortal {
    pub(crate) fn new() -> Self {
        Self {
            gateways_by_site: HashMap::default(),
        }
    }

    pub(crate) fn register_site(&mut self, site: SiteId, gateway: GatewayId) {
        self.gateways_by_site.insert(site, gateway);
    }

    /// Picks, which gateway and site we should connect to for the given resource.
    pub(crate) fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: HashSet<GatewayId>,
        client: &RefClient,
    ) -> (GatewayId, SiteId) {
        // TODO: Should we somehow vary how many gateways we connect to?
        // TODO: Should we somehow pick, which site to use?

        let site_id = client
            .site_for_resource(resource)
            .expect("resource to be known CIDR or DNS resource");

        let gateway_id = self.gateways_by_site.get(&site_id).unwrap();

        (*gateway_id, site_id)
    }
}
