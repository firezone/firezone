use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Owns the channel endpoints and worker threads of a TUN implementation.
///
/// Dropping closes the channels before joining the threads. Platform-specific
/// blocking IO must be cancelled before these workers are dropped.
pub struct Workers<Outbound = crate::OutboundTx, Inbound = crate::InboundRx> {
    state: Option<(Outbound, Inbound)>,
    send_thread: Option<JoinHandle<()>>,
    recv_thread: Option<JoinHandle<()>>,
}

impl<Outbound, Inbound> Workers<Outbound, Inbound> {
    /// Starts one worker thread per IO direction.
    pub fn spawn(
        outbound_tx: Outbound,
        inbound_rx: Inbound,
        send: impl FnOnce() + Send + 'static,
        recv: impl FnOnce() + Send + 'static,
    ) -> std::io::Result<Self> {
        let mut workers = Self {
            state: Some((outbound_tx, inbound_rx)),
            send_thread: None,
            recv_thread: None,
        };

        workers.send_thread = Some(
            std::thread::Builder::new()
                .name("TUN send".to_owned())
                .spawn(send)?,
        );
        workers.recv_thread = Some(
            std::thread::Builder::new()
                .name("TUN recv".to_owned())
                .spawn(recv)?,
        );

        Ok(workers)
    }

    pub fn sender(&self) -> &Outbound {
        &self
            .state
            .as_ref()
            .expect("Worker channels are present until drop")
            .0
    }

    pub fn receiver(&mut self) -> &mut Inbound {
        &mut self
            .state
            .as_mut()
            .expect("Worker channels are present until drop")
            .1
    }
}

impl<Outbound, Inbound> Drop for Workers<Outbound, Inbound> {
    fn drop(&mut self) {
        const SHUTDOWN_WAIT: Duration = Duration::from_secs(10);

        let threads = [
            ("recv", self.recv_thread.take()),
            ("send", self.send_thread.take()),
        ];
        drop(self.state.take());
        let start = Instant::now();

        loop {
            let finished = threads
                .iter()
                .all(|(_, thread)| thread.as_ref().is_none_or(JoinHandle::is_finished));

            if finished {
                break;
            }

            if start.elapsed() > SHUTDOWN_WAIT {
                tracing::warn!("TUN worker threads did not exit gracefully in {SHUTDOWN_WAIT:?}");
                return;
            }

            std::thread::sleep(Duration::from_millis(100));
        }

        tracing::debug!(elapsed = ?start.elapsed(), "TUN worker threads exited gracefully");

        for (direction, thread) in threads {
            let Some(thread) = thread else {
                continue;
            };
            if let Err(error) = thread.join() {
                tracing::error!(direction, "TUN worker thread panicked: {error:?}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc, Barrier,
        atomic::{AtomicUsize, Ordering},
    };

    #[test]
    fn drop_closes_channels_and_joins_both_workers() {
        let (outbound_tx, mut outbound_rx) = tokio::sync::mpsc::channel::<()>(1);
        let (inbound_tx, inbound_rx) = tokio::sync::mpsc::channel::<()>(1);
        let started = Arc::new(Barrier::new(3));
        let stopped = Arc::new(AtomicUsize::new(0));
        let workers = Workers::spawn(
            outbound_tx,
            inbound_rx,
            {
                let started = started.clone();
                let stopped = stopped.clone();
                move || {
                    started.wait();
                    assert!(outbound_rx.blocking_recv().is_none());
                    stopped.fetch_add(1, Ordering::SeqCst);
                }
            },
            {
                let started = started.clone();
                let stopped = stopped.clone();
                move || {
                    started.wait();
                    while inbound_tx.blocking_send(()).is_ok() {}
                    stopped.fetch_add(1, Ordering::SeqCst);
                }
            },
        )
        .unwrap();
        started.wait();

        drop(workers);

        assert_eq!(stopped.load(Ordering::SeqCst), 2);
    }
}
