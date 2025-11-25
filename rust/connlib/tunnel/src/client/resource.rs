//! Internal model of resources as used by connlib's client code.

use std::{collections::BTreeSet, fmt};

use connlib_model::{
    CidrResourceView, DnsResourceView, InternetResourceView, IpStack, ResourceId, ResourceStatus,
    ResourceView, Site,
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use itertools::Itertools as _;
use serde::Deserialize;

use crate::messages::client::{
    ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns,
    ResourceDescriptionInternet,
};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Resource {
    Dns(DnsResource),
    Cidr(CidrResource),
    Internet(InternetResource),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DnsResource {
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

    pub ip_stack: IpStack,
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CidrResource {
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
}

/// Description of an internet resource.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct InternetResource {
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,
    /// Resource's id.
    pub id: ResourceId,
    /// Sites for the internet resource
    pub sites: Vec<Site>,
}

impl Resource {
    pub fn from_description(resource: ResourceDescription) -> Option<Self> {
        match resource {
            ResourceDescription::Dns(json) => {
                let i = ResourceDescriptionDns::deserialize(&json)
                    .inspect_err(
                        |e| tracing::warn!(%json, "Failed to deserialise `ResourceDescriptionDns`: {e}"),
                    )
                    .ok()?;

                Some(Resource::Dns(DnsResource::from_description(i)))
            }
            ResourceDescription::Cidr(json) => {
                let i = ResourceDescriptionCidr::deserialize(&json)
                    .inspect_err(|e| {
                        tracing::warn!(%json, "Failed to deserialise `ResourceDescriptionCidr`: {e}")
                    })
                    .ok()?;

                Some(Resource::Cidr(CidrResource::from_description(i)))
            }
            ResourceDescription::Internet(json) => {
                let i = ResourceDescriptionInternet::deserialize(&json)
                    .inspect_err(|e| {
                        tracing::warn!(%json, "Failed to deserialise `ResourceDescriptionInternet`: {e}")
                    })
                    .ok()?;

                Some(Resource::Internet(InternetResource::from_description(i)))
            }
            ResourceDescription::Unknown => None,
        }
    }

    #[cfg(all(feature = "proptest", test))]
    pub fn into_dns(self) -> Option<DnsResource> {
        match self {
            Resource::Dns(d) => Some(d),
            Resource::Cidr(_) | Resource::Internet(_) => None,
        }
    }

    pub fn address_string(&self) -> Option<String> {
        match self {
            Resource::Dns(d) => Some(d.address.clone()),
            Resource::Cidr(c) => Some(c.address.to_string()),
            Resource::Internet(_) => None,
        }
    }

    pub fn sites_string(&self) -> String {
        self.sites().iter().map(|s| &s.name).join("|")
    }

    pub fn id(&self) -> ResourceId {
        match self {
            Resource::Dns(r) => r.id,
            Resource::Cidr(r) => r.id,
            Resource::Internet(r) => r.id,
        }
    }

    pub fn sites(&self) -> BTreeSet<&Site> {
        match self {
            Resource::Dns(r) => BTreeSet::from_iter(r.sites.iter()),
            Resource::Cidr(r) => BTreeSet::from_iter(r.sites.iter()),
            Resource::Internet(r) => BTreeSet::from_iter(r.sites.iter()),
        }
    }

    /// Returns the [`Site`] of a [`Resource`] if there is exactly one site.
    pub fn site(
        &self,
    ) -> Result<&Site, itertools::ExactlyOneError<impl Iterator<Item = &Site> + fmt::Debug>> {
        self.sites().into_iter().exactly_one()
    }

    /// What the GUI clients should show as the user-friendly display name, e.g. `Firezone GitHub`
    pub fn name(&self) -> &str {
        match self {
            Resource::Dns(r) => &r.name,
            Resource::Cidr(r) => &r.name,
            Resource::Internet(_) => "Internet",
        }
    }

    pub fn address_description(&self) -> Option<&str> {
        match self {
            Resource::Dns(r) => r.address_description.as_deref(),
            Resource::Cidr(r) => r.address_description.as_deref(),
            Resource::Internet(_) => None,
        }
    }

    pub fn has_different_address(&self, other: &Resource) -> bool {
        match (self, other) {
            (Resource::Dns(dns_a), Resource::Dns(dns_b)) => dns_a.address != dns_b.address,
            (Resource::Cidr(cidr_a), Resource::Cidr(cidr_b)) => cidr_a.address != cidr_b.address,
            (Resource::Internet(_), Resource::Internet(_)) => false,
            _ => true,
        }
    }

    pub fn has_different_ip_stack(&self, other: &Resource) -> bool {
        match (self, other) {
            (Resource::Dns(dns_a), Resource::Dns(dns_b)) => dns_a.ip_stack != dns_b.ip_stack,
            _ => false,
        }
    }

    pub fn has_different_site(&self, other: &Resource) -> bool {
        self.sites() != other.sites()
    }

    pub fn addresses(&self) -> Vec<IpNetwork> {
        match self {
            Resource::Dns(_) => vec![],
            Resource::Cidr(c) => vec![c.address],
            Resource::Internet(_) => vec![
                Ipv4Network::DEFAULT_ROUTE.into(),
                Ipv6Network::DEFAULT_ROUTE.into(),
            ],
        }
    }

    pub fn with_status(self, status: ResourceStatus) -> ResourceView {
        match self {
            Resource::Dns(r) => ResourceView::Dns(r.with_status(status)),
            Resource::Cidr(r) => ResourceView::Cidr(r.with_status(status)),
            Resource::Internet(r) => ResourceView::Internet(r.with_status(status)),
        }
    }

    #[cfg(all(test, feature = "proptest"))]
    pub fn with_new_site(self, site: Site) -> Self {
        match self {
            Resource::Dns(r) => Self::Dns(DnsResource {
                sites: vec![site],
                ..r
            }),
            Resource::Cidr(r) => Self::Cidr(CidrResource {
                sites: vec![site],
                ..r
            }),
            Resource::Internet(r) => Self::Internet(InternetResource {
                sites: vec![site],
                ..r
            }),
        }
    }
}

impl TryFrom<ResourceDescription> for Resource {
    type Error = UnknownResourceType;

    fn try_from(value: ResourceDescription) -> Result<Self, Self::Error> {
        Self::from_description(value).ok_or(UnknownResourceType)
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Unknown resource type")]
pub struct UnknownResourceType;

impl CidrResource {
    pub fn from_description(resource: ResourceDescriptionCidr) -> Self {
        Self {
            id: resource.id,
            address: resource.address,
            name: resource.name,
            address_description: resource.address_description,
            sites: resource.sites,
        }
    }

    pub fn with_status(self, status: ResourceStatus) -> CidrResourceView {
        CidrResourceView {
            id: self.id,
            address: self.address,
            name: self.name,
            address_description: self.address_description,
            sites: self.sites,
            status,
        }
    }
}

impl InternetResource {
    pub fn from_description(resource: ResourceDescriptionInternet) -> Self {
        Self {
            name: resource.name,
            id: resource.id,
            sites: resource.sites,
        }
    }

    pub fn with_status(self, status: ResourceStatus) -> InternetResourceView {
        InternetResourceView {
            name: self.name,
            id: self.id,
            sites: self.sites,
            status,
        }
    }
}

impl DnsResource {
    pub fn from_description(resource: ResourceDescriptionDns) -> Self {
        Self {
            id: resource.id,
            address: resource.address,
            name: resource.name,
            address_description: resource.address_description,
            sites: resource.sites,
            ip_stack: resource.ip_stack.unwrap_or(IpStack::Dual),
        }
    }

    pub fn with_status(self, status: ResourceStatus) -> DnsResourceView {
        DnsResourceView {
            id: self.id,
            address: self.address,
            name: self.name,
            address_description: self.address_description,
            sites: self.sites,
            status,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn can_deserialize_dns_resource_with_ipv4_only_ip_stack() {
        let resource = Resource::from_description(ResourceDescription::Dns(serde_json::json!({
            "address": "example.com",
            "id": "03000143-e25e-45c7-aafb-144990e57dce",
            "name": "example.com",
            "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "type": "dns",
            "ip_stack": "ipv4_only"
        })))
        .unwrap();

        let Resource::Dns(dns) = resource else {
            panic!("Unexpected resource")
        };

        assert_eq!(dns.ip_stack, IpStack::Ipv4Only)
    }

    #[test]
    fn can_deserialize_dns_resource_with_ipv6_only_ip_stack() {
        let resource = Resource::from_description(ResourceDescription::Dns(serde_json::json!({
            "address": "example.com",
            "id": "03000143-e25e-45c7-aafb-144990e57dce",
            "name": "example.com",
            "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "type": "dns",
            "ip_stack": "ipv6_only"
        })))
        .unwrap();

        let Resource::Dns(dns) = resource else {
            panic!("Unexpected resource")
        };

        assert_eq!(dns.ip_stack, IpStack::Ipv6Only)
    }

    #[test]
    fn can_deserialize_dns_resource_with_dual_ip_stack() {
        let resource = Resource::from_description(ResourceDescription::Dns(serde_json::json!({
            "address": "example.com",
            "id": "03000143-e25e-45c7-aafb-144990e57dce",
            "name": "example.com",
            "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "type": "dns",
            "ip_stack": "dual"
        })))
        .unwrap();

        let Resource::Dns(dns) = resource else {
            panic!("Unexpected resource")
        };

        assert_eq!(dns.ip_stack, IpStack::Dual)
    }

    #[test]
    fn can_deserialize_dns_resource_with_no_stack() {
        let resource = Resource::from_description(ResourceDescription::Dns(serde_json::json!({
            "address": "example.com",
            "id": "03000143-e25e-45c7-aafb-144990e57dce",
            "name": "example.com",
            "gateway_groups": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "type": "dns"
        })))
        .unwrap();

        let Resource::Dns(dns) = resource else {
            panic!("Unexpected resource")
        };

        assert_eq!(dns.ip_stack, IpStack::Dual)
    }

    #[test]
    fn name_changes_of_site_doesnt_matter() {
        let resource1 = Resource::from_description(ResourceDescription::Dns(serde_json::json!({
            "address": "example.com",
            "id": "03000143-e25e-45c7-aafb-144990e57dce",
            "name": "example.com",
            "gateway_groups": [{"name": "foo", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "type": "dns"
        })))
        .unwrap();
        let resource2 = Resource::from_description(ResourceDescription::Dns(serde_json::json!({
            "address": "example.com",
            "id": "03000143-e25e-45c7-aafb-144990e57dce",
            "name": "example.com",
            "gateway_groups": [{"name": "bar", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "type": "dns"
        })))
        .unwrap();

        assert!(!resource1.has_different_site(&resource2))
    }
}
