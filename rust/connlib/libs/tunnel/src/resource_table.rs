//! A resource table is a custom type that allows us to store a resource under an id and possibly multiple ips or even network ranges
use std::{collections::HashMap, net::IpAddr, ptr::NonNull};

use ip_network_table::IpNetworkTable;
use libs_common::messages::{Id, ResourceDescription};

// Oh boy... here we go
/// The resource table type
///
/// This is specifically crafted for our use case, so the API is particularly made for us and not generic
pub(crate) struct ResourceTable {
    id_table: HashMap<Id, ResourceDescription>,
    network_table: IpNetworkTable<NonNull<ResourceDescription>>,
    dns_name: HashMap<String, NonNull<ResourceDescription>>,
}

// SAFETY: We actually hold a `Vec` internally that the poitners points to
unsafe impl Send for ResourceTable {}
// SAFETY: we don't allow interior mutability of the pointers we hold, in fact we don't allow ANY mutability!
// (this is part of the reason why the API is so limiting, it is easier to reason about.
unsafe impl Sync for ResourceTable {}

impl Default for ResourceTable {
    fn default() -> ResourceTable {
        ResourceTable::new()
    }
}

impl ResourceTable {
    /// Creates a new `ResourceTable`
    pub fn new() -> ResourceTable {
        ResourceTable {
            network_table: IpNetworkTable::new(),
            id_table: HashMap::new(),
            dns_name: HashMap::new(),
        }
    }

    /// Gets the resource by ip
    pub fn get_by_ip(&self, ip: impl Into<IpAddr>) -> Option<&ResourceDescription> {
        // SAFETY: if we found the pointer, due to our internal consistency rules it is in the id_table
        self.network_table
            .longest_match(ip)
            .map(|m| unsafe { m.1.as_ref() })
    }

    /// Gets the resource by id
    pub fn get_by_id(&self, id: &Id) -> Option<&ResourceDescription> {
        self.id_table.get(id)
    }

    // SAFETY: resource_description must still be in storage since we are going to reference it.
    unsafe fn remove_resource(&mut self, resource_description: NonNull<ResourceDescription>) {
        let id = {
            let res = resource_description.as_ref();
            match res {
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

    fn cleaup_resource(&mut self, resource_description: &ResourceDescription) {
        match resource_description {
            ResourceDescription::Dns(r) => {
                if let Some(res) = self.id_table.get(&r.id) {
                    // SAFETY: We are consistent that if the item exists on any of the containers it still exists in the storage
                    unsafe {
                        self.remove_resource(res.into());
                    }
                    // Don't use res after here
                }

                if let Some(res) = self.dns_name.remove(&r.address) {
                    // SAFETY: We are consistent that if the item exists on any of the containers it still exists in the storage
                    unsafe {
                        self.remove_resource(res);
                    }
                    // Don't use res after here
                }

                if let Some(res) = self.network_table.remove(r.ipv4) {
                    // SAFETY: We are consistent that if the item exists on any of the containers it still exists in the storage
                    unsafe {
                        self.remove_resource(res);
                    }
                }

                if let Some(res) = self.network_table.remove(r.ipv6) {
                    // SAFETY: We are consistent that if the item exists on any of the containers it still exists in the storage
                    unsafe {
                        self.remove_resource(res);
                    }
                }
            }
            ResourceDescription::Cidr(r) => {
                if let Some(res) = self.id_table.get(&r.id) {
                    // SAFETY: We are consistent that if the item exists on any of the containers it still exists in the storage
                    unsafe {
                        self.remove_resource(res.into());
                    }
                    // Don't use res after here
                }

                if let Some(res) = self.network_table.remove(r.address) {
                    // SAFETY: We are consistent that if the item exists on any of the containers it still exists in the storage
                    unsafe {
                        self.remove_resource(res);
                    }
                }
            }
        }
    }

    // For soundness it's very important that this API only takes a resource_description
    // doing this, we can assume that when removing a resource from the id table we have all the info
    // about all the o
    /// Inserts a new resource_description
    ///
    /// If the id was used previously the old value will be deleted.
    /// Same goes if any of the ip matches exactly an old ip or dns name.
    /// This means that a match in IP or dns name will discard all old values.
    ///
    /// This is done so that we don't have dangling values.
    pub fn insert(&mut self, resource_description: ResourceDescription) {
        self.cleaup_resource(&resource_description);
        let id = resource_description.id();
        self.id_table.insert(id, resource_description);
        // we just inserted it we can unwrap
        let res = self.id_table.get(&id).unwrap();
        match res {
            ResourceDescription::Dns(r) => {
                self.network_table.insert(r.ipv4, res.into());
                self.network_table.insert(r.ipv6, res.into());
                self.dns_name.insert(r.address.clone(), res.into());
            }
            ResourceDescription::Cidr(r) => {
                self.network_table.insert(r.address, res.into());
            }
        }
    }
}
