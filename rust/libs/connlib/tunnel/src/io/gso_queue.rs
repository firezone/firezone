use std::{
    collections::{BTreeMap, VecDeque},
    net::SocketAddr,
};

use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::Ecn;
use snownet::{BufferProvider, Reservation};
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

    /// Copy an already-formed datagram into the queue.
    ///
    /// This is used for datagrams we cannot (or need not) encrypt in place, e.g. STUN/TURN control
    /// messages and handshakes. The throughput-critical TUN -> network direction encrypts packets
    /// directly into the queue via the [`BufferProvider`] implementation.
    pub fn enqueue(&mut self, src: Option<SocketAddr>, dst: SocketAddr, payload: &[u8], ecn: Ecn) {
        let mut reservation = self.reserve(src, dst, ecn, payload.len());
        reservation.buffer().copy_from_slice(payload);
        reservation.commit();
    }

    /// Undo the most recent reservation for `connection`.
    fn rollback(&mut self, connection: Connection, len: usize) {
        let Some(batches) = self.inner.get_mut(&connection) else {
            return;
        };
        let Some((_, buffer)) = batches.back_mut() else {
            return;
        };

        let new_len = buffer.len().saturating_sub(len);
        buffer.truncate(new_len);

        // Drop any batch (and connection) that became empty as a result.
        if buffer.is_empty() {
            batches.pop_back();

            if batches.is_empty() {
                self.inner.remove(&connection);
            }
        }
    }

    pub fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut> + '_ {
        DrainDatagramsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

impl BufferProvider for GsoQueue {
    type Reservation<'a> = GsoReservation<'a>;

    fn reserve(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        ecn: Ecn,
        len: usize,
    ) -> GsoReservation<'_> {
        debug_assert!(len <= MAX_SEGMENT_SIZE, "MAX_SEGMENT_SIZE is miscalculated");

        let connection = Connection { src, dst, ecn };
        let batches = self.inner.entry(connection).or_default();

        // Decide whether the datagram can extend the current batch or has to start a new one.
        let needs_new_batch = match batches.back() {
            None => true,
            Some((batch_size, buffer)) => {
                // A batch is "ongoing" as long as every segment so far has been full-size.
                let batch_is_ongoing = buffer.len() % batch_size == 0;

                !(batch_is_ongoing && len <= *batch_size)
            }
        };

        if needs_new_batch {
            let mut buffer = self.buffer_pool.pull();
            buffer.clear();
            batches.push_back((len, buffer));
        }

        let (_, buffer) = batches.back_mut().expect("we ensured a batch exists");
        let new_len = buffer.len() + len;
        buffer.resize(new_len, 0);

        GsoReservation {
            queue: self,
            connection,
            len,
            committed: false,
        }
    }
}

/// A [`Reservation`] into a [`GsoQueue`], pointing at the tail of the current batch.
pub struct GsoReservation<'a> {
    queue: &'a mut GsoQueue,
    connection: Connection,
    len: usize,
    committed: bool,
}

impl Reservation for GsoReservation<'_> {
    fn buffer(&mut self) -> &mut [u8] {
        let (_, buffer) = self
            .queue
            .inner
            .get_mut(&self.connection)
            .expect("reserved connection to exist")
            .back_mut()
            .expect("reserved batch to exist");

        let offset = buffer.len() - self.len;

        &mut buffer[offset..]
    }

    fn commit(mut self) {
        self.committed = true;
    }
}

impl Drop for GsoReservation<'_> {
    fn drop(&mut self) {
        if !self.committed {
            self.queue.rollback(self.connection, self.len);
        }
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

    #[test]
    fn committing_a_reservation_keeps_the_datagram() {
        let mut send_queue = GsoQueue::new();

        {
            let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"foobar");
            reservation.commit();
        }

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobar");
    }

    #[test]
    fn dropping_a_reservation_without_committing_rolls_it_back() {
        let mut send_queue = GsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);

        // Reserve a second segment in the same batch but drop it without committing.
        {
            let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"barbaz");
        }

        // Only the committed datagram remains; the reserved bytes were rolled back.
        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(datagrams[0].packet.as_ref(), b"foobar");
        assert_eq!(datagrams[0].segment_size, 6);
    }

    #[test]
    fn dropping_the_only_reservation_leaves_the_queue_empty() {
        let mut send_queue = GsoQueue::new();

        {
            let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"barbaz");
        }

        // Rolling back the last segment drops the empty batch and connection.
        assert_eq!(send_queue.datagrams().count(), 0);
    }

    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
}
