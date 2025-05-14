use super::sim_net::Host;
use snownet::Transmit;
use std::{
    cmp::Reverse,
    collections::BinaryHeap,
    time::{Duration, Instant},
};

/// A buffer for network packets that need to be handled at a certain point in time.
#[derive(Debug, Clone, Default)]
pub(crate) struct BufferedTransmits {
    // Transmits are stored in reverse ordering to emit the earliest first.
    inner: BinaryHeap<Reverse<ByTime<Transmit>>>,
}

#[derive(Clone, Debug, PartialEq, PartialOrd, Eq, Ord)]
struct ByTime<T> {
    at: Instant,
    value: T,
}

impl BufferedTransmits {
    /// Pushes a new [`Transmit`] from a given [`Host`].
    pub(crate) fn push_from<T>(
        &mut self,
        transmit: impl Into<Option<Transmit>>,
        sending_host: &Host<T>,
        now: Instant,
    ) {
        let Some(transmit) = transmit.into() else {
            return;
        };

        if transmit.src.is_some() {
            self.push(transmit, sending_host.latency(), now);
            return;
        }

        // The `src` of a [`Transmit`] is empty if we want to send if via the default interface.
        // In production, the kernel does this for us.
        // In this test, we need to always set a `src` so that the remote peer knows where the packet is coming from.

        let Some(src) = sending_host.sending_socket_for(transmit.dst.ip()) else {
            tracing::debug!(dst = %transmit.dst, "No socket");

            return;
        };

        let transmit = Transmit {
            src: Some(src),
            ..transmit
        };

        tracing::trace!(?transmit, "Scheduling transmit");

        self.push(transmit, sending_host.latency(), now);
    }

    pub(crate) fn push(
        &mut self,
        transmit: impl Into<Option<Transmit>>,
        latency: Duration,
        now: Instant,
    ) {
        let Some(transmit) = transmit.into() else {
            return;
        };

        debug_assert!(transmit.src.is_some(), "src must be set for `push`");

        self.inner.push(Reverse(ByTime {
            at: now + latency,
            value: transmit,
        }));
    }

    pub(crate) fn pop(&mut self, now: Instant) -> Option<Transmit> {
        if self.next_transmit()? > now {
            return None;
        }

        let next = self.inner.pop().unwrap().0;

        tracing::trace!(transmit = ?next.value, "Delivering transmit");

        Some(next.value)
    }

    pub(crate) fn next_transmit(&self) -> Option<Instant> {
        Some(self.inner.peek()?.0.at)
    }

    pub(crate) fn drain(&mut self) -> impl Iterator<Item = (Transmit, Instant)> + '_ {
        self.inner
            .drain()
            .map(|Reverse(ByTime { at, value })| (value, at))
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn by_time_orders_from_earliest_to_latest() {
        let mut heap = BinaryHeap::new();
        let start = Instant::now();

        heap.push(ByTime {
            at: start + Duration::from_secs(1),
            value: 1,
        });
        heap.push(ByTime {
            at: start,
            value: 0,
        });
        heap.push(ByTime {
            at: start + Duration::from_secs(2),
            value: 2,
        });

        assert_eq!(
            heap.pop().unwrap(),
            ByTime {
                at: start + Duration::from_secs(2),
                value: 2
            },
        );
        assert_eq!(
            heap.pop().unwrap(),
            ByTime {
                at: start + Duration::from_secs(1),
                value: 1
            }
        );
        assert_eq!(
            heap.pop().unwrap(),
            ByTime {
                at: start,
                value: 0
            }
        );
    }
}
