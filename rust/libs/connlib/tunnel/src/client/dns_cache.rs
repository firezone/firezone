use std::time::Duration;
use std::{fmt, net::IpAddr, time::Instant};

use dns_types::{DomainName, RecordType, ResponseBuilder, ResponseCode, Ttl};
use dns_types::{OwnedRecord, Query};
use dns_types::{Response, prelude::*};

use crate::expiring_map::{self, ExpiringMap};

#[derive(Debug, Default)]
pub struct DnsCache {
    inner: ExpiringMap<(DomainName, RecordType), Response>,
}

impl DnsCache {
    pub fn try_answer(&self, query: &Query, now: Instant) -> Option<Response> {
        let domain = query.domain();
        let qtype = query.qtype();

        let entry = self.inner.get(&(domain.clone(), qtype))?;

        let records = entry.value.records().map(|r| {
            let original_ttl = r.ttl();
            let elapsed = now.saturating_duration_since(entry.inserted_at);
            let elapsed_secs = elapsed.as_secs().min(original_ttl.as_secs() as u64);
            let new_ttl =
                Ttl::from_secs(original_ttl.as_secs().saturating_sub(elapsed_secs as u32));

            OwnedRecord::new(
                r.owner().flatten_into(),
                r.class(),
                new_ttl,
                r.into_data().flatten_into(),
            )
        });

        let response = ResponseBuilder::for_query(query, ResponseCode::NOERROR)
            .with_records(records)
            .build();

        tracing::trace!(%domain, records = ?fmt_friendly_records(&response), remaining_ttl = ?response.ttl(qtype), "Cache hit");

        Some(response)
    }

    pub fn flush(&mut self, reason: &'static str) {
        tracing::trace!("Flushing DNS cache ({reason})");

        self.inner.clear();
    }

    pub fn insert(&mut self, domain: DomainName, response: &dns_types::Response, now: Instant) {
        let qtype = response.qtype();

        if response.response_code() != dns_types::ResponseCode::NOERROR {
            tracing::trace!("Refusing to cache failed response");
            return;
        }

        if response.truncated() {
            tracing::trace!("Refusing to cache truncated response");
            return;
        }

        if response.records().count() == 0 {
            tracing::trace!("Cannot cache response without entries");
            return;
        }

        let Some(ttl) = response.ttl(qtype) else {
            tracing::trace!(?response, "Cannot cache DNS response without a TTL");
            return;
        };

        if ttl < Duration::from_secs(5) {
            tracing::trace!("Refusing to cache response with TTL < 5s");
            return;
        }

        tracing::trace!(%domain, %qtype, records = ?fmt_friendly_records(response), ?ttl, "New entry");

        self.inner
            .insert((domain, qtype), response.clone(), now, ttl);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.inner.handle_timeout(now);

        while let Some(event) = self.inner.poll_event() {
            let expiring_map::Event::EntryExpired {
                key: (domain, qtype),
                value: response,
            } = event;

            tracing::trace!(%domain, %qtype, records = ?fmt_friendly_records(&response), "Entry expired");
        }
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        self.inner.poll_timeout()
    }
}

#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "We don't want to enumerate all record types."
)]
fn fmt_friendly_records(response: &Response) -> Vec<FmtFriendlyRecord<'_>> {
    response
        .records()
        .map(|r| match r.into_data() {
            dns_types::RecordData::A(a) => FmtFriendlyRecord::Ip(a.addr().into()),
            dns_types::RecordData::Aaaa(aaaa) => FmtFriendlyRecord::Ip(aaaa.addr().into()),
            dns_types::RecordData::Cname(cname) => {
                FmtFriendlyRecord::Domain(cname.cname().flatten_into())
            }
            other => FmtFriendlyRecord::Other(other),
        })
        .collect::<Vec<_>>()
}

// Wrapper around `RecordData` that is more friendly to look at in the logs.
enum FmtFriendlyRecord<'a> {
    Ip(IpAddr),
    Domain(dns_types::DomainName),
    Other(dns_types::RecordData<'a>),
}

impl fmt::Debug for FmtFriendlyRecord<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FmtFriendlyRecord::Ip(ip_addr) => ip_addr.fmt(f),
            FmtFriendlyRecord::Domain(name) => name.fmt(f),
            FmtFriendlyRecord::Other(all_record_data) => all_record_data.fmt(f),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{iter, net::Ipv4Addr};

    use connlib_model::{IpStack, ResourceId};
    use dns_types::{RecordType, ResponseCode, records};

    use crate::dns::{ResolveStrategy, StubResolver};

    use super::*;

    #[test]
    fn cache_hit_decrements_ttl() {
        let mut cache = DnsCache::default();
        let mut now = Instant::now();

        let domain = DomainName::vec_from_str("example.com").unwrap();
        let query1 = Query::new(domain.clone(), RecordType::A);
        let response = dns_types::ResponseBuilder::for_query(&query1, ResponseCode::NOERROR)
            .with_records(iter::once((
                domain.clone(),
                3600,
                records::a(Ipv4Addr::LOCALHOST),
            )))
            .build();

        cache.insert(domain.clone(), &response, now);

        now += Duration::from_secs(100);

        let query2 = Query::new(domain, RecordType::A);

        let response = cache.try_answer(&query2, now).unwrap();

        assert_eq!(
            response.ttl(RecordType::A).unwrap(),
            Duration::from_secs(3500)
        );
        assert_eq!(response.id(), query2.id());
    }

    #[test]
    fn cache_with_multiple_ttls_calculates_correctly() {
        let mut cache = DnsCache::default();
        let mut now = Instant::now();

        let domain = DomainName::vec_from_str("example.com").unwrap();
        let query1 = Query::new(domain.clone(), RecordType::A);

        // Create a response with two A records with different TTLs
        let response = dns_types::ResponseBuilder::for_query(&query1, ResponseCode::NOERROR)
            .with_records(vec![
                (domain.clone(), 1800, records::a(Ipv4Addr::new(1, 1, 1, 1))),
                (domain.clone(), 3600, records::a(Ipv4Addr::new(2, 2, 2, 2))),
            ])
            .build();

        cache.insert(domain.clone(), &response, now);

        // Advance time by 100 seconds
        now += Duration::from_secs(100);

        let query2 = Query::new(domain, RecordType::A);
        let response = cache.try_answer(&query2, now).unwrap();

        // Both records should have their TTLs reduced by 100 seconds
        let ttls: Vec<_> = response.records().map(|r| r.ttl().as_secs()).collect();

        assert_eq!(ttls, vec![1700, 3500]);
    }

    #[test]
    fn does_not_cache_response_from_stub_resolver() {
        let mut resolver = StubResolver::default();
        let mut cache = DnsCache::default();

        resolver.add_resource(
            ResourceId::from_u128(1),
            "example.com".to_owned(),
            IpStack::Dual,
        );

        let query = Query::new("example.com".parse().unwrap(), RecordType::A);

        let ResolveStrategy::LocalResponse(response) = resolver.handle(&query) else {
            panic!("Unexpected result")
        };
        cache.insert("example.com".parse().unwrap(), &response, Instant::now());

        let result = cache.try_answer(&query, Instant::now());

        assert!(result.is_none());
    }
}
