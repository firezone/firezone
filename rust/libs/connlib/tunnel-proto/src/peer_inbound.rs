//! What this device admits from one peer.

pub(crate) mod nat_table;
mod resource_targets;
mod self_targets;

use std::collections::BTreeSet;
use std::time::Instant;

use connlib_model::{DeviceId, ResourceId};

use crate::IpConfig;
use crate::messages::Key;

pub(crate) use resource_targets::{
    DEFAULT_MAX_DNS_DOMAINS, InboundRewrite, OutboundRewrite, ProxyIpAlreadyAssigned,
    ResourceTargets, TooManyDnsDomains, TooManyProxyIpsForDomain, TranslateOutboundResult,
};
pub(crate) use self_targets::{InboundResult, SelfTargets};

/// The targets one peer may reach through this device.
///
/// A peer reaches the device itself through a device pool, or a resource the
/// device serves. The portal authorizes each target on its own, and this type
/// keeps both kinds side by side.
pub(crate) struct PeerInbound {
    id: DeviceId,
    peer_tun: IpConfig,
    identity: Option<PeerIdentity>,

    self_targets: SelfTargets,
    resources: ResourceTargets,
}

/// How the portal names a peer that reaches us.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PeerIdentity {
    pub(crate) name: String,
    pub(crate) slug: String,
}

impl PeerInbound {
    pub(crate) fn new(
        id: DeviceId,
        public_key: Key,
        peer_tun: IpConfig,
        local_tun: IpConfig,
        max_dns_domains: usize,
    ) -> Self {
        Self {
            id,
            peer_tun,
            identity: None,
            self_targets: SelfTargets::new(id, local_tun, peer_tun),
            resources: ResourceTargets::new(id, public_key, peer_tun, local_tun, max_dns_domains),
        }
    }

    pub(crate) fn id(&self) -> DeviceId {
        self.id
    }

    pub(crate) fn peer_tun(&self) -> IpConfig {
        self.peer_tun
    }

    pub(crate) fn public_key(&self) -> Key {
        self.resources.public_key()
    }

    pub(crate) fn identity(&self) -> Option<&PeerIdentity> {
        self.identity.as_ref()
    }

    pub(crate) fn set_identity(&mut self, identity: PeerIdentity) {
        if self.identity.as_ref() == Some(&identity) {
            return;
        }

        tracing::debug!(id = %self.id, name = %identity.name, slug = %identity.slug, "Updated peer identity");

        self.identity = Some(identity);
    }

    /// The device itself, reached through device pools.
    pub(crate) fn self_targets(&self) -> &SelfTargets {
        &self.self_targets
    }

    pub(crate) fn self_targets_mut(&mut self) -> &mut SelfTargets {
        &mut self.self_targets
    }

    /// The resources this device serves to the peer.
    pub(crate) fn resources(&self) -> &ResourceTargets {
        &self.resources
    }

    pub(crate) fn resources_mut(&mut self) -> &mut ResourceTargets {
        &mut self.resources
    }

    /// Whether the peer may reach nothing through this device.
    pub(crate) fn is_empty(&self) -> bool {
        self.self_targets.is_empty() && self.resources.is_empty()
    }

    pub(crate) fn poll_timeout(&self) -> Option<Instant> {
        [
            self.self_targets.poll_timeout(),
            self.resources.poll_timeout(),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.self_targets.handle_timeout(now);
        self.resources.handle_timeout(now);
    }

    /// Drops every authorization that is not in `retain`, whichever kind of target it is for.
    pub(crate) fn retain_authorizations(&mut self, retain: BTreeSet<ResourceId>) {
        self.self_targets.retain_authorizations(&retain);
        self.resources.retain_authorizations(retain);
    }
}
