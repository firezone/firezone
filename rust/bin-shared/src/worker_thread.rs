//! A generic worker thread with channels for communication and graceful stopping.
//!
//! The Rust GUI Clients have a bunch of random things that aren't happy
//! with Tokio's `async`, like DNS and network change listening on Windows,
//! and the upcoming `tray_icon` tray menu. (Presumably Tauri runs a worker thread internally or does something special)
//!
//! Using a worker thread and `LocalSet` appeases these APIs.

use anyhow::{anyhow, Context as _, Result};
use std::thread;
use tokio::sync::{mpsc, oneshot};

/// Container for a worker thread that we can cooperatively stop.
///
/// The worker thread emits notifications with no data in them.
pub(crate) struct Worker<Inbound: Send + 'static> {
    inner: Option<Inner>,
    thread_name: String,
    /// This will be needed later when the system tray uses this code
    _in_tx: mpsc::Sender<Inbound>,
}

struct Inner {
    stop_tx: oneshot::Sender<()>,
    thread: thread::JoinHandle<Result<()>>,
}

/// Inbound to the worker thread, outbound from the worker thread.
pub(crate) struct Params<Inbound, Outbound> {
    /// This will be needed later when the system tray uses this code
    pub(crate) _in_rx: mpsc::Receiver<Inbound>,
    pub(crate) out_tx: mpsc::Sender<Outbound>,
    pub(crate) stop_rx: oneshot::Receiver<()>,
}

impl<Inbound: Send + 'static> Drop for Worker<Inbound> {
    fn drop(&mut self) {
        self.close()
            .expect("Should be able to stop worker thread gracefully.");
    }
}

impl<Inbound: Send + 'static> Worker<Inbound> {
    /// Spawn and run a new worker thread.
    pub(crate) fn new<
        Outbound: Send + 'static,
        S: Into<String>,
        F: FnOnce(Params<Inbound, Outbound>) -> Result<()> + Send + 'static,
    >(
        thread_name: S,
        func: F,
    ) -> Result<(Self, mpsc::Receiver<Outbound>)> {
        let (_in_tx, _in_rx) = mpsc::channel(1);
        let (out_tx, out_rx) = mpsc::channel(1);
        let (stop_tx, stop_rx) = oneshot::channel();

        let params = Params {
            _in_rx,
            out_tx,
            stop_rx,
        };
        let thread_name = thread_name.into();
        let thread = thread::Builder::new()
            .name(thread_name.clone())
            .spawn(move || func(params))?;

        let inner = Inner { stop_tx, thread };

        Ok((
            Self {
                inner: Some(inner),
                thread_name,
                _in_tx,
            },
            out_rx,
        ))
    }

    /// Same as `drop`, but you can catch and log errors
    pub(crate) fn close(&mut self) -> Result<()> {
        let Some(inner) = self.inner.take() else {
            return Ok(());
        };

        tracing::trace!(
            thread_name = self.thread_name,
            "Asking worker thread to stop gracefully."
        );
        if let Err(_error) = inner.stop_tx.send(()) {
            tracing::error!(
                "Couldn't stop `{}` worker thread, maybe it crashed",
                self.thread_name
            );
        }
        match inner.thread.join() {
            Err(error) => {
                tracing::error!("Resuming unwind for worker thread");
                std::panic::resume_unwind(error)
            }
            Ok(x) => {
                x.with_context(|| format!("Error inside worker thread `{}`", self.thread_name))?
            }
        }
        tracing::trace!("Worker thread `{}` stopped gracefully.", self.thread_name);

        Ok(())
    }

    /// This will be needed later when the system tray uses this code
    pub(crate) async fn _send(&self, inbound: Inbound) -> Result<()> {
        self._in_tx.send(inbound).await.map_err(|_| {
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
    use tokio::task::LocalSet;

    #[tokio::test]
    async fn ping() {
        let _logs = firezone_logging::test("debug");
        let tokio_handle = tokio::runtime::Handle::current();
        let (mut worker, mut rx) = Worker::new("Firezone ping", move |params| {
            let local = LocalSet::new();
            let task = local.run_until(ping_task(params));
            tokio_handle.block_on(task)
        })
        .unwrap();

        worker._send(42).await.unwrap();
        assert_eq!(rx.recv().await.unwrap(), 84);

        worker.close().unwrap();
    }

    async fn ping_task(params: Params<u32, u32>) -> Result<()> {
        let Params {
            mut _in_rx,
            out_tx,
            stop_rx,
        } = params;
        let mut stop_rx = pin!(stop_rx.fuse());
        loop {
            let mut in_rx = pin!(_in_rx.recv().fuse());
            futures::select! {
                _ = stop_rx => break,
                inbound = in_rx => out_tx.send(inbound.unwrap() * 2).await.unwrap(),
            }
        }
        Ok(())
    }

    #[tokio::test]
    async fn notifier_worker() {
        let _logs = firezone_logging::test("debug");

        let (mut worker, mut rx) =
            Worker::new("Firezone bogus network notifier", notifier_task).unwrap();

        rx.recv().await.unwrap();
        tracing::info!("Got notification");

        worker.close().unwrap();
    }

    fn notifier_task(params: Params<(), ()>) -> Result<()> {
        let Params {
            _in_rx,
            out_tx,
            stop_rx,
        } = params;
        out_tx.try_send(())?;
        stop_rx.blocking_recv()?;
        Ok(())
    }
}
