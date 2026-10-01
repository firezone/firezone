use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

use crate::{InboundRx, InboundTx, OutboundRx, OutboundTx};

/// Owns the channel endpoints and worker threads of a TUN implementation.
///
/// Dropping closes the channels before joining the threads. Platform-specific
/// blocking IO must be cancelled before these workers are dropped.
pub struct Workers {
    state: Option<(OutboundTx, InboundRx)>,
    send_thread: Option<JoinHandle<()>>,
    recv_thread: Option<JoinHandle<()>>,
}

impl Workers {
    /// Starts one worker per IO direction, with packet channels and queue metrics.
    pub fn spawn(
        runtime: &tokio::runtime::Handle,
        send: impl FnOnce(OutboundRx) -> anyhow::Result<()> + Send + 'static,
        recv: impl FnOnce(InboundTx) -> anyhow::Result<()> + Send + 'static,
    ) -> std::io::Result<Self> {
        let (outbound_tx, outbound_rx) = mpsc::channel(crate::CHANNEL_CAPACITY);
        let (inbound_tx, inbound_rx) = mpsc::channel(crate::CHANNEL_CAPACITY);

        runtime.spawn(otel_instruments::periodic_queue_length(
            outbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_transmit(),
            ],
        ));
        runtime.spawn(otel_instruments::periodic_queue_length(
            inbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_receive(),
            ],
        ));

        let mut workers = Self {
            state: Some((OutboundTx(outbound_tx), InboundRx(inbound_rx))),
            send_thread: None,
            recv_thread: None,
        };

        let send_thread = spawn_worker("send", move || send(OutboundRx(outbound_rx)))?;
        workers.send_thread = Some(send_thread);
        let recv_thread = spawn_worker("recv", move || recv(InboundTx(inbound_tx)))?;
        workers.recv_thread = Some(recv_thread);

        Ok(workers)
    }
}

impl Workers {
    pub fn sender(&self) -> &OutboundTx {
        &self
            .state
            .as_ref()
            .expect("Worker channels are present until drop")
            .0
    }

    pub fn receiver(&mut self) -> &mut InboundRx {
        &mut self
            .state
            .as_mut()
            .expect("Worker channels are present until drop")
            .1
    }
}

impl Drop for Workers {
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

fn spawn_worker(
    direction: &'static str,
    worker: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
) -> std::io::Result<JoinHandle<()>> {
    let thread = std::thread::Builder::new()
        .name(format!("TUN {direction}"))
        .spawn(move || {
            logging::unwrap_or_warn!(worker(), "TUN {direction} worker failed: {}");
        })?;

    Ok(thread)
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
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let started = Arc::new(Barrier::new(3));
        let stopped = Arc::new(AtomicUsize::new(0));
        let workers = Workers::spawn(
            runtime.handle(),
            {
                let started = started.clone();
                let stopped = stopped.clone();
                move |mut outbound_rx| {
                    started.wait();
                    assert!(outbound_rx.blocking_recv().is_none());
                    stopped.fetch_add(1, Ordering::SeqCst);

                    Ok(())
                }
            },
            {
                let started = started.clone();
                let stopped = stopped.clone();
                move |inbound_tx| {
                    started.wait();
                    while inbound_tx
                        .blocking_send(crate::PacketBatch::default())
                        .is_ok()
                    {}
                    stopped.fetch_add(1, Ordering::SeqCst);

                    Ok(())
                }
            },
        )
        .unwrap();
        started.wait();

        drop(workers);

        assert_eq!(stopped.load(Ordering::SeqCst), 2);
    }
}
