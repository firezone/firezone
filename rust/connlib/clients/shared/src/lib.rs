//! Main connlib library for clients.
pub use connlib_shared::messages::ResourceDescription;
pub use connlib_shared::{Callbacks, Error};
pub use tracing_appender::non_blocking::WorkerGuard;

use backoff::{backoff::Backoff, ExponentialBackoffBuilder};
use connlib_shared::control::SecureUrl;
use connlib_shared::{control::PhoenixChannel, login_url, CallbackErrorFacade, Mode, Result};
use control::ControlPlane;
use firezone_tunnel::Tunnel;
use messages::IngressMessages;
use messages::Messages;
use messages::ReplyMessages;
use secrecy::{Secret, SecretString};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::{Interval, MissedTickBehavior};
use tokio::{runtime::Runtime, sync::Mutex, time::Instant};
use url::Url;

mod control;
pub mod file_logger;
mod messages;

struct StopRuntime;

/// Max interval to retry connections to the portal if it's down or the client has network
/// connectivity changes. Set this to something short so that the end-user experiences
/// minimal disruption to their Firezone resources when switching networks.
const MAX_RECONNECT_INTERVAL: Duration = Duration::from_secs(5);

/// A session is the entry-point for connlib, maintains the runtime and the tunnel.
///
/// A session is created using [Session::connect], then to stop a session we use [Session::disconnect].
pub struct Session<CB: Callbacks> {
    runtime_stopper: tokio::sync::mpsc::Sender<StopRuntime>,
    pub callbacks: CallbackErrorFacade<CB>,
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

impl<CB> Session<CB>
where
    CB: Callbacks + 'static,
{
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
    pub fn connect(
        api_url: impl TryInto<Url>,
        token: SecretString,
        device_id: String,
        device_name_override: Option<String>,
        os_version_override: Option<String>,
        callbacks: CB,
        max_partition_time: Option<Duration>,
    ) -> Result<Self> {
        // TODO: We could use tokio::runtime::current() to get the current runtime
        // which could work with swift-rust that already runs a runtime. But IDK if that will work
        // in all platforms, a couple of new threads shouldn't bother none.
        // Big question here however is how do we get the result? We could block here await the result and spawn a new task.
        // but then platforms should know that this function is blocking.

        let callbacks = CallbackErrorFacade(callbacks);
        let (tx, mut rx) = tokio::sync::mpsc::channel(1);
        let this = Self {
            runtime_stopper: tx.clone(),
            callbacks,
        };
        // In android we get an stack-overflow due to tokio
        // taking too much of the stack-space:
        // See: https://github.com/firezone/firezone/issues/2227
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .thread_stack_size(3 * 1024 * 1024)
            .enable_all()
            .build()?;
        {
            let callbacks = this.callbacks.clone();
            let default_panic_hook = std::panic::take_hook();
            std::panic::set_hook(Box::new({
                let tx = tx.clone();
                move |info| {
                    let tx = tx.clone();
                    let err = info
                        .payload()
                        .downcast_ref::<&str>()
                        .map(|s| Error::Panic(s.to_string()))
                        .unwrap_or(Error::PanicNonStringPayload);
                    eprintln!("Panicking: {err}");
                    eprintln!("Panic payload: {:?}", info.payload());
                    Self::disconnect_inner(tx, &callbacks, Some(err));
                    default_panic_hook(info);
                }
            }));
        }

        Self::connect_inner(
            &runtime,
            tx,
            api_url.try_into().map_err(|_| Error::UriError)?,
            token,
            device_id,
            device_name_override,
            os_version_override,
            this.callbacks.clone(),
            max_partition_time,
        );
        std::thread::spawn(move || {
            rx.blocking_recv();
            runtime.shutdown_background();
        });

        Ok(this)
    }

    // TODO: Refactor this when we refactor PhoenixChannel.
    // See https://github.com/firezone/firezone/issues/2158
    #[allow(clippy::too_many_arguments)]
    fn connect_inner(
        runtime: &Runtime,
        runtime_stopper: tokio::sync::mpsc::Sender<StopRuntime>,
        api_url: Url,
        token: SecretString,
        device_id: String,
        device_name_override: Option<String>,
        os_version_override: Option<String>,
        callbacks: CallbackErrorFacade<CB>,
        max_partition_time: Option<Duration>,
    ) {
        runtime.spawn(async move {
            let (connect_url, private_key) = fatal_error!(
                login_url(Mode::Client, api_url, token, device_id, device_name_override),
                runtime_stopper,
                &callbacks
            );

            // This is kinda hacky, the buffer size is 1 so that we make sure that we
            // process one message at a time, blocking if a previous message haven't been processed
            // to force queue ordering.
            let (control_plane_sender, mut control_plane_receiver) = tokio::sync::mpsc::channel(1);

            let mut connection = PhoenixChannel::<_, IngressMessages, ReplyMessages, Messages>::new(Secret::new(SecureUrl::from_url(connect_url)), os_version_override, move |msg, reference, topic| {
                let control_plane_sender = control_plane_sender.clone();
                async move {
                    tracing::trace!(?msg);
                    if let Err(e) = control_plane_sender.send((msg, reference, topic)).await {
                        tracing::warn!("Received a message after handler already closed: {e}. Probably message received during session clean up.");
                    }
                }
            });

            let tunnel = fatal_error!(
                Tunnel::new(private_key, callbacks.clone()).await,
                runtime_stopper,
                &callbacks
            );

            let mut control_plane = ControlPlane {
                tunnel: Arc::new(tunnel),
                phoenix_channel: connection.sender_with_topic("client".to_owned()),
                tunnel_init: Mutex::new(false),
                fallback_resolver: parking_lot::Mutex::new(HashMap::new()),
            };

            tokio::spawn({
                let runtime_stopper = runtime_stopper.clone();
                let callbacks = callbacks.clone();
                async move {
                let mut log_stats_interval = tokio::time::interval(Duration::from_secs(10));
                let mut upload_logs_interval = upload_interval();
                loop {
                    tokio::select! {
                        Some((msg, reference, topic)) = control_plane_receiver.recv() => {
                            match msg {
                                Ok(msg) => control_plane.handle_message(msg, reference).await?,
                                Err(err) => {
                                    if let Err(e) = control_plane.handle_error(err, reference, topic).await {
                                        Self::disconnect_inner(runtime_stopper, &callbacks, Some(e));
                                        break;
                                    }
                                },
                            }
                        },
                        event = control_plane.tunnel.next_event() => control_plane.handle_tunnel_event(event).await,
                        _ = log_stats_interval.tick() => control_plane.stats_event().await,
                        _ = upload_logs_interval.tick() => control_plane.request_log_upload_url().await,
                        else => break
                    }
                }

                Result::Ok(())
            }});

            tokio::spawn(async move {
                let mut exponential_backoff = ExponentialBackoffBuilder::default().with_max_elapsed_time(max_partition_time).with_max_interval(MAX_RECONNECT_INTERVAL).build();
                loop {
                    // `connection.start` calls the callback only after connecting
                    tracing::debug!("Attempting connection to portal...");
                    let result = connection.start(vec!["client".to_owned()], || exponential_backoff.reset()).await;
                    tracing::warn!("Disconnected from the portal");
                    if let Err(e) = &result {
                        if e.is_http_client_error() {
                            tracing::error!(error = ?e, "Connection to portal failed. Is your token valid?");
                            fatal_error!(result, runtime_stopper, &callbacks);
                        } else {
                            tracing::error!(error = ?e, "Connection to portal failed. Starting retries with backoff timer.");
                        }
                    }
                    if let Some(t) = exponential_backoff.next_backoff() {
                        tracing::debug!("Connection to portal failed. Retrying connection to portal in {:?}", t);
                        tokio::time::sleep(t).await;
                    } else {
                        tracing::error!("Connection to portal failed, giving up!");
                        Self::disconnect_inner(runtime_stopper, &callbacks, None);
                        break;
                    }
                }

            });

        });
    }

    fn disconnect_inner(
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

        let _ = callbacks.on_disconnect(error.as_ref());
    }

    /// Cleanup a [Session].
    ///
    /// For now this just drops the runtime, which should drop all pending tasks.
    /// Further cleanup should be done here. (Otherwise we can just drop [Session]).
    pub fn disconnect(&mut self, error: Option<Error>) {
        Self::disconnect_inner(self.runtime_stopper.clone(), &self.callbacks, error)
    }
}

fn upload_interval() -> Interval {
    let duration = upload_interval_duration_from_env_or_default();
    let mut interval = tokio::time::interval_at(Instant::now() + duration, duration);
    interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

    interval
}

/// Parses an interval from the _compile-time_ env variable `CONNLIB_LOG_UPLOAD_INTERVAL_SECS`.
///
/// If not present or parsing as u64 fails, we fall back to a default interval of 5 minutes.
fn upload_interval_duration_from_env_or_default() -> Duration {
    const DEFAULT: Duration = Duration::from_secs(60 * 5);

    let Some(interval) = option_env!("CONNLIB_LOG_UPLOAD_INTERVAL_SECS") else {
        tracing::warn!(interval = ?DEFAULT, "Env variable `CONNLIB_LOG_UPLOAD_INTERVAL_SECS` was not set during compile-time, falling back to default");

        return DEFAULT;
    };

    let interval = match interval.parse() {
        Ok(i) => i,
        Err(e) => {
            tracing::warn!(interval = ?DEFAULT, "Failed to parse `CONNLIB_LOG_UPLOAD_INTERVAL_SECS` as u64: {e}");
            return DEFAULT;
        }
    };

    tracing::info!(
        ?interval,
        "Using upload interval specified at compile-time via `CONNLIB_LOG_UPLOAD_INTERVAL_SECS`"
    );

    Duration::from_secs(interval)
}
