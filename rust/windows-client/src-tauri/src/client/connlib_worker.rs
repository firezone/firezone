//! Worker subprocess for connlib, to work around <https://github.com/firezone/firezone/issues/2975>

use crate::client::{
    crash_handling,
    ipc::{self, ManagerMsg, WorkerMsg},
    logging, resolvers,
    settings::{self, AdvancedSettings},
};
use anyhow::{Context, Result};
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
    let logger = logging::setup(&advanced_settings.log_filter, logging::CONNLIB_DIR)?;
    tracing::info!("started connlib log");
    tracing::info!("GIT_VERSION = {}", crate::client::GIT_VERSION);

    // Need to keep this alive so crashes will be handled. Dropping detaches it.
    let _crash_handler = match crash_handling::attach_handler(logging::CONNLIB_CRASH_DUMP) {
        Ok(x) => Some(x),
        Err(error) => {
            tracing::warn!(?error, "Did not set up crash handler");
            None
        }
    };

    let rt = tokio::runtime::Runtime::new()?;
    if let Err(error) = rt.block_on(async move {
        let cw = ConnlibWorker::new(advanced_settings, logger.logger, pipe_id).await?;
        cw.run_async().await
    }) {
        tracing::error!(?error, "error from async runtime");
    }

    tracing::info!("connlib worker subprocess exiting cleanly");
    Ok(())
}

struct ConnlibWorker {
    advanced_settings: AdvancedSettings,
    callback_handler: CallbackHandler,
    client: ipc::Client,
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
    async fn new(
        advanced_settings: AdvancedSettings,
        logger: file_logger::Handle,
        pipe_id: String,
    ) -> Result<Self> {
        let client = ipc::Client::new(&pipe_id).await?;
        // TODO: Replace this with some atomics or something
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
            client,
            connlib: None,
            notify,
            rx,
        })
    }

    async fn run_async(mut self) -> Result<()> {
        loop {
            // Note: Make sure these are all cancel-safe
            tokio::select! {
                // Cancel safe per <https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Receiver.html#cancel-safety>
                req = self.client.recv() => {
                    let Ok(req) = req else {
                        tracing::info!("named pipe dropped");
                        break;
                    };
                    let resp = self.handle_manager_msg(&req).await.context("handle_manager_msg failed")?;
                    self.client.send(&ipc::WorkerMsg::Response(resp)).await.context("ipc::Client::send failed")?;
                    if let ipc::ManagerMsg::Disconnect = req {
                        break;
                    }
                },
                // ReactorScram thinks `notified` here is cancel-safe <https://docs.rs/tokio/latest/tokio/sync/struct.Notify.html#method.notified>
                () = self.notify.notified() => self.refresh().await.context("ConnlibWorker::refresh failed")?,
                // Cancel safe per <https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Receiver.html#cancel-safety>
                msg = self.rx.recv() => {
                    tracing::debug!(?msg, "trying to send message over IPC");
                    self.client.send(&msg.ok_or_else(|| anyhow::anyhow!("should have received a message over mpsc"))?).await.context("ipc::Client::send failed")?;
                },
            }
        }

        if let Some(mut connlib) = self.connlib.take() {
            tracing::info!("Disconnecting connlib...");
            connlib.disconnect(None);
            tracing::info!("Disconnected connlib.");
        }

        self.client
            .close()
            .await
            .context("ipc::Client::close failed")?;
        tracing::info!("ConnlibWorker::run_async exiting gracefully");
        Ok::<_, anyhow::Error>(())
    }

    async fn handle_manager_msg(&mut self, msg: &ipc::ManagerMsg) -> Result<ipc::ManagerMsg> {
        match msg {
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
                    Some(MAX_PARTITION_TIME),
                )?;
                self.connlib = Some(connlib);
                Ok(ipc::ManagerMsg::Connect)
            }
            ManagerMsg::Disconnect => Ok(ipc::ManagerMsg::Disconnect),
        }
    }

    // TODO: Better name
    async fn refresh(&mut self) -> Result<()> {
        let resources = Vec::clone(&self.callback_handler.resources.load());
        self.client
            .send(&ipc::WorkerMsg::Callback(ipc::Callback::OnUpdateResources(
                resources,
            )))
            .await?;
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
            Some(connlib_client_shared::Error::TokenExpired) => {
                ipc::WorkerMsg::Callback(ipc::Callback::DisconnectedTokenExpired)
            }
            _ => ipc::WorkerMsg::Callback(ipc::Callback::OnDisconnect),
        })?;
        Ok(())
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        self.ipc_tx
            .try_send(ipc::WorkerMsg::Callback(ipc::Callback::TunnelReady))?;
        tracing::info!("Sent on_tunnel_ready");
        Ok(())
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) -> Result<(), Self::Error> {
        tracing::trace!("on_update_resources");
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
