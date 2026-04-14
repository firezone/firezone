use std::{
    collections::HashMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

use connlib_model::ResourceId;

use crate::dns;

/// How long to wait for the portal to resolve a device pool domain before giving up.
const QUERY_TIMEOUT: Duration = Duration::from_secs(5);

/// Buffers DNS queries waiting for device pool domain resolution from the portal.
///
/// When a DNS query matches a dynamic device pool pattern, we ask the portal
/// to resolve the domain to a tunnel IPv4. This struct holds the original query
/// context so we can construct the DNS response when the portal replies.
///
/// Keyed by `(ResourceId, domain)` — the same pair the portal includes in its response.
/// If multiple queries arrive for the same domain while waiting, we keep only the latest.
/// Entries expire after [`QUERY_TIMEOUT`] if the portal never responds.
#[derive(Default)]
pub struct PendingDevicePoolDns {
    pending: HashMap<(ResourceId, String), PendingQuery>,
}

pub struct PendingQuery {
    created_at: Instant,
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub transport: dns::Transport,
    pub query: dns_types::Query,
}

impl PendingDevicePoolDns {
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
    pub fn insert(
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
    pub fn remove(
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

    /// Drop all queries that have been pending longer than [`QUERY_TIMEOUT`].
    pub fn handle_timeout(&mut self, now: Instant) {
        self.pending.retain(|(_rid, domain), query| {
            let expired = now.duration_since(query.created_at) > QUERY_TIMEOUT;

            if expired {
                tracing::debug!(%domain, "Pending device pool DNS query timed out");
            }

            !expired
        });
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_remove_returns_pending_query() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        pending.insert(rid, domain.to_owned(), make_query(now));

        let result = pending.remove(rid, domain, now);
        assert!(result.is_some());
    }

    #[test]
    fn remove_unknown_returns_none() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);

        assert!(
            pending
                .remove(rid, "unknown.example.com", Instant::now())
                .is_none()
        );
    }

    #[test]
    fn remove_is_one_shot() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        pending.insert(rid, domain.to_owned(), make_query(now));

        assert!(pending.remove(rid, domain, now).is_some());
        assert!(pending.remove(rid, domain, now).is_none());
    }

    #[test]
    fn different_resources_are_independent() {
        let mut pending = PendingDevicePoolDns::default();
        let rid_a = ResourceId::from_u128(1);
        let rid_b = ResourceId::from_u128(2);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        pending.insert(rid_a, domain.to_owned(), make_query(now));
        pending.insert(rid_b, domain.to_owned(), make_query(now));

        assert!(pending.remove(rid_a, domain, now).is_some());
        assert!(pending.remove(rid_b, domain, now).is_some());
    }

    #[test]
    fn duplicate_insert_replaces_previous() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        assert!(
            pending.insert(rid, domain.to_owned(), make_query(now)),
            "first insert should report a new entry"
        );
        assert!(
            !pending.insert(rid, domain.to_owned(), make_query(now)),
            "duplicate insert should report an existing entry"
        );

        assert!(pending.remove(rid, domain, now).is_some());
        assert!(pending.remove(rid, domain, now).is_none());
    }

    #[test]
    fn expired_query_returns_none_on_remove() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        pending.insert(rid, domain.to_owned(), make_query(now));

        let later = now + QUERY_TIMEOUT + Duration::from_millis(1);
        assert!(pending.remove(rid, domain, later).is_none());
    }

    #[test]
    fn handle_timeout_removes_expired_entries() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        pending.insert(rid, domain.to_owned(), make_query(now));

        let later = now + QUERY_TIMEOUT + Duration::from_millis(1);
        pending.handle_timeout(later);

        // Entry was cleaned up — remove returns None even though we never consumed it
        assert!(pending.remove(rid, domain, later).is_none());
    }

    #[test]
    fn duplicate_insert_preserves_original_deadline() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        pending.insert(rid, domain.to_owned(), make_query(now));

        // A refreshing query arrives just before the original deadline fires.
        let refreshed_at = now + QUERY_TIMEOUT - Duration::from_millis(1);
        pending.insert(rid, domain.to_owned(), make_query(refreshed_at));

        // The deadline should still be anchored to the original `created_at`, not
        // the refreshed one — otherwise a stream of repeats could postpone it forever.
        let past_original_deadline = now + QUERY_TIMEOUT + Duration::from_millis(1);
        assert!(
            pending
                .remove(rid, domain, past_original_deadline)
                .is_none(),
            "refreshed insert must not extend the original query's deadline"
        );
    }

    #[test]
    fn handle_timeout_keeps_fresh_entries() {
        let mut pending = PendingDevicePoolDns::default();
        let rid = ResourceId::from_u128(1);
        let domain = "device-1.pool.example.com";
        let now = Instant::now();

        pending.insert(rid, domain.to_owned(), make_query(now));

        let slightly_later = now + Duration::from_secs(1);
        pending.handle_timeout(slightly_later);

        assert!(pending.remove(rid, domain, slightly_later).is_some());
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
