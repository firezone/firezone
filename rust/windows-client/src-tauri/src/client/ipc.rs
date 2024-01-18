//! Inter-process communication for the connlib subprocess

use serde::{Deserialize, Serialize};
use tokio::{
    io::{
        AsyncReadExt,
        AsyncWriteExt,
    },
    net::windows::named_pipe,
    runtime::Runtime,
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
    CouldntConnect,
    NotConnected,
}

pub(crate) struct Subprocess {

}

impl Subprocess {
    pub(crate) fn new(pipe_id: &str) -> Self {
        todo!();
    }

    pub(crate) fn close(self) -> anyhow::Result<()> {
        todo!();
    }

    pub(crate) async fn request(&mut self, req: Request) -> anyhow::Result<Response> {
        todo!();
    }
}

pub(crate) struct Client {

}

impl Client {
    pub(crate) fn new(pipe_id: &str) -> Self {
        todo!();
    }

    pub(crate) async next_request(&mut self) -> anyhow::Result<Request> {
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

pub(crate) async fn connlib_client(pipe_id: &str) -> anyhow::Result<()> {
    let mut client = Client::new(pipe_id);
    let mut connlib_session = None;

    loop {
        match client.next_request().await? {
            Request::AwaitCallback => {
                if let Some(connlib_session) = connlib_session.as_mut() {

                } else {
                    client.respond(Response::Callback(Err(SerializedError::NotConnected))).await?;
                };
            }
        }
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
            assert_eq!(resp, Response::Callback(Callback::TunnelReady));

            let resp = subprocess.request(Request::Disconnect).await?;
            assert_eq!(resp, Response::Disconnect(Ok(())));

            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }
}
