use connlib_shared::messages::{
    client::{ResourceDescriptionCidr, ResourceDescriptionDns, SiteId},
    ClientId, GatewayId, RelayId, ResourceId,
};
use ip_network_table::IpNetworkTable;
use std::collections::{BTreeMap, HashSet};

/// Stub implementation of the portal.
///
/// Currently, we only simulate a connection between a single client and a single gateway on a single site.
#[derive(Debug, Clone)]
pub(crate) struct SimPortal {
    _client: ClientId,
    gateway: GatewayId,
    _relay: RelayId,
}

impl SimPortal {
    pub(crate) fn new(_client: ClientId, gateway: GatewayId, _relay: RelayId) -> Self {
        Self {
            _client,
            gateway,
            _relay,
        }
    }

    /// Picks, which gateway and site we should connect to for the given resource.
    pub(crate) fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: HashSet<GatewayId>,
        client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
        client_dns_resources: &BTreeMap<ResourceId, ResourceDescriptionDns>,
    ) -> (GatewayId, SiteId) {
        // TODO: Should we somehow vary how many gateways we connect to?
        // TODO: Should we somehow pick, which site to use?

        let cidr_site = client_cidr_resources
            .iter()
            .find_map(|(_, r)| (r.id == resource).then_some(r.sites.first()?.id));

        let dns_site = client_dns_resources
            .get(&resource)
            .and_then(|r| Some(r.sites.first()?.id));

        (
            self.gateway,
            cidr_site
                .or(dns_site)
                .expect("resource to be a known CIDR or DNS resource"),
        )
    }
}
