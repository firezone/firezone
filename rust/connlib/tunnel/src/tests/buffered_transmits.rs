use super::sim_net::Host;
use snownet::Transmit;
use std::{cmp::Reverse, collections::BinaryHeap, time::Instant};

#[derive(Debug, Default)]
pub(crate) struct BufferedTransmits {
    // Transmits are stored in reverse ordering to emit the earliest first.
    inner: BinaryHeap<Reverse<ByTime<Transmit<'static>>>>,
}

#[derive(Debug, PartialEq, PartialOrd, Eq, Ord)]
struct ByTime<T> {
    at: Instant,
    value: T,
}

impl BufferedTransmits {
    pub(crate) fn push<T>(
        &mut self,
        transmit: impl Into<Option<Transmit<'static>>>,
        sending_host: &Host<T>,
        now: Instant,
    ) {
        let Some(transmit) = transmit.into() else {
            return;
        };

        if transmit.src.is_some() {
            self.inner.push(Reverse(ByTime {
                at: now + sending_host.latency(),
                value: transmit,
            }));
            return;
        }

        // The `src` of a [`Transmit`] is empty if we want to send if via the default interface.
        // In production, the kernel does this for us.
        // In this test, we need to always set a `src` so that the remote peer knows where the packet is coming from.

        let Some(src) = sending_host.sending_socket_for(transmit.dst.ip()) else {
            tracing::debug!(dst = %transmit.dst, "No socket");

            return;
        };

        self.inner.push(Reverse(ByTime {
            at: now + sending_host.latency(),
            value: Transmit {
                src: Some(src),
                ..transmit
            },
        }));
    }

    pub(crate) fn pop(&mut self, now: Instant) -> Option<Transmit<'static>> {
        let next = self.inner.peek()?.0.at;

        if next > now {
            return None;
        }

        let next = self.inner.pop().unwrap().0;

        Some(next.value)
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
