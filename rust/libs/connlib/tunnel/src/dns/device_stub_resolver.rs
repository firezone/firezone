use std::{
    collections::BTreeMap,
    net::Ipv4Addr,
    time::{Duration, Instant},
};

use connlib_model::ResourceId;
use logging::err_with_src;

use crate::{
    dns::pattern::{Candidate, Pattern},
    expiring_map::ExpiringMap,
};

/// How long a resolved device pool domain stays cached before we re-query the portal.
const CACHE_TTL: Duration = Duration::from_secs(5);

#[derive(Default)]
pub struct DeviceStubResolver {
    device_pools: BTreeMap<Pattern, ResourceId>,
    /// Avoids a round-trip to the portal for every repeat DNS lookup of the
    /// same device pool domain within the [`CACHE_TTL`] window.
    resolved: ExpiringMap<String, CachedResolution>,
}

#[derive(Debug)]
struct CachedResolution {
    resource_id: ResourceId,
    ipv4: Ipv4Addr,
}

impl DeviceStubResolver {
    pub(crate) fn add_resource(&mut self, id: ResourceId, pattern: String) -> bool {
        let parsed = match Pattern::new(&pattern) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(%pattern, "Device pool pattern is not valid: {}", err_with_src(&e));
                return false;
            }
        };

        if let Some(existing_id) = self.device_pools.get(&parsed) {
            if *existing_id != id {
                tracing::warn!(
                    %pattern,
                    %existing_id,
                    new_id = %id,
                    "Device pool pattern is already registered to a different resource; ignoring duplicate"
                );
            }
            return false;
        }

        self.device_pools.insert(parsed, id);
        true
    }

    pub(crate) fn remove_resource(&mut self, id: ResourceId) {
        self.device_pools.retain(|_, r| *r != id);
        self.resolved.retain(|_, entry| entry.resource_id != id);
    }

    /// Attempts to match the given domain against device pool patterns.
    ///
    /// Returns the [`ResourceId`] of the first matching device pool, if any.
    pub(crate) fn match_device_pool_linear(
        &self,
        domain: &dns_types::DomainName,
    ) -> Option<ResourceId> {
        let name = Candidate::from_domain(domain);

        for (pattern, id) in &self.device_pools {
            if pattern.matches(&name) {
                tracing::trace!(resource_id = %id, %pattern, %domain, "Matched device pool");
                return Some(*id);
            }
        }

        None
    }

    /// Returns the cached IPv4 for `domain` if a fresh entry exists.
    pub(crate) fn cached_resolution(&self, domain: &str, now: Instant) -> Option<Ipv4Addr> {
        let entry = self.resolved.get(&domain.to_owned())?;
        (entry.expires_at > now).then_some(entry.value.ipv4)
    }

    /// Records a portal-provided resolution in the cache.
    pub(crate) fn cache_resolution(
        &mut self,
        resource_id: ResourceId,
        domain: String,
        ipv4: Ipv4Addr,
        now: Instant,
    ) {
        self.resolved.insert(
            domain,
            CachedResolution { resource_id, ipv4 },
            now,
            CACHE_TTL,
        );
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.resolved.handle_timeout(now);
        // Drop any expiration events `ExpiringMap` just emitted: eviction from the
        // cache is the only observable effect we care about here, and leaving them
        // queued would otherwise leak memory unboundedly.
        while self.resolved.poll_event().is_some() {}
    }

    pub(crate) fn poll_timeout(&self) -> Option<Instant> {
        self.resolved.poll_timeout()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dynamic_device_pool_wildcard_match() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        resolver.add_resource(rid, "*.devices.example.com".to_owned());

        let matched =
            resolver.match_device_pool_linear(&"foo.devices.example.com".parse().unwrap());

        assert_eq!(matched, Some(rid));
    }

    #[test]
    fn dynamic_device_pool_no_match_for_unrelated_domain() {
        let mut resolver = DeviceStubResolver::default();
        resolver.add_resource(ResourceId::from_u128(1), "*.devices.example.com".to_owned());

        let matched = resolver.match_device_pool_linear(&"foo.other.example.com".parse().unwrap());

        assert_eq!(matched, None);
    }

    #[test]
    fn dynamic_device_pool_remove_resource() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        resolver.add_resource(rid, "*.devices.example.com".to_owned());

        resolver.remove_resource(rid);

        let matched =
            resolver.match_device_pool_linear(&"foo.devices.example.com".parse().unwrap());

        assert_eq!(matched, None);
    }

    #[test]
    fn dynamic_device_pool_prioritises_specific_over_wildcard() {
        let mut resolver = DeviceStubResolver::default();
        let wildcard = ResourceId::from_u128(1);
        let specific = ResourceId::from_u128(2);

        resolver.add_resource(wildcard, "**.devices.example.com".to_owned());
        resolver.add_resource(specific, "foo.devices.example.com".to_owned());

        let matched =
            resolver.match_device_pool_linear(&"foo.devices.example.com".parse().unwrap());

        assert_eq!(matched, Some(specific));
    }

    #[test]
    fn dynamic_device_pool_invalid_pattern_returns_false() {
        let mut resolver = DeviceStubResolver::default();
        let added = resolver.add_resource(ResourceId::from_u128(1), "[invalid".to_owned());

        assert!(!added);
    }

    #[test]
    fn dynamic_device_pool_duplicate_pattern_is_ignored() {
        let mut resolver = DeviceStubResolver::default();
        let first = ResourceId::from_u128(1);
        let second = ResourceId::from_u128(2);

        assert!(resolver.add_resource(first, "*.devices.example.com".to_owned()));
        assert!(
            !resolver.add_resource(second, "*.devices.example.com".to_owned()),
            "duplicate pattern registration should be rejected"
        );

        let matched =
            resolver.match_device_pool_linear(&"foo.devices.example.com".parse().unwrap());
        assert_eq!(
            matched,
            Some(first),
            "original resource must remain matchable"
        );
    }

    #[test]
    fn cache_returns_stored_resolution_before_expiry() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.cache_resolution(
            rid,
            "device-1.pool.example.com".to_owned(),
            Ipv4Addr::new(100, 64, 0, 42),
            now,
        );

        assert_eq!(
            resolver.cached_resolution("device-1.pool.example.com", now),
            Some(Ipv4Addr::new(100, 64, 0, 42))
        );
    }

    #[test]
    fn cache_ignores_expired_resolution() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.cache_resolution(
            rid,
            "device-1.pool.example.com".to_owned(),
            Ipv4Addr::new(100, 64, 0, 42),
            now,
        );

        let later = now + CACHE_TTL + Duration::from_millis(1);
        assert_eq!(
            resolver.cached_resolution("device-1.pool.example.com", later),
            None
        );
    }

    #[test]
    fn handle_timeout_evicts_expired_entries() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.cache_resolution(
            rid,
            "device-1.pool.example.com".to_owned(),
            Ipv4Addr::new(100, 64, 0, 42),
            now,
        );

        let later = now + CACHE_TTL + Duration::from_millis(1);
        resolver.handle_timeout(later);

        assert_eq!(
            resolver.cached_resolution("device-1.pool.example.com", later),
            None
        );
    }

    #[test]
    fn removing_resource_invalidates_its_cached_resolutions() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let other = ResourceId::from_u128(2);
        let now = Instant::now();

        resolver.cache_resolution(
            rid,
            "device-1.pool.example.com".to_owned(),
            Ipv4Addr::new(100, 64, 0, 42),
            now,
        );
        resolver.cache_resolution(
            other,
            "device-2.other.example.com".to_owned(),
            Ipv4Addr::new(100, 64, 0, 43),
            now,
        );

        resolver.remove_resource(rid);

        assert_eq!(
            resolver.cached_resolution("device-1.pool.example.com", now),
            None,
            "cache entries for removed resource must be evicted"
        );
        assert_eq!(
            resolver.cached_resolution("device-2.other.example.com", now),
            Some(Ipv4Addr::new(100, 64, 0, 43)),
            "unrelated cache entries must be preserved"
        );
    }
}
