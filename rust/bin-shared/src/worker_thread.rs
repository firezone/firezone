//! A generic worker thread with channels for communication and graceful stopping.
//!
//! The Rust GUI Clients have a bunch of random things that aren't happy
//! with Tokio's `async`, like DNS and network change listening on Windows,
//! and the upcoming `tray_icon` tray menu. (Presumably Tauri runs a worker thread internally or does something special)
//!
//! Using a worker thread and `LocalSet` appeases these APIs.

use anyhow::{anyhow, Result};
use std::{future::Future, thread};
use tokio::{
    sync::{mpsc, oneshot},
    task::LocalSet,
};

/// Container for a worker thread that we can cooperatively stop.
///
/// The worker thread emits notifications with no data in them.
pub struct Worker<Inbound: Send + 'static> {
    inner: Option<WorkerInner>,
    thread_name: String,
    in_tx: mpsc::Sender<Inbound>,
}

struct WorkerInner {
    stop_tx: oneshot::Sender<()>,
    thread: thread::JoinHandle<Result<()>>,
}

pub struct Params<Inbound, Outbound> {
    in_rx: mpsc::Receiver<Inbound>,
    stop_rx: oneshot::Receiver<()>,
    out_tx: mpsc::Sender<Outbound>,
}

impl<Inbound: Send + 'static> Drop for Worker<Inbound> {
    fn drop(&mut self) {
        self.close()
            .expect("Should be able to stop worker thread gracefully.");
    }
}

impl<Inbound: Send + 'static> Worker<Inbound> {
    /// Spawn and run a new worker thread.
    pub fn new<
        Outbound: Send + 'static,
        S: Into<String>,
        Fut: Future<Output = Result<()>>,
        F: FnOnce(Params<Inbound, Outbound>) -> Fut + Send + 'static,
    >(
        tokio_handle: tokio::runtime::Handle,
        thread_name: S,
        func: F,
    ) -> Result<(Self, mpsc::Receiver<Outbound>)> {
        let (in_tx, in_rx) = mpsc::channel(1);
        let (out_tx, out_rx) = mpsc::channel(1);
        let (stop_tx, stop_rx) = oneshot::channel();

        let params = Params {
            in_rx,
            stop_rx,
            out_tx,
        };
        let thread_name = thread_name.into();
        let thread = thread::Builder::new()
            .name(thread_name.clone())
            .spawn(move || {
                let local = LocalSet::new();
                let task = local.run_until(func(params));
                tokio_handle.block_on(task)
            })?;

        let inner = WorkerInner { stop_tx, thread };

        Ok((
            Self {
                inner: Some(inner),
                thread_name,
                in_tx,
            },
            out_rx,
        ))
    }

    /// Same as `drop`, but you can catch and log errors
    pub fn close(&mut self) -> Result<()> {
        let Some(inner) = self.inner.take() else {
            return Ok(());
        };

        tracing::debug!(
            thread_name = self.thread_name,
            "Asking worker thread to stop gracefully."
        );
        inner
            .stop_tx
            .send(())
            .map_err(|_| anyhow!("Couldn't stop `{}` worker thread", self.thread_name))?;
        match inner.thread.join() {
            Err(error) => std::panic::resume_unwind(error),
            Ok(x) => x?,
        }
        tracing::debug!("Worker thread `{}` stopped gracefully.", self.thread_name);

        Ok(())
    }

    pub async fn send(&self, inbound: Inbound) -> Result<()> {
        self.in_tx.send(inbound).await.map_err(|_| {
            anyhow!(
                "Can't send to worker thread `{}`, maybe it crashed",
                self.thread_name
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::FutureExt;
    use std::pin::pin;

    #[tokio::test]
    async fn ping() {
        let (mut worker, mut rx) = Worker::new(
            tokio::runtime::Handle::current(),
            "Firezone test worker",
            ping_task,
        )
        .unwrap();

        worker.send(42).await.unwrap();
        assert_eq!(rx.recv().await.unwrap(), 84);

        worker.close().unwrap();
    }

    // Task that
    async fn ping_task(params: Params<u32, u32>) -> Result<()> {
        let Params {
            mut in_rx,
            stop_rx,
            out_tx,
        } = params;
        let mut stop_rx = pin!(stop_rx.fuse());
        loop {
            let mut in_rx = pin!(in_rx.recv().fuse());
            futures::select! {
                _ = stop_rx => break,
                inbound = in_rx => out_tx.send(inbound.unwrap() * 2).await.unwrap(),
            }
        }
        Ok(())
    }
}
