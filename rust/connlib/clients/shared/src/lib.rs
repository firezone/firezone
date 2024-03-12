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

        // In android we get an stack-overflow due to tokio
        // taking too much of the stack-space:
        // See: https://github.com/firezone/firezone/issues/2227
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .thread_stack_size(3 * 1024 * 1024)
            .enable_all()
            .build()?;
        {
            let callbacks = callbacks.clone();
            let default_panic_hook = std::panic::take_hook();
            std::panic::set_hook(Box::new({
                let tx = tx.clone();
                move |info| {
                    let tx = tx.clone();
                    let err = info
                        .payload()
                        .downcast_ref::<&str>()
                        .map(|s| Error::Panic(s.to_string()))
                        .unwrap_or(Error::PanicNonStringPayload(
                            info.location().map(ToString::to_string),
                        ));
                    Self::disconnect_inner(tx, &callbacks, Some(err));
                    default_panic_hook(info);
                }
            }));
        }

        runtime.spawn(connect(
            url,
            private_key,
            os_version_override,
            callbacks,
            max_partition_time,
            rx,
        ));

        Ok(Self {
            channel: tx,
            _runtime: runtime,
        })
    }

    fn disconnect_inner<CB: Callbacks + 'static>(
        channel: tokio::sync::mpsc::Sender<Command>,
        callbacks: &CallbackErrorFacade<CB>,
        error: Option<Error>,
    ) {
        if let Err(err) = channel.try_send(Command::Stop) {
            tracing::error!("Couldn't stop eventloop: {err}");
        }

        if let Some(error) = error {
            let _ = callbacks.on_disconnect(&error);
        }
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
) where
    CB: Callbacks + 'static,
{
    let tunnel = match Tunnel::new(private_key, callbacks.clone()) {
        Ok(tunnel) => tunnel,
        Err(e) => {
            tracing::error!("Failed to make tunnel: {e}");
            let _ = callbacks.on_disconnect(&e);
            return;
        }
    };

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

    match std::future::poll_fn(|cx| eventloop.poll(cx)).await {
        Ok(()) => {} // `Ok(())` means the eventloop exited gracefully.
        Err(e) => {
            tracing::error!("Eventloop failed: {e}");
            let _ = callbacks.on_disconnect(&Error::PortalConnectionFailed); // TMP Error until we have a narrower API for `onDisconnect`
        }
    }
}
