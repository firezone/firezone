use crate::messages::ResourceDescription;
use ip_network::IpNetwork;
use std::error::Error;
use std::fmt::{Debug, Display};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::PathBuf;

// Avoids having to map types for Windows
type RawFd = i32;

/// Traits that will be used by connlib to callback the client upper layers.
pub trait Callbacks: Clone + Send + Sync {
    /// Error returned when a callback fails.
    type Error: Debug + Display + Error;

    /// Called when the tunnel address is set.
    ///
    /// This should return a new `fd` if there is one.
    /// (Only happens on android for now)
    fn on_set_interface_config(
        &self,
        _: Ipv4Addr,
        _: Ipv6Addr,
        _: Vec<IpAddr>,
    ) -> Result<Option<RawFd>, Self::Error> {
        Ok(None)
    }

    /// Called when the tunnel is connected.
    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        tracing::trace!("tunnel_connected");
        Ok(())
    }

    /// Called when when a route is added.
    ///
    /// This should return a new `fd` if there is one.
    /// (Only happens on android for now)
    fn on_add_route(&self, _: IpNetwork) -> Result<Option<RawFd>, Self::Error> {
        Ok(None)
    }

    /// Called when when a route is removed.
    fn on_remove_route(&self, _: IpNetwork) -> Result<Option<RawFd>, Self::Error> {
        Ok(None)
    }

    /// Called when the resource list changes.
    fn on_update_resources(
        &self,
        resource_list: Vec<ResourceDescription>,
    ) -> Result<(), Self::Error> {
        tracing::trace!(?resource_list, "resource_updated");
        Ok(())
    }

    /// Called when the tunnel is disconnected.
    ///
    /// If the tunnel disconnected due to a fatal error, `error` is the error
    /// that caused the disconnect.
    fn on_disconnect(&self, error: Option<&crate::Error>) -> Result<(), Self::Error> {
        tracing::trace!(error = ?error, "tunnel_disconnected");
        // Note that we can't panic here, since we already hooked the panic to this function.
        std::process::exit(0);
    }

    /// Returns the system's default resolver(s)
    ///
    /// It's okay for clients to include Firezone's own DNS here, e.g. 100.100.111.1.
    /// connlib internally filters them out.
    fn get_system_default_resolvers(&self) -> Result<Option<Vec<IpAddr>>, Self::Error> {
        Ok(None)
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        None
    }
}
