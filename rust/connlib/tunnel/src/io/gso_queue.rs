use std::{collections::BTreeMap, net::SocketAddr, sync::Arc};

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

    pub fn enqueue(&mut self, src: Option<SocketAddr>, dst: SocketAddr, payload: &[u8], ecn: Ecn) {
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
                inner: self.buffer_pool.pull_owned(),
                ecn,
            });

        buffer.inner.extend_from_slice(payload);
        buffer.ecn = ecn;
    }

    pub fn datagrams(
        &mut self,
    ) -> impl Iterator<Item = DatagramOut<lockfree_object_pool::SpinLockOwnedReusable<BytesMut>>> + '_
    {
        DrainDatagramsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Key {
    segment_size: usize, // `segment_size` comes first to ensure that the datagrams are flushed to the socket in descending order.
    src: Option<SocketAddr>,
    dst: SocketAddr,
}

struct DatagramBuffer {
    inner: lockfree_object_pool::SpinLockOwnedReusable<BytesMut>,
    ecn: Ecn,
}

/// An [`Iterator`] that drains datagrams from the [`GsoQueue`].
struct DrainDatagramsIter<'a> {
    queue: &'a mut GsoQueue,
}

impl Iterator for DrainDatagramsIter<'_> {
    type Item = DatagramOut<lockfree_object_pool::SpinLockOwnedReusable<BytesMut>>;

    fn next(&mut self) -> Option<Self::Item> {
        let (key, buffer) = self.queue.inner.pop_last()?;

        Some(DatagramOut {
            src: key.src,
            dst: key.dst,
            packet: buffer.inner,
            segment_size: Some(key.segment_size),
            ecn: buffer.ecn,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    #[test]
    fn dropping_datagram_iterator_does_not_drop_items() {
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);

        let datagrams = send_queue.datagrams();
        drop(datagrams);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobar");
    }

    #[test]
    fn prioritises_large_packets() {
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(
            None,
            DST_1,
            b"foobarfoobarfoobarfoobarfoobarfoobarfoobarfoobar",
            Ecn::NonEct,
        );
        send_queue.enqueue(None, DST_2, b"barbaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_3, b"barbaz1234", Ecn::NonEct);
        send_queue.enqueue(None, DST_4, b"b", Ecn::NonEct);
        send_queue.enqueue(None, DST_5, b"barbazfoobafoobarfoobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_2, b"baz", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        let is_sorted = datagrams.is_sorted_by(|a, b| a.segment_size >= b.segment_size);

        assert!(is_sorted);
        assert_eq!(datagrams[0].segment_size, Some(48));
    }

    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
    const DST_3: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 3333));
    const DST_4: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 4444));
    const DST_5: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 5555));
}
