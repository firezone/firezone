//! Resource model used by the reference implementation.
//!
//! These types intentionally do not reuse `tunnel-proto`'s internal resource
//! model. The SUT only receives portal-facing [`ResourceDescription`] values,
//! matching the production event loop and keeping the internal model private.

use connlib_model::{IpStack, ResourceId, Site};
use ip_network::IpNetwork;
use itertools::Itertools as _;
use serde_json::{Value, json};
use tunnel_proto::messages::{
    Filter,
    client::{DevicePoolMember, ResourceDescription},
};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Resource {
    Dns(DnsResource),
    Cidr(CidrResource),
    Internet(InternetResource),
    StaticDevicePool(StaticDevicePoolResource),
    DynamicDevicePool(DynamicDevicePoolResource),
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
pub(crate) struct StaticDevicePoolResource {
    pub(crate) id: ResourceId,
    pub(crate) name: String,
    pub(crate) devices: Vec<DevicePoolMember>,
    pub(crate) filters: Vec<Filter>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct DynamicDevicePoolResource {
    pub(crate) id: ResourceId,
    pub(crate) name: String,
    pub(crate) address: String,
}

impl Resource {
    pub(crate) fn into_dns(self) -> Option<DnsResource> {
        match self {
            Resource::Dns(resource) => Some(resource),
            Resource::Cidr(_)
            | Resource::Internet(_)
            | Resource::StaticDevicePool(_)
            | Resource::DynamicDevicePool(_) => None,
        }
    }

    pub(crate) fn into_cidr(self) -> Option<CidrResource> {
        match self {
            Resource::Cidr(resource) => Some(resource),
            Resource::Dns(_)
            | Resource::Internet(_)
            | Resource::StaticDevicePool(_)
            | Resource::DynamicDevicePool(_) => None,
        }
    }

    pub(crate) fn id(&self) -> ResourceId {
        match self {
            Resource::Dns(r) => r.id,
            Resource::Cidr(r) => r.id,
            Resource::Internet(r) => r.id,
            Resource::StaticDevicePool(r) => r.id,
            Resource::DynamicDevicePool(r) => r.id,
        }
    }

    pub(crate) fn name(&self) -> &str {
        match self {
            Resource::Dns(r) => &r.name,
            Resource::Cidr(r) => &r.name,
            Resource::Internet(r) => &r.name,
            Resource::StaticDevicePool(r) => &r.name,
            Resource::DynamicDevicePool(r) => &r.name,
        }
    }

    pub(crate) fn sites(&self) -> &[Site] {
        match self {
            Resource::Dns(r) => &r.sites,
            Resource::Cidr(r) => &r.sites,
            Resource::Internet(r) => &r.sites,
            Resource::StaticDevicePool(_) | Resource::DynamicDevicePool(_) => &[],
        }
    }

    pub(crate) fn is_exclusively_at(&self, site: &Site) -> bool {
        self.sites().len() == 1 && self.sites().first() == Some(site)
    }

    pub(crate) fn filters(&self) -> &[Filter] {
        match self {
            Resource::Dns(r) => &r.filters,
            Resource::Cidr(r) => &r.filters,
            Resource::StaticDevicePool(r) => &r.filters,
            Resource::Internet(_) | Resource::DynamicDevicePool(_) => &[],
        }
    }

    pub(crate) fn site(
        &self,
    ) -> Result<&Site, itertools::ExactlyOneError<impl Iterator<Item = &Site> + std::fmt::Debug>>
    {
        self.sites().iter().exactly_one()
    }

    pub(crate) fn has_different_address(&self, other: &Resource) -> bool {
        match (self, other) {
            (Resource::Dns(a), Resource::Dns(b)) => a.address != b.address,
            (Resource::Cidr(a), Resource::Cidr(b)) => a.address != b.address,
            (Resource::Internet(_), Resource::Internet(_)) => false,
            (Resource::StaticDevicePool(a), Resource::StaticDevicePool(b)) => {
                a.devices != b.devices
            }
            (Resource::DynamicDevicePool(a), Resource::DynamicDevicePool(b)) => {
                a.address != b.address
            }
            _ => true,
        }
    }

    pub(crate) fn has_different_ip_stack(&self, other: &Resource) -> bool {
        matches!((self, other), (Resource::Dns(a), Resource::Dns(b)) if a.ip_stack != b.ip_stack)
    }

    pub(crate) fn has_different_site(&self, other: &Resource) -> bool {
        self.sites() != other.sites()
    }

    pub(crate) fn has_different_filters(&self, other: &Resource) -> bool {
        self.filters() != other.filters()
    }

    pub(crate) fn with_new_site(self, site: Site) -> Self {
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
            Resource::StaticDevicePool(r) => Self::StaticDevicePool(r),
            Resource::DynamicDevicePool(r) => Self::DynamicDevicePool(r),
        }
    }

    pub(crate) fn with_new_filters(self, filters: Vec<Filter>) -> Self {
        match self {
            Resource::Dns(r) => Self::Dns(DnsResource { filters, ..r }),
            Resource::Cidr(r) => Self::Cidr(CidrResource { filters, ..r }),
            Resource::StaticDevicePool(r) => {
                Self::StaticDevicePool(StaticDevicePoolResource { filters, ..r })
            }
            Resource::Internet(_) | Resource::DynamicDevicePool(_) => self,
        }
    }

    /// Convert the reference resource into the portal message consumed by the SUT.
    pub(crate) fn into_description(self) -> ResourceDescription {
        match self {
            Resource::Dns(r) => ResourceDescription::Dns(json!({
                "id": r.id,
                "address": r.address,
                "name": r.name,
                "address_description": r.address_description,
                "gateway_groups": sites_json(r.sites),
                "ip_stack": ip_stack_json(r.ip_stack),
                "filters": filters_json(r.filters),
            })),
            Resource::Cidr(r) => ResourceDescription::Cidr(json!({
                "id": r.id,
                "address": r.address.to_string(),
                "name": r.name,
                "address_description": r.address_description,
                "gateway_groups": sites_json(r.sites),
                "filters": filters_json(r.filters),
            })),
            Resource::Internet(r) => ResourceDescription::Internet(json!({
                "id": r.id,
                "name": r.name,
                "gateway_groups": sites_json(r.sites),
            })),
            Resource::StaticDevicePool(r) => ResourceDescription::StaticDevicePool(json!({
                "id": r.id,
                "name": r.name,
                "devices": r.devices.into_iter().map(device_json).collect::<Vec<_>>(),
                "filters": filters_json(r.filters),
            })),
            Resource::DynamicDevicePool(r) => ResourceDescription::DynamicDevicePool(json!({
                "id": r.id,
                "name": r.name,
                "address": r.address,
            })),
        }
    }
}

fn sites_json(sites: Vec<Site>) -> Vec<Value> {
    sites
        .into_iter()
        .map(|site| json!({ "id": site.id, "name": site.name }))
        .collect()
}

fn device_json(device: DevicePoolMember) -> Value {
    json!({
        "client_id": device.id,
        "ipv4": device.ipv4.to_string(),
        "ipv6": device.ipv6.to_string(),
    })
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
                "port_range_start": range.port_range_start,
                "port_range_end": range.port_range_end,
            }),
            Filter::Tcp(range) => json!({
                "protocol": "tcp",
                "port_range_start": range.port_range_start,
                "port_range_end": range.port_range_end,
            }),
            Filter::Icmp => json!({ "protocol": "icmp" }),
        })
        .collect()
}
