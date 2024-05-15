//! Client related messages that are needed within connlib

use std::{collections::HashSet, str::FromStr};

use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::callbacks::Status;

use super::ResourceId;

/// Description of a resource that maps to a DNS record.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: String,
    #[serde(rename = "gateway_groups")]
    pub sites: Vec<Site>,
}

impl ResourceDescriptionDns {
    fn with_status(self, status: Status) -> crate::callbacks::ResourceDescriptionDns {
        crate::callbacks::ResourceDescriptionDns {
            id: self.id,
            address: self.address,
            name: self.name,
            address_description: self.address_description,
            sites: self.sites,
            status,
        }
    }
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ResourceDescriptionCidr {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: String,
    #[serde(rename = "gateway_groups")]
    pub sites: Vec<Site>,
}

impl ResourceDescriptionCidr {
    fn with_status(self, status: Status) -> crate::callbacks::ResourceDescriptionCidr {
        crate::callbacks::ResourceDescriptionCidr {
            id: self.id,
            address: self.address,
            name: self.name,
            address_description: self.address_description,
            sites: self.sites,
            status,
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Site {
    pub name: String,
    pub id: SiteId,
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SiteId(Uuid);

impl FromStr for SiteId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(SiteId(Uuid::parse_str(s)?))
    }
}

impl SiteId {
    #[cfg(feature = "proptest")]
    pub(crate) fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl ResourceDescription {
    pub fn dns_name(&self) -> Option<&str> {
        match self {
            ResourceDescription::Dns(r) => Some(&r.address),
            ResourceDescription::Cidr(_) => None,
        }
    }

    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
        }
    }

    pub fn sites(&self) -> HashSet<&Site> {
        match self {
            ResourceDescription::Dns(r) => HashSet::from_iter(r.sites.iter()),
            ResourceDescription::Cidr(r) => HashSet::from_iter(r.sites.iter()),
        }
    }

    /// What the GUI clients should show as the user-friendly display name, e.g. `Firezone GitHub`
    pub fn name(&self) -> &str {
        match self {
            ResourceDescription::Dns(r) => &r.name,
            ResourceDescription::Cidr(r) => &r.name,
        }
    }

    pub fn has_different_address(&self, other: &ResourceDescription) -> bool {
        match (self, other) {
            (ResourceDescription::Dns(dns_a), ResourceDescription::Dns(dns_b)) => {
                dns_a.address != dns_b.address
            }
            (ResourceDescription::Cidr(cidr_a), ResourceDescription::Cidr(cidr_b)) => {
                cidr_a.address != cidr_b.address
            }
            _ => true,
        }
    }

    pub fn with_status(self, status: Status) -> crate::callbacks::ResourceDescription {
        match self {
            ResourceDescription::Dns(r) => {
                crate::callbacks::ResourceDescription::Dns(r.with_status(status))
            }
            ResourceDescription::Cidr(r) => {
                crate::callbacks::ResourceDescription::Cidr(r.with_status(status))
            }
        }
    }
}

impl PartialOrd for ResourceDescription {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ResourceDescription {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (self.name(), self.id()).cmp(&(other.name(), other.id()))
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(ResourceDescriptionDns),
    Cidr(ResourceDescriptionCidr),
}
