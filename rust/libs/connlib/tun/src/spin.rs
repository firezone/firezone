use std::time::{Duration, Instant};

use tokio::sync::mpsc::{self, error::TryRecvError};

/// How long a receiver spins on an empty channel before parking.
///
/// Off on mobile, where the battery is worth more than the wake-ups saved.
const SPIN_MAX: Duration = cfg_select! {
    any(target_os = "ios", target_os = "android") => { Duration::ZERO }
    _ => { Duration::from_micros(200) }
};

/// A channel receiver that keeps polling an empty channel for up to [`SPIN_MAX`] before parking,
/// as long as its last item arrived within that time.
///
/// While it spins, a sender has no parked receiver to wake and thus skips the wake-up syscall.
/// A receiver whose items arrive further apart parks right away.
#[derive(Debug)]
pub struct SpinningReceiver<T> {
    inner: mpsc::Receiver<T>,
    last_wait: Duration,
}

impl<T> SpinningReceiver<T> {
    pub fn new(inner: mpsc::Receiver<T>) -> Self {
        Self {
            inner,
            last_wait: Duration::MAX,
        }
    }

    pub async fn recv(&mut self) -> Option<T> {
        let start = Instant::now();
        let spin_until = start + self.spin_budget();

        let item = loop {
            match self.inner.try_recv() {
                Ok(item) => break Some(item),
                Err(TryRecvError::Disconnected) => break None,
                Err(TryRecvError::Empty) if Instant::now() < spin_until => {
                    tokio::task::yield_now().await
                }
                Err(TryRecvError::Empty) => break self.inner.recv().await,
            }
        };
        self.last_wait = start.elapsed();

        item
    }

    pub fn blocking_recv(&mut self) -> Option<T> {
        let start = Instant::now();
        let spin_until = start + self.spin_budget();

        let item = loop {
            match self.inner.try_recv() {
                Ok(item) => break Some(item),
                Err(TryRecvError::Disconnected) => break None,
                Err(TryRecvError::Empty) if Instant::now() < spin_until => std::hint::spin_loop(),
                Err(TryRecvError::Empty) => break self.inner.blocking_recv(),
            }
        };
        self.last_wait = start.elapsed();

        item
    }

    /// Receives up to `limit` items into `buffer`, waiting like [`SpinningReceiver::recv`] for the first.
    ///
    /// Returns 0 once the channel is closed and empty.
    pub async fn recv_many(&mut self, buffer: &mut Vec<T>, limit: usize) -> usize {
        let Some(first) = self.recv().await else {
            return 0;
        };
        buffer.push(first);

        let mut received = 1;
        while received < limit
            && let Ok(item) = self.inner.try_recv()
        {
            buffer.push(item);
            received += 1;
        }

        received
    }

    fn spin_budget(&self) -> Duration {
        if self.last_wait < SPIN_MAX {
            SPIN_MAX
        } else {
            Duration::ZERO
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recv_many_takes_at_most_limit_and_reports_close() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let (tx, rx) = mpsc::channel(4);
        let mut rx = SpinningReceiver::new(rx);
        for i in 0..3 {
            tx.try_send(i).unwrap();
        }
        drop(tx);
        let mut buffer = Vec::new();

        runtime.block_on(async {
            assert_eq!(rx.recv_many(&mut buffer, 2).await, 2);
            assert_eq!(rx.recv_many(&mut buffer, 2).await, 1);
            assert_eq!(rx.recv_many(&mut buffer, 2).await, 0);
        });
        assert_eq!(buffer, [0, 1, 2]);
    }
}
