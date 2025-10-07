use std::time::Duration;
use std::{fmt, net::IpAddr, time::Instant};

use dns_types::DomainName;
use dns_types::prelude::*;

use crate::expiring_map::{self, ExpiringMap};

#[derive(Debug, Default)]
pub struct DnsCache {
    inner: ExpiringMap<DomainName, dns_types::Response>,
}

impl DnsCache {
    pub fn get(&self, domain: &DomainName) -> Option<&dns_types::Response> {
        let response = self.inner.get(domain)?;

        tracing::trace!(%domain, records = ?records(response), "Cache hit");

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

        tracing::trace!(%domain, records = ?records(response), ?ttl, "New entry");

        self.inner.insert(domain, response.clone(), now + ttl);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.inner.handle_timeout(now);

        while let Some(event) = self.inner.poll_event() {
            let expiring_map::Event::EntryExpired { key, value } = event;

            tracing::trace!(domain = %key, records = ?records(&value), "Entry expired");
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
fn records(response: &dns_types::Response) -> Vec<Record<'_>> {
    response
        .records()
        .map(|r| match r.into_data() {
            dns_types::RecordData::A(a) => Record::Ip(a.addr().into()),
            dns_types::RecordData::Aaaa(aaaa) => Record::Ip(aaaa.addr().into()),
            dns_types::RecordData::Cname(cname) => {
                Record::Domain(cname.into_cname().flatten_into())
            }
            other => Record::Other(other),
        })
        .collect::<Vec<_>>()
}

// Wrapper around `RecordData` that is more friendly to look at in the logs.
enum Record<'a> {
    Ip(IpAddr),
    Domain(dns_types::DomainName),
    Other(dns_types::RecordData<'a>),
}

impl fmt::Debug for Record<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Record::Ip(ip_addr) => ip_addr.fmt(f),
            Record::Domain(name) => name.fmt(f),
            Record::Other(all_record_data) => all_record_data.fmt(f),
        }
    }
}
