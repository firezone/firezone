use anyhow::{Context as _, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::{file_logger, Callbacks, ResourceDescription};
use firezone_headless_client::{imp::sock_path, IpcClientMsg, IpcServerMsg};
use futures::{Sink, Stream};
use secrecy::{ExposeSecret, SecretString};
use std::{
    future::poll_fn,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::{net::UnixStream, sync::Notify};
use tokio_util::codec::{Framed, LengthDelimitedCodec};

use super::ControllerRequest;
use super::CtlrTx;

#[derive(Clone)]
pub(crate) struct CallbackHandler {
    pub _logger: file_logger::Handle,
    pub notify_controller: Arc<Notify>,
    pub ctlr_tx: CtlrTx,
    pub resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

/// Forwards events to and from connlib
pub(crate) struct TunnelWrapper {
    ipc_task: tokio::task::JoinHandle<Result<SignedIn>>,
    tx: tokio::sync::mpsc::Sender<IpcClientMsg>,
}

impl TunnelWrapper {
    pub(crate) async fn disconnect(mut self) -> Result<()> {
        self.send_msg(IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        Ok(())
    }

    pub(crate) async fn reconnect(&mut self) -> Result<()> {
        self.send_msg(IpcClientMsg::Reconnect)
            .await
            .context("Couldn't send Reconnect")?;
        Ok(())
    }

    /// Tell connlib about the system's default resolvers
    ///
    /// `dns` is passed as value because the in-proc impl needs that
    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.send_msg(IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }

    async fn send_msg(&mut self, msg: IpcClientMsg) -> Result<()> {
        self.tx
            .send(msg)
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }
}

pub async fn connect(
    api_url: &str,
    token: SecretString,
    callback_handler: CallbackHandler,
    tokio_handle: tokio::runtime::Handle,
) -> Result<TunnelWrapper> {
    tracing::info!(pid = std::process::id(), "Connecting to IPC service...");
    let stream = UnixStream::connect(sock_path())
        .await
        .context("Couldn't connect to UDS")?;

    let (tx, rx) = tokio::sync::mpsc::channel(1);
    let stream = Framed::new(stream, LengthDelimitedCodec::new());
    let mut signed_in = SignedIn {
        callback_handler,
        outbound: rx,
        stream: Box::pin(stream),
    };

    // TODO: Make sure this joins / drops somewhere
    let ipc_task = tokio_handle.spawn(async move {
        poll_fn(|cx| signed_in.poll(cx)).await?;
        tracing::debug!("IPC task exiting");
        Ok(signed_in)
    });

    let mut client = TunnelWrapper { ipc_task, tx };
    let token = token.expose_secret().clone();
    client
        .send_msg(IpcClientMsg::Connect {
            api_url: api_url.to_string(),
            token,
        })
        .await
        .context("Couldn't send Connect message")?;

    Ok(client)
}

/// IPC for a session that's sent `Connect`
struct SignedIn {
    callback_handler: CallbackHandler,
    outbound: tokio::sync::mpsc::Receiver<IpcClientMsg>,
    stream: Pin<Box<Framed<UnixStream, LengthDelimitedCodec>>>,
}

impl SignedIn {
    /// Returns `Ready` when connlib disconnects or on error
    fn poll(&mut self, cx: &mut Context) -> Poll<Result<()>> {
        tracing::debug!("SignedIn::poll");
        loop {
            if let Poll::Ready(Err(e)) = self.stream.as_mut().poll_flush(cx) {
                return Poll::Ready(Err(e.into()));
            }
            match self.stream.as_mut().poll_ready(cx) {
                Poll::Ready(Ok(())) => {
                    // IPC stream can send
                    match self.outbound.poll_recv(cx) {
                        Poll::Ready(Some(msg)) => {
                            if let Err(e) = self.stream.as_mut().start_send(encode(&msg)?) {
                                return Poll::Ready(Err(e.into()));
                            }
                            if let IpcClientMsg::Disconnect = msg {
                                return Poll::Ready(Ok(()));
                            }
                            continue;
                        }
                        Poll::Ready(None) => {
                            return Poll::Ready(Err(anyhow::anyhow!("outbound rx closed")))
                        }
                        Poll::Pending => {}
                    }
                }
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e.into())),
                Poll::Pending => {}
            }

            match self.stream.as_mut().poll_next(cx) {
                Poll::Ready(Some(msg)) => {
                    let msg = match msg {
                        Ok(x) => x,
                        Err(e) => return Poll::Ready(Err(e.into())),
                    };
                    let msg: IpcServerMsg = serde_json::from_slice(&msg).unwrap();
                    match msg {
                        IpcServerMsg::Ok => {}
                        IpcServerMsg::OnDisconnect => {
                            self.callback_handler.on_disconnect(
                                &connlib_client_shared::Error::Other("errors can't be serialized"),
                            );
                            return Poll::Ready(Ok(()));
                        }
                        IpcServerMsg::OnUpdateResources(res) => {
                            self.callback_handler.on_update_resources(res)
                        }
                        IpcServerMsg::TunnelReady => self.callback_handler.on_tunnel_ready(),
                    }
                    continue;
                }
                Poll::Ready(None) => return Poll::Ready(Err(anyhow::anyhow!("shutting down"))),
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

fn encode(msg: &IpcClientMsg) -> Result<bytes::Bytes> {
    Ok(serde_json::to_string(msg)
        .context("Failed to encode IPC client message JSON")?
        .into())
}

// Callbacks must all be non-blocking
// TODO: DRY
impl connlib_client_shared::Callbacks for CallbackHandler {
    fn on_disconnect(&self, error: &connlib_client_shared::Error) {
        tracing::debug!("on_disconnect {error:?}");
        self.ctlr_tx
            .try_send(ControllerRequest::Disconnected)
            .expect("controller channel failed");
    }

    fn on_set_interface_config(&self, _: Ipv4Addr, _: Ipv6Addr, _: Vec<IpAddr>) -> Option<i32> {
        unimplemented!()
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) {
        tracing::debug!("on_update_resources");
        self.resources.store(resources.into());
        self.notify_controller.notify_one();
    }
}

impl CallbackHandler {
    fn on_tunnel_ready(&self) {
        self.ctlr_tx
            .try_send(ControllerRequest::TunnelReady)
            .expect("controller channel failed");
    }
}
