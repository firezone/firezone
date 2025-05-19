use connlib_model::ResourceView;
use dns_types::DomainName;
use ip_network::{Ipv4Network, Ipv6Network};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Arc,
};
use tokio::sync::mpsc;

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
        _: Option<DomainName>,
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
#[error("{0:#}")]
pub struct DisconnectError(anyhow::Error);

impl From<anyhow::Error> for DisconnectError {
    fn from(e: anyhow::Error) -> Self {
        Self(e)
    }
}

impl DisconnectError {
    pub fn is_authentication_error(&self) -> bool {
        let Some(e) = self.0.downcast_ref::<phoenix_channel::Error>() else {
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
        search_domain: Option<DomainName>,
        route_list_4: Vec<Ipv4Network>,
        route_list_6: Vec<Ipv6Network>,
    ) {
        let callbacks = self.inner.clone();

        self.threadpool.spawn(move || {
            callbacks.on_set_interface_config(
                ipv4_addr,
                ipv6_addr,
                dns_addresses,
                search_domain,
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

/// Messages that connlib can produce and send to the headless Client, Tunnel service, or GUI process.
///
/// i.e. callbacks
// The names are CamelCase versions of the connlib callbacks.
#[expect(clippy::enum_variant_names)]
pub enum ConnlibMsg {
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    /// Use this as `TunnelReady`, per `callbacks.rs`
    OnSetInterfaceConfig {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
        search_domain: Option<DomainName>,
        ipv4_routes: Vec<Ipv4Network>,
        ipv6_routes: Vec<Ipv6Network>,
    },
    OnUpdateResources(Vec<ResourceView>),
}

#[derive(Clone)]
pub struct ChannelCallbackHandler {
    cb_tx: mpsc::Sender<ConnlibMsg>,
}

impl ChannelCallbackHandler {
    pub fn new() -> (Self, mpsc::Receiver<ConnlibMsg>) {
        let (cb_tx, cb_rx) = mpsc::channel(1_000);

        (Self { cb_tx }, cb_rx)
    }
}

impl Callbacks for ChannelCallbackHandler {
    fn on_disconnect(&self, error: DisconnectError) {
        self.cb_tx
            .try_send(ConnlibMsg::OnDisconnect {
                error_msg: error.to_string(),
                is_authentication_error: error.is_authentication_error(),
            })
            .expect("should be able to send OnDisconnect");
    }

    fn on_set_interface_config(
        &self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
        search_domain: Option<DomainName>,
        ipv4_routes: Vec<Ipv4Network>,
        ipv6_routes: Vec<Ipv6Network>,
    ) {
        self.cb_tx
            .try_send(ConnlibMsg::OnSetInterfaceConfig {
                ipv4,
                ipv6,
                dns,
                search_domain,
                ipv4_routes,
                ipv6_routes,
            })
            .expect("Should be able to send OnSetInterfaceConfig");
    }

    fn on_update_resources(&self, resources: Vec<ResourceView>) {
        tracing::debug!(len = resources.len(), "New resource list");
        self.cb_tx
            .try_send(ConnlibMsg::OnUpdateResources(resources))
            .expect("Should be able to send OnUpdateResources");
    }
}

#[cfg(test)]
mod tests {
    use phoenix_channel::StatusCode;

    use super::*;

    #[test]
    fn printing_disconnect_error_contains_401() {
        let disconnect_error = DisconnectError::from(anyhow::Error::new(
            phoenix_channel::Error::Client(StatusCode::UNAUTHORIZED),
        ));

        assert!(disconnect_error.to_string().contains("401 Unauthorized")); // Apple client relies on this.
    }

    // Make sure it's okay to store a bunch of these to mitigate #5880
    #[test]
    fn callback_msg_size() {
        assert_eq!(std::mem::size_of::<ConnlibMsg>(), 120)
    }
}
