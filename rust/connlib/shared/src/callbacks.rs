use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::fmt::Debug;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

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
            ResourceDescription::Internet(_) => "Internet",
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
    pub can_toggle: bool,
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
    pub can_toggle: bool,
}

/// Description of an Internet resource
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ResourceDescriptionInternet {
    pub id: ResourceId,
    pub sites: Vec<Site>,
    pub status: Status,
    pub can_toggle: bool,
}

/// Traits that will be used by connlib to callback the client upper layers.
pub trait Callbacks: Clone + Send + Sync {
    /// Called when the tunnel address is set.
    ///
    /// The first time this is called, the Resources list is also ready,
    /// the routes are also ready, and the Client can consider the tunnel
    /// to be ready for incoming traffic.
    fn on_set_interface_config(&self, _: Ipv4Addr, _: Ipv6Addr, _: Vec<IpAddr>) {}

    /// Called when the route list changes.
    fn on_update_routes(&self, _: Vec<Ipv4Network>, _: Vec<Ipv6Network>) {}

    /// Called when the resource list changes.
    ///
    /// This may not be called if a Client has no Resources, which can
    /// happen to new accounts, or when removing and re-adding Resources,
    /// or if all Resources for a user are disabled by policy.
    fn on_update_resources(&self, _: Vec<ResourceDescription>) {}

    /// Called when the tunnel is disconnected.
    ///
    /// If the tunnel disconnected due to a fatal error, `error` is the error
    /// that caused the disconnect.
    fn on_disconnect(&self, error: &crate::Error) {
        tracing::error!(error = ?error, "tunnel_disconnected");
        // Note that we can't panic here, since we already hooked the panic to this function.
        std::process::exit(0);
    }
}
