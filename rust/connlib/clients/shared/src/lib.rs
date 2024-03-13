//! Main connlib library for clients.
pub use connlib_shared::messages::ResourceDescription;
pub use connlib_shared::{keypair, Callbacks, Error, LoginUrl, LoginUrlError, StaticSecret};
pub use tracing_appender::non_blocking::WorkerGuard;

use backoff::ExponentialBackoffBuilder;
use connlib_shared::{get_user_agent, CallbackErrorFacade};
use firezone_tunnel::Tunnel;
use phoenix_channel::PhoenixChannel;
use std::time::Duration;

mod eventloop;
pub mod file_logger;
mod messages;

const PHOENIX_TOPIC: &str = "client";

use eventloop::Command;
pub use eventloop::Eventloop;
use secrecy::Secret;
use tokio::task::JoinHandle;

/// Max interval to retry connections to the portal if it's down or the client has network
/// connectivity changes. Set this to something short so that the end-user experiences
/// minimal disruption to their Firezone resources when switching networks.
const MAX_RECONNECT_INTERVAL: Duration = Duration::from_secs(5);

/// A session is the entry-point for connlib, maintains the runtime and the tunnel.
///
/// A session is created using [Session::connect], then to stop a session we use [Session::disconnect].
pub struct Session {
    channel: tokio::sync::mpsc::Sender<Command>,
    _runtime: tokio::runtime::Runtime,
}

impl Session {
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
    ///
    /// * `device_id` - The cleartext device ID. connlib will obscure this with a hash internally.
    // TODO: token should be something like SecretString but we need to think about FFI compatibility
    pub fn connect<CB: Callbacks + 'static>(
        url: LoginUrl,
        private_key: StaticSecret,
        os_version_override: Option<String>,
        callbacks: CB,
        max_partition_time: Option<Duration>,
    ) -> connlib_shared::Result<Self> {
        // TODO: We could use tokio::runtime::current() to get the current runtime
        // which could work with swift-rust that already runs a runtime. But IDK if that will work
        // in all platforms, a couple of new threads shouldn't bother none.
        // Big question here however is how do we get the result? We could block here await the result and spawn a new task.
        // but then platforms should know that this function is blocking.

        let callbacks = CallbackErrorFacade(callbacks);
        let (tx, rx) = tokio::sync::mpsc::channel(1);

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;

        let connect_handle = runtime.spawn(connect(
            url,
            private_key,
            os_version_override,
            callbacks.clone(),
            max_partition_time,
            rx,
        ));
        runtime.spawn(connect_supervisor(connect_handle, callbacks));

        Ok(Self {
            channel: tx,
            _runtime: runtime,
        })
    }

    /// Disconnect a [`Session`].
    ///
    /// This consumes [`Session`] which cleans up all state associated with it.
    pub fn disconnect(self) {
        let _ = self.channel.try_send(Command::Stop);
    }
}

/// Connects to the portal and starts a tunnel.
///
/// When this function exits, the tunnel failed unrecoverably and you need to call it again.
async fn connect<CB>(
    url: LoginUrl,
    private_key: StaticSecret,
    os_version_override: Option<String>,
    callbacks: CB,
    max_partition_time: Option<Duration>,
    rx: tokio::sync::mpsc::Receiver<Command>,
) -> Result<(), Error>
where
    CB: Callbacks + 'static,
{
    let tunnel = Tunnel::new(private_key, callbacks.clone())?;

    let portal = PhoenixChannel::connect(
        Secret::new(url),
        get_user_agent(os_version_override),
        PHOENIX_TOPIC,
        (),
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(max_partition_time)
            .with_max_interval(MAX_RECONNECT_INTERVAL)
            .build(),
    );

    let mut eventloop = Eventloop::new(tunnel, portal, rx);

    std::future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .map_err(Error::PortalConnectionFailed)?;

    Ok(())
}

/// A supervisor task that handles, when [`connect`] exits.
async fn connect_supervisor<CB>(connect_handle: JoinHandle<Result<(), Error>>, callbacks: CB)
where
    CB: Callbacks,
{
    match connect_handle.await {
        Ok(Ok(())) => {
            tracing::info!("connlib exited gracefully");
        }
        Ok(Err(e)) => {
            tracing::error!("connlib failed: {e}");
            let _ = callbacks.on_disconnect(&e);
        }
        Err(e) => match e.try_into_panic() {
            Ok(panic) => {
                if let Some(msg) = panic.downcast_ref::<&str>() {
                    let _ = callbacks.on_disconnect(&Error::Panic(msg.to_string()));
                    return;
                }

                let _ = callbacks.on_disconnect(&Error::PanicNonStringPayload);
            }
            Err(_) => {
                tracing::error!("connlib task was cancelled");
                let _ = callbacks.on_disconnect(&Error::Cancelled);
            }
        },
    }
}
