use crate::messages::ResourceDescription;
use crate::{Callbacks, Error, Result, DNS_SENTINEL};
use ip_network::IpNetwork;
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
        dns_address: Ipv4Addr,
    ) -> Result<Option<RawFd>> {
        let result = self
            .0
            .on_set_interface_config(tunnel_address_v4, tunnel_address_v6, dns_address)
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

    fn on_add_route(&self, route: IpNetwork) -> Result<Option<RawFd>> {
        let result = self
            .0
            .on_add_route(route)
            .map_err(|err| Error::OnAddRouteFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!(?err);
        }
        result
    }

    fn on_remove_route(&self, route: IpNetwork) -> Result<Option<RawFd>> {
        let result = self
            .0
            .on_remove_route(route)
            .map_err(|err| Error::OnRemoveRouteFailed(err.to_string()));
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

    fn on_error(&self, error: &Error) -> Result<()> {
        if let Err(err) = self.0.on_error(error) {
            tracing::error!(?err, "`on_error` failed");
        }
        // There's nothing we really want to do if `on_error` fails.
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
            .map(|resolvers| {
                if let Some(mut resolvers) = resolvers {
                    resolvers.retain(|resolver| {
                        if *resolver == DNS_SENTINEL {
                            tracing::warn!("Found our DNS Sentinel {:?} in the list of returned system resolvers. Ignoring...", resolver);
                            // Remove the sentinel from the list of resolvers
                            false
                        } else {
                            true
                        }
                    });

                    Some(resolvers)
                } else {
                    Some(vec![])
                }
            })
    }
}
