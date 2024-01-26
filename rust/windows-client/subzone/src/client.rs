use anyhow::Result;
use serde::{de::DeserializeOwned, Serialize};
use std::marker::PhantomData;
use tokio::{
    io::AsyncWriteExt,
    net::windows::named_pipe::{self, NamedPipeClient},
    sync::mpsc,
};

use crate::{read_deserialize, write_serialize, Error, ManagerMsgInternal, WorkerMsgInternal};

/// A client that's connected to a server
///
/// Manual testing shows that if the corresponding Server's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Client
pub struct Client<M, W> {
    pipe_writer: tokio::io::WriteHalf<NamedPipeClient>,
    /// Needed to make `next` cancel-safe
    read_rx: mpsc::Receiver<Vec<u8>>,
    /// Needed to make `next` cancel-safe
    reader_task: tokio::task::JoinHandle<Result<()>>,
    _manager_msg: PhantomData<M>,
    _worker_msg: PhantomData<W>,
}

impl<M: DeserializeOwned, W: Serialize> Client<M, W> {
    /// Creates a `Client` and echoes the security cookie back to the `Server`
    ///
    /// Doesn't block, fails instantly if the server isn't up.
    pub async fn new(server_id: &str) -> Result<Self> {
        let mut client = Client::new_unsecured(server_id)?;
        let mut cookie = String::new();
        std::io::stdin().read_line(&mut cookie)?;
        let cookie = WorkerMsgInternal::Cookie(cookie.trim().to_string());
        client.send_internal(&cookie).await?;
        Ok(client)
    }

    /// Creates a `Client`. Requires a Tokio context
    ///
    /// Doesn't block, will fail instantly if the server isn't ready
    #[tracing::instrument(skip_all)]
    pub(crate) fn new_unsecured(server_id: &str) -> Result<Self> {
        let pipe = named_pipe::ClientOptions::new().open(server_id)?;
        let (mut pipe_reader, pipe_writer) = tokio::io::split(pipe);
        let (read_tx, read_rx) = mpsc::channel(1);
        let reader_task = tokio::spawn(async move {
            loop {
                let msg = read_deserialize(&mut pipe_reader).await?;
                read_tx.send(msg).await?;
            }
        });

        Ok(Self {
            pipe_writer,
            read_rx,
            reader_task,
            _manager_msg: Default::default(),
            _worker_msg: Default::default(),
        })
    }

    pub async fn close(mut self) -> Result<()> {
        self.pipe_writer.shutdown().await?;
        self.reader_task.abort();
        tracing::debug!("Client closing gracefully");
        Ok(())
    }

    /// Receives a message from the server
    ///
    /// # Cancel safety
    ///
    /// This method is cancel-safe, internally it calls `tokio::sync::mpsc::Receiver::recv`
    pub async fn next(&mut self) -> Result<ManagerMsgInternal<M>, Error> {
        let buf = self.read_rx.recv().await.ok_or_else(|| Error::Eof)?;
        let buf = std::str::from_utf8(&buf)?;
        let msg = serde_json::from_str(buf)?;
        Ok(msg)
    }

    pub async fn send(&mut self, msg: W) -> Result<(), Error> {
        self.send_internal(&WorkerMsgInternal::User(msg)).await
    }

    async fn send_internal(&mut self, msg: &WorkerMsgInternal<W>) -> Result<(), Error> {
        write_serialize(&mut self.pipe_writer, msg).await
    }
}
