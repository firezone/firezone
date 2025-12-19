use std::{collections::HashMap, num::NonZeroUsize};

use connlib_model::{GatewayId, ResourceStatus, SiteId};
use lru::LruCache;

use crate::client::Resource;

/// How many gateways we at most remember that we connected to.
///
/// 100 has been chosen as a pretty arbitrary value.
/// We only store [`GatewayId`]s so the memory footprint is negligible.
const MAX_REMEMBERED_GATEWAYS: NonZeroUsize = NonZeroUsize::new(100).expect("100 > 0");

#[derive(Debug)]
pub(crate) struct Sites {
    /// Which Gateway we prefer for a given site.
    gateway_preference: HashMap<SiteId, GatewayId>,
    /// The online/offline status of a site.
    sites_status: HashMap<SiteId, ResourceStatus>,
    /// Stores the gateways we recently connected to.
    ///
    /// We use this as a hint to the portal to re-connect us to the same gateway for a resource.
    recently_connected_gateways: LruCache<GatewayId, ()>,
}

impl Default for Sites {
    fn default() -> Self {
        Self {
            gateway_preference: Default::default(),
            sites_status: Default::default(),
            recently_connected_gateways: LruCache::new(MAX_REMEMBERED_GATEWAYS),
        }
    }
}

impl Sites {
    /// Checks whether we have a preferred Gateway in the given site.
    pub(crate) fn has_preferred_gateway(&self, sid: SiteId) -> bool {
        self.preferred_gateway(sid).is_some()
    }

    pub(crate) fn preferred_gateway(&self, sid: SiteId) -> Option<GatewayId> {
        self.gateway_preference.get(&sid).copied()
    }

    /// Sets the preferred Gateway in this site.
    pub(crate) fn set_preferred_gateway(&mut self, sid: SiteId, gid: GatewayId) {
        self.gateway_preference.insert(sid, gid);
        self.recently_connected_gateways.put(gid, ());
    }

    pub(crate) fn clear(&mut self) {
        self.gateway_preference.clear();
        self.recently_connected_gateways.clear();
    }

    pub(crate) fn on_resource_offline(&mut self, resource: &Resource) {
        for site in resource.sites() {
            self.sites_status.insert(site.id, ResourceStatus::Offline);
        }
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "The iteration order doesn't matter here."
    )]
    pub(crate) fn set_status_by_gateway(&mut self, gid: &GatewayId, status: ResourceStatus) {
        let Some(sid) = self
            .gateway_preference
            .iter()
            .find_map(|(s, g)| (g == gid).then_some(*s))
        else {
            tracing::warn!(%gid, "Cannot update status of unknown site");
            return;
        };

        self.sites_status.insert(sid, status);
    }

    pub(crate) fn resource_status(&self, resource: &Resource) -> ResourceStatus {
        if resource.sites().iter().any(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|s| *s == ResourceStatus::Online)
        }) {
            return ResourceStatus::Online;
        }

        if resource.sites().iter().all(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|s| *s == ResourceStatus::Offline)
        }) {
            return ResourceStatus::Offline;
        }

        ResourceStatus::Unknown
    }

    // We tell the portal about all gateways we ever connected to, to encourage re-connecting us to the same ones during a session.
    // The LRU cache visits them in MRU order, meaning a gateway that we recently connected to should still be preferred.
    pub(crate) fn connected_gateway_ids(&self) -> Vec<GatewayId> {
        self.recently_connected_gateways
            .iter()
            .map(|(g, _)| *g)
            .collect()
    }
}
