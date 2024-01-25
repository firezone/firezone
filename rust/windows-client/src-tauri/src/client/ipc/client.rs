use anyhow::{bail, Context, Result};
use tokio::{io::AsyncWriteExt, net::windows::named_pipe, sync::mpsc, task::JoinHandle};

use super::{read_deserialize, write_serialize, Callback, ManagerMsg, WorkerMsg};

/// A client that's connected to a server
///
/// Manual testing shows that if the corresponding Server's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Client
pub(crate) struct Client {
    pipe_task: JoinHandle<Result<()>>,
    pub(crate) request_rx: mpsc::Receiver<ManagerMsg>,
    write_tx: mpsc::Sender<ClientInternalMsg>,
}

enum ClientInternalMsg {
    Msg(WorkerMsg),
    Shutdown,
}

impl Client {
    /// Creates a `Client` and echoes the security cookie back to the `Server`
    ///
    /// Doesn't block, fails instantly if the server isn't up.
    pub(crate) async fn new(server_id: &str) -> Result<Self> {
        let client = Client::new_unsecured(server_id)?;
        let mut cookie = String::new();
        std::io::stdin().read_line(&mut cookie)?;
        let cookie = WorkerMsg::Callback(Callback::Cookie(cookie.trim().to_string()));
        client.send(cookie).await?;
        Ok(client)
    }

    /// Creates a `Client`. Requires a Tokio context
    ///
    /// Doesn't block, will fail instantly if the server isn't ready
    #[tracing::instrument(skip_all)]
    pub(crate) fn new_unsecured(server_id: &str) -> Result<Self> {
        let pipe = named_pipe::ClientOptions::new().open(server_id)?;
        let (request_tx, request_rx) = mpsc::channel(5);
        let (write_tx, write_rx) = mpsc::channel(5);

        // TODO: Make sure this task stops
        let pipe_task =
            tokio::task::spawn(async move { Self::pipe_task(pipe, request_tx, write_rx).await });

        Ok(Self {
            pipe_task,
            request_rx,
            write_tx,
        })
    }

    pub(crate) async fn close(self) -> Result<()> {
        // Worker signals its pipe task to shut down
        self.write_tx
            .send(ClientInternalMsg::Shutdown)
            .await
            .context("couldn't send ClientInternalMsg::Shutdown")?;
        let Self { pipe_task, .. } = self;
        pipe_task
            .await
            .context("async runtime error for ipc::Client::pipe_task")?
            .context("ipc::Client::pipe_task returned an error")?;
        Ok(())
    }

    pub(crate) async fn send(&self, msg: WorkerMsg) -> Result<()> {
        self.write_tx.send(ClientInternalMsg::Msg(msg)).await?;
        Ok(())
    }

    #[tracing::instrument(skip_all)]
    async fn pipe_task(
        mut pipe: named_pipe::NamedPipeClient,
        request_tx: mpsc::Sender<ManagerMsg>,
        mut write_rx: mpsc::Receiver<ClientInternalMsg>,
    ) -> Result<()> {
        loop {
            // Note: Make sure these are all cancel-safe
            tokio::select! {
                // Thomas and ReactorScram assume this is cancel-safe
                ready = pipe.ready(tokio::io::Interest::READABLE) => {
                    // Zero bytes just to see if any data is ready at all
                    let mut buf = [];
                    if ready?.is_readable() && pipe.try_read(&mut buf).is_ok() {
                        let req = read_deserialize(&mut pipe).await?;
                        request_tx.send(req).await?;
                    }
                },
                // Cancel-safe per <https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Receiver.html#cancel-safety>
                msg = write_rx.recv() => {
                    let Some(msg) = msg else {
                        bail!("Client::write_rx closed suddenly");
                    };
                    let msg = match msg {
                        ClientInternalMsg::Shutdown => break,
                        ClientInternalMsg::Msg(msg) => msg,
                    };
                    write_serialize(&mut pipe, &msg).await?;
                }
            }
        }

        // Worker's pipe task closes its end of the pipe cleanly and joins
        pipe.shutdown().await?;
        tracing::debug!("Client::pipe_task exiting gracefully");
        Ok(())
    }
}
