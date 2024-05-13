use anyhow::{Context, Result};
use connlib_client_shared::Callbacks;
use firezone_headless_client::{imp::sock_path, IpcClientMsg, IpcServerMsg};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use std::net::IpAddr;
use tokio::net::{unix::OwnedWriteHalf, UnixStream};
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};

/// Forwards events to and from connlib
pub(crate) struct TunnelWrapper {
    recv_task: tokio::task::JoinHandle<Result<()>>,
    tx: FramedWrite<OwnedWriteHalf, LengthDelimitedCodec>,
}

impl TunnelWrapper {
    pub(crate) async fn disconnect(mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        self.tx.close().await?;
        self.recv_task.abort();
        Ok(())
    }

    pub(crate) async fn reconnect(&mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Reconnect)
            .await
            .context("Couldn't send Reconnect")?;
        Ok(())
    }

    /// Tell connlib about the system's default resolvers
    ///
    /// `dns` is passed as value because the in-proc impl needs that
    pub(crate) async fn set_dns(&mut self, dns: Vec<IpAddr>) -> Result<()> {
        self.send_msg(&IpcClientMsg::SetDns(dns))
            .await
            .context("Couldn't send SetDns")?;
        Ok(())
    }

    async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
        self.tx
            .send(
                serde_json::to_string(msg)
                    .context("Couldn't encode IPC message as JSON")?
                    .into(),
            )
            .await
            .context("Couldn't send IPC message")?;
        Ok(())
    }
}

pub async fn connect(
    api_url: &str,
    token: SecretString,
    callback_handler: crate::client::gui::CallbackHandler,
    tokio_handle: tokio::runtime::Handle,
) -> Result<TunnelWrapper> {
    tracing::info!(pid = std::process::id(), "Connecting to IPC service...");
    let stream = UnixStream::connect(sock_path())
        .await
        .context("Couldn't connect to UDS")?;
    let (rx, tx) = stream.into_split();
    let mut rx = FramedRead::new(rx, LengthDelimitedCodec::new());
    let tx = FramedWrite::new(tx, LengthDelimitedCodec::new());

    // TODO: Make sure this joins / drops somewhere
    let recv_task = tokio_handle.spawn(async move {
        while let Some(msg) = rx.next().await {
            let msg = msg?;
            let msg: IpcServerMsg = serde_json::from_slice(&msg)?;
            match msg {
                IpcServerMsg::Ok => {}
                IpcServerMsg::OnDisconnect => callback_handler.on_disconnect(
                    &connlib_client_shared::Error::Other("errors can't be serialized"),
                ),
                IpcServerMsg::OnUpdateResources(v) => callback_handler.on_update_resources(v),
                IpcServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns } => {
                    callback_handler.on_set_interface_config(ipv4, ipv6, dns);
                }
            }
        }
        Ok(())
    });

    let mut client = TunnelWrapper { recv_task, tx };
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
