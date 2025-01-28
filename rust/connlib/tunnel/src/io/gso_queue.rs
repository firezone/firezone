use std::{
    collections::HashMap,
    mem,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use bytes::BytesMut;
use socket_factory::DatagramOut;

use super::MAX_INBOUND_PACKET_BATCH;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// Holds UDP datagrams that we need to send, indexed by src, dst and segment size.
///
/// Calling [`Io::send_network`](super::Io::send_network) will copy the provided payload into this buffer.
/// The buffer is then flushed using GSO in a single syscall.
pub struct GsoQueue {
    inner: HashMap<Key, DatagramBuffer>,
    buffer_pool: Arc<lockfree_object_pool::SpinLockObjectPool<BytesMut>>,
}

impl GsoQueue {
    pub fn new() -> Self {
        Self {
            inner: Default::default(),
            buffer_pool: Arc::new(lockfree_object_pool::SpinLockObjectPool::new(
                || {
                    tracing::debug!("Initialising new buffer for GSO queue");

                    BytesMut::with_capacity(MAX_SEGMENT_SIZE * MAX_INBOUND_PACKET_BATCH)
                },
                |b| b.clear(),
            )),
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

        debug_assert!(
            segment_size <= MAX_SEGMENT_SIZE,
            "MAX_SEGMENT_SIZE is miscalculated"
        );

        self.inner
            .entry(Key {
                src,
                dst,
                segment_size,
            })
            .or_insert_with(|| DatagramBuffer {
                inner: self.buffer_pool.pull_owned(),
                last_access: now,
            })
            .extend(payload, now);
    }

    pub fn datagrams(
        &mut self,
    ) -> impl Iterator<Item = DatagramOut<lockfree_object_pool::SpinLockOwnedReusable<BytesMut>>> + '_
    {
        self.inner
            .iter_mut()
            .filter(|(_, b)| !b.is_empty())
            .map(|(key, buffer)| DatagramOut {
                src: key.src,
                dst: key.dst,
                packet: mem::replace(&mut buffer.inner, self.buffer_pool.pull_owned()),
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
    inner: lockfree_object_pool::SpinLockOwnedReusable<BytesMut>,
    last_access: Instant,
}

impl DatagramBuffer {
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

    #[test]
    fn dropping_datagram_iterator_does_not_drop_items() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST, b"foobar", now);

        let datagrams = send_queue.datagrams();
        drop(datagrams);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(datagrams[0].dst, DST);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobar");
    }

    const DST: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1234));
}
