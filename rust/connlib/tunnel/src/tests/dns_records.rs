use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
};

use connlib_model::{DomainName, DomainRecord};
use domain::base::{RecordData, Rtype};
use itertools::Itertools;

#[derive(Debug, Default, Clone)]
pub(crate) struct DnsRecords {
    inner: BTreeMap<DomainName, BTreeSet<DomainRecord>>,
}

impl DnsRecords {
    pub(crate) fn domain_ips_iter(&self, name: &DomainName) -> impl Iterator<Item = IpAddr> + '_ {
        #[expect(clippy::wildcard_enum_match_arm)]
        self.domain_records_iter(name).filter_map(|r| match r {
            DomainRecord::A(a) => Some(a.addr().into()),
            DomainRecord::Aaaa(aaaa) => Some(aaaa.addr().into()),
            _ => None,
        })
    }

    pub(crate) fn ips_iter(&self) -> impl Iterator<Item = IpAddr> + '_ {
        #[expect(clippy::wildcard_enum_match_arm)]
        self.inner.values().flatten().filter_map(|r| match r {
            DomainRecord::A(a) => Some(a.addr().into()),
            DomainRecord::Aaaa(aaaa) => Some(aaaa.addr().into()),
            _ => None,
        })
    }

    pub(crate) fn domain_records_iter(
        &self,
        name: &DomainName,
    ) -> impl Iterator<Item = DomainRecord> + '_ {
        self.inner.get(name).cloned().into_iter().flatten()
    }

    pub(crate) fn domains_iter(&self) -> impl Iterator<Item = DomainName> + '_ {
        self.inner.keys().cloned()
    }

    pub(crate) fn contains_domain(&self, name: &DomainName) -> bool {
        self.inner.contains_key(name)
    }

    pub(crate) fn merge(&mut self, other: Self) {
        self.inner.extend(other.inner);
    }

    pub(crate) fn domain_rtypes(&self, name: &DomainName) -> Vec<Rtype> {
        self.domain_records_iter(name)
            .map(|r| r.rtype())
            .dedup()
            .collect_vec()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}

impl<I> From<I> for DnsRecords
where
    BTreeMap<DomainName, BTreeSet<DomainRecord>>: From<I>,
{
    fn from(value: I) -> Self {
        Self {
            inner: BTreeMap::from(value),
        }
    }
}

impl<I> FromIterator<I> for DnsRecords
where
    BTreeMap<DomainName, BTreeSet<DomainRecord>>: FromIterator<I>,
{
    fn from_iter<T: IntoIterator<Item = I>>(iter: T) -> Self {
        Self {
            inner: BTreeMap::from_iter(iter),
        }
    }
}

pub(crate) fn ip_to_domain_record(ip: IpAddr) -> DomainRecord {
    match ip {
        IpAddr::V4(ip) => DomainRecord::A(ip.into()),
        IpAddr::V6(ip) => DomainRecord::Aaaa(ip.into()),
    }
}
