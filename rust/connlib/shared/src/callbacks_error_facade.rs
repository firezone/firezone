use ip_network::{Ipv4Network, Ipv6Network};

use crate::messages::ResourceDescription;
use crate::{Callbacks, Error, Result};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::PathBuf;

// Avoids having to map types for Windows
type RawFd = i32;

#[derive(Clone)]
pub struct CallbackErrorFacade<CB>(pub CB);

impl<CB: Callbacks> Callbacks for CallbackErrorFacade<CB> {
    type Error = Error;

    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_addresses: Vec<IpAddr>,
    ) -> Result<Option<RawFd>> {
        let result = self
            .0
            .on_set_interface_config(tunnel_address_v4, tunnel_address_v6, dns_addresses)
            .map_err(|err| Error::OnSetInterfaceConfigFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!(?err);
        }
        result
    }

    fn on_tunnel_ready(&self) -> Result<()> {
        let result = self
            .0
            .on_tunnel_ready()
            .map_err(|err| Error::OnTunnelReadyFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!(?err);
        }
        result
    }

    fn on_update_routes(
        &self,
        routes4: Vec<Ipv4Network>,
        routes6: Vec<Ipv6Network>,
    ) -> Result<Option<RawFd>> {
        let result = self
            .0
            .on_update_routes(routes4, routes6)
            .map_err(|err| Error::OnUpdateRoutesFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!(?err);
        }
        result
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceDescription>) -> Result<()> {
        let result = self
            .0
            .on_update_resources(resource_list)
            .map_err(|err| Error::OnUpdateResourcesFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!(?err);
        }
        result
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<()> {
        if let Err(err) = self.0.on_disconnect(error) {
            tracing::error!(?err, "`on_disconnect` failed");
        }
        // There's nothing we can really do if `on_disconnect` fails.
        Ok(())
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.0.roll_log_file()
    }

    fn get_system_default_resolvers(
        &self,
    ) -> std::result::Result<Option<Vec<IpAddr>>, Self::Error> {
        self.0
            .get_system_default_resolvers()
            .map_err(|err| Error::GetSystemDefaultResolverFailed(err.to_string()))
    }

    #[cfg(target_os = "android")]
    fn protect_file_descriptor(&self, file_descriptor: std::os::fd::RawFd) -> Result<()> {
        self.0
            .protect_file_descriptor(file_descriptor)
            .map_err(|err| Error::ProtectFileDescriptorFailed(err.to_string()))
    }
}
