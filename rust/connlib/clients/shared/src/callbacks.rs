use connlib_model::ResourceView;
use ip_network::{Ipv4Network, Ipv6Network};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Arc,
};

/// Traits that will be used by connlib to callback the client upper layers.
pub trait Callbacks: Clone + Send + Sync {
    /// Called when the tunnel address is set.
    ///
    /// The first time this is called, the Resources list is also ready,
    /// the routes are also ready, and the Client can consider the tunnel
    /// to be ready for incoming traffic.
    fn on_set_interface_config(
        &self,
        _: Ipv4Addr,
        _: Ipv6Addr,
        _: Vec<IpAddr>,
        _: Vec<Ipv4Network>,
        _: Vec<Ipv6Network>,
    ) {
    }

    /// Called when the resource list changes.
    ///
    /// This may not be called if a Client has no Resources, which can
    /// happen to new accounts, or when removing and re-adding Resources,
    /// or if all Resources for a user are disabled by policy.
    fn on_update_resources(&self, _: Vec<ResourceView>) {}

    /// Called when the tunnel is disconnected.
    fn on_disconnect(&self, _: DisconnectError) {}
}

/// Unified error type to use across connlib.
#[derive(thiserror::Error, Debug)]
pub enum DisconnectError {
    #[error("connlib crashed: {0}")]
    Crash(#[from] tokio::task::JoinError),

    #[error("connection to the portal failed: {0}")]
    PortalConnectionFailed(#[from] phoenix_channel::Error),
}

impl DisconnectError {
    pub fn is_authentication_error(&self) -> bool {
        let Self::PortalConnectionFailed(e) = self else {
            return false;
        };

        e.is_authentication_error()
    }
}

#[derive(Debug, Clone)]
pub struct BackgroundCallbacks<C> {
    inner: C,
    threadpool: Arc<rayon::ThreadPool>,
}

impl<C> BackgroundCallbacks<C> {
    pub fn new(callbacks: C) -> Self {
        Self {
            inner: callbacks,
            threadpool: Arc::new(
                rayon::ThreadPoolBuilder::new()
                    .num_threads(1)
                    .thread_name(|_| "connlib callbacks".to_owned())
                    .build()
                    .expect("Unable to create thread-pool"),
            ),
        }
    }
}

impl<C> Callbacks for BackgroundCallbacks<C>
where
    C: Callbacks + 'static,
{
    fn on_set_interface_config(
        &self,
        ipv4_addr: Ipv4Addr,
        ipv6_addr: Ipv6Addr,
        dns_addresses: Vec<IpAddr>,
        route_list_4: Vec<Ipv4Network>,
        route_list_6: Vec<Ipv6Network>,
    ) {
        let callbacks = self.inner.clone();

        self.threadpool.spawn(move || {
            callbacks.on_set_interface_config(
                ipv4_addr,
                ipv6_addr,
                dns_addresses,
                route_list_4,
                route_list_6,
            );
        });
    }

    fn on_update_resources(&self, resources: Vec<ResourceView>) {
        let callbacks = self.inner.clone();

        self.threadpool.spawn(move || {
            callbacks.on_update_resources(resources);
        });
    }

    fn on_disconnect(&self, error: DisconnectError) {
        let callbacks = self.inner.clone();

        self.threadpool.spawn(move || {
            callbacks.on_disconnect(error);
        });
    }
}
