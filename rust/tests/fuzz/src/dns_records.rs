use std::collections::{BTreeMap, BTreeSet};
use std::net::IpAddr;

use dns_types::prelude::*;
use dns_types::{DomainName, OwnedRecordData, RecordType};

#[derive(Debug, Default, Clone)]
pub(crate) struct DnsRecords {
    inner: BTreeMap<DomainName, BTreeSet<OwnedRecordData>>,
}

impl DnsRecords {
    pub(crate) fn domain_ips_iter(&self, name: &DomainName) -> impl Iterator<Item = IpAddr> + '_ {
        #[expect(clippy::wildcard_enum_match_arm)]
        self.domain_records_iter(name).filter_map(|r| match r {
            OwnedRecordData::A(a) => Some(a.addr().into()),
            OwnedRecordData::Aaaa(aaaa) => Some(aaaa.addr().into()),
            _ => None,
        })
    }

    pub(crate) fn ips_iter(&self) -> impl Iterator<Item = IpAddr> + '_ {
        #[expect(clippy::wildcard_enum_match_arm)]
        self.inner.values().flatten().filter_map(|r| match r {
            OwnedRecordData::A(a) => Some(a.addr().into()),
            OwnedRecordData::Aaaa(aaaa) => Some(aaaa.addr().into()),
            _ => None,
        })
    }

    pub(crate) fn domain_records_iter(
        &self,
        name: &DomainName,
    ) -> impl Iterator<Item = OwnedRecordData> + '_ {
        self.inner.get(name).into_iter().flatten().cloned()
    }

    pub(crate) fn domains_iter(&self) -> impl Iterator<Item = DomainName> + '_ {
        self.inner.keys().cloned()
    }

    pub(crate) fn overwrite_with(&mut self, other: Self) {
        self.inner.extend(other.inner);
    }

    pub(crate) fn insert(&mut self, domain: DomainName, records: BTreeSet<OwnedRecordData>) {
        self.inner.insert(domain, records);
    }

    pub(crate) fn domain_rtypes(&self, name: &DomainName) -> BTreeSet<RecordType> {
        self.domain_records_iter(name).map(|r| r.rtype()).collect()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}

impl<I> From<I> for DnsRecords
where
    BTreeMap<DomainName, BTreeSet<OwnedRecordData>>: From<I>,
{
    fn from(value: I) -> Self {
        Self {
            inner: BTreeMap::from(value),
        }
    }
}

impl<I> FromIterator<I> for DnsRecords
where
    BTreeMap<DomainName, BTreeSet<OwnedRecordData>>: FromIterator<I>,
{
    fn from_iter<T: IntoIterator<Item = I>>(iter: T) -> Self {
        Self {
            inner: BTreeMap::from_iter(iter),
        }
    }
}
