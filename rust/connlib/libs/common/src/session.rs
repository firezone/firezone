use async_trait::async_trait;
use backoff::{backoff::Backoff, ExponentialBackoffBuilder};
use boringtun::x25519::{PublicKey, StaticSecret};
use ip_network::IpNetwork;
use parking_lot::Mutex;
use rand::{distributions::Alphanumeric, thread_rng, Rng};
use rand_core::OsRng;
use std::{
    error::Error as StdError,
    fmt::{Debug, Display},
    marker::PhantomData,
    net::{Ipv4Addr, Ipv6Addr},
    result::Result as StdResult,
    sync::Arc,
    time::Duration,
};
use tokio::{runtime::Runtime, sync::mpsc::Receiver};
use url::Url;
use uuid::Uuid;

use crate::{
    control::{MessageResult, PhoenixChannel, PhoenixSenderWithTopic},
    messages::{Key, ResourceDescription, ResourceDescriptionCidr},
    Error, Result,
};

pub const DNS_SENTINEL: Ipv4Addr = Ipv4Addr::new(100, 100, 111, 1);

// TODO: Not the most tidy trait for a control-plane.
/// Trait that represents a control-plane.
#[async_trait]
pub trait ControlSession<T, CB: Callbacks> {
    /// Start control-plane with the given private-key in the background.
    async fn start(
        private_key: StaticSecret,
        receiver: Receiver<MessageResult<T>>,
        control_signal: PhoenixSenderWithTopic,
        callbacks: CB,
    ) -> Result<()>;

    /// Either "gateway" or "client" used to get the control-plane URL.
    fn socket_path() -> &'static str;
}

// TODO: Currently I'm using Session for both gateway and clients
// however, gateway could use the runtime directly and could make things easier
// so revisit this.
/// A session is the entry-point for connlib, maintains the runtime and the tunnel.
///
/// A session is created using [Session::connect], then to stop a session we use [Session::disconnect].
pub struct Session<T, U, V, R, M, CB: Callbacks> {
    runtime: Arc<Mutex<Option<Runtime>>>,
    callbacks: CallbackErrorFacade<CB>,
    _phantom: PhantomData<(T, U, V, R, M)>,
}

/// Traits that will be used by connlib to callback the client upper layers.
pub trait Callbacks: Clone + Send + Sync {
    /// Error returned when a callback fails.
    type Error: Debug + Display + StdError;

    /// Called when the tunnel address is set.
    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_address: Ipv4Addr,
    ) -> StdResult<(), Self::Error>;
    /// Called when the tunnel is connected.
    fn on_tunnel_ready(&self) -> StdResult<(), Self::Error>;
    /// Called when when a route is added.
    fn on_add_route(&self, route: IpNetwork) -> StdResult<(), Self::Error>;
    /// Called when when a route is removed.
    fn on_remove_route(&self, route: IpNetwork) -> StdResult<(), Self::Error>;
    /// Called when the resource list changes.
    fn on_update_resources(
        &self,
        resource_list: Vec<ResourceDescription>,
    ) -> StdResult<(), Self::Error>;
    /// Called when the tunnel is disconnected.
    ///
    /// If the tunnel disconnected due to a fatal error, `error` is the error
    /// that caused the disconnect.
    fn on_disconnect(&self, error: Option<&Error>) -> StdResult<(), Self::Error>;
    /// Called when there's a recoverable error.
    fn on_error(&self, error: &Error) -> StdResult<(), Self::Error>;
}

#[derive(Clone)]
pub struct CallbackErrorFacade<CB: Callbacks>(pub CB);

impl<CB: Callbacks> Callbacks for CallbackErrorFacade<CB> {
    type Error = Error;

    fn on_set_interface_config(
        &self,
        tunnel_address_v4: Ipv4Addr,
        tunnel_address_v6: Ipv6Addr,
        dns_address: Ipv4Addr,
    ) -> Result<()> {
        let result = self
            .0
            .on_set_interface_config(tunnel_address_v4, tunnel_address_v6, dns_address)
            .map_err(|err| Error::OnSetInterfaceConfigFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!("{err}");
        }
        result
    }

    fn on_tunnel_ready(&self) -> Result<()> {
        let result = self
            .0
            .on_tunnel_ready()
            .map_err(|err| Error::OnTunnelReadyFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!("{err}");
        }
        result
    }

    fn on_add_route(&self, route: IpNetwork) -> Result<()> {
        let result = self
            .0
            .on_add_route(route)
            .map_err(|err| Error::OnAddRouteFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!("{err}");
        }
        result
    }

    fn on_remove_route(&self, route: IpNetwork) -> Result<()> {
        let result = self
            .0
            .on_remove_route(route)
            .map_err(|err| Error::OnRemoveRouteFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!("{err}");
        }
        result
    }

    fn on_update_resources(&self, resource_list: Vec<ResourceDescription>) -> Result<()> {
        let result = self
            .0
            .on_update_resources(resource_list)
            .map_err(|err| Error::OnUpdateResourcesFailed(err.to_string()));
        if let Err(err) = result.as_ref() {
            tracing::error!("{err}");
        }
        result
    }

    fn on_disconnect(&self, error: Option<&Error>) -> Result<()> {
        if let Err(err) = self.0.on_disconnect(error) {
            tracing::error!("`on_disconnect` failed: {err}");
        }
        // There's nothing we can really do if `on_disconnect` fails.
        Ok(())
    }

    fn on_error(&self, error: &Error) -> Result<()> {
        if let Err(err) = self.0.on_error(error) {
            tracing::error!("`on_error` failed: {err}");
        }
        // There's nothing we really want to do if `on_error` fails.
        Ok(())
    }
}

macro_rules! fatal_error {
    ($result:expr, $rt:expr, $cb:expr) => {
        match $result {
            Ok(res) => res,
            Err(err) => {
                Self::disconnect_inner($rt, $cb, Some(err));
                return;
            }
        }
    };
}

impl<T, U, V, R, M, CB> Session<T, U, V, R, M, CB>
where
    T: ControlSession<M, CB>,
    U: for<'de> serde::Deserialize<'de> + std::fmt::Debug + Send + 'static,
    R: for<'de> serde::Deserialize<'de> + std::fmt::Debug + Send + 'static,
    V: serde::Serialize + Send + 'static,
    M: From<U> + From<R> + Send + 'static + std::fmt::Debug,
    CB: Callbacks + 'static,
{
    /// Block on waiting for ctrl+c to terminate the runtime.
    /// (Used for the gateways).
    pub fn wait_for_ctrl_c(&mut self) -> Result<()> {
        self.runtime
            .lock()
            .as_ref()
            .ok_or(Error::NoRuntime)?
            .block_on(async {
                tokio::signal::ctrl_c().await?;
                Ok(())
            })
    }

    /// Starts a session in the background.
    ///
    /// This will:
    /// 1. Create and start a tokio runtime
    /// 2. Connect to the control plane to the portal
    /// 3. Start the tunnel in the background and forward control plane messages to it.
    ///
    /// The generic parameter `CB` should implement all the handlers and that's how errors will be surfaced.
    ///
    /// On a fatal error you should call `[Session::disconnect]` and start a new one.
    // TODO: token should be something like SecretString but we need to think about FFI compatibility
    pub fn connect(portal_url: impl TryInto<Url>, token: String, callbacks: CB) -> Result<Self> {
        // TODO: We could use tokio::runtime::current() to get the current runtime
        // which could work with swif-rust that already runs a runtime. But IDK if that will work
        // in all pltaforms, a couple of new threads shouldn't bother none.
        // Big question here however is how do we get the result? We could block here await the result and spawn a new task.
        // but then platforms should know that this function is blocking.

        let callbacks = CallbackErrorFacade(callbacks);
        let this = Self {
            runtime: Mutex::new(Some(
                tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()?,
            ))
            .into(),
            callbacks,
            _phantom: PhantomData,
        };

        {
            let runtime_disconnector = Arc::clone(&this.runtime);
            let callbacks = this.callbacks.clone();
            let default_panic_hook = std::panic::take_hook();
            std::panic::set_hook(Box::new(move |info| {
                let err = info
                    .payload()
                    .downcast_ref::<&str>()
                    .map(|s| Error::Panic(s.to_string()))
                    .unwrap_or(Error::PanicNonStringPayload);
                Self::disconnect_inner(&runtime_disconnector, &callbacks, Some(err));
                default_panic_hook(info);
            }));
        }

        if cfg!(feature = "mock") {
            Self::connect_mock(Arc::clone(&this.runtime), this.callbacks.clone());
        } else {
            Self::connect_inner(
                Arc::clone(&this.runtime),
                portal_url.try_into().map_err(|_| Error::UriError)?,
                token,
                this.callbacks.clone(),
            );
        }

        Ok(this)
    }

    fn connect_inner(
        runtime: Arc<Mutex<Option<Runtime>>>,
        portal_url: Url,
        token: String,
        callbacks: CallbackErrorFacade<CB>,
    ) {
        let runtime_disconnector = Arc::clone(&runtime);
        runtime.lock().as_ref().unwrap().spawn(async move {
            let private_key = StaticSecret::random_from_rng(OsRng);
            let self_id = uuid::Uuid::new_v4();
            let name_suffix: String = thread_rng().sample_iter(&Alphanumeric).take(8).map(char::from).collect();

            let connect_url = fatal_error!(
                get_websocket_path(portal_url, token, T::socket_path(), &Key(PublicKey::from(&private_key).to_bytes()), &self_id.to_string(), &name_suffix),
                &runtime_disconnector,
                &callbacks
            );


            // This is kinda hacky, the buffer size is 1 so that we make sure that we
            // process one message at a time, blocking if a previous message haven't been processed
            // to force queue ordering.
            let (control_plane_sender, control_plane_receiver) = tokio::sync::mpsc::channel(1);

            let mut connection = PhoenixChannel::<_, U, R, M>::new(connect_url, move |msg| {
                let control_plane_sender = control_plane_sender.clone();
                async move {
                    tracing::trace!("Received message: {msg:?}");
                    if let Err(e) = control_plane_sender.send(msg).await {
                        tracing::warn!("Received a message after handler already closed: {e}. Probably message received during session clean up.");
                    }
                }
            });

            // Used to send internal messages
            let topic = T::socket_path().to_string();
            let internal_sender = connection.sender_with_topic(topic.clone());
            fatal_error!(
                T::start(private_key, control_plane_receiver, internal_sender, callbacks.0.clone()).await,
                &runtime_disconnector,
                &callbacks
            );

            tokio::spawn(async move {
                let mut exponential_backoff = ExponentialBackoffBuilder::default().build();
                loop {
                    // `connection.start` calls the callback only after connecting
                    let result = connection.start(vec![topic.clone()], || exponential_backoff.reset()).await;
                    if let Some(t) = exponential_backoff.next_backoff() {
                        tracing::warn!("Error connecting to portal, retrying in {} seconds", t.as_secs());
                        let _ = callbacks.on_error(&result.err().unwrap_or(Error::PortalConnectionError(tokio_tungstenite::tungstenite::Error::ConnectionClosed)));
                        tokio::time::sleep(t).await;
                    } else {
                        tracing::error!("Connection to the portal error, check your internet or the status of the portal.\nDisconnecting interface.");
                        fatal_error!(
                            result.and(Err(Error::PortalConnectionError(tokio_tungstenite::tungstenite::Error::ConnectionClosed))),
                            &runtime_disconnector,
                            &callbacks
                        );
                    }
                }

            });

        });
    }

    fn connect_mock(runtime: Arc<Mutex<Option<Runtime>>>, callbacks: CallbackErrorFacade<CB>) {
        std::thread::sleep(Duration::from_secs(1));
        fatal_error!(
            callbacks.on_set_interface_config(
                "100.100.111.2".parse().unwrap(),
                "fd00:0222:2021:1111::2".parse().unwrap(),
                DNS_SENTINEL,
            ),
            &runtime,
            &callbacks
        );
        fatal_error!(callbacks.on_tunnel_ready(), &runtime, &callbacks);
        let handle = {
            let callbacks = callbacks.clone();
            std::thread::spawn(move || -> Result<()> {
                std::thread::sleep(Duration::from_secs(3));
                let resources = vec![
                    ResourceDescriptionCidr {
                        id: Uuid::new_v4(),
                        address: "8.8.4.4".parse::<Ipv4Addr>().unwrap().into(),
                        name: "Google Public DNS IPv4".to_string(),
                    },
                    ResourceDescriptionCidr {
                        id: Uuid::new_v4(),
                        address: "2001:4860:4860::8844".parse::<Ipv6Addr>().unwrap().into(),
                        name: "Google Public DNS IPv6".to_string(),
                    },
                ];
                for resource in &resources {
                    callbacks.on_add_route(resource.address)?;
                }
                callbacks.on_update_resources(
                    resources
                        .into_iter()
                        .map(ResourceDescription::Cidr)
                        .collect(),
                )
            })
        };
        fatal_error!(
            handle.join().expect("mock thread panicked"),
            &runtime,
            &callbacks
        );
    }

    fn disconnect_inner(
        runtime: &Mutex<Option<Runtime>>,
        callbacks: &CallbackErrorFacade<CB>,
        error: Option<Error>,
    ) {
        // 1. Close the websocket connection
        // 2. Free the device handle (UNIX)
        // 3. Close the file descriptor (UNIX)
        // 4. Remove the mapping

        // The way we cleanup the tasks is we drop the runtime
        // this means we don't need to keep track of different tasks
        // but if any of the tasks never yields this will block forever!
        // So always yield and if you spawn a blocking tasks rewrite this.
        // Furthermore, we will depend on Drop impls to do the list above so,
        // implement them :)
        *runtime.lock() = None;

        let _ = callbacks.on_disconnect(error.as_ref());
    }

    /// Cleanup a [Session].
    ///
    /// For now this just drops the runtime, which should drop all pending tasks.
    /// Further cleanup should be done here. (Otherwise we can just drop [Session]).
    pub fn disconnect(&mut self, error: Option<Error>) {
        Self::disconnect_inner(&self.runtime, &self.callbacks, error)
    }

    // TODO: See https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKitGo/api-apple.go#L177
    pub fn bump_sockets(&self) {
        tracing::error!("`bump_sockets` is unimplemented");
    }

    // TODO: See https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKitGo/api-apple.go#LL197C6-L197C50
    pub fn disable_some_roaming_for_broken_mobile_semantics(&self) {
        tracing::error!("`disable_some_roaming_for_broken_mobile_semantics` is unimplemented");
    }
}

fn set_ws_scheme(url: &mut Url) -> Result<()> {
    let scheme = match url.scheme() {
        "http" | "ws" => "ws",
        "https" | "wss" => "wss",
        _ => return Err(Error::UriScheme),
    };
    url.set_scheme(scheme)
        .expect("Developer error: the match before this should make sure we can set this");
    Ok(())
}

fn get_websocket_path(
    mut url: Url,
    secret: String,
    mode: &str,
    public_key: &Key,
    external_id: &str,
    name_suffix: &str,
) -> Result<Url> {
    set_ws_scheme(&mut url)?;

    {
        let mut paths = url.path_segments_mut().map_err(|_| Error::UriError)?;
        paths.pop_if_empty();
        paths.push(mode);
        paths.push("websocket");
    }

    {
        let mut query_pairs = url.query_pairs_mut();
        query_pairs.clear();
        query_pairs.append_pair("token", &secret);
        query_pairs.append_pair("public_key", &public_key.to_string());
        query_pairs.append_pair("external_id", external_id);
        query_pairs.append_pair("name_suffix", name_suffix);
    }

    Ok(url)
}
