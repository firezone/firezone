use anyhow::{anyhow, Result};
use control_types::{CommResult, Command, Protocol};
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, tungstenite::Message::Text,
    MaybeTlsStream, WebSocketStream,
};

use crate::config::{Address, ExternalNodeDescriptor, InternalNodeDescriptor};

#[derive(Debug)]
pub struct Node {
    ws_stream: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl Node {
    pub async fn new(url: impl IntoClientRequest + Unpin) -> Result<Self> {
        let (ws_stream, _) = connect_async(url).await?;
        Ok(Self { ws_stream })
    }

    pub async fn send_cmd(&mut self, cmd: &Command) -> Result<()> {
        let msg = serde_json::to_string(cmd)?;
        let msg = Text(msg);
        self.ws_stream.send(msg).await?;
        Ok(())
    }

    pub async fn recv_response(&mut self) -> Result<CommResult> {
        while let Some(msg) = self.ws_stream.next().await {
            let msg = msg?;
            if let Text(msg) = msg {
                return Ok(serde_json::from_str(&msg)?);
            }
        }

        Err(anyhow!(
            "Websocket connection ended and no response was recieved"
        ))
    }

    pub async fn shutdown(&mut self) -> Result<()> {
        self.ws_stream.close(None).await?;
        Ok(())
    }
}

#[derive(Debug)]
pub struct ExternalNodeWithDesc {
    pub node: Node,
    pub descriptor: ExternalNodeDescriptor,
}

impl ExternalNodeWithDesc {
    pub async fn set_as_listener<T>(&mut self, protocol: Protocol) -> Result<()>
    where
        ExternalNodeDescriptor: Address<T>,
    {
        self.node
            .send_cmd(&Command::listen(self.descriptor.address(), protocol))
            .await?;
        Ok(())
    }
    pub async fn from_descriptor(descriptor: ExternalNodeDescriptor) -> Result<Self> {
        let node = Node::new(descriptor.control_url.clone()).await?;
        Ok(Self { node, descriptor })
    }
}

#[derive(Debug)]
pub struct InternalNodeWithDesc {
    pub node: Node,
    pub descriptor: InternalNodeDescriptor,
    pub tag: Option<String>,
}

impl InternalNodeWithDesc {
    pub async fn from_descriptor(descriptor: InternalNodeDescriptor) -> Result<Self> {
        let node = Node::new(descriptor.control_url.clone()).await?;
        Ok(Self {
            node,
            descriptor,
            tag: None,
        })
    }

    pub async fn send_msg<T>(
        &mut self,
        msg: Vec<u8>,
        to: &ExternalNodeDescriptor,
        protocol: Protocol,
    ) -> Result<()>
    where
        ExternalNodeDescriptor: Address<T>,
    {
        self.node
            .send_cmd(&Command::send(to.address(), protocol, msg))
            .await
    }
}
