use std::time::Duration;
use std::{fmt, net::IpAddr, time::Instant};

use dns_types::{DomainName, ResponseBuilder, ResponseCode, Ttl};
use dns_types::{OwnedRecord, Query};
use dns_types::{Response, prelude::*};

use crate::expiring_map::{self, ExpiringMap};

#[derive(Debug, Default)]
pub struct DnsCache {
    inner: ExpiringMap<DomainName, Vec<OwnedRecord>>,
}

impl DnsCache {
    pub fn try_answer(&self, query: &Query, now: Instant) -> Option<Response> {
        let domain = query.domain();

        let expiring_map::Entry {
            value: response,
            expires_at,
        } = self.inner.get(&domain)?;

        tracing::trace!(%domain, records = ?fmt_friendly_records(response), "Cache hit");

        let records = response.clone().into_iter().map(|mut r| {
            let original_ttl = r.ttl();
            let inserted_at = expires_at - original_ttl.into_duration();
            let expired_ttl = Ttl::from_secs(now.duration_since(inserted_at).as_secs() as u32);

            r.set_ttl(original_ttl.saturating_sub(expired_ttl));

            r
        });

        let response = ResponseBuilder::for_query(query, ResponseCode::NOERROR)
            .with_records(records)
            .build();

        Some(response)
    }

    pub fn insert(&mut self, domain: DomainName, response: &dns_types::Response, now: Instant) {
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

        let Some(ttl) = response.ttl() else {
            tracing::trace!(?response, "Cannot cache DNS response without a TTL");

            return;
        };

        if ttl < Duration::from_secs(5) {
            tracing::trace!("Refusing to cache response with TTL < 5s");
            return;
        }

        let records = response
            .records()
            .map(|r| {
                OwnedRecord::new(
                    r.owner().flatten_into(),
                    r.class(),
                    r.ttl(),
                    r.into_data().flatten_into(),
                )
            })
            .collect::<Vec<_>>();

        tracing::trace!(%domain, records = ?fmt_friendly_records(&records), ?ttl, "New entry");

        self.inner.insert(domain, records, now + ttl);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.inner.handle_timeout(now);

        while let Some(event) = self.inner.poll_event() {
            let expiring_map::Event::EntryExpired {
                key,
                value: records,
            } = event;

            tracing::trace!(domain = %key, records = ?fmt_friendly_records(&records), "Entry expired");
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
fn fmt_friendly_records(records: &[OwnedRecord]) -> Vec<FmtFriendlyRecord<'_>> {
    records
        .iter()
        .map(|r| match r.data() {
            dns_types::OwnedRecordData::A(a) => FmtFriendlyRecord::Ip(a.addr().into()),
            dns_types::OwnedRecordData::Aaaa(aaaa) => FmtFriendlyRecord::Ip(aaaa.addr().into()),
            dns_types::OwnedRecordData::Cname(cname) => FmtFriendlyRecord::Domain(cname.cname()),
            other => FmtFriendlyRecord::Other(other),
        })
        .collect::<Vec<_>>()
}

// Wrapper around `RecordData` that is more friendly to look at in the logs.
enum FmtFriendlyRecord<'a> {
    Ip(IpAddr),
    Domain(&'a dns_types::DomainName),
    Other(&'a dns_types::OwnedRecordData),
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

        assert_eq!(response.ttl().unwrap(), Duration::from_secs(3500));
        assert_eq!(response.id(), query2.id());
    }
}
