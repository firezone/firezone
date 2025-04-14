use std::{
    collections::BTreeMap,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use bytes::BytesMut;
use ip_packet::Ecn;
use socket_factory::DatagramOut;

use super::MAX_INBOUND_PACKET_BATCH;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// Holds UDP datagrams that we need to send, indexed by src, dst and segment size.
///
/// Calling [`Io::send_network`](super::Io::send_network) will copy the provided payload into this buffer.
/// The buffer is then flushed using GSO in a single syscall.
pub struct GsoQueue {
    inner: BTreeMap<Key, DatagramBuffer>,
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
            if !{
                let this = &b;
                this.inner.as_ref().is_none_or(|b| b.is_empty())
            } {
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
        ecn: Ecn,
        now: Instant,
    ) {
        let segment_size = payload.len();

        debug_assert!(
            segment_size <= MAX_SEGMENT_SIZE,
            "MAX_SEGMENT_SIZE is miscalculated"
        );

        let buffer = self
            .inner
            .entry(Key {
                src,
                dst,
                segment_size,
            })
            .or_insert_with(|| DatagramBuffer {
                inner: None,
                last_access: now,
                ecn,
            });

        buffer
            .inner
            .get_or_insert_with(|| self.buffer_pool.pull_owned())
            .extend_from_slice(payload);
        buffer.last_access = now;
        buffer.ecn = ecn;
    }

    pub fn datagrams(
        &mut self,
    ) -> impl Iterator<Item = DatagramOut<lockfree_object_pool::SpinLockOwnedReusable<BytesMut>>> + '_
    {
        self.inner.iter_mut().filter_map(|(key, buffer)| {
            let ecn = buffer.ecn;
            // It is really important that we `take` the buffer here, otherwise it is not returned to the pool after.
            let buffer = buffer.inner.take()?;

            if buffer.is_empty() {
                return None;
            }

            Some(DatagramOut {
                src: key.src,
                dst: key.dst,
                packet: buffer,
                segment_size: Some(key.segment_size),
                ecn,
            })
        })
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Key {
    segment_size: usize, // `segment_size` comes first to ensure that the datagrams are flushed to the socket in ascending order.
    src: Option<SocketAddr>,
    dst: SocketAddr,
}

struct DatagramBuffer {
    inner: Option<lockfree_object_pool::SpinLockOwnedReusable<BytesMut>>,
    last_access: Instant,
    ecn: Ecn,
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    #[test]
    fn send_queue_gcs_after_1_minute() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct, now);
        for _entry in send_queue.datagrams() {}

        send_queue.handle_timeout(now + Duration::from_secs(60));

        assert_eq!(send_queue.inner.len(), 0);
    }

    #[test]
    fn does_not_gc_unsent_items() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct, now);

        send_queue.handle_timeout(now + Duration::from_secs(60));

        assert_eq!(send_queue.inner.len(), 1);
    }

    #[test]
    fn dropping_datagram_iterator_does_not_drop_items() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct, now);

        let datagrams = send_queue.datagrams();
        drop(datagrams);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobar");
    }

    #[test]
    fn sending_datagrams_returns_buffers_to_pool() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct, now);
        send_queue.enqueue(None, DST_2, b"bar", Ecn::NonEct, now);

        // Taking it from the iterator is "sending" ...
        let _datagrams = send_queue.datagrams().collect::<Vec<_>>();

        for buf in send_queue.inner.values() {
            assert!(buf.inner.is_none())
        }
    }

    #[test]
    fn prioritises_small_packets() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(
            None,
            DST_1,
            b"foobarfoobarfoobarfoobarfoobarfoobarfoobarfoobar",
            Ecn::NonEct,
            now,
        );
        send_queue.enqueue(None, DST_2, b"barbaz", Ecn::NonEct, now);
        send_queue.enqueue(None, DST_3, b"barbaz1234", Ecn::NonEct, now);
        send_queue.enqueue(None, DST_4, b"b", Ecn::NonEct, now);
        send_queue.enqueue(None, DST_5, b"barbazfoobafoobarfoobar", Ecn::NonEct, now);
        send_queue.enqueue(None, DST_2, b"baz", Ecn::NonEct, now);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        let is_sorted = datagrams.is_sorted_by_key(|datagram| datagram.segment_size);

        assert!(is_sorted);
        assert_eq!(datagrams[0].segment_size, Some(1));
    }

    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
    const DST_3: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 3333));
    const DST_4: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 4444));
    const DST_5: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 5555));
}
