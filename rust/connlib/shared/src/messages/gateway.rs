//! Gateway related messages that are needed within connlib

use std::net::IpAddr;

use ip_network::IpNetwork;
use itertools::Itertools;
use serde::Deserialize;

use super::{Filter, Filters, ResourceId};

/// Description of a resource that maps to a DNS record.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct ResourceDescriptionDns {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub filters: Filters,
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct ResourceDescriptionCidr {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub filters: Filters,
}

/// Description of a resource that maps to a DNS record which had its domain already resolved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedResourceDescriptionDns {
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub domain: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub addresses: Vec<IpAddr>,

    pub filters: Filters,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceDescription<TDNS = ResourceDescriptionDns> {
    Dns(TDNS),
    Cidr(ResourceDescriptionCidr),
}

impl ResourceDescription<ResourceDescriptionDns> {
    pub fn into_resolved(
        self,
        addresses: Vec<IpAddr>,
    ) -> ResourceDescription<ResolvedResourceDescriptionDns> {
        match self {
            ResourceDescription::Dns(ResourceDescriptionDns {
                id,
                address,
                name,
                filters,
            }) => ResourceDescription::Dns(ResolvedResourceDescriptionDns {
                id,
                domain: address,
                name,
                addresses,

                filters,
            }),
            ResourceDescription::Cidr(c) => ResourceDescription::Cidr(c),
        }
    }
}

impl ResourceDescription<ResourceDescriptionDns> {
    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
        }
    }

    pub fn filters(&self) -> Vec<Filter> {
        match self {
            ResourceDescription::Dns(r) => r.filters.clone(),
            ResourceDescription::Cidr(r) => r.filters.clone(),
        }
    }
}

impl ResourceDescription<ResolvedResourceDescriptionDns> {
    pub fn addresses(&self) -> Vec<IpNetwork> {
        match self {
            ResourceDescription::Dns(r) => r.addresses.iter().copied().map_into().collect_vec(),
            ResourceDescription::Cidr(r) => vec![r.address],
        }
    }

    pub fn id(&self) -> ResourceId {
        match self {
            ResourceDescription::Dns(r) => r.id,
            ResourceDescription::Cidr(r) => r.id,
        }
    }

    pub fn filters(&self) -> Vec<Filter> {
        match self {
            ResourceDescription::Dns(r) => r.filters.clone(),
            ResourceDescription::Cidr(r) => r.filters.clone(),
        }
    }
}
