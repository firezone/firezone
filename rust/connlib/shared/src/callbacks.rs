use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::fmt::Debug;

use crate::messages::client::Site;
use crate::messages::ResourceId;

#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Status {
    Unknown,
    Online,
    Offline,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription {
    Dns(ResourceDescriptionDns),
    Cidr(ResourceDescriptionCidr),
    Internet(ResourceDescriptionInternet),
}

impl ResourceDescription {
    pub fn address_description(&self) -> Option<&str> {
        match self {
            ResourceDescription::Dns(r) => r.address_description.as_deref(),
            ResourceDescription::Cidr(r) => r.address_description.as_deref(),
            ResourceDescription::Internet(_) => None,
        }
    }

    pub fn name(&self) -> &str {
        match self {
            ResourceDescription::Dns(r) => &r.name,
            ResourceDescription::Cidr(r) => &r.name,
            ResourceDescription::Internet(r) => &r.name,
        }
    }

    pub fn status(&self) -> Status {
        match self {
            ResourceDescription::Dns(r) => r.status,
            ResourceDescription::Cidr(r) => r.status,
            ResourceDescription::Internet(r) => r.status,
        }
    }

    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
            ResourceDescription::Internet(r) => r.id,
        }
    }

    /// What the GUI clients should paste to the clipboard, e.g. `https://github.com/firezone`
    pub fn pastable(&self) -> Cow<'_, str> {
        match self {
            ResourceDescription::Dns(r) => Cow::from(&r.address),
            ResourceDescription::Cidr(r) => Cow::from(r.address.to_string()),
            ResourceDescription::Internet(_) => Cow::default(),
        }
    }

    pub fn sites(&self) -> &[Site] {
        match self {
            ResourceDescription::Dns(r) => &r.sites,
            ResourceDescription::Cidr(r) => &r.sites,
            ResourceDescription::Internet(r) => &r.sites,
        }
    }

    pub fn can_be_disabled(&self) -> bool {
        match self {
            ResourceDescription::Dns(r) => r.can_be_disabled,
            ResourceDescription::Cidr(r) => r.can_be_disabled,
            ResourceDescription::Internet(r) => r.can_be_disabled,
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: Option<String>,
    pub sites: Vec<Site>,

    pub status: Status,
    pub can_be_disabled: bool,
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ResourceDescriptionCidr {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: Option<String>,
    pub sites: Vec<Site>,

    pub status: Status,
    pub can_be_disabled: bool,
}

/// Description of an Internet resource
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ResourceDescriptionInternet {
    /// Name for display always set to "Internet Resource"
    pub name: String,

    /// Address for display always set to "All internet addresses"
    pub address: String,

    pub id: ResourceId,
    pub sites: Vec<Site>,

    pub status: Status,
    pub can_be_disabled: bool,
}
