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

struct StopRuntime;

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
    runtime_stopper: tokio::sync::mpsc::Sender<StopRuntime>,
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
        let (tx, mut rx) = tokio::sync::mpsc::channel(1);

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
        ));

        std::thread::spawn(move || {
            rx.blocking_recv();
            runtime.shutdown_background();
        });

        Ok(Self {
            runtime_stopper: tx,
        })
    }

    fn disconnect_inner<CB: Callbacks + 'static>(
        runtime_stopper: tokio::sync::mpsc::Sender<StopRuntime>,
        callbacks: &CallbackErrorFacade<CB>,
        error: Option<Error>,
    ) {
        // 1. Close the websocket connection
        // 2. Free the device handle (Linux)
        // 3. Close the file descriptor (Linux/Android)
        // 4. Remove the mapping

        // The way we cleanup the tasks is we drop the runtime
        // this means we don't need to keep track of different tasks
        // but if any of the tasks never yields this will block forever!
        // So always yield and if you spawn a blocking tasks rewrite this.
        // Furthermore, we will depend on Drop impls to do the list above so,
        // implement them :)
        // if there's no receiver the runtime is already stopped
        // there's an edge case where this is called before the thread is listening for stop threads.
        // but I believe in that case the channel will be in a signaled state achieving the same result

        if let Err(err) = runtime_stopper.try_send(StopRuntime) {
            tracing::error!("Couldn't stop runtime: {err}");
        }

        if let Some(error) = error {
            let _ = callbacks.on_disconnect(&error);
        }
    }

    /// Cleanup a [Session].
    ///
    /// For now this just drops the runtime, which should drop all pending tasks.
    /// Further cleanup should be done here. (Otherwise we can just drop [Session]).
    pub fn disconnect(&mut self) {
        if let Err(err) = self.runtime_stopper.try_send(StopRuntime) {
            tracing::error!("Couldn't stop runtime: {err}");
        }
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

    let mut eventloop = Eventloop::new(tunnel, portal);

    match std::future::poll_fn(|cx| eventloop.poll(cx)).await {
        Ok(never) => match never {},
        Err(e) => {
            tracing::error!("Eventloop failed: {e}");
            let _ = callbacks.on_disconnect(&Error::PortalConnectionFailed); // TMP Error until we have a narrower API for `onDisconnect`
        }
    }
}
