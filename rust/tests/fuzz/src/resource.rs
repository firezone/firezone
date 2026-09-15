//! Resource model used by the reference implementation.
//!
//! These types intentionally do not reuse `tunnel-proto`'s internal resource
//! model. The SUT only receives portal-facing [`ResourceDescription`] values,
//! matching the production event loop and keeping the internal model private.

use crate::resource_edit_path_coverage::ResourceEditPath;

use connlib_model::{
    CidrResourceView, DnsResourceView, InternetResourceView, IpStack, ResourceId, ResourceStatus,
    ResourceView, Site,
};
use ip_network::IpNetwork;
use itertools::Itertools as _;
use serde_json::{Value, json};
use struct_to_enum_macros::FieldType;
use tunnel_proto::messages::{
    Filter,
    client::{
        DevicePoolMember, ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns,
        ResourceDescriptionDynamicDevicePool, ResourceDescriptionInternet,
        ResourceDescriptionStaticDevicePool,
    },
};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Resource {
    Dns(DnsResource),
    Cidr(CidrResource),
    Internet(InternetResource),
    StaticDevicePool(StaticDevicePoolResource),
    DynamicDevicePool(DynamicDevicePoolResource),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, FieldType)]
#[stem_type_derive(Debug, Clone)]
pub(crate) struct DnsResource {
    pub(crate) id: ResourceId,
    pub(crate) address: String,
    pub(crate) name: String,
    pub(crate) address_description: Option<String>,
    pub(crate) sites: Vec<Site>,
    pub(crate) ip_stack: IpStack,
    pub(crate) filters: Vec<Filter>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, FieldType)]
#[stem_type_derive(Debug, Clone)]
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

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, FieldType)]
#[stem_type_derive(Debug, Clone)]
pub(crate) struct StaticDevicePoolResource {
    pub(crate) id: ResourceId,
    pub(crate) name: String,
    pub(crate) devices: Vec<DevicePoolMember>,
    pub(crate) filters: Vec<Filter>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, FieldType)]
#[stem_type_derive(Debug, Clone)]
pub(crate) struct DynamicDevicePoolResource {
    pub(crate) id: ResourceId,
    pub(crate) name: String,
    pub(crate) address: String,
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

const _: fn(ResourceDescriptionStaticDevicePool) -> StaticDevicePoolResource = |description| {
    let ResourceDescriptionStaticDevicePool {
        id,
        name,
        devices,
        filters,
    } = description;

    StaticDevicePoolResource {
        id,
        name,
        devices,
        filters,
    }
};

const _: fn(ResourceDescriptionDynamicDevicePool) -> DynamicDevicePoolResource = |description| {
    let ResourceDescriptionDynamicDevicePool {
        id,
        name,
        address,
        filters,
    } = description;

    DynamicDevicePoolResource {
        id,
        name,
        address,
        filters,
    }
};

const _: fn(ResourceDescriptionInternet) -> InternetResource = |description| {
    let ResourceDescriptionInternet { name, id, sites } = description;

    InternetResource { name, id, sites }
};

const _: fn(ResourceDescription) -> bool = |description| match description {
    ResourceDescription::Dns(_) => true,
    ResourceDescription::Cidr(_) => true,
    ResourceDescription::StaticDevicePool(_) => true,
    ResourceDescription::DynamicDevicePool(_) => true,
    ResourceDescription::Internet(_) => false,
    ResourceDescription::Unknown => false,
};

pub(crate) type DnsResourceValue = DnsResourceFieldType;
pub(crate) type CidrResourceValue = CidrResourceFieldType;
pub(crate) type StaticDevicePoolResourceValue = StaticDevicePoolResourceFieldType;
pub(crate) type DynamicDevicePoolResourceValue = DynamicDevicePoolResourceFieldType;

impl DnsResource {
    pub(crate) fn values(&self) -> Vec<DnsResourceValue> {
        <[DnsResourceValue; 7]>::from(self.clone())
            .into_iter()
            .filter(|value| match value {
                DnsResourceValue::Id(_) => false,
                DnsResourceValue::Address(_) => true,
                DnsResourceValue::Name(_) => true,
                DnsResourceValue::AddressDescription(_) => true,
                DnsResourceValue::Sites(_) => true,
                DnsResourceValue::IpStack(_) => true,
                DnsResourceValue::Filters(_) => true,
            })
            .collect()
    }

    fn update(&mut self, value: DnsResourceValue) {
        match value {
            DnsResourceValue::Id(_) => unreachable!("resource identity is not editable"),
            DnsResourceValue::Address(value) => self.address = value,
            DnsResourceValue::Name(value) => self.name = value,
            DnsResourceValue::AddressDescription(value) => self.address_description = value,
            DnsResourceValue::Sites(value) => self.sites = value,
            DnsResourceValue::IpStack(value) => self.ip_stack = value,
            DnsResourceValue::Filters(value) => self.filters = value,
        }
    }
}

impl CidrResource {
    pub(crate) fn values(&self) -> Vec<CidrResourceValue> {
        <[CidrResourceValue; 6]>::from(self.clone())
            .into_iter()
            .filter(|value| match value {
                CidrResourceValue::Id(_) => false,
                CidrResourceValue::Address(_) => true,
                CidrResourceValue::Name(_) => true,
                CidrResourceValue::AddressDescription(_) => true,
                CidrResourceValue::Sites(_) => true,
                CidrResourceValue::Filters(_) => true,
            })
            .collect()
    }

    fn update(&mut self, value: CidrResourceValue) {
        match value {
            CidrResourceValue::Id(_) => unreachable!("resource identity is not editable"),
            CidrResourceValue::Address(value) => self.address = value,
            CidrResourceValue::Name(value) => self.name = value,
            CidrResourceValue::AddressDescription(value) => self.address_description = value,
            CidrResourceValue::Sites(value) => self.sites = value,
            CidrResourceValue::Filters(value) => self.filters = value,
        }
    }
}

impl StaticDevicePoolResource {
    pub(crate) fn values(&self) -> Vec<StaticDevicePoolResourceValue> {
        <[StaticDevicePoolResourceValue; 4]>::from(self.clone())
            .into_iter()
            .filter(|value| match value {
                StaticDevicePoolResourceValue::Id(_) => false,
                StaticDevicePoolResourceValue::Name(_) => true,
                StaticDevicePoolResourceValue::Devices(_) => true,
                StaticDevicePoolResourceValue::Filters(_) => true,
            })
            .collect()
    }

    fn update(&mut self, value: StaticDevicePoolResourceValue) {
        match value {
            StaticDevicePoolResourceValue::Id(_) => {
                unreachable!("resource identity is not editable")
            }
            StaticDevicePoolResourceValue::Name(value) => self.name = value,
            StaticDevicePoolResourceValue::Devices(value) => self.devices = value,
            StaticDevicePoolResourceValue::Filters(value) => self.filters = value,
        }
    }
}

impl DynamicDevicePoolResource {
    pub(crate) fn values(&self) -> Vec<DynamicDevicePoolResourceValue> {
        <[DynamicDevicePoolResourceValue; 4]>::from(self.clone())
            .into_iter()
            .filter(|value| match value {
                DynamicDevicePoolResourceValue::Id(_) => false,
                DynamicDevicePoolResourceValue::Name(_) => true,
                DynamicDevicePoolResourceValue::Address(_) => true,
                DynamicDevicePoolResourceValue::Filters(_) => true,
            })
            .collect()
    }

    fn update(&mut self, value: DynamicDevicePoolResourceValue) {
        match value {
            DynamicDevicePoolResourceValue::Id(_) => {
                unreachable!("resource identity is not editable")
            }
            DynamicDevicePoolResourceValue::Name(value) => self.name = value,
            DynamicDevicePoolResourceValue::Address(value) => self.address = value,
            DynamicDevicePoolResourceValue::Filters(value) => self.filters = value,
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) enum ResourceEdit {
    Dns(DnsResourceEdit),
    Cidr(CidrResourceEdit),
    StaticDevicePool(StaticDevicePoolResourceEdit),
    DynamicDevicePool(DynamicDevicePoolResourceEdit),
    Type(ResourceTypeEdit),
}

#[derive(Debug, Clone)]
pub(crate) struct DnsResourceEdit {
    pub(crate) resource: DnsResource,
    pub(crate) value: DnsResourceValue,
}

#[derive(Debug, Clone)]
pub(crate) struct CidrResourceEdit {
    pub(crate) resource: CidrResource,
    pub(crate) value: CidrResourceValue,
}

#[derive(Debug, Clone)]
pub(crate) struct StaticDevicePoolResourceEdit {
    pub(crate) resource: StaticDevicePoolResource,
    pub(crate) value: StaticDevicePoolResourceValue,
}

#[derive(Debug, Clone)]
pub(crate) struct DynamicDevicePoolResourceEdit {
    pub(crate) resource: DynamicDevicePoolResource,
    pub(crate) value: DynamicDevicePoolResourceValue,
}

#[derive(Debug, Clone)]
pub(crate) struct ResourceTypeEdit {
    pub(crate) old_resource: Resource,
    pub(crate) new_resource: Resource,
}

impl ResourceEdit {
    pub(crate) fn path(&self) -> ResourceEditPath {
        match self {
            ResourceEdit::Dns(DnsResourceEdit {
                value: DnsResourceValue::Id(_),
                ..
            }) => unreachable!("resource identity is not editable"),
            ResourceEdit::Dns(DnsResourceEdit {
                value: DnsResourceValue::Address(_),
                ..
            }) => ResourceEditPath::DnsAddress,
            ResourceEdit::Dns(DnsResourceEdit {
                value: DnsResourceValue::Name(_),
                ..
            }) => ResourceEditPath::DnsName,
            ResourceEdit::Dns(DnsResourceEdit {
                value: DnsResourceValue::AddressDescription(_),
                ..
            }) => ResourceEditPath::DnsAddressDescription,
            ResourceEdit::Dns(DnsResourceEdit {
                value: DnsResourceValue::Sites(_),
                ..
            }) => ResourceEditPath::DnsSites,
            ResourceEdit::Dns(DnsResourceEdit {
                value: DnsResourceValue::IpStack(_),
                ..
            }) => ResourceEditPath::DnsIpStack,
            ResourceEdit::Dns(DnsResourceEdit {
                value: DnsResourceValue::Filters(_),
                ..
            }) => ResourceEditPath::DnsFilters,
            ResourceEdit::Cidr(CidrResourceEdit {
                value: CidrResourceValue::Id(_),
                ..
            }) => unreachable!("resource identity is not editable"),
            ResourceEdit::Cidr(CidrResourceEdit {
                value: CidrResourceValue::Address(_),
                ..
            }) => ResourceEditPath::CidrAddress,
            ResourceEdit::Cidr(CidrResourceEdit {
                value: CidrResourceValue::Name(_),
                ..
            }) => ResourceEditPath::CidrName,
            ResourceEdit::Cidr(CidrResourceEdit {
                value: CidrResourceValue::AddressDescription(_),
                ..
            }) => ResourceEditPath::CidrAddressDescription,
            ResourceEdit::Cidr(CidrResourceEdit {
                value: CidrResourceValue::Sites(_),
                ..
            }) => ResourceEditPath::CidrSites,
            ResourceEdit::Cidr(CidrResourceEdit {
                value: CidrResourceValue::Filters(_),
                ..
            }) => ResourceEditPath::CidrFilters,
            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
                value: StaticDevicePoolResourceValue::Id(_),
                ..
            }) => unreachable!("resource identity is not editable"),
            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
                value: StaticDevicePoolResourceValue::Name(_),
                ..
            }) => ResourceEditPath::StaticDevicePoolName,
            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
                value: StaticDevicePoolResourceValue::Devices(_),
                ..
            }) => ResourceEditPath::StaticDevicePoolDevices,
            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
                value: StaticDevicePoolResourceValue::Filters(_),
                ..
            }) => ResourceEditPath::StaticDevicePoolFilters,
            ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit {
                value: DynamicDevicePoolResourceValue::Id(_),
                ..
            }) => unreachable!("resource identity is not editable"),
            ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit {
                value: DynamicDevicePoolResourceValue::Name(_),
                ..
            }) => ResourceEditPath::DynamicDevicePoolName,
            ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit {
                value: DynamicDevicePoolResourceValue::Address(_),
                ..
            }) => ResourceEditPath::DynamicDevicePoolAddress,
            ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit {
                value: DynamicDevicePoolResourceValue::Filters(_),
                ..
            }) => ResourceEditPath::DynamicDevicePoolFilters,
            ResourceEdit::Type(edit) => edit.path(),
        }
    }

    pub(crate) fn id(&self) -> ResourceId {
        match self {
            ResourceEdit::Dns(edit) => edit.resource.id,
            ResourceEdit::Cidr(edit) => edit.resource.id,
            ResourceEdit::StaticDevicePool(edit) => edit.resource.id,
            ResourceEdit::DynamicDevicePool(edit) => edit.resource.id,
            ResourceEdit::Type(edit) => edit.old_resource.id(),
        }
    }

    pub(crate) fn updated_resource(&self) -> Resource {
        match self {
            ResourceEdit::Dns(edit) => {
                let mut resource = edit.resource.clone();
                resource.update(edit.value.clone());

                Resource::Dns(resource)
            }
            ResourceEdit::Cidr(edit) => {
                let mut resource = edit.resource.clone();
                resource.update(edit.value.clone());

                Resource::Cidr(resource)
            }
            ResourceEdit::StaticDevicePool(edit) => {
                let mut resource = edit.resource.clone();
                resource.update(edit.value.clone());

                Resource::StaticDevicePool(resource)
            }
            ResourceEdit::DynamicDevicePool(edit) => {
                let mut resource = edit.resource.clone();
                resource.update(edit.value.clone());

                Resource::DynamicDevicePool(resource)
            }
            ResourceEdit::Type(edit) => {
                debug_assert_eq!(edit.old_resource.id(), edit.new_resource.id());

                edit.new_resource.clone()
            }
        }
    }

    pub(crate) fn removed_static_device_pool_members(&self) -> Vec<DevicePoolMember> {
        match self {
            ResourceEdit::Dns(_) => Vec::new(),
            ResourceEdit::Cidr(_) => Vec::new(),
            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
                value: StaticDevicePoolResourceValue::Id(_),
                ..
            }) => unreachable!("resource identity is not editable"),
            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
                value:
                    StaticDevicePoolResourceValue::Name(_) | StaticDevicePoolResourceValue::Filters(_),
                ..
            }) => Vec::new(),
            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit {
                resource,
                value: StaticDevicePoolResourceValue::Devices(updated),
            }) => resource
                .devices
                .iter()
                .filter(|previous| updated.iter().all(|member| member.id != previous.id))
                .cloned()
                .collect(),
            ResourceEdit::DynamicDevicePool(_) => Vec::new(),
            ResourceEdit::Type(ResourceTypeEdit {
                old_resource: Resource::Dns(_) | Resource::Cidr(_) | Resource::DynamicDevicePool(_),
                ..
            }) => Vec::new(),
            ResourceEdit::Type(ResourceTypeEdit {
                old_resource: Resource::StaticDevicePool(previous),
                new_resource: Resource::Dns(_) | Resource::Cidr(_) | Resource::DynamicDevicePool(_),
            }) => previous.devices.clone(),
            ResourceEdit::Type(ResourceTypeEdit {
                old_resource: Resource::StaticDevicePool(_),
                new_resource: Resource::StaticDevicePool(_),
            }) => unreachable!("resource type edits must change the resource type"),
            ResourceEdit::Type(ResourceTypeEdit {
                old_resource: Resource::Internet(_),
                ..
            })
            | ResourceEdit::Type(ResourceTypeEdit {
                new_resource: Resource::Internet(_),
                ..
            }) => unreachable!("the Portal API does not allow editing the Internet Resource"),
        }
    }
}

impl ResourceTypeEdit {
    fn path(&self) -> ResourceEditPath {
        let old = EditableResourceType::from_resource(&self.old_resource);
        let new = EditableResourceType::from_resource(&self.new_resource);

        match (old, new) {
            (EditableResourceType::Dns, EditableResourceType::Dns) => {
                unreachable!("resource type edits must change the resource type")
            }
            (EditableResourceType::Dns, EditableResourceType::Cidr) => ResourceEditPath::DnsToCidr,
            (EditableResourceType::Dns, EditableResourceType::StaticDevicePool) => {
                ResourceEditPath::DnsToStaticDevicePool
            }
            (EditableResourceType::Dns, EditableResourceType::DynamicDevicePool) => {
                ResourceEditPath::DnsToDynamicDevicePool
            }
            (EditableResourceType::Cidr, EditableResourceType::Dns) => ResourceEditPath::CidrToDns,
            (EditableResourceType::Cidr, EditableResourceType::Cidr) => {
                unreachable!("resource type edits must change the resource type")
            }
            (EditableResourceType::Cidr, EditableResourceType::StaticDevicePool) => {
                ResourceEditPath::CidrToStaticDevicePool
            }
            (EditableResourceType::Cidr, EditableResourceType::DynamicDevicePool) => {
                ResourceEditPath::CidrToDynamicDevicePool
            }
            (EditableResourceType::StaticDevicePool, EditableResourceType::Dns) => {
                ResourceEditPath::StaticDevicePoolToDns
            }
            (EditableResourceType::StaticDevicePool, EditableResourceType::Cidr) => {
                ResourceEditPath::StaticDevicePoolToCidr
            }
            (EditableResourceType::StaticDevicePool, EditableResourceType::StaticDevicePool) => {
                unreachable!("resource type edits must change the resource type")
            }
            (EditableResourceType::StaticDevicePool, EditableResourceType::DynamicDevicePool) => {
                ResourceEditPath::StaticDevicePoolToDynamicDevicePool
            }
            (EditableResourceType::DynamicDevicePool, EditableResourceType::Dns) => {
                ResourceEditPath::DynamicDevicePoolToDns
            }
            (EditableResourceType::DynamicDevicePool, EditableResourceType::Cidr) => {
                ResourceEditPath::DynamicDevicePoolToCidr
            }
            (EditableResourceType::DynamicDevicePool, EditableResourceType::StaticDevicePool) => {
                ResourceEditPath::DynamicDevicePoolToStaticDevicePool
            }
            (EditableResourceType::DynamicDevicePool, EditableResourceType::DynamicDevicePool) => {
                unreachable!("resource type edits must change the resource type")
            }
        }
    }
}

#[derive(Clone, Copy)]
enum EditableResourceType {
    Dns,
    Cidr,
    StaticDevicePool,
    DynamicDevicePool,
}

impl EditableResourceType {
    fn from_resource(resource: &Resource) -> Self {
        match resource {
            Resource::Dns(_) => Self::Dns,
            Resource::Cidr(_) => Self::Cidr,
            Resource::Internet(_) => {
                unreachable!("the Portal API does not allow editing the Internet Resource")
            }
            Resource::StaticDevicePool(_) => Self::StaticDevicePool,
            Resource::DynamicDevicePool(_) => Self::DynamicDevicePool,
        }
    }
}

impl Resource {
    pub(crate) fn into_dns(self) -> Option<DnsResource> {
        match self {
            Resource::Dns(resource) => Some(resource),
            Resource::Cidr(_) => None,
            Resource::Internet(_) => None,
            Resource::StaticDevicePool(_) => None,
            Resource::DynamicDevicePool(_) => None,
        }
    }

    pub(crate) fn into_cidr(self) -> Option<CidrResource> {
        match self {
            Resource::Cidr(resource) => Some(resource),
            Resource::Dns(_) => None,
            Resource::Internet(_) => None,
            Resource::StaticDevicePool(_) => None,
            Resource::DynamicDevicePool(_) => None,
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
            Resource::StaticDevicePool(_) => &[],
            Resource::DynamicDevicePool(_) => &[],
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
            Resource::Internet(_) => &[],
            Resource::DynamicDevicePool(r) => &r.filters,
        }
    }

    pub(crate) fn site(
        &self,
    ) -> Result<&Site, itertools::ExactlyOneError<impl Iterator<Item = &Site> + std::fmt::Debug>>
    {
        let site = self.sites().iter().exactly_one()?;

        Ok(site)
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
        match (self, other) {
            (Resource::Dns(a), Resource::Dns(b)) => a.ip_stack != b.ip_stack,
            _ => false,
        }
    }

    pub(crate) fn has_different_site(&self, other: &Resource) -> bool {
        self.sites() != other.sites()
    }

    pub(crate) fn has_different_filters(&self, other: &Resource) -> bool {
        self.filters() != other.filters()
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
            Resource::StaticDevicePool(StaticDevicePoolResource {
                id,
                name,
                devices,
                filters,
            }) => ResourceDescription::StaticDevicePool(json!({
                "id": id,
                "name": name,
                "devices": devices.into_iter().map(device_json).collect::<Vec<_>>(),
                "filters": filters_json(filters),
            })),
            Resource::DynamicDevicePool(DynamicDevicePoolResource {
                id,
                name,
                address,
                filters,
            }) => ResourceDescription::DynamicDevicePool(json!({
                "id": id,
                "name": name,
                "address": address,
                "filters": filters_json(filters),
            })),
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
            Resource::StaticDevicePool(_) => None,
            Resource::DynamicDevicePool(_) => None,
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
