use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

use connlib_model::{Site, SiteId};
use dns_types::{DomainName, RecordType};
use ip_network::{Ipv4Network, Ipv6Network};

use crate::dns_records::DnsRecords;
use crate::icmp_error_hosts::IcmpError;

/// The local networks behind each site's Gateways.
///
/// Every regular site has a subnet per IP family that only its own Gateways reach; every
/// other address is public. The names a site's DNS resources resolve to are either public
/// or local to one site, and a Gateway may fail to resolve another site's local names.
#[derive(Debug, Clone)]
pub(crate) struct SiteNetworks {
    subnets: BTreeMap<SiteId, (Ipv4Network, Ipv6Network)>,
    local_names: BTreeMap<DomainName, SiteId>,
    unresolvable: BTreeSet<(SiteId, DomainName)>,
    /// What each site's network answers traffic to another site's subnet with; `None` drops it.
    unreachable_responses: BTreeMap<SiteId, Option<IcmpError>>,
}

impl SiteNetworks {
    pub(crate) fn new(
        subnets: BTreeMap<SiteId, (Ipv4Network, Ipv6Network)>,
        local_names: BTreeMap<DomainName, SiteId>,
        unresolvable: BTreeSet<(SiteId, DomainName)>,
        unreachable_responses: BTreeMap<SiteId, Option<IcmpError>>,
    ) -> Self {
        Self {
            subnets,
            local_names,
            unresolvable,
            unreachable_responses,
        }
    }

    /// Assigns each regular site its own subnet within the documentation ranges.
    pub(crate) fn subnets(sites: &[Site]) -> BTreeMap<SiteId, (Ipv4Network, Ipv6Network)> {
        sites
            .iter()
            .enumerate()
            .map(|(index, site)| {
                let index = u8::try_from(index).expect("at most three regular sites");
                let v4 = Ipv4Network::new(Ipv4Addr::new(192, 0, 2, index * 64), 26).unwrap();
                let v6 = Ipv6Network::new(
                    Ipv6Addr::new(0x2001, 0xDB8, u16::from(index), 0, 0, 0, 0, 0),
                    48,
                )
                .unwrap();

                (site.id, (v4, v6))
            })
            .collect()
    }

    /// Whether a Gateway in `site` reaches `ip`.
    pub(crate) fn reaches(&self, site: SiteId, ip: IpAddr) -> bool {
        self.owner_of(ip).is_none_or(|owner| owner == site)
    }

    /// Whether a Gateway in `site` reaches the addresses `name` resolves to.
    pub(crate) fn reaches_name(&self, site: SiteId, name: &DomainName) -> bool {
        self.local_names
            .get(name)
            .is_none_or(|owner| *owner == site)
    }

    /// The site whose subnet `ip` is in, if any.
    pub(crate) fn owner_of(&self, ip: IpAddr) -> Option<SiteId> {
        self.subnets
            .iter()
            .find(|(_, (v4, v6))| match ip {
                IpAddr::V4(ip) => v4.contains(ip),
                IpAddr::V6(ip) => v6.contains(ip),
            })
            .map(|(site, _)| *site)
    }

    pub(crate) fn local_site(&self, name: &DomainName) -> Option<SiteId> {
        self.local_names.get(name).copied()
    }

    pub(crate) fn subnet(&self, site: SiteId) -> Option<(Ipv4Network, Ipv6Network)> {
        self.subnets.get(&site).copied()
    }

    pub(crate) fn resolves(&self, site: SiteId, name: &DomainName) -> bool {
        !self.unresolvable.contains(&(site, name.clone()))
    }

    /// The record types a Gateway in `site` resolves `name` to.
    pub(crate) fn resolved_rtypes(
        &self,
        site: SiteId,
        name: &DomainName,
        records: &DnsRecords,
    ) -> BTreeSet<RecordType> {
        if !self.resolves(site, name) {
            return BTreeSet::new();
        }

        records.domain_rtypes(name)
    }

    pub(crate) fn unreachable_response(&self, site: SiteId) -> Option<IcmpError> {
        self.unreachable_responses.get(&site).copied().flatten()
    }
}
