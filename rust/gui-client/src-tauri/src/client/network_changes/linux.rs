//! Not implemented for Linux yet

use anyhow::Result;
use tokio::{sync::mpsc, task::JoinHandle, time::Interval};

/// TODO: Implement for Linux
pub(crate) fn check_internet() -> Result<bool> {
    Ok(true)
}

/// Worker task (on Linux) that can be aborted explicitly, and aborts on Drop
///
/// On Linux, this exists to match the design of the worker thread on Windows.
pub(crate) struct Worker {
    task: JoinHandle<Result<()>>,
    rx: mpsc::Receiver<()>,
}

pub(crate) fn dns_notifier(tokio_handle: tokio::runtime::Handle) -> Result<Worker> {
    let (tx, rx) = mpsc::channel(1);
    let task = tokio_handle.spawn(dns_worker_task(tx));
    Ok(Worker { task, rx })
}

/// Signals every 5 seconds (on Linux) when we should check for DNS changes
///
/// This is meant to be spawned. Cancelling it will reset the interval.
///
/// This may switch from polling to listening when <https://github.com/firezone/firezone/issues/5846> closes.
async fn dns_worker_task(tx: mpsc::Sender<()>) -> Result<()> {
    let mut interval = create_interval();
    loop {
        interval.tick().await;
        tracing::trace!("Checking for DNS changes");
        tx.send(()).await?;
    }
}

/// Never signals (on Linux).
///
/// This will be implemented for <https://github.com/firezone/firezone/issues/5846>
pub(crate) fn network_notifier(tokio_handle: tokio::runtime::Handle) -> Result<Worker> {
    let (_tx, rx) = mpsc::channel(1);
    let task = tokio_handle.spawn(futures::future::pending());
    Ok(Worker { task, rx })
}

impl Worker {
    pub(crate) fn close(&mut self) -> Result<()> {
        self.task.abort();
        Ok(())
    }

    pub(crate) async fn notified(&mut self) {
        self.rx.recv().await;
    }
}

/// Creates a 5-second interval that won't spam ticks if it falls behind
fn create_interval() -> Interval {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval
}
