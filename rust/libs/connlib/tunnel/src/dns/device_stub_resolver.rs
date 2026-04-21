use crate::{
    dns::{
        self,
        pattern::{Candidate, Pattern},
    },
    expiring_map::{self, ExpiringMap},
    messages::client::FailReason,
};
use connlib_model::ResourceId;
use dns_types::DomainName;
use logging::err_with_src;
use std::{
    collections::{BTreeMap, VecDeque},
    iter,
    net::{Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};

/// How long to wait for the portal to resolve a device pool domain before giving up.
const QUERY_TIMEOUT: Duration = Duration::from_secs(5);

/// TTL used in synthesised DNS responses for device pool resolutions.
///
/// Keeps downstream resolver caches short-lived so mapping changes propagate quickly.
const DNS_TTL: u32 = 1;

#[derive(Default)]
pub struct DeviceStubResolver {
    device_pools: BTreeMap<ResourceId, Pattern>,
    resolved: BTreeMap<DomainName, CachedResolution>,
    pending: ExpiringMap<(ResourceId, DomainName), PendingQuery>,

    events: VecDeque<Event>,
}

pub(crate) enum ResolveStrategy {
    /// The query didn't match any of our device pools.
    Passthrough,
    /// The query matched a device pool and a response has been formed.
    LocalResponse(dns_types::Response),
    /// The query matched a device pool but we cannot answer it yet.
    Pending,
}

#[derive(Debug)]
pub(crate) enum Event {
    QueryDomain {
        resource_id: ResourceId,
        domain: DomainName,
    },
    SendResponse {
        local: SocketAddr,
        remote: SocketAddr,
        transport: dns::Transport,
        response: dns_types::Response,
    },
}

#[derive(Debug)]
struct PendingQuery {
    local: SocketAddr,
    remote: SocketAddr,
    transport: dns::Transport,
    query: dns_types::Query,
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

        if let Some(previous) = self.device_pools.insert(id, parsed) {
            tracing::debug!(
                %id,
                %previous,
                new = %pattern,
                "Replacing device pool pattern"
            );

            // Existing cache entries refer to the previous pattern, so purge them.
            self.resolved.retain(|_, entry| entry.resource_id != id);
        }

        true
    }

    pub(crate) fn remove_resource(&mut self, id: ResourceId) {
        self.device_pools.remove(&id);
        for _ in self
            .resolved
            .extract_if(.., |_, entry| entry.resource_id == id)
        {}
    }

    /// Processes a DNS query against the device pool patterns.
    pub(crate) fn handle_query(
        &mut self,
        query: &dns_types::Query,
        local: SocketAddr,
        remote: SocketAddr,
        transport: dns::Transport,
        now: Instant,
    ) -> ResolveStrategy {
        let domain = query.domain();
        let Some(resource_id) = self.match_device_pool_linear(&domain) else {
            return ResolveStrategy::Passthrough;
        };

        // Device pools are IPv4-only; answer AAAA and other non-A queries
        // immediately with NOERROR + no records (the name exists, we just
        // don't have records of the requested type).
        if query.qtype() != dns_types::RecordType::A {
            return ResolveStrategy::LocalResponse(
                dns_types::ResponseBuilder::for_query(query, dns_types::ResponseCode::NOERROR)
                    .build(),
            );
        }

        if let Some(entry) = self.resolved.get(&domain) {
            return ResolveStrategy::LocalResponse(build_response(query, domain, entry.ipv4));
        }

        let is_new = self
            .pending
            .insert(
                (resource_id, domain.clone()),
                PendingQuery {
                    local,
                    remote,
                    transport,
                    query: query.clone(),
                },
                now,
                QUERY_TIMEOUT,
            )
            .is_none();

        if is_new {
            self.events.push_back(Event::QueryDomain {
                resource_id,
                domain,
            });
        }

        ResolveStrategy::Pending
    }

    pub(crate) fn handle_device_domain_resolved(
        &mut self,
        resource_id: ResourceId,
        domain: DomainName,
        result: Result<Ipv4Addr, FailReason>,
    ) {
        let Some(entry) = self.pending.remove(&(resource_id, domain.clone())) else {
            tracing::debug!(%resource_id, %domain, ?result, "Received device pool resolution for unknown query");
            return;
        };
        let pending = entry.value;

        let response = match result {
            Ok(ipv4) => {
                tracing::debug!(%resource_id, %domain, %ipv4, "Device pool domain resolved");
                self.resolved
                    .insert(domain, CachedResolution { resource_id, ipv4 });
                build_response(&pending.query, pending.query.domain(), ipv4)
            }
            Err(reason) => {
                tracing::debug!(%resource_id, %domain, ?reason, "Device pool domain resolution failed");
                match reason {
                    FailReason::NotFound => dns_types::Response::nxdomain(&pending.query),
                    FailReason::Offline
                    | FailReason::VersionMismatch
                    | FailReason::Forbidden
                    | FailReason::Unknown => dns_types::Response::servfail(&pending.query),
                }
            }
        };

        self.events.push_back(Event::SendResponse {
            local: pending.local,
            remote: pending.remote,
            transport: pending.transport,
            response,
        });
    }

    pub(crate) fn poll_event(&mut self) -> Option<Event> {
        self.events.pop_front()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.pending.handle_timeout(now);
        while let Some(expiring_map::Event::EntryExpired {
            key: (_rid, domain),
            value: pending,
        }) = self.pending.poll_event()
        {
            tracing::debug!(%domain, "Pending device pool DNS query timed out; returning SERVFAIL");

            let response = dns_types::Response::servfail(&pending.query);
            self.events.push_back(Event::SendResponse {
                local: pending.local,
                remote: pending.remote,
                transport: pending.transport,
                response,
            });
        }
    }

    pub(crate) fn poll_timeout(&self) -> Option<Instant> {
        self.pending.poll_timeout()
    }

    fn match_device_pool_linear(&self, domain: &dns_types::DomainName) -> Option<ResourceId> {
        let name = Candidate::from_domain(domain);

        for (id, pattern) in &self.device_pools {
            if pattern.matches(&name) {
                tracing::trace!(resource_id = %id, %pattern, %domain, "Matched device pool");
                return Some(*id);
            }
        }

        None
    }
}

fn build_response(
    query: &dns_types::Query,
    domain: dns_types::DomainName,
    ipv4: Ipv4Addr,
) -> dns_types::Response {
    let record = dns_types::records::a(ipv4);
    dns_types::ResponseBuilder::for_query(query, dns_types::ResponseCode::NOERROR)
        .with_records(iter::once((domain, DNS_TTL, record)))
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;

    const LOCAL: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 53);
    const REMOTE: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 12345);
    const POOL_PATTERN: &str = "*.pool.example.com";
    const POOL_DOMAIN: &str = "foo.pool.example.com";

    #[test]
    fn handle_returns_passthrough_for_unmatched_domain() {
        let mut resolver = DeviceStubResolver::default();
        resolver.add_resource(ResourceId::from_u128(1), POOL_PATTERN.to_owned());

        let s = resolver.handle_query(
            &query("other.example.com", dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            Instant::now(),
        );

        assert!(matches!(s, ResolveStrategy::Passthrough));
        assert!(resolver.poll_event().is_none());
    }

    #[test]
    fn handle_answers_aaaa_with_empty_noerror() {
        let mut resolver = DeviceStubResolver::default();
        resolver.add_resource(ResourceId::from_u128(1), POOL_PATTERN.to_owned());

        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::AAAA),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            Instant::now(),
        );

        let ResolveStrategy::LocalResponse(resp) = s else {
            panic!("expected LocalResponse")
        };
        assert_eq!(resp.response_code(), dns_types::ResponseCode::NOERROR);
        assert_eq!(resp.records().count(), 0);
        assert!(resolver.poll_event().is_none());
    }

    #[test]
    fn handle_emits_query_domain_event_on_first_query() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        resolver.add_resource(rid, POOL_PATTERN.to_owned());

        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            Instant::now(),
        );

        assert!(matches!(s, ResolveStrategy::Pending));
        let Some(Event::QueryDomain {
            resource_id,
            domain,
        }) = resolver.poll_event()
        else {
            panic!("expected QueryDomain event")
        };
        assert_eq!(resource_id, rid);
        assert_eq!(domain.to_string(), POOL_DOMAIN);
        assert!(resolver.poll_event().is_none());
    }

    #[test]
    fn handle_reports_pending_on_duplicate_in_flight_query() {
        let mut resolver = DeviceStubResolver::default();
        resolver.add_resource(ResourceId::from_u128(1), POOL_PATTERN.to_owned());

        let s1 = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            Instant::now(),
        );
        let s2 = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            Instant::now(),
        );

        assert!(matches!(s1, ResolveStrategy::Pending));
        assert!(matches!(s2, ResolveStrategy::Pending));
        assert_eq!(iter::from_fn(|| resolver.poll_event()).count(), 1);
    }

    #[test]
    fn resolved_emits_send_response() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.add_resource(rid, POOL_PATTERN.to_owned());
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();

        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Ok(Ipv4Addr::new(100, 64, 0, 42)),
        );

        let Some(Event::SendResponse { response, .. }) = resolver.poll_event() else {
            panic!("expected SendResponse event")
        };
        assert_eq!(response.response_code(), dns_types::ResponseCode::NOERROR);
    }

    #[test]
    fn not_found_emits_nxdomain() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.add_resource(rid, POOL_PATTERN.to_owned());
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();

        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Err(FailReason::NotFound),
        );

        let Some(Event::SendResponse { response, .. }) = resolver.poll_event() else {
            panic!("expected SendResponse event")
        };
        assert_eq!(response.response_code(), dns_types::ResponseCode::NXDOMAIN);
    }

    #[test]
    fn non_not_found_failures_emit_servfail() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.add_resource(rid, POOL_PATTERN.to_owned());
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();

        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Err(FailReason::Forbidden),
        );

        let Some(Event::SendResponse { response, .. }) = resolver.poll_event() else {
            panic!("expected SendResponse event")
        };
        assert_eq!(response.response_code(), dns_types::ResponseCode::SERVFAIL);
    }

    #[test]
    fn handle_serves_from_cache_on_repeat_query() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.add_resource(rid, POOL_PATTERN.to_owned());

        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();

        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Ok(Ipv4Addr::new(100, 64, 0, 42)),
        );
        resolver.poll_event();

        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        assert!(matches!(s, ResolveStrategy::LocalResponse(_)));
        assert!(resolver.poll_event().is_none());
    }

    #[test]
    fn removing_resource_invalidates_its_cached_resolutions() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.add_resource(rid, POOL_PATTERN.to_owned());
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();
        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Ok(Ipv4Addr::new(100, 64, 0, 42)),
        );
        resolver.poll_event();

        resolver.remove_resource(rid);
        resolver.add_resource(rid, POOL_PATTERN.to_owned());

        // After removing the resource the cache should be empty, so the next
        // query goes through the portal again.
        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        assert!(matches!(s, ResolveStrategy::Pending));
    }

    #[test]
    fn pending_query_timeout_emits_servfail() {
        let mut resolver = DeviceStubResolver::default();
        resolver.add_resource(ResourceId::from_u128(1), POOL_PATTERN.to_owned());

        let now = Instant::now();
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();

        let later = now + QUERY_TIMEOUT + Duration::from_millis(1);
        resolver.handle_timeout(later);

        let Some(Event::SendResponse { response, .. }) = resolver.poll_event() else {
            panic!("expected SendResponse event")
        };
        assert_eq!(response.response_code(), dns_types::ResponseCode::SERVFAIL);
    }

    #[test]
    fn portal_resolution_after_timeout_emits_no_event() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        resolver.add_resource(rid, POOL_PATTERN.to_owned());

        let now = Instant::now();
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();

        // A regular `handle_timeout` pass clears the expired pending entry
        // (and emits a SERVFAIL response in its place — drain it).
        let later = now + QUERY_TIMEOUT + Duration::from_millis(1);
        resolver.handle_timeout(later);
        resolver.poll_event();

        // A late portal reply has nothing to match against and is a no-op.
        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Ok(Ipv4Addr::new(100, 64, 0, 42)),
        );

        assert!(resolver.poll_event().is_none());
    }

    fn query(domain: &str, record_type: dns_types::RecordType) -> dns_types::Query {
        dns_types::Query::new(domain.parse().unwrap(), record_type)
    }
}
