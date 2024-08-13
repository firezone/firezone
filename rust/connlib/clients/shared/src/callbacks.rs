use connlib_shared::callbacks::ResourceDescription;
use firezone_tunnel::NoInterfaces;
use ip_network::{Ipv4Network, Ipv6Network};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Traits that will be used by connlib to callback the client upper layers.
pub trait Callbacks: Clone + Send + Sync {
    /// Called when the tunnel address is set.
    ///
    /// The first time this is called, the Resources list is also ready,
    /// the routes are also ready, and the Client can consider the tunnel
    /// to be ready for incoming traffic.
    fn on_set_interface_config(&self, _: Ipv4Addr, _: Ipv6Addr, _: Vec<IpAddr>) {}

    /// Called when the route list changes.
    fn on_update_routes(&self, _: Vec<Ipv4Network>, _: Vec<Ipv6Network>) {}

    /// Called when the resource list changes.
    ///
    /// This may not be called if a Client has no Resources, which can
    /// happen to new accounts, or when removing and re-adding Resources,
    /// or if all Resources for a user are disabled by policy.
    fn on_update_resources(&self, _: Vec<ResourceDescription>) {}

    /// Called when the tunnel is disconnected.
    ///
    /// If the tunnel disconnected due to a fatal error, `error` is the error
    /// that caused the disconnect.
    fn on_disconnect(&self, error: &DisconnectError) {
        tracing::error!(error = ?error, "tunnel_disconnected");
        // Note that we can't panic here, since we already hooked the panic to this function.
        std::process::exit(0);
    }
}

/// Unified error type to use across connlib.
#[derive(thiserror::Error, Debug)]
pub enum DisconnectError {
    /// Failed to bind to interfaces.
    #[error(transparent)]
    NoInterfaces(#[from] NoInterfaces),
    /// A panic occurred.
    #[error("Connlib panicked: {0}")]
    Panic(String),
    /// The task was cancelled
    #[error("Connlib task was cancelled")]
    Cancelled,
    /// A panic occurred with a non-string payload.
    #[error("Panicked with a non-string payload")]
    PanicNonStringPayload,

    #[error("connection to the portal failed: {0}")]
    PortalConnectionFailed(#[from] phoenix_channel::Error),
}
