use std::{
    collections::{BTreeMap, VecDeque},
    net::SocketAddr,
};

use bufferpool::{Buffer, BufferPool};
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
    inner: BTreeMap<Connection, VecDeque<(usize, Buffer<BytesMut>)>>,
    buffer_pool: BufferPool<BytesMut>,
}

impl GsoQueue {
    pub fn new() -> Self {
        Self {
            inner: Default::default(),
            buffer_pool: BufferPool::new(MAX_SEGMENT_SIZE * MAX_INBOUND_PACKET_BATCH, "gso-queue"),
        }
    }

    pub fn enqueue(&mut self, src: Option<SocketAddr>, dst: SocketAddr, payload: &[u8], ecn: Ecn) {
        let payload_len = payload.len();

        debug_assert!(
            payload_len <= MAX_SEGMENT_SIZE,
            "MAX_SEGMENT_SIZE is miscalculated"
        );

        let batches = self.inner.entry(Connection { src, dst, ecn }).or_default();

        let Some((batch_size, buffer)) = batches.back_mut() else {
            batches.push_back((payload_len, self.buffer_pool.pull_initialised(payload)));

            return;
        };
        let batch_size = *batch_size;

        // A batch is considered "ongoing" if so far we have only pushed packets of the same length.
        let batch_is_ongoing = buffer.len() % batch_size == 0;

        if batch_is_ongoing && payload_len <= batch_size {
            buffer.extend_from_slice(payload);
            return;
        }

        batches.push_back((payload_len, self.buffer_pool.pull_initialised(payload)));
    }

    pub fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut> + '_ {
        DrainDatagramsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Connection {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    ecn: Ecn,
}

/// An [`Iterator`] that drains datagrams from the [`GsoQueue`].
struct DrainDatagramsIter<'a> {
    queue: &'a mut GsoQueue,
}

impl Iterator for DrainDatagramsIter<'_> {
    type Item = DatagramOut;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let mut entry = self.queue.inner.first_entry()?;

            let connection = *entry.key();

            let Some((segment_size, buffer)) = entry.get_mut().pop_front() else {
                entry.remove();
                continue;
            };

            return Some(DatagramOut {
                src: connection.src,
                dst: connection.dst,
                packet: buffer,
                segment_size,
                ecn: connection.ecn,
            });
        }
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
    fn appends_items_of_same_batch() {
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"foobaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"foo", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobarbarbazfoobazfoo");
        assert_eq!(datagrams[0].segment_size, 6);
    }

    #[test]
    fn starts_new_batch_for_new_dst() {
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);

        send_queue.enqueue(None, DST_2, b"barbarba", Ecn::NonEct);
        send_queue.enqueue(None, DST_2, b"foofoo", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobarbarbaz");
        assert_eq!(datagrams[0].segment_size, 6);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(datagrams[1].packet.as_ref(), b"barbarbafoofoo");
        assert_eq!(datagrams[1].segment_size, 8);
        assert_eq!(datagrams[1].dst, DST_2);
    }

    #[test]
    fn continues_batch_for_old_dst() {
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);

        send_queue.enqueue(None, DST_2, b"barbarba", Ecn::NonEct);
        send_queue.enqueue(None, DST_2, b"foofoo", Ecn::NonEct);

        send_queue.enqueue(None, DST_1, b"foobaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"bazfoo", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobarbarbazfoobazbazfoo");
        assert_eq!(datagrams[0].segment_size, 6);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(datagrams[1].packet.as_ref(), b"barbarbafoofoo");
        assert_eq!(datagrams[1].segment_size, 8);
        assert_eq!(datagrams[1].dst, DST_2);
    }

    #[test]
    fn starts_new_batch_after_single_item_less_than_segment_length() {
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"bar", Ecn::NonEct);

        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobarbarbazbar");
        assert_eq!(datagrams[0].segment_size, 6);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(datagrams[1].packet.as_ref(), b"barbaz");
        assert_eq!(datagrams[1].segment_size, 6);
        assert_eq!(datagrams[1].dst, DST_1);
    }

    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
}
