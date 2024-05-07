//! Client related messages that are needed within connlib

use std::borrow::Cow;

use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};

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

    /// What the GUI clients should show as the user-friendly display name, e.g. `Firezone GitHub`
    pub fn name(&self) -> &str {
        match self {
            ResourceDescription::Dns(r) => &r.name,
            ResourceDescription::Cidr(r) => &r.name,
        }
    }

    /// What the GUI clients should paste to the clipboard, e.g. `https://github.com/firezone`
    pub fn pastable(&self) -> Cow<'_, str> {
        match self {
            ResourceDescription::Dns(r) => Cow::from(&r.address),
            ResourceDescription::Cidr(r) => Cow::from(r.address.to_string()),
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
