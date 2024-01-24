//! Worker subprocess for connlib, to work around <https://github.com/firezone/firezone/issues/2975>

use crate::client::{
    ipc::{self, ManagerMsg, WorkerMsg},
    logging, resolvers,
    settings::{self, AdvancedSettings},
};
use anyhow::Result;
use arc_swap::ArcSwap;
use connlib_client_shared::{file_logger, ResourceDescription};
use std::{net::IpAddr, path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::{mpsc, Notify};

/// The Windows client doesn't use platform APIs to detect network connectivity changes,
/// so we rely on connlib to do so. We have valid use cases for headless Windows clients
/// (IoT devices, point-of-sale devices, etc), so try to reconnect for 30 days if there's
/// been a partition.
const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24 * 30);

pub(crate) fn run(pipe_id: String) -> Result<()> {
    let advanced_settings = settings::load_advanced_settings().unwrap_or_default();
    let logger = logging::setup(&advanced_settings.log_filter)?;
    tracing::info!("started connlib log");
    tracing::info!("GIT_VERSION = {}", crate::client::GIT_VERSION);

    let rt = tokio::runtime::Runtime::new()?;
    if let Err(error) = rt.block_on(async move {
        let mut cw = ConnlibWorker::new(advanced_settings, logger.logger)?;
        cw.run_async(pipe_id).await
    }) {
        tracing::error!(?error, "error from async runtime");
    }

    tracing::info!("connlib worker subproces exiting cleanly");
    Ok(())
}

enum ControlFlow {
    Break,
    Nothing,
}

struct ConnlibWorker {
    advanced_settings: AdvancedSettings,
    callback_handler: CallbackHandler,
    connlib: Option<connlib_client_shared::Session<CallbackHandler>>,
    /// Tells us when to wake up and look for a new resource list. Tokio docs say that memory reads and writes are synchronized when notifying, so we don't need an extra mutex on the resources.
    notify: Arc<Notify>,
    rx: mpsc::Receiver<WorkerMsg>,
}

#[derive(Clone)]
struct CallbackHandler {
    ipc_tx: mpsc::Sender<WorkerMsg>,
    logger: file_logger::Handle,
    notify: Arc<Notify>,
    resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

impl ConnlibWorker {
    fn new(advanced_settings: AdvancedSettings, logger: file_logger::Handle) -> Result<Self> {
        let (ipc_tx, rx) = mpsc::channel(10);

        let notify = Arc::new(Notify::new());

        let callback_handler = CallbackHandler {
            ipc_tx,
            logger,
            notify: Arc::clone(&notify),
            resources: Default::default(),
        };

        Ok(Self {
            advanced_settings,
            callback_handler,
            connlib: None,
            notify,
            rx,
        })
    }

    async fn run_async(&mut self, pipe_id: String) -> Result<()> {
        let mut client = ipc::client(&pipe_id).await?;

        loop {
            // Note: Make sure these are all cancel-safe
            tokio::select! {
                // TODO: Is this cancel-safe?
                ready = client.ready(tokio::io::Interest::READABLE) => if ready?.is_readable() {
                    let msg = client.read().await?;
                    match self.handle_manager_msg(msg).await? {
                        ControlFlow::Break => break,
                        ControlFlow::Nothing => {}
                    }
                },
                // TODO: Not sure if this is cancel-safe? <https://docs.rs/tokio/latest/tokio/sync/struct.Notify.html#cancel-safety>
                () = self.notify.notified() => self.refresh().await?,
                // Cancel safe. <https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Receiver.html#cancel-safety>
                msg = self.rx.recv() => client.write(msg.ok_or_else(|| anyhow::anyhow!("should have received a message over mpsc"))?).await?,
            }
        }

        Ok::<_, anyhow::Error>(())
    }

    async fn handle_manager_msg(&mut self, manager_msg: ipc::ManagerMsg) -> Result<ControlFlow> {
        match manager_msg {
            ManagerMsg::Connect => {
                let auth = crate::client::auth::Auth::new()?;
                let token = auth
                    .token()?
                    .ok_or_else(|| anyhow::anyhow!("should be able to load the token"))?;

                let device_id =
                    crate::client::device_id::device_id(crate::client::BUNDLE_ID).await?;

                let connlib = connlib_client_shared::Session::connect(
                    self.advanced_settings.api_url.clone(),
                    token,
                    device_id,
                    None, // TODO: Send device name here (windows computer name)
                    None,
                    self.callback_handler.clone(),
                    MAX_PARTITION_TIME,
                )?;
                self.connlib = Some(connlib);
                Ok(ControlFlow::Nothing)
            }
            ManagerMsg::Disconnect => Ok(ControlFlow::Break),
        }
    }

    async fn refresh(&mut self) -> Result<()> {
        // TODO: Handle when connlib tells us we have new resources

        Ok(())
    }
}

#[derive(thiserror::Error, Debug)]
enum CallbackError {
    #[error("system DNS resolver problem: {0}")]
    Resolvers(#[from] resolvers::Error),
    #[error("can't send to controller task: {0}")]
    SendError(#[from] mpsc::error::TrySendError<WorkerMsg>),
}

// Callbacks must all be non-blocking
impl connlib_client_shared::Callbacks for CallbackHandler {
    type Error = CallbackError;

    fn on_disconnect(
        &self,
        error: Option<&connlib_client_shared::Error>,
    ) -> Result<(), Self::Error> {
        tracing::debug!("on_disconnect {error:?}");
        // TODO: This is suspicious
        self.ipc_tx.try_send(match error {
            Some(connlib_client_shared::Error::TokenExpired) => ipc::WorkerMsg::Callback(ipc::Callback::DisconnectedTokenExpired),
            _ => ipc::WorkerMsg::Response(ipc::ManagerMsg::Disconnect),
        })?;
        Ok(())
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        tracing::info!("on_tunnel_ready");
        self.ipc_tx.try_send(ipc::WorkerMsg::Callback(ipc::Callback::TunnelReady))?;
        Ok(())
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) -> Result<(), Self::Error> {
        tracing::info!("on_update_resources");
        self.resources.store(resources.into());
        self.notify.notify_one();
        Ok(())
    }

    fn get_system_default_resolvers(&self) -> Result<Option<Vec<IpAddr>>, Self::Error> {
        Ok(Some(resolvers::get()?))
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.logger.roll_to_new_file().unwrap_or_else(|e| {
            tracing::debug!("Failed to roll over to new file: {e}");

            None
        })
    }
}
