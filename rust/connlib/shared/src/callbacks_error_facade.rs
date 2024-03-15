use crate::callbacks::{Cidrv4, Cidrv6};
use crate::messages::ResourceDescription;
use crate::{Callbacks, Error};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::PathBuf;

// Avoids having to map types for Windows
type RawFd = i32;

#[derive(Clone)]
pub struct CallbackErrorFacade<CB>(pub CB);

impl<CB: Callbacks> Callbacks for CallbackErrorFacade<CB> {
    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_addresses: Vec<IpAddr>,
    ) -> Option<RawFd> {
        self.0
            .on_set_interface_config(tunnel_address_v4, tunnel_address_v6, dns_addresses)
    }

    fn on_tunnel_ready(&self) {
        self.0.on_tunnel_ready()
    }

    fn on_update_routes(&self, routes4: Vec<Cidrv4>, routes6: Vec<Cidrv6>) -> Option<RawFd> {
        self.0.on_update_routes(routes4, routes6)
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceDescription>) {
        self.0.on_update_resources(resource_list)
    }

    fn on_disconnect(&self, error: &Error) {
        self.0.on_disconnect(error)
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.0.roll_log_file()
    }

    fn get_system_default_resolvers(&self) -> Option<Vec<IpAddr>> {
        self.0.get_system_default_resolvers()
    }

    #[cfg(target_os = "android")]
    fn protect_file_descriptor(&self, file_descriptor: std::os::fd::RawFd) {
        self.0.protect_file_descriptor(file_descriptor)
    }
}
