//! Resource model used by the reference implementation.
//!
//! These types intentionally do not reuse `tunnel-proto`'s internal resource
//! model. The SUT only receives portal-facing [`ResourceDescription`] values,
//! matching the production event loop and keeping the internal model private.

use connlib_model::{
    CidrResourceView, DnsResourceView, InternetResourceView, IpStack, ResourceId, ResourceStatus,
    ResourceView, Site,
};
use ip_network::IpNetwork;
use itertools::Itertools as _;
use serde_json::{Value, json};
use tunnel_proto::messages::{
    Filter,
    client::{
        ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDevicePool,
        ResourceDescriptionDns, ResourceDescriptionInternet,
    },
};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Resource {
    Dns(DnsResource),
    Cidr(CidrResource),
    Internet(InternetResource),
    DevicePool(DevicePoolResource),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct DnsResource {
    pub(crate) id: ResourceId,
    pub(crate) address: String,
    pub(crate) name: String,
    pub(crate) address_description: Option<String>,
    pub(crate) sites: Vec<Site>,
    pub(crate) ip_stack: IpStack,
    pub(crate) filters: Vec<Filter>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct CidrResource {
    pub(crate) id: ResourceId,
    pub(crate) address: IpNetwork,
    pub(crate) name: String,
    pub(crate) address_description: Option<String>,
    pub(crate) sites: Vec<Site>,
    pub(crate) filters: Vec<Filter>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct InternetResource {
    pub(crate) name: String,
    pub(crate) id: ResourceId,
    pub(crate) sites: Vec<Site>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct DevicePoolResource {
    pub(crate) id: ResourceId,
    pub(crate) name: String,
    pub(crate) filters: Vec<Filter>,
}

// Exhaustive conversions keep the reference fields aligned with the Portal messages.
const _: fn(ResourceDescriptionDns) -> DnsResource = |description| {
    let ResourceDescriptionDns {
        id,
        address,
        name,
        address_description,
        sites,
        ip_stack,
        filters,
    } = description;

    DnsResource {
        id,
        address,
        name,
        address_description,
        sites,
        ip_stack: ip_stack.unwrap_or(IpStack::Dual),
        filters,
    }
};

const _: fn(ResourceDescriptionCidr) -> CidrResource = |description| {
    let ResourceDescriptionCidr {
        id,
        address,
        name,
        address_description,
        sites,
        filters,
    } = description;

    CidrResource {
        id,
        address,
        name,
        address_description,
        sites,
        filters,
    }
};

const _: fn(ResourceDescriptionDevicePool) -> DevicePoolResource = |description| {
    let ResourceDescriptionDevicePool { id, name, filters } = description;

    DevicePoolResource { id, name, filters }
};

const _: fn(ResourceDescriptionInternet) -> InternetResource = |description| {
    let ResourceDescriptionInternet { name, id, sites } = description;

    InternetResource { name, id, sites }
};

const _: fn(ResourceDescription) -> bool = |description| match description {
    ResourceDescription::Dns(_) => true,
    ResourceDescription::Cidr(_) => true,
    ResourceDescription::DevicePool(_) => true,
    ResourceDescription::Internet(_) => false,
    ResourceDescription::Unknown => false,
};

/// An edit of the resource with `old.id()`; any number of fields, including the type, may differ.
#[derive(Debug, Clone)]
pub(crate) struct ResourceEdit {
    pub(crate) old: Resource,
    pub(crate) new: Resource,
}

pub(crate) enum EditEffect<'a> {
    /// Only fields the data plane never acts on changed.
    Metadata,
    /// The gateway swaps the resource's filters in place; clients reconnect to it.
    Filters {
        resource_id: ResourceId,
        affects_tcp: bool,
    },
    /// The gateway revokes all access to the resource; clients reconnect to it.
    Access {
        resource_id: ResourceId,
        affects_tcp: bool,
        forgets_dns_records_under: Option<&'a str>,
    },
    /// The pool's filters change the client's routes but keep its peer authorizations.
    DevicePoolRouting,
    /// The resource is removed and re-added as a different type.
    Type {
        old: &'a Resource,
        new: &'a Resource,
        forgets_dns_records_under: Option<&'a str>,
    },
}

pub(crate) fn classify<'a>(old: &'a Resource, new: &'a Resource) -> EditEffect<'a> {
    debug_assert_eq!(old.id(), new.id());

    match (old, new) {
        (Resource::Dns(old), Resource::Dns(new)) => {
            let DnsResource {
                id,
                address,
                name: _,
                address_description: _,
                sites,
                ip_stack,
                filters,
            } = old;
            let DnsResource {
                id: _,
                address: new_address,
                name: _,
                address_description: _,
                sites: new_sites,
                ip_stack: new_ip_stack,
                filters: new_filters,
            } = new;

            if address != new_address || sites != new_sites || ip_stack != new_ip_stack {
                return EditEffect::Access {
                    resource_id: *id,
                    affects_tcp: true,
                    forgets_dns_records_under: (address != new_address).then_some(new_address),
                };
            }

            if filters != new_filters {
                return EditEffect::Filters {
                    resource_id: *id,
                    affects_tcp: true,
                };
            }

            EditEffect::Metadata
        }
        (Resource::Cidr(old), Resource::Cidr(new)) => {
            let CidrResource {
                id,
                address,
                name: _,
                address_description: _,
                sites,
                filters,
            } = old;
            let CidrResource {
                id: _,
                address: new_address,
                name: _,
                address_description: _,
                sites: new_sites,
                filters: new_filters,
            } = new;

            if address != new_address || sites != new_sites {
                return EditEffect::Access {
                    resource_id: *id,
                    affects_tcp: false,
                    forgets_dns_records_under: None,
                };
            }

            if filters != new_filters {
                return EditEffect::Filters {
                    resource_id: *id,
                    affects_tcp: false,
                };
            }

            EditEffect::Metadata
        }
        (Resource::Internet(old), Resource::Internet(new)) => {
            let InternetResource { name: _, id, sites } = old;
            let InternetResource {
                name: _,
                id: _,
                sites: new_sites,
            } = new;

            if sites != new_sites {
                return EditEffect::Access {
                    resource_id: *id,
                    affects_tcp: false,
                    forgets_dns_records_under: None,
                };
            }

            EditEffect::Metadata
        }
        (Resource::DevicePool(old), Resource::DevicePool(new)) => {
            let DevicePoolResource {
                id: _,
                name: _,
                filters,
            } = old;
            let DevicePoolResource {
                id: _,
                name: _,
                filters: new_filters,
            } = new;

            if filters != new_filters {
                return EditEffect::DevicePoolRouting;
            }

            EditEffect::Metadata
        }
        _ => EditEffect::Type {
            old,
            new,
            forgets_dns_records_under: match new {
                Resource::Dns(new) => Some(&new.address),
                Resource::Cidr(_) => None,
                Resource::Internet(_) => None,
                Resource::DevicePool(_) => None,
            },
        },
    }
}

impl Resource {
    pub(crate) fn into_dns(self) -> Option<DnsResource> {
        match self {
            Resource::Dns(resource) => Some(resource),
            Resource::Cidr(_) => None,
            Resource::Internet(_) => None,
            Resource::DevicePool(_) => None,
        }
    }

    pub(crate) fn into_cidr(self) -> Option<CidrResource> {
        match self {
            Resource::Cidr(resource) => Some(resource),
            Resource::Dns(_) => None,
            Resource::Internet(_) => None,
            Resource::DevicePool(_) => None,
        }
    }

    pub(crate) fn id(&self) -> ResourceId {
        match self {
            Resource::Dns(r) => r.id,
            Resource::Cidr(r) => r.id,
            Resource::Internet(r) => r.id,
            Resource::DevicePool(r) => r.id,
        }
    }

    pub(crate) fn name(&self) -> &str {
        match self {
            Resource::Dns(r) => &r.name,
            Resource::Cidr(r) => &r.name,
            Resource::Internet(r) => &r.name,
            Resource::DevicePool(r) => &r.name,
        }
    }

    pub(crate) fn sites(&self) -> &[Site] {
        match self {
            Resource::Dns(r) => &r.sites,
            Resource::Cidr(r) => &r.sites,
            Resource::Internet(r) => &r.sites,
            Resource::DevicePool(_) => &[],
        }
    }

    pub(crate) fn filters(&self) -> &[Filter] {
        match self {
            Resource::Dns(r) => &r.filters,
            Resource::Cidr(r) => &r.filters,
            Resource::DevicePool(r) => &r.filters,
            Resource::Internet(_) => &[],
        }
    }

    pub(crate) fn site(
        &self,
    ) -> Result<&Site, itertools::ExactlyOneError<impl Iterator<Item = &Site> + std::fmt::Debug>>
    {
        let site = self.sites().iter().exactly_one()?;

        Ok(site)
    }

    /// Converts the reference resource into the portal message consumed by the SUT.
    pub(crate) fn into_description(self) -> ResourceDescription {
        match self {
            Resource::Dns(DnsResource {
                id,
                address,
                name,
                address_description,
                sites,
                ip_stack,
                filters,
            }) => ResourceDescription::Dns(json!({
                "id": id,
                "address": address,
                "name": name,
                "address_description": address_description,
                "gateway_groups": sites_json(sites),
                "ip_stack": ip_stack_json(ip_stack),
                "filters": filters_json(filters),
            })),
            Resource::Cidr(CidrResource {
                id,
                address,
                name,
                address_description,
                sites,
                filters,
            }) => ResourceDescription::Cidr(json!({
                "id": id,
                "address": address.to_string(),
                "name": name,
                "address_description": address_description,
                "gateway_groups": sites_json(sites),
                "filters": filters_json(filters),
            })),
            Resource::Internet(InternetResource { name, id, sites }) => {
                ResourceDescription::Internet(json!({
                    "id": id,
                    "name": name,
                    "gateway_groups": sites_json(sites),
                }))
            }
            Resource::DevicePool(DevicePoolResource { id, name, filters }) => {
                ResourceDescription::DevicePool(json!({
                "id": id,
                "name": name,
                "filters": filters_json(filters),
                }))
            }
        }
    }

    pub(crate) fn into_view(self, status: ResourceStatus) -> Option<ResourceView> {
        match self {
            Resource::Dns(r) => Some(ResourceView::Dns(DnsResourceView {
                id: r.id,
                address: r.address,
                name: r.name,
                address_description: r.address_description,
                sites: r.sites,
                status,
            })),
            Resource::Cidr(r) => Some(ResourceView::Cidr(CidrResourceView {
                id: r.id,
                address: r.address,
                name: r.name,
                address_description: r.address_description,
                sites: r.sites,
                status,
            })),
            Resource::Internet(r) => Some(ResourceView::Internet(InternetResourceView {
                name: r.name,
                id: r.id,
                sites: r.sites,
                status,
            })),
            Resource::DevicePool(_) => None,
        }
    }
}

fn sites_json(sites: Vec<Site>) -> Vec<Value> {
    sites
        .into_iter()
        .map(|site| json!({ "id": site.id, "name": site.name }))
        .collect()
}

fn ip_stack_json(ip_stack: IpStack) -> &'static str {
    match ip_stack {
        IpStack::Dual => "dual",
        IpStack::Ipv4Only => "ipv4_only",
        IpStack::Ipv6Only => "ipv6_only",
    }
}

fn filters_json(filters: Vec<Filter>) -> Vec<Value> {
    filters
        .into_iter()
        .map(|filter| match filter {
            Filter::Udp(range) => json!({
                "protocol": "udp",
                "port_range_start": range.start(),
                "port_range_end": range.end(),
            }),
            Filter::Tcp(range) => json!({
                "protocol": "tcp",
                "port_range_start": range.start(),
                "port_range_end": range.end(),
            }),
            Filter::Icmp => json!({ "protocol": "icmp" }),
        })
        .collect()
}
