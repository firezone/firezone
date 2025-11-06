use std::collections::BTreeSet;
use std::{collections::BTreeMap, net::IpAddr, time::Instant};

use dns_types::prelude::*;
use dns_types::{DomainName, OwnedRecordData, RecordType};
use itertools::Itertools;

#[derive(Debug, Default, Clone)]
pub(crate) struct DnsRecords {
    inner: BTreeMap<DomainName, BTreeMap<Instant, BTreeSet<OwnedRecordData>>>,
}

impl DnsRecords {
    pub(crate) fn domain_ips_iter(
        &self,
        name: &DomainName,
        at: Instant,
    ) -> impl Iterator<Item = IpAddr> + '_ {
        #[expect(clippy::wildcard_enum_match_arm)]
        self.domain_records_iter(name, at).filter_map(|r| match r {
            OwnedRecordData::A(a) => Some(a.addr().into()),
            OwnedRecordData::Aaaa(aaaa) => Some(aaaa.addr().into()),
            _ => None,
        })
    }

    pub(crate) fn ips_iter(&self, at: Instant) -> impl Iterator<Item = IpAddr> + '_ {
        #[expect(clippy::wildcard_enum_match_arm)]
        self.records_at(at).filter_map(|(_, r)| match r {
            OwnedRecordData::A(a) => Some(a.addr().into()),
            OwnedRecordData::Aaaa(aaaa) => Some(aaaa.addr().into()),
            _ => None,
        })
    }

    pub(crate) fn domain_records_iter(
        &self,
        name: &DomainName,
        at: Instant,
    ) -> impl Iterator<Item = OwnedRecordData> + '_ {
        let name = name.clone();

        self.records_at(at)
            .filter_map(move |(domain, records)| (domain == &name).then_some(records.clone()))
    }

    pub(crate) fn domains_iter(&self) -> impl Iterator<Item = DomainName> + '_ {
        self.inner.keys().cloned()
    }

    pub(crate) fn merge(&mut self, other: Self) {
        for (domain, records) in other.inner {
            for (timestamp, records) in records {
                self.inner
                    .entry(domain.clone())
                    .or_default()
                    .insert(timestamp, records);
            }
        }
    }

    pub(crate) fn domain_rtypes(&self, name: &DomainName, at: Instant) -> Vec<RecordType> {
        self.domain_records_iter(name, at)
            .map(|r| r.rtype())
            .dedup()
            .collect_vec()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    fn records_at(
        &self,
        at: Instant,
    ) -> impl Iterator<Item = (&DomainName, &OwnedRecordData)> + '_ {
        self.inner.iter().flat_map(move |(domain, records)| {
            records
                .iter()
                .filter(|(timestamp, _)| **timestamp <= at)
                .max_by_key(|(timestamp, _)| **timestamp)
                .into_iter()
                .flat_map(move |(_, records)| records.iter().map(move |records| (domain, records)))
        })
    }
}

impl<I> From<I> for DnsRecords
where
    BTreeMap<DomainName, BTreeMap<Instant, BTreeSet<OwnedRecordData>>>: From<I>,
{
    fn from(value: I) -> Self {
        Self {
            inner: BTreeMap::from(value),
        }
    }
}

impl<I> FromIterator<I> for DnsRecords
where
    BTreeMap<DomainName, BTreeMap<Instant, BTreeSet<OwnedRecordData>>>: FromIterator<I>,
{
    fn from_iter<T: IntoIterator<Item = I>>(iter: T) -> Self {
        Self {
            inner: BTreeMap::from_iter(iter),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use dns_types::DomainNameRef;

    use super::*;

    #[test]
    fn returns_most_recent_records_at_timestamp() {
        let now = Instant::now();

        let mut dns_records = DnsRecords::default();

        dns_records.merge(DnsRecords::from([(
            EXAMPLE_COM.to_vec(),
            BTreeMap::from([(
                now,
                BTreeSet::from([a_record("127.0.0.1"), a_record("127.0.0.2")]),
            )]),
        )]));
        dns_records.merge(DnsRecords::from([(
            EXAMPLE_COM.to_vec(),
            BTreeMap::from([(
                now + Duration::from_secs(5),
                BTreeSet::from([a_record("127.0.0.3"), a_record("127.0.0.4")]),
            )]),
        )]));
        dns_records.merge(DnsRecords::from([(
            EXAMPLE_COM.to_vec(),
            BTreeMap::from([(
                now + Duration::from_secs(10),
                BTreeSet::from([a_record("127.0.0.5"), a_record("127.0.0.6")]),
            )]),
        )]));

        assert_eq!(
            dns_records
                .domain_ips_iter(&EXAMPLE_COM.to_vec(), now)
                .collect::<Vec<_>>(),
            vec![ip("127.0.0.1"), ip("127.0.0.2")]
        );
        assert_eq!(
            dns_records
                .domain_ips_iter(&EXAMPLE_COM.to_vec(), now + Duration::from_secs(2))
                .collect::<Vec<_>>(),
            vec![ip("127.0.0.1"), ip("127.0.0.2")]
        );
        assert_eq!(
            dns_records
                .domain_ips_iter(&EXAMPLE_COM.to_vec(), now + Duration::from_secs(7))
                .collect::<Vec<_>>(),
            vec![ip("127.0.0.3"), ip("127.0.0.4")]
        );
        assert_eq!(
            dns_records
                .domain_ips_iter(&EXAMPLE_COM.to_vec(), now + Duration::from_secs(12))
                .collect::<Vec<_>>(),
            vec![ip("127.0.0.5"), ip("127.0.0.6")]
        );
    }

    const EXAMPLE_COM: DomainNameRef =
        unsafe { DomainNameRef::from_octets_unchecked(b"\x08example\x03com\x00") };

    fn a_record(ip: &str) -> OwnedRecordData {
        OwnedRecordData::A(ip.parse().unwrap())
    }

    fn ip(ip: &str) -> IpAddr {
        ip.parse().unwrap()
    }
}
