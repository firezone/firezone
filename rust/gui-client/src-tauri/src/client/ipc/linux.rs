use anyhow::{Context as _, Result};
use connlib_client_shared::Callbacks;
use firezone_headless_client::{platform::sock_path, IpcClientMsg, IpcServerMsg};
use futures::{SinkExt, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use tokio::net::{unix::OwnedWriteHalf, UnixStream};
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};

/// A type alias to abstract over the Windows and Unix IPC primitives
pub(crate) type IpcStream = UnixStream;

/// Forwards events to and from connlib
pub(crate) struct Client {
    recv_task: tokio::task::JoinHandle<Result<()>>,
    tx: FramedWrite<tokio::io::WriteHalf<IpcStream>, LengthDelimitedCodec>,
}

/// Connect to the IPC service
pub(crate) async fn connect_to_service() -> Result<IpcStream> {
    let stream = UnixStream::connect(sock_path())
        .await
        .context("Couldn't connect to Unix domain socket")?;
    Ok(stream)
}

impl Client {
    pub(crate) async fn disconnect(mut self) -> Result<()> {
        self.send_msg(&IpcClientMsg::Disconnect)
            .await
            .context("Couldn't send Disconnect")?;
        self.tx.close().await?;
        self.task.abort();
        Ok(())
    }

    pub(crate) async fn send_msg(&mut self, msg: &IpcClientMsg) -> Result<()> {
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

    pub(crate) async fn connect(
        api_url: &str,
        token: SecretString,
        callback_handler: super::CallbackHandler,
        tokio_handle: tokio::runtime::Handle,
    ) -> Result<Self> {
        tracing::info!(pid = std::process::id(), "Connecting to IPC service...");
        let stream = connect_to_service().await?;
        let (rx, tx) = tokio::io::split(stream.0);
        // Receives messages from the IPC service
        let mut rx = FramedRead::new(rx, LengthDelimitedCodec::new());
        let tx = FramedWrite::new(tx, LengthDelimitedCodec::new());

        // TODO: Make sure this joins / drops somewhere
        let task = tokio_handle.spawn(async move {
            while let Some(msg) = rx.next().await.transpose()? {
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

        let mut client = Self { task, tx };
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
}
