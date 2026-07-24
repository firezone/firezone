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
use smallvec::SmallVec;
use std::{
    collections::{BTreeMap, VecDeque},
    iter,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
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
    pending: ExpiringMap<(ResourceId, DomainName, dns_types::RecordType), PendingQuery>,

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
    ipv6: Ipv6Addr,
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

        // Cancel any in-flight portal queries for this resource with SERVFAIL,
        // so clients waiting on them don't hang until the query timeout.
        for ((_, domain, _), pending) in self.pending.extract_if(|(rid, _, _), _| *rid == id) {
            tracing::debug!(%domain, "Pending device pool DNS query cancelled; returning SERVFAIL");

            self.events.push_back(Event::SendResponse {
                local: pending.local,
                remote: pending.remote,
                transport: pending.transport,
                response: dns_types::Response::servfail(&pending.query),
            });
        }
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

        let qtype = query.qtype();

        // Only A and AAAA are answered from device pool resolutions; for any other
        // qtype, the name exists but we have no records of that type (NOERROR + empty).
        if qtype != dns_types::RecordType::A && qtype != dns_types::RecordType::AAAA {
            return ResolveStrategy::LocalResponse(
                dns_types::ResponseBuilder::for_query(query, dns_types::ResponseCode::NOERROR)
                    .build(),
            );
        }

        if let Some(entry) = self.resolved.get(&domain) {
            return ResolveStrategy::LocalResponse(build_response(
                query,
                domain.clone(),
                entry.ipv4,
                entry.ipv6,
            ));
        }

        // If a portal query for this (resource, domain) is already in flight under
        // either A or AAAA, don't fire another — the response will populate the cache
        // for both, and `handle_device_domain_resolved` drains all waiters for the
        // domain regardless of qtype.
        let portal_query_already_in_flight =
            self.pending
                .contains_key(&(resource_id, domain.clone(), dns_types::RecordType::A))
                || self.pending.contains_key(&(
                    resource_id,
                    domain.clone(),
                    dns_types::RecordType::AAAA,
                ));

        self.pending.insert(
            (resource_id, domain.clone(), qtype),
            PendingQuery {
                local,
                remote,
                transport,
                query: query.clone(),
            },
            now,
            QUERY_TIMEOUT,
        );

        if !portal_query_already_in_flight {
            tracing::debug!(%domain, "Querying portal for device FQDN");

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
        result: Result<(Ipv4Addr, Ipv6Addr), FailReason>,
    ) {
        let pending = self
            .pending
            .extract_if(|(rid, dom, _), _| *rid == resource_id && *dom == domain)
            .map(|(_, p)| p)
            .collect::<SmallVec<[PendingQuery; 2]>>();

        if pending.is_empty() {
            tracing::debug!(%resource_id, %domain, "Received device pool resolution for unknown query");
            return;
        }

        tracing::debug!(%resource_id, %domain, ?result, "Device FQDN resolved");

        if let Ok((ipv4, ipv6)) = result {
            self.resolved.insert(
                domain,
                CachedResolution {
                    resource_id,
                    ipv4,
                    ipv6,
                },
            );
        }

        for pending in pending {
            let response = match result {
                Ok((ipv4, ipv6)) => {
                    build_response(&pending.query, pending.query.domain(), ipv4, ipv6)
                }
                Err(FailReason::NotFound) => dns_types::Response::nxdomain(&pending.query),
                Err(
                    FailReason::Offline
                    | FailReason::VersionMismatch
                    | FailReason::Forbidden
                    | FailReason::Disabled
                    | FailReason::AmbiguousAddress
                    | FailReason::MissingAddress
                    | FailReason::InvalidAddress
                    | FailReason::Unknown,
                ) => dns_types::Response::servfail(&pending.query),
            };

            self.events.push_back(Event::SendResponse {
                local: pending.local,
                remote: pending.remote,
                transport: pending.transport,
                response,
            });
        }
    }

    pub(crate) fn poll_event(&mut self) -> Option<Event> {
        self.events.pop_front()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.pending.handle_timeout(now);
        while let Some(expiring_map::Event::EntryExpired {
            key: (_, domain, _),
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
    ipv6: Ipv6Addr,
) -> dns_types::Response {
    let builder = dns_types::ResponseBuilder::for_query(query, dns_types::ResponseCode::NOERROR);

    match query.qtype() {
        dns_types::RecordType::A => builder
            .with_records(iter::once((domain, DNS_TTL, dns_types::records::a(ipv4))))
            .build(),
        dns_types::RecordType::AAAA => builder
            .with_records(iter::once((
                domain,
                DNS_TTL,
                dns_types::records::aaaa(ipv6),
            )))
            .build(),
        // The name exists but we don't have a record of the requested type.
        _ => builder.build(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;

    const LOCAL: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 53);
    const REMOTE: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 12345);
    const POOL_PATTERN: &str = "*.pool.example.com";
    const POOL_DOMAIN: &str = "foo.pool.example.com";
    const TEST_IPV4: Ipv4Addr = Ipv4Addr::new(100, 64, 0, 42);
    const TEST_IPV6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 42);

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
    fn handle_answers_unsupported_qtypes_with_empty_noerror() {
        let mut resolver = DeviceStubResolver::default();
        resolver.add_resource(ResourceId::from_u128(1), POOL_PATTERN.to_owned());

        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::TXT),
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
    fn handle_emits_query_domain_event_on_first_a_query() {
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
    fn handle_emits_query_domain_event_on_first_aaaa_query() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        resolver.add_resource(rid, POOL_PATTERN.to_owned());

        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::AAAA),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            Instant::now(),
        );

        assert!(matches!(s, ResolveStrategy::Pending));
        let Some(Event::QueryDomain { .. }) = resolver.poll_event() else {
            panic!("expected QueryDomain event")
        };
    }

    #[test]
    fn aaaa_followup_after_a_coalesces_into_single_portal_query() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();
        resolver.add_resource(rid, POOL_PATTERN.to_owned());

        // First, an A query — fires a portal request.
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        assert!(matches!(
            resolver.poll_event(),
            Some(Event::QueryDomain { .. })
        ));

        // Then an AAAA query for the same domain — should coalesce.
        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::AAAA),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        assert!(matches!(s, ResolveStrategy::Pending));
        assert!(resolver.poll_event().is_none(), "should not re-fire portal");

        // Resolution responds to both waiters.
        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Ok((TEST_IPV4, TEST_IPV6)),
        );

        let responses = iter::from_fn(|| resolver.poll_event())
            .filter_map(|e| match e {
                Event::SendResponse { response, .. } => Some(response),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(responses.len(), 2);
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
    fn resolved_a_query_emits_a_record() {
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
            Ok((TEST_IPV4, TEST_IPV6)),
        );

        let Some(Event::SendResponse { response, .. }) = resolver.poll_event() else {
            panic!("expected SendResponse event")
        };
        assert_eq!(response.response_code(), dns_types::ResponseCode::NOERROR);
        assert_eq!(response.records().count(), 1);
    }

    #[test]
    fn resolved_aaaa_query_emits_aaaa_record() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);
        let now = Instant::now();

        resolver.add_resource(rid, POOL_PATTERN.to_owned());
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::AAAA),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        resolver.poll_event();

        resolver.handle_device_domain_resolved(
            rid,
            POOL_DOMAIN.parse().unwrap(),
            Ok((TEST_IPV4, TEST_IPV6)),
        );

        let Some(Event::SendResponse { response, .. }) = resolver.poll_event() else {
            panic!("expected SendResponse event")
        };
        assert_eq!(response.response_code(), dns_types::ResponseCode::NOERROR);
        assert_eq!(response.records().count(), 1);
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
            Ok((TEST_IPV4, TEST_IPV6)),
        );
        resolver.poll_event();

        // Repeat A query hits the cache.
        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            now,
        );
        assert!(matches!(s, ResolveStrategy::LocalResponse(_)));

        // AAAA query for the same domain also hits the cache (no portal roundtrip).
        let s = resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::AAAA),
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
            Ok((TEST_IPV4, TEST_IPV6)),
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
    fn removing_resource_cancels_pending_queries_with_servfail() {
        let mut resolver = DeviceStubResolver::default();
        let rid = ResourceId::from_u128(1);

        resolver.add_resource(rid, POOL_PATTERN.to_owned());
        resolver.handle_query(
            &query(POOL_DOMAIN, dns_types::RecordType::A),
            LOCAL,
            REMOTE,
            dns::Transport::Udp,
            Instant::now(),
        );
        resolver.poll_event();

        resolver.remove_resource(rid);

        let Some(Event::SendResponse { response, .. }) = resolver.poll_event() else {
            panic!("expected SendResponse event")
        };
        assert_eq!(response.response_code(), dns_types::ResponseCode::SERVFAIL);
        assert!(resolver.poll_event().is_none());
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
            Ok((TEST_IPV4, TEST_IPV6)),
        );

        assert!(resolver.poll_event().is_none());
    }

    fn query(domain: &str, record_type: dns_types::RecordType) -> dns_types::Query {
        dns_types::Query::new(domain.parse().unwrap(), record_type)
    }
}
