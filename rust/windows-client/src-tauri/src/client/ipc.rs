//! Inter-process communication for the connlib subprocess

use serde::{Deserialize, Serialize};
use tokio::{
    io::{
        AsyncReadExt,
        AsyncWriteExt,
    },
    net::windows::named_pipe,
    runtime::Runtime,
    sync::mpsc,
};

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Request {
    AwaitCallback,
    Connect,
    Disconnect,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Response {
    Callback(Result<Callback, SerializedError>),
    Connect(Result<(), SerializedError>),
    Disconnect(Result<(), SerializedError>),
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Callback {
    Disconnected,
    TunnelReady,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
enum SerializedError {
    AlreadyConnected,
    AlreadyDisconnected,
    CouldntConnect,
    NotConnected,
}

pub(crate) struct Subprocess {

}

impl Subprocess {
    pub fn new(pipe_id: &str) -> Self {
        todo!();
    }

    pub fn close(self) -> anyhow::Result<()> {
        todo!();
    }

    pub async fn request(&mut self, req: Request) -> anyhow::Result<Response> {
        todo!();
    }
}

pub(crate) struct Client {

}

impl Client {
    pub fn new(pipe_id: &str) -> Self {
        todo!();
    }

    pub async fn next_request(&mut self) -> anyhow::Result<Request> {
        todo!();
    }

    /// Only valid if we're responding to a request
    pub async fn respond(&mut self, response: Response) -> anyhow::Result<()> {
        todo!();
    }
}

trait MockCallbacks {
    fn on_disconnect(&self);
    fn on_tunnel_ready(&self);
}

struct CallbackHandler {
    tx: mpsc::Sender<Callback>,
}

impl MockCallbacks for CallbackHandler {
    fn on_disconnect(&self) {
        self.tx.blocking_send(Callback::Disconnected).unwrap();
    }

    fn on_tunnel_ready(&self) {
        self.tx.blocking_send(Callback::TunnelReady).unwrap();
    }
}

struct MockConnlib {}

impl MockConnlib {
    fn connect() -> MockConnlib {
        todo!()
    }

    fn disconnect(self) {
        todo!()
    }
}

struct ConnlibProxy {
    client: Client,
    connlib_session: Option<MockConnlib>,
}

impl ConnlibProxy {
    pub(crate) fn new(pipe_id: &str) -> Self {
        let client = Client::new(pipe_id);
        Self {
            client,
            connlib_session: None,
        }
    }

    pub(crate) async fn run(&mut self, pipe_id: &str) -> anyhow::Result<()> {
        loop {
            let req = self.client.next_request().await?;
            let resp = self.handle_request(req).await?;
            self.client.respond(resp).await?;
        }
    }

    async fn handle_request(&mut self, request: Request) -> anyhow::Result<Response> {
        let resp = match request {
            Request::AwaitCallback => {
                if let Some(connlib_session) = self.connlib_session.as_mut() {
                    todo!()
                } else {
                    Response::Callback(Err(SerializedError::NotConnected))
                }
            }
            Request::Connect => {
                if self.connlib_session.is_some() {
                    Response::Connect(Err(SerializedError::AlreadyConnected))
                } else {
                    self.connlib_session = Some(MockConnlib::connect());
                    Response::Connect(Ok(()))
                }
            }
            Request::Disconnect => {
                if let Some(connlib_session) = self.connlib_session.take() {
                    connlib_session.disconnect();
                    Response::Disconnect(Ok(()))
                } else {
                    Response::Disconnect(Err(SerializedError::AlreadyDisconnected))
                }
            }
        };
        Ok(resp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipc() -> anyhow::Result<()> {
        let rt = Runtime::new()?;
        rt.block_on(async move {
            let mut subprocess = Subprocess::new("debug-subprocess-CJKCN43B");

            let resp = subprocess.request(Request::Connect).await?;
            assert_eq!(resp, Response::Connect(Ok(())));

            let resp = subprocess.request(Request::AwaitCallback).await?;
            assert_eq!(resp, Response::Callback(Ok(Callback::TunnelReady)));

            let resp = subprocess.request(Request::Disconnect).await?;
            assert_eq!(resp, Response::Disconnect(Ok(())));

            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }
}
