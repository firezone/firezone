use anyhow::Result;
use tokio::{io::AsyncWriteExt, net::windows::named_pipe};

use super::{read_deserialize, write_serialize, Callback, Error, ManagerMsg, WorkerMsg};

/// A client that's connected to a server
///
/// Manual testing shows that if the corresponding Server's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Client
pub(crate) struct Client {
    pipe_reader: tokio::io::ReadHalf<named_pipe::NamedPipeClient>,
    pipe_writer: tokio::io::WriteHalf<named_pipe::NamedPipeClient>,
}

impl Client {
    /// Creates a `Client` and echoes the security cookie back to the `Server`
    ///
    /// Doesn't block, fails instantly if the server isn't up.
    pub(crate) async fn new(server_id: &str) -> Result<Self> {
        let mut client = Client::new_unsecured(server_id)?;
        let mut cookie = String::new();
        std::io::stdin().read_line(&mut cookie)?;
        let cookie = WorkerMsg::Callback(Callback::Cookie(cookie.trim().to_string()));
        client.send(&cookie).await?;
        Ok(client)
    }

    /// Creates a `Client`. Requires a Tokio context
    ///
    /// Doesn't block, will fail instantly if the server isn't ready
    #[tracing::instrument(skip_all)]
    pub(crate) fn new_unsecured(server_id: &str) -> Result<Self> {
        let pipe = named_pipe::ClientOptions::new().open(server_id)?;
        let (pipe_reader, pipe_writer) = tokio::io::split(pipe);

        Ok(Self {
            pipe_reader,
            pipe_writer,
        })
    }

    pub(crate) async fn close(mut self) -> Result<()> {
        self.pipe_writer.shutdown().await?;
        tracing::debug!("Client closing gracefully");
        Ok(())
    }

    pub(crate) async fn recv(&mut self) -> Result<ManagerMsg, Error> {
        read_deserialize::<_, ManagerMsg>(&mut self.pipe_reader).await
    }

    pub(crate) async fn send(&mut self, msg: &WorkerMsg) -> Result<(), Error> {
        write_serialize(&mut self.pipe_writer, msg).await
    }
}
