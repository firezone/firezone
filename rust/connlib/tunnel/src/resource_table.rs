//! A resource table is a custom type that allows us to store a resource under an id and possibly multiple ips or even network ranges
use std::{collections::HashMap, net::IpAddr, rc::Rc};

use chrono::{DateTime, Utc};
use connlib_shared::messages::{ResourceDescription, ResourceId};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;

pub(crate) trait Resource {
    fn description(&self) -> &ResourceDescription;
}

impl Resource for ResourceDescription {
    fn description(&self) -> &ResourceDescription {
        self
    }
}

impl Resource for (ResourceDescription, DateTime<Utc>) {
    fn description(&self) -> &ResourceDescription {
        &self.0
    }
}

/// The resource table type
///
/// This is specifically crafted for our use case, so the API is particularly made for us and not generic
pub(crate) struct ResourceTable<T> {
    id_table: HashMap<ResourceId, Rc<T>>,
    network_table: IpNetworkTable<Rc<T>>,
    dns_name: HashMap<String, Rc<T>>,
}

// SAFETY: This type is send since you can't obtain the underlying `Rc` and the only way to clone it is using `insert` which requires an &mut self
unsafe impl<T> Send for ResourceTable<T> {}
// SAFETY: This type is sync since you can't obtain the underlying `Rc` and the only way to clone it is using `insert` which requires an &mut self
unsafe impl<T> Sync for ResourceTable<T> {}

impl<T> Default for ResourceTable<T> {
    fn default() -> ResourceTable<T> {
        ResourceTable::new()
    }
}

impl<T> ResourceTable<T> {
    /// Creates a new `ResourceTable`
    pub fn new() -> ResourceTable<T> {
        ResourceTable {
            network_table: IpNetworkTable::new(),
            id_table: HashMap::new(),
            dns_name: HashMap::new(),
        }
    }
}

impl<T> ResourceTable<T>
where
    T: Resource + Clone,
{
    pub fn values(&self) -> impl Iterator<Item = &T> {
        self.id_table.values().map(AsRef::as_ref)
    }

    pub fn network_resources(&self) -> HashMap<IpNetwork, T> {
        // Safety: Due to internal consistency, since the value is stored the reference should be valid
        self.network_table
            .iter()
            .map(|(wg_ip, res)| (wg_ip, res.as_ref().clone()))
            .collect()
    }

    pub fn dns_resources(&self) -> HashMap<String, T> {
        // Safety: Due to internal consistency, since the value is stored the reference should be valid
        self.dns_name
            .iter()
            .map(|(name, res)| (name.clone(), res.as_ref().clone()))
            .collect()
    }

    /// Tells you if it's empty
    pub fn is_empty(&self) -> bool {
        self.id_table.is_empty()
    }

    /// Gets the resource by ip
    pub fn get_by_ip(&self, ip: impl Into<IpAddr>) -> Option<&T> {
        self.network_table.longest_match(ip).map(|m| m.1.as_ref())
    }

    /// Gets the resource by id
    pub fn get_by_id(&self, id: &ResourceId) -> Option<&T> {
        self.id_table.get(id).map(AsRef::as_ref)
    }

    /// Gets the resource by name
    pub fn get_by_name(&self, name: impl AsRef<str>) -> Option<&T> {
        self.dns_name.get(name.as_ref()).map(AsRef::as_ref)
    }

    fn remove_resource(&mut self, resource_description: &T) {
        let id = {
            match resource_description.description() {
                ResourceDescription::Dns(r) => {
                    self.dns_name.remove(&r.address);
                    self.network_table.remove(r.ipv4);
                    self.network_table.remove(r.ipv6);
                    r.id
                }
                ResourceDescription::Cidr(r) => {
                    self.network_table.remove(r.address);
                    r.id
                }
            }
        };
        self.id_table.remove(&id);
    }

    pub(crate) fn cleanup_resource(&mut self, resource_description: &T) {
        match resource_description.description() {
            ResourceDescription::Dns(r) => {
                if let Some(res) = self.id_table.remove(&r.id) {
                    self.remove_resource(res.as_ref());
                }

                if let Some(res) = self.dns_name.remove(&r.address) {
                    self.remove_resource(res.as_ref());
                }

                if let Some(res) = self.network_table.remove(r.ipv4) {
                    self.remove_resource(res.as_ref());
                }

                if let Some(res) = self.network_table.remove(r.ipv6) {
                    self.remove_resource(res.as_ref());
                }
            }
            ResourceDescription::Cidr(r) => {
                if let Some(res) = self.id_table.remove(&r.id) {
                    self.remove_resource(res.as_ref());
                }

                if let Some(res) = self.network_table.remove(r.address) {
                    self.remove_resource(res.as_ref());
                }
            }
        }
    }

    // For soundness it's very important that this API only takes a resource_description
    // doing this, we can assume that when removing a resource from the id table we have all the info
    // about all the tables.
    /// Inserts a new resource_description
    ///
    /// If the id was used previously the old value will be deleted.
    /// Same goes if any of the ip matches exactly an old ip or dns name.
    /// This means that a match in IP or dns name will discard all old values.
    ///
    /// This is done so that we don't have dangling values.
    pub fn insert(&mut self, resource_description: T) {
        self.cleanup_resource(&resource_description);
        let id = resource_description.description().id();
        let resource_description = Rc::new(resource_description);
        self.id_table.insert(id, Rc::clone(&resource_description));
        // we just inserted it we can unwrap
        let res = self.id_table.get(&id).unwrap();
        match res.description() {
            ResourceDescription::Dns(r) => {
                self.network_table
                    .insert(r.ipv4, Rc::clone(&resource_description));
                self.network_table
                    .insert(r.ipv6, Rc::clone(&resource_description));
                self.dns_name
                    .insert(r.address.clone(), resource_description);
            }
            ResourceDescription::Cidr(r) => {
                self.network_table.insert(r.address, resource_description);
            }
        }
    }

    pub fn resource_list(&self) -> Vec<ResourceDescription> {
        self.id_table
            .values()
            .map(|r| r.description())
            .cloned()
            .collect()
    }
}
