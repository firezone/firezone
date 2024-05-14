use anyhow::{anyhow, Context as _, Result};
use connlib_client_shared::Callbacks;
use firezone_headless_client::{IpcClientMsg, IpcServerMsg};
use futures::{SinkExt, Stream};
use secrecy::{ExposeSecret, SecretString};
use std::{pin::pin, task::Poll};
use tokio::{net::windows::named_pipe, sync::mpsc};
use tokio_util::codec::{Framed, LengthDelimitedCodec};

pub(crate) struct TunnelWrapper {
    task: tokio::task::JoinHandle<Result<()>>,
    // Needed temporarily to avoid a big refactor. We can remove this in the future.
    tx: mpsc::Sender<String>,
}

impl TunnelWrapper {
    pub(crate) async fn disconnect(mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        self.task.abort();
        Ok(())
    }

    #[allow(clippy::unused_async)]
    pub(crate) async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.tx
            .send(serde_json::to_string(msg).context("Couldn't encode IPC message as JSON")?)
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }
}

enum IpcEvent {
    /// The client wants to send a message to the service
    Client(String),
    /// The connlib instance in the server wants to send a message to the client
    Connlib(IpcServerMsg),
}

pub(crate) async fn connect(
    api_url: &str,
    token: SecretString,
    callback_handler: super::CallbackHandler,
    tokio_handle: tokio::runtime::Handle,
) -> Result<TunnelWrapper> {
    tracing::info!(pid = std::process::id(), "Connecting to IPC service...");
    let ipc = named_pipe::ClientOptions::new()
        .open(firezone_headless_client::windows::pipe_path())
        .context("Couldn't connect to named pipe server")?;
    let ipc = Framed::new(ipc, LengthDelimitedCodec::new());
    // This channel allows us to communicate with the GUI even though NamedPipeClient
    // doesn't have `into_split`.
    let (tx, mut rx) = mpsc::channel(1);

    let task = tokio_handle.spawn(async move {
        let mut ipc = pin!(ipc);
        loop {
            let ev = std::future::poll_fn(|cx| {
                match rx.poll_recv(cx) {
                    Poll::Ready(Some(msg)) => return Poll::Ready(Ok(IpcEvent::Client(msg))),
                    Poll::Ready(None) => {
                        return Poll::Ready(Err(anyhow!("MPSC channel from GUI closed")))
                    }
                    Poll::Pending => {}
                }

                match ipc.as_mut().poll_next(cx) {
                    Poll::Ready(Some(msg)) => {
                        let msg = serde_json::from_slice(&msg?)?;
                        return Poll::Ready(Ok(IpcEvent::Connlib(msg)));
                    }
                    Poll::Ready(None) => {}
                    Poll::Pending => {}
                }

                Poll::Pending
            })
            .await;

            match ev {
                Ok(IpcEvent::Client(msg)) => ipc.send(msg.into()).await?,
                Ok(IpcEvent::Connlib(msg)) => match msg {
                    IpcServerMsg::Ok => {}
                    IpcServerMsg::OnDisconnect => callback_handler.on_disconnect(
                        &connlib_client_shared::Error::Other("errors can't be serialized"),
                    ),
                    IpcServerMsg::OnUpdateResources(v) => callback_handler.on_update_resources(v),
                    IpcServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns } => {
                        callback_handler.on_set_interface_config(ipv4, ipv6, dns);
                    }
                },
                Err(e) => return Err(e),
            }
        }
    });

    let mut client = TunnelWrapper { task, tx };
    let token = token.expose_secret().clone();
    client
        .send_msg(&IpcClientMsg::Connect {
            api_url: api_url.to_string(),
            token,
        })
        .await
        .context("Couldn't send Connect message")?;
    Ok(client)
}
