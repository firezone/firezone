use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use sentry::{Envelope, sentry_debug};

use crate::sentry_vendor::{RateLimiter, RateLimitingCategory};

#[expect(
    clippy::large_enum_variant,
    reason = "In normal usage this is usually SendEnvelope, the other variants are only used when \
    the user manually calls transport.flush() or when the transport is shut down."
)]
enum Task {
    SendEnvelope(Envelope),
    Flush(SyncSender<()>),
    Shutdown,
}

pub struct TransportThread {
    sender: SyncSender<Task>,
    shutdown: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl TransportThread {
    pub fn new<S, SendFn, SendFuture>(mut state: S, mut send: SendFn) -> Self
    where
        SendFn: FnMut(S, Envelope, RateLimiter) -> SendFuture + Send + 'static,
        // NOTE: returning RateLimiter here, otherwise we are in borrow hell
        SendFuture: std::future::Future<Output = (S, RateLimiter)>,
        S: Send + 'static,
    {
        let (sender, receiver) = sync_channel(30);
        let shutdown = Arc::new(AtomicBool::new(false));
        let shutdown_worker = shutdown.clone();
        let handle = thread::Builder::new()
            .name("sentry-transport".into())
            .spawn(move || {
                // create a runtime on the transport thread
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("Should be able to create a runtime");

                let mut rl = RateLimiter::new();

                // and block on an async fn in this runtime/thread
                rt.block_on(async move {
                    for task in receiver.into_iter() {
                        if shutdown_worker.load(Ordering::SeqCst) {
                            return;
                        }
                        let envelope = match task {
                            Task::SendEnvelope(envelope) => envelope,
                            Task::Flush(sender) => {
                                sender.send(()).ok();
                                continue;
                            }
                            Task::Shutdown => {
                                return;
                            }
                        };

                        if let Some(time_left) = rl.is_disabled(RateLimitingCategory::Any) {
                            sentry_debug!(
                                "Skipping event send because we're disabled due to rate limits for {}s",
                                time_left.as_secs()
                            );
                            continue;
                        }
                        match rl.filter_envelope(envelope) {
                            Some(envelope) => {
                                let (new_state, new_rl) = send(state, envelope, rl).await;

                                state = new_state;
                                rl = new_rl;
                            },
                            None => {
                                sentry_debug!("Envelope was discarded due to per-item rate limits");
                            },
                        };
                    }
                })
            })
            .ok();

        Self {
            sender,
            shutdown,
            handle,
        }
    }

    pub fn send(&self, envelope: Envelope) {
        // Using send here would mean that when the channel fills up for whatever
        // reason, trying to send an envelope would block everything. We'd rather
        // drop the envelope in that case.
        if let Err(e) = self.sender.try_send(Task::SendEnvelope(envelope)) {
            sentry_debug!("envelope dropped: {e}");
        }
    }

    pub fn flush(&self, timeout: Duration) -> bool {
        let (sender, receiver) = sync_channel(1);
        let _ = self.sender.send(Task::Flush(sender));
        receiver.recv_timeout(timeout).is_ok()
    }
}

impl Drop for TransportThread {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        let _ = self.sender.send(Task::Shutdown);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}
