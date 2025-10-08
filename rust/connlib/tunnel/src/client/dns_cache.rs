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

        let expiring_map::Entry {
            value: response,
            expires_at,
        } = self.inner.get(&(domain.clone(), qtype))?;

        let records = response.records().map(|r| {
            let original_ttl = r.ttl();
            let inserted_at = expires_at - original_ttl.into_duration();
            let expired_ttl = Ttl::from_secs(now.duration_since(inserted_at).as_secs() as u32);

            let new_ttl = original_ttl.saturating_sub(expired_ttl);

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
            .insert((domain, qtype), response.clone(), now + ttl);
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

    use dns_types::{RecordType, ResponseCode, records};

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
}
