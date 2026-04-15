use std::{
    collections::{BTreeMap, HashMap},
    iter,
    net::{Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};

use connlib_model::ResourceId;
use logging::err_with_src;

use crate::{
    dns::{
        self,
        pattern::{Candidate, Pattern},
    },
    expiring_map::ExpiringMap,
};

/// How long a resolved device pool domain stays cached before we re-query the portal.
const CACHE_TTL: Duration = Duration::from_secs(5);

/// How long to wait for the portal to resolve a device pool domain before giving up.
const QUERY_TIMEOUT: Duration = Duration::from_secs(5);

/// TTL used in synthesised DNS responses for device pool resolutions.
///
/// Keeps downstream resolver caches short-lived so mapping changes propagate quickly;
/// internal caching is handled by [`DeviceStubResolver`] on its own schedule.
const DNS_TTL: u32 = 1;

#[derive(Default)]
pub struct DeviceStubResolver {
    device_pools: BTreeMap<Pattern, ResourceId>,
    /// Avoids a round-trip to the portal for every repeat DNS lookup of the
    /// same device pool domain within the [`CACHE_TTL`] window.
    resolved: ExpiringMap<String, CachedResolution>,
    /// Buffers DNS queries waiting for device pool domain resolution from the portal.
    ///
    /// Keyed by `(ResourceId, domain)` — the same pair the portal includes in its response.
    /// If multiple queries arrive for the same domain while waiting, we keep only the latest.
    /// Entries expire after [`QUERY_TIMEOUT`] if the portal never responds.
    pending: HashMap<(ResourceId, String), PendingQuery>,
}

pub struct PendingQuery {
    created_at: Instant,
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub transport: dns::Transport,
    pub query: dns_types::Query,
}

impl PendingQuery {
    pub fn new(
        local: SocketAddr,
        remote: SocketAddr,
        transport: dns::Transport,
        query: dns_types::Query,
        now: Instant,
    ) -> Self {
        Self {
            created_at: now,
            local,
            remote,
            transport,
            query,
        }
    }
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

    /// Builds a DNS response for a resolved device pool domain.
    pub(crate) fn build_response(
        query: &dns_types::Query,
        domain: dns_types::DomainName,
        ipv4: Ipv4Addr,
    ) -> dns_types::Response {
        let record = dns_types::records::a(ipv4);
        dns_types::ResponseBuilder::for_query(query, dns_types::ResponseCode::NOERROR)
            .with_records(iter::once((domain, DNS_TTL, record)))
            .build()
    }

    /// Buffer a DNS query while we wait for the portal to resolve the domain.
    ///
    /// Returns `true` if this is the first pending query for `(resource_id, domain)`,
    /// signalling that the caller should ask the portal to resolve it.
    /// Returns `false` if a query was already pending — the latest query replaces
    /// the previous one, but no new portal request is needed.
    ///
    /// When replacing an existing entry, the original `created_at` is preserved so
    /// the [`QUERY_TIMEOUT`] deadline stays anchored to the in-flight portal request.
    /// Otherwise a stream of repeated queries could indefinitely postpone the timeout
    /// while still attached to a single portal request that may already be lost.
    pub(crate) fn insert_pending(
        &mut self,
        resource_id: ResourceId,
        domain: String,
        mut query: PendingQuery,
    ) -> bool {
        if let Some(existing) = self.pending.get(&(resource_id, domain.clone())) {
            query.created_at = existing.created_at;
        }
        self.pending.insert((resource_id, domain), query).is_none()
    }

    /// Returns `None` if no query is pending or if the query has expired.
    pub(crate) fn remove_pending(
        &mut self,
        resource_id: ResourceId,
        domain: &str,
        now: Instant,
    ) -> Option<PendingQuery> {
        let query = self.pending.remove(&(resource_id, domain.to_owned()))?;

        if now.duration_since(query.created_at) > QUERY_TIMEOUT {
            tracing::debug!(%resource_id, %domain, "Pending device pool DNS query expired");
            return None;
        }

        Some(query)
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.resolved.handle_timeout(now);
        // Drop any expiration events `ExpiringMap` just emitted: eviction from the
        // cache is the only observable effect we care about here, and leaving them
        // queued would otherwise leak memory unboundedly.
        while self.resolved.poll_event().is_some() {}

        self.pending.retain(|(_rid, domain), query| {
            let expired = now.duration_since(query.created_at) > QUERY_TIMEOUT;

            if expired {
                tracing::debug!(%domain, "Pending device pool DNS query timed out");
            }

            !expired
        });
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

    // --- Pending query tests ---

    #[test]
    fn insert_and_remove_returns_pending_query() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        resolver.insert_pending(rid, domain.to_owned(), make_query(now));

        let result = resolver.remove_pending(rid, domain, now);
        assert!(result.is_some());
    }

    #[test]
    fn remove_unknown_returns_none() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);

        assert!(
            resolver
                .remove_pending(rid, "unknown.example.com", Instant::now())
                .is_none()
        );
    }

    #[test]
    fn remove_is_one_shot() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        resolver.insert_pending(rid, domain.to_owned(), make_query(now));

        assert!(resolver.remove_pending(rid, domain, now).is_some());
        assert!(resolver.remove_pending(rid, domain, now).is_none());
    }

    #[test]
    fn different_resources_are_independent() {
        let mut resolver = DeviceStubResolver::default();
        let rid_a = ResourceId::from_u128(1);
        let rid_b = ResourceId::from_u128(2);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        resolver.insert_pending(rid_a, domain.to_owned(), make_query(now));
        resolver.insert_pending(rid_b, domain.to_owned(), make_query(now));

        assert!(resolver.remove_pending(rid_a, domain, now).is_some());
        assert!(resolver.remove_pending(rid_b, domain, now).is_some());
    }

    #[test]
    fn duplicate_insert_replaces_previous() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        assert!(
            resolver.insert_pending(rid, domain.to_owned(), make_query(now)),
            "first insert should report a new entry"
        );
        assert!(
            !resolver.insert_pending(rid, domain.to_owned(), make_query(now)),
            "duplicate insert should report an existing entry"
        );

        assert!(resolver.remove_pending(rid, domain, now).is_some());
        assert!(resolver.remove_pending(rid, domain, now).is_none());
    }

    #[test]
    fn expired_query_returns_none_on_remove() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        resolver.insert_pending(rid, domain.to_owned(), make_query(now));

        let later = now + QUERY_TIMEOUT + Duration::from_millis(1);
        assert!(resolver.remove_pending(rid, domain, later).is_none());
    }

    #[test]
    fn handle_timeout_removes_expired_pending_queries() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        resolver.insert_pending(rid, domain.to_owned(), make_query(now));

        let later = now + QUERY_TIMEOUT + Duration::from_millis(1);
        resolver.handle_timeout(later);

        // Entry was cleaned up — remove returns None even though we never consumed it
        assert!(resolver.remove_pending(rid, domain, later).is_none());
    }

    #[test]
    fn duplicate_insert_preserves_original_deadline() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        resolver.insert_pending(rid, domain.to_owned(), make_query(now));

        // A refreshing query arrives just before the original deadline fires.
        let refreshed_at = now + QUERY_TIMEOUT - Duration::from_millis(1);
        resolver.insert_pending(rid, domain.to_owned(), make_query(refreshed_at));

        // The deadline should still be anchored to the original `created_at`, not
        // the refreshed one — otherwise a stream of repeats could postpone it forever.
        let past_original_deadline = now + QUERY_TIMEOUT + Duration::from_millis(1);
        assert!(
            resolver
                .remove_pending(rid, domain, past_original_deadline)
                .is_none(),
            "refreshed insert must not extend the original query's deadline"
        );
    }

    #[test]
    fn handle_timeout_keeps_fresh_pending_queries() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        resolver.insert_pending(rid, domain.to_owned(), make_query(now));

        let slightly_later = now + Duration::from_secs(1);
        resolver.handle_timeout(slightly_later);

        assert!(
            resolver
                .remove_pending(rid, domain, slightly_later)
                .is_some()
        );
    }

    fn make_query(now: Instant) -> PendingQuery {
        PendingQuery::new(
            "127.0.0.1:53".parse().unwrap(),
            "127.0.0.1:12345".parse().unwrap(),
            dns::Transport::Udp,
            dns_types::Query::new(
                "device-1.pool.example.com".parse().unwrap(),
                dns_types::RecordType::A,
            ),
            now,
        )
    }
}
