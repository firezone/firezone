//! Worker subprocesses with async IPC for Windows
//!
//! To run the unit tests and multi-process tests, use
//! ```bash
//! cargo test && cargo run && echo good
//! ```
//!
//! # Security
//!
//! The IPC module uses Windows' named pipes primitive.
//!
//! These seem *relatively* secure. Chromium also uses them.
//! Privileged applications with admin powers or kernel
//! modules, like Wireshark, can snoop on named pipes, because they're running as root.
//!
//! Non-privileged processes can enumerate the names of named pipes. To prevent
//! a process that isn't our child from connecting to our named pipe, I check the
//! process ID before communicating, and then require the first message to be a cookie
//! echoed to the child's stdin and back through the pipe, similar to a CSRF token.
//!
//! Also by default, non-elevated processes cannot connect to named pipe servers
//! inside elevated processes.
//!
//! # Design
//!
//! subzone has these features:
//!
//! - Kill unresponsive worker if needed
//! - Graceful shutdown
//! - Automatically kill workers even if the manager process crashes
//! - Bails out if some other process tries to intercept IPC between the two processes

use anyhow::Result;
use clap::Parser;
use serde::{Deserialize, Serialize};
use std::{fmt::Debug, marker::Unpin};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

mod client;
mod server;
// Always enabled, since the integration tests can't run in `cargo test` yet
pub(crate) mod multi_process_tests;

pub use client::Client;
pub use server::{LeakGuard, Server, SubcommandChild, SubcommandExit, Subprocess};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Used to detected graceful named pipe closes
    #[error("EOF")]
    Eof,
    /// Any IO error except EOF
    #[error(transparent)]
    Io(std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("Something went wrong while converting message length to u32 or usize")]
    MessageLength,
    #[error("Protocol error, got Cookie or Shutdown at an incorrect time")]
    Protocol,
    #[error(transparent)]
    Utf8(#[from] std::str::Utf8Error),
}

#[derive(Deserialize, Serialize)]
pub enum ManagerMsgInternal<T> {
    Shutdown,
    User(T),
}

#[derive(Deserialize, Serialize)]
pub enum WorkerMsgInternal<T> {
    Cookie(String),
    User(T),
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        if e.kind() == std::io::ErrorKind::UnexpectedEof {
            Self::Eof
        } else {
            Self::Io(e)
        }
    }
}

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Option<multi_process_tests::Subcommand>,
}

/// Don't use. This is just for internal tests that are difficult to do with `cargo test`
pub fn run_multi_process_tests() -> Result<()> {
    let cli = Cli::parse();
    multi_process_tests::run(cli.cmd)
}

/// Returns a random valid named pipe ID based on a UUIDv4
///
/// e.g. "\\.\pipe\dev.firezone.client\9508e87c-1c92-4630-bb20-839325d169bd"
///
/// Normally you don't need to call this directly. Tests may need it to inject
/// a known pipe ID into a process controlled by the test.
pub(crate) fn random_pipe_id() -> String {
    named_pipe_path(&uuid::Uuid::new_v4().to_string())
}

/// Returns a valid named pipe ID
///
/// e.g. "\\.\pipe\dev.firezone.client\{path}"
pub(crate) fn named_pipe_path(path: &str) -> String {
    format!(r"\\.\pipe\subzone\{path}")
}

/// Reads a message from an async reader, with a 32-bit little-endian length prefix
async fn read_deserialize<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Vec<u8>, Error> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    tracing::trace!(?len, "reading message");
    let len = usize::try_from(len).map_err(|_| Error::MessageLength)?;
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf).await?;
    Ok(buf)
}

/// Writes a message to an async writer, with a 32-bit little-endian length prefix
async fn write_serialize<W: AsyncWrite + Unpin, T: Serialize>(
    writer: &mut W,
    msg: &T,
) -> Result<(), Error> {
    // Using JSON because `bincode` couldn't decode `ResourceDescription`
    let buf = serde_json::to_string(msg)?;
    let len = u32::try_from(buf.len())
        .map_err(|_| Error::MessageLength)?
        .to_le_bytes();
    tracing::trace!(len = buf.len(), "writing message");
    writer.write_all(&len).await?;
    writer.write_all(buf.as_bytes()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::server::UnconnectedServer;
    use super::*;
    use crate::multi_process_tests::{Callback, ManagerMsg, WorkerMsg};
    use anyhow::Context;
    use std::time::{Duration, Instant};
    use tokio::runtime::Runtime;

    /// Because it turns out `bincode` can't deserialize `ResourceDescription` or something.
    #[test]
    fn round_trip_serde() -> Result<()> {
        let cb: WorkerMsg = WorkerMsg::Callback(Callback::OnUpdateResources(sample_resources()));

        let v = serde_json::to_string(&cb)?;
        let roundtripped: WorkerMsg = serde_json::from_str(&v)?;

        assert_eq!(roundtripped, cb);

        Ok(())
    }

    /// Test just the happy path
    /// It's hard to simulate a process crash because:
    /// - If I Drop anything, Tokio will clean it up
    /// - If I `std::mem::forget` anything, the test process is still running, so Windows will not clean it up
    #[test]
    #[tracing::instrument(skip_all)]
    fn happy_path() -> Result<()> {
        tracing_subscriber::fmt::try_init().ok();

        let rt = Runtime::new()?;
        rt.block_on(async move {
            // Pretend we're in the main process
            let (server, server_id) = UnconnectedServer::new()?;

            let worker_task = tokio::spawn(async move {
                // Pretend we're in a worker process
                let mut client: Client<ManagerMsg, WorkerMsg> = Client::new_unsecured(&server_id)?;

                client
                    .send(WorkerMsg::Callback(Callback::OnUpdateResources(
                        sample_resources(),
                    )))
                    .await?;

                // Handle requests from the main process
                loop {
                    let Ok(ManagerMsgInternal::User(req)) = client.next().await else {
                        tracing::debug!("shutting down worker_task");
                        break;
                    };
                    tracing::debug!(?req, "worker_task got request");
                    let resp = WorkerMsg::Response(req.clone());
                    client.send(resp).await?;
                }
                client.close().await?;
                Ok::<_, anyhow::Error>(())
            });

            let mut server: Server<ManagerMsg, WorkerMsg> = server.accept().await?;

            let start_time = Instant::now();

            let cb = server
                .next()
                .await
                .context("should have gotten a OnUpdateResources callback")?;
            assert_eq!(
                cb,
                WorkerMsg::Callback(Callback::OnUpdateResources(sample_resources()))
            );

            server.send(ManagerMsg::Connect).await?;
            assert_eq!(
                server.next().await.unwrap(),
                WorkerMsg::Response(ManagerMsg::Connect)
            );
            server.send(ManagerMsg::Connect).await?;
            assert_eq!(
                server.next().await.unwrap(),
                WorkerMsg::Response(ManagerMsg::Connect)
            );

            let elapsed = start_time.elapsed();
            assert!(elapsed < Duration::from_millis(20), "{:?}", elapsed);

            server.close().await?;

            // Make sure the worker 'process' exited
            worker_task.await??;

            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    fn sample_resources() -> Vec<String> {
        vec![
            "2efe9c25-bd92-49a0-99d7-8b92da014dd5".into(),
            "613eaf56-6efa-45e5-88aa-ea4ad64d8c18".into(),
        ]
    }
}
