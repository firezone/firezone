use std::{
    collections::BTreeMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

use bytes::{Bytes, BytesMut};
use socket_factory::DatagramOut;

use super::MAX_INBOUND_PACKET_BATCH;

/// Holds UDP datagrams that we need to send, indexed by src, dst and segment size.
///
/// Calling [`Io::send_network`](super::Io::send_network) will copy the provided payload into this buffer.
/// The buffer is then flushed using GSO in a single syscall.
pub struct GsoQueue {
    inner: BTreeMap<Key, DatagramBuffer>,
}

impl GsoQueue {
    pub fn new() -> Self {
        Self {
            inner: Default::default(),
        }
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.inner.retain(|_, b| {
            if !b.is_empty() {
                return true;
            }

            now.duration_since(b.last_access) < Duration::from_secs(60)
        })
    }

    pub fn enqueue(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        payload: &[u8],
        now: Instant,
    ) {
        let segment_size = payload.len();

        // At most, a single batch translates to packets all going to the same destination and length.
        // Thus, to avoid a lot of re-allocations during sending, allocate enough space to store a quarter of the packets in a batch.
        // Re-allocations happen by doubling the capacity, so this means we have at most 2 re-allocation.
        // This number has been chosen empirically by observing how big the GSO batches typically are.
        let capacity = segment_size * MAX_INBOUND_PACKET_BATCH / 4;

        self.inner
            .entry(Key {
                src,
                dst,
                segment_size,
            })
            .or_insert_with(|| DatagramBuffer::new(now, capacity))
            .extend(payload, now);
    }

    pub fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut<Bytes>> + '_ {
        self.inner
            .iter_mut()
            .filter(|(_, b)| !b.is_empty())
            .map(|(key, buffer)| DatagramOut {
                src: key.src,
                dst: key.dst,
                packet: buffer.inner.split().freeze(),
                segment_size: Some(key.segment_size),
            })
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Key {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    segment_size: usize,
}

struct DatagramBuffer {
    inner: BytesMut,
    last_access: Instant,
}

impl DatagramBuffer {
    pub fn new(now: Instant, capacity: usize) -> Self {
        Self {
            inner: BytesMut::with_capacity(capacity),
            last_access: now,
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    pub(crate) fn extend(&mut self, payload: &[u8], now: Instant) {
        self.inner.extend_from_slice(payload);
        self.last_access = now;
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    #[test]
    fn send_queue_gcs_after_1_minute() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST, b"foobar", now);
        for _entry in send_queue.datagrams() {}

        send_queue.handle_timeout(now + Duration::from_secs(60));

        assert_eq!(send_queue.inner.len(), 0);
    }

    #[test]
    fn does_not_gc_unsent_items() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST, b"foobar", now);

        send_queue.handle_timeout(now + Duration::from_secs(60));

        assert_eq!(send_queue.inner.len(), 1);
    }

    const DST: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1234));
}
