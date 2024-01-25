//! Inter-process communication for the connlib subprocess on Windows
//!
//! To run the unit tests and multi-process tests, use
//! ```bash
//! cargo test --all-features -p firezone-windows-client && \
//! RUST_LOG=debug cargo run -p firezone-windows-client debug test-ipc
//! ```
//!
//! # Design
//!
//! The IPC module is specialized for Firezone, but it could be made generic by
//! replacing `WorkerMsg` and `ManagerMsg` with generics.
//!
//! `ManagerMsg::Disconnect` is used as an in-band shutdown signal. It disconnects
//! connlib and then gracefully shuts down the named pipe and worker process.
//!
//! It has these features:
//!
//! - Kill unresponsive worker if needed
//! - Automatically kill workers if the manager process exits
//! - The manager can receive callbacks concurrently with 0 or 1 in-flight requests to the worker
//! - Confirms that the child process connected to our named pipe and not some other process
//!
//! # Graceful shutdown
//!
//! For consistency, graceful shutdowns of a worker process are always initiated
//! by the manager process. If a worker process wants to shut down, it should ask
//! the manager to shut it down, and the manager will enter the shutdown flow.
//!
//! Always initiating from the manager means that killing an unresponsive worker process
//! is only an edge case of a normal shutdown.
//!
//! A graceful shutdown requires 3 steps :
//!
//! 1. Closing the named pipe on both sides
//! 1. Stopping the `pipe_task` on both sides
//! 1. Exiting the worker process
//!
//! Closing one side of the named pipe will cause the other side's read half to
//! return an error, so only one side can close gracefully.
//!
//! The shutdown flow is:
//!
//! 1. Manager decides to shut down worker
//! 1. Manager signals its pipe task that it will be shut down
//! 1. Manager's pipe task stops reading and waits
//! 1. Manager sends shut down message to worker
//! 1. Worker signals its pipe task to shut down
//! 1. Worker's pipe task closes its end of the pipe cleanly and joins
//! 1. The manager's pipe task detects the pipe close and joins
//! 1. The worker exits its process
//! 1. The manager joins the worker process
//!
//! Since this is all async, it can and should be wrapped with a `tokio::time::timeout`.

use anyhow::Result;
use connlib_shared::messages::ResourceDescription;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::marker::Unpin;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

mod client;
mod server;
// Always enabled, since the integration tests can't run in `cargo test` yet
pub(crate) mod multi_process_tests;

pub(crate) use client::Client;
pub(crate) use server::{LeakGuard, Server, SubcommandChild, Subprocess};

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
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
    #[error(transparent)]
    Utf8(#[from] std::string::FromUtf8Error),
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

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum ManagerMsg {
    Connect,
    Disconnect,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum WorkerMsg {
    /// A message that is not in response to any manager request
    ///
    /// Typically a wrapped connlib callback
    Callback(Callback),
    /// Response to a manager-initiated request to connlib (e.g. connect, disconnect)
    Response(ManagerMsg), // All ManagerMsg variants happen to be requests
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Callback {
    /// Cookie for named pipe security
    Cookie(String),
    DisconnectedTokenExpired,
    /// Connlib disconnected and we should gracefully join the worker process
    OnDisconnect,
    OnUpdateResources(Vec<ResourceDescription>),
    TunnelReady,
}

/// Reads a message from an async reader, with a 32-bit little-endian length prefix
#[tracing::instrument(skip(reader))]
async fn read_deserialize<R: AsyncRead + Unpin, T: std::fmt::Debug + DeserializeOwned>(
    reader: &mut R,
) -> Result<T, Error> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    tracing::trace!(?len, "reading message");
    let len = usize::try_from(len).map_err(|_| Error::MessageLength)?;
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf).await?;
    let buf = String::from_utf8(buf)?;
    let msg = serde_json::from_str(&buf)?;
    tracing::trace!(?msg, "read message");
    Ok(msg)
}

/// Writes a message to an async writer, with a 32-bit little-endian length prefix
#[tracing::instrument(skip(writer))]
async fn write_serialize<W: AsyncWrite + Unpin, T: std::fmt::Debug + Serialize>(
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
    use anyhow::Context;
    use connlib_shared::messages::{
        ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns, ResourceId,
    };
    use std::{
        str::FromStr,
        time::{Duration, Instant},
    };
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
                let mut client = Client::new_unsecured(&server_id)?;

                client
                    .send(&WorkerMsg::Callback(Callback::OnUpdateResources(
                        sample_resources(),
                    )))
                    .await?;

                // Handle requests from the main process
                loop {
                    let Ok(req) = client.recv().await else {
                        tracing::debug!("shutting down worker_task");
                        break;
                    };
                    tracing::debug!(?req, "worker_task got request");
                    let resp = WorkerMsg::Response(req.clone());
                    client.send(&resp).await?;

                    if let ManagerMsg::Disconnect = req {
                        break;
                    }
                }
                client.close().await?;
                Ok::<_, anyhow::Error>(())
            });

            let mut server = server.accept().await?;

            let start_time = Instant::now();

            let cb = server
                .cb_rx
                .recv()
                .await
                .context("should have gotten a OnUpdateResources callback")?;
            assert_eq!(cb, Callback::OnUpdateResources(sample_resources()));

            server.send(&ManagerMsg::Connect).await?;
            assert_eq!(
                server.response_rx.recv().await.unwrap(),
                ManagerMsg::Connect
            );
            server.send(&ManagerMsg::Connect).await?;
            assert_eq!(
                server.response_rx.recv().await.unwrap(),
                ManagerMsg::Connect
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

    fn sample_resources() -> Vec<ResourceDescription> {
        vec![
            ResourceDescription::Cidr(ResourceDescriptionCidr {
                id: ResourceId::from_str("2efe9c25-bd92-49a0-99d7-8b92da014dd5").unwrap(),
                name: "Cloudflare DNS".to_string(),
                address: ip_network::IpNetwork::from_str("1.1.1.1/32").unwrap(),
            }),
            ResourceDescription::Dns(ResourceDescriptionDns {
                id: ResourceId::from_str("613eaf56-6efa-45e5-88aa-ea4ad64d8c18").unwrap(),
                name: "Example".to_string(),
                address: "*.example.com".to_string(),
            }),
        ]
    }
}
