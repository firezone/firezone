use std::{collections::VecDeque, net::SocketAddr};

use bufferpool::{Buffer, BufferPool};
use ip_packet::Ecn;
use snownet::{BufferProvider, Reservation};
use socket_factory::DatagramOut;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// The size every buffer in the [`UdpGsoQueue`]'s pool is allocated with, and thus the maximum size of a batch.
///
/// A buffer holds a single GSO batch: the segments coalesced for one `(src, dst, ecn)`. UDP payloads
/// cannot exceed 65535 bytes (their length field is 16 bits wide), so a larger batch could never be
/// flushed in a single GSO send anyway. Sealing batches at the allocated capacity also guarantees
/// that a buffer never reallocates.
///
/// The buffer occupies this much memory regardless of how many segments it actually carries; every
/// in-flight [`DatagramOut`] pins one, which is why the outbound socket queue's depth directly bounds
/// the send path's memory footprint.
pub(crate) const GSO_BUFFER_SIZE: usize = u16::MAX as usize;

/// Holds UDP datagrams that we need to send, grouped into GSO batches per connection.
///
/// Calling [`Io::send_network`](super::Io::send_network) will copy the provided payload into this buffer.
/// The buffer is then flushed using GSO in a single syscall.
pub struct UdpGsoQueue {
    /// Queued batches, in write order.
    ///
    /// A datagram may only be appended to the most recent batch of its connection,
    /// so per-connection ordering is preserved by construction.
    batches: VecDeque<Batch>,
    buffer_pool: BufferPool<Vec<u8>>,
}

impl UdpGsoQueue {
    pub fn new() -> Self {
        Self {
            batches: VecDeque::new(),
            buffer_pool: BufferPool::new(GSO_BUFFER_SIZE, "gso-queue"),
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

    /// Undo the reservation of `len` bytes at the tail of the batch at `index`.
    fn rollback(&mut self, index: usize, len: usize) {
        let Some(batch) = self.batches.get_mut(index) else {
            return;
        };

        let new_len = batch.buffer.len().saturating_sub(len);
        batch.buffer.truncate(new_len);

        // Drop a batch that became empty as a result.
        if batch.buffer.is_empty() {
            self.batches.remove(index);
        }
    }

    pub fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut> + '_ {
        DrainDatagramsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.batches.clear()
    }
}

impl BufferProvider for UdpGsoQueue {
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

        // A datagram may only extend the most recent batch of its connection;
        // extending anything older would reorder the flow.
        let index = self
            .batches
            .iter()
            .rposition(|b| b.connection == connection)
            .filter(|i| self.batches[*i].can_append(len));

        let index = match index {
            Some(index) => index,
            None => {
                let mut buffer = self.buffer_pool.pull();
                buffer.clear();

                self.batches.push_back(Batch {
                    connection,
                    segment_size: len,
                    buffer,
                });

                self.batches.len() - 1
            }
        };

        let batch = &mut self.batches[index];
        let new_len = batch.buffer.len() + len;
        batch.buffer.resize(new_len, 0);

        GsoReservation {
            queue: self,
            index,
            len,
            committed: false,
        }
    }
}

/// One or more equal-size datagrams to a single [`Connection`], laid out back-to-back.
struct Batch {
    connection: Connection,
    /// The GSO segment size: the length of the first datagram in the batch.
    segment_size: usize,
    buffer: Buffer<Vec<u8>>,
}

impl Batch {
    /// Whether another datagram of `len` bytes may be appended.
    fn can_append(&self, len: usize) -> bool {
        // A batch is "ongoing" as long as every segment so far has been full-size;
        // a shorter, final segment seals it.
        let is_ongoing = self.buffer.len().is_multiple_of(self.segment_size);

        // Only equal-size segments plus at most one shorter, final one form a valid GSO batch.
        let fits_segment = len <= self.segment_size;

        // Growing past the allocated capacity would reallocate the pooled buffer.
        let fits_buffer = self.buffer.len() + len <= GSO_BUFFER_SIZE;

        is_ongoing && fits_segment && fits_buffer
    }
}

/// A [`Reservation`] into a [`UdpGsoQueue`], pointing at the tail of one of its batches.
pub struct GsoReservation<'a> {
    queue: &'a mut UdpGsoQueue,
    index: usize,
    len: usize,
    committed: bool,
}

impl Reservation for GsoReservation<'_> {
    fn buffer(&mut self) -> &mut [u8] {
        let batch = self
            .queue
            .batches
            .get_mut(self.index)
            .expect("reserved batch to exist");

        let offset = batch.buffer.len() - self.len;

        &mut batch.buffer[offset..]
    }

    fn commit(mut self) {
        self.committed = true;
    }
}

impl Drop for GsoReservation<'_> {
    fn drop(&mut self) {
        if !self.committed {
            self.queue.rollback(self.index, self.len);
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
struct Connection {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    ecn: Ecn,
}

/// An [`Iterator`] that drains datagrams from the [`UdpGsoQueue`].
struct DrainDatagramsIter<'a> {
    queue: &'a mut UdpGsoQueue,
}

impl Iterator for DrainDatagramsIter<'_> {
    type Item = DatagramOut;

    fn next(&mut self) -> Option<Self::Item> {
        let Batch {
            connection,
            segment_size,
            buffer,
        } = self.queue.batches.pop_front()?;

        Some(DatagramOut {
            src: connection.src,
            dst: connection.dst,
            packet: buffer,
            segment_size,
            ecn: connection.ecn,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    #[test]
    fn dropping_datagram_iterator_does_not_drop_items() {
        let mut send_queue = UdpGsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);

        let datagrams = send_queue.datagrams();
        drop(datagrams);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(&datagrams[0].packet[..], b"foobar");
    }

    #[test]
    fn appends_items_of_same_batch() {
        let mut send_queue = UdpGsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"foobaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"foo", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(&datagrams[0].packet[..], b"foobarbarbazfoobazfoo");
        assert_eq!(datagrams[0].segment_size, 6);
    }

    #[test]
    fn starts_new_batch_for_new_dst() {
        let mut send_queue = UdpGsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);

        send_queue.enqueue(None, DST_2, b"barbarba", Ecn::NonEct);
        send_queue.enqueue(None, DST_2, b"foofoo", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(&datagrams[0].packet[..], b"foobarbarbaz");
        assert_eq!(datagrams[0].segment_size, 6);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(&datagrams[1].packet[..], b"barbarbafoofoo");
        assert_eq!(datagrams[1].segment_size, 8);
        assert_eq!(datagrams[1].dst, DST_2);
    }

    #[test]
    fn continues_batch_for_old_dst() {
        let mut send_queue = UdpGsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);

        send_queue.enqueue(None, DST_2, b"barbarba", Ecn::NonEct);
        send_queue.enqueue(None, DST_2, b"foofoo", Ecn::NonEct);

        send_queue.enqueue(None, DST_1, b"foobaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"bazfoo", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(&datagrams[0].packet[..], b"foobarbarbazfoobazbazfoo");
        assert_eq!(datagrams[0].segment_size, 6);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(&datagrams[1].packet[..], b"barbarbafoofoo");
        assert_eq!(datagrams[1].segment_size, 8);
        assert_eq!(datagrams[1].dst, DST_2);
    }

    #[test]
    fn starts_new_batch_after_single_item_less_than_segment_length() {
        let mut send_queue = UdpGsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"bar", Ecn::NonEct);

        send_queue.enqueue(None, DST_1, b"barbaz", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(&datagrams[0].packet[..], b"foobarbarbazbar");
        assert_eq!(datagrams[0].segment_size, 6);
        assert_eq!(datagrams[0].dst, DST_1);
        assert_eq!(&datagrams[1].packet[..], b"barbaz");
        assert_eq!(datagrams[1].segment_size, 6);
        assert_eq!(datagrams[1].dst, DST_1);
    }

    #[test]
    fn starts_new_batch_at_buffer_capacity() {
        let mut send_queue = UdpGsoQueue::new();
        let segment = [0u8; MAX_SEGMENT_SIZE];

        let segments_per_batch = GSO_BUFFER_SIZE / MAX_SEGMENT_SIZE;

        for _ in 0..(segments_per_batch + 1) {
            send_queue.enqueue(None, DST_1, &segment, Ecn::NonEct);
        }

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(
            datagrams[0].packet.len(),
            segments_per_batch * MAX_SEGMENT_SIZE
        );
        assert_eq!(datagrams[1].packet.len(), MAX_SEGMENT_SIZE);
    }

    #[test]
    fn batch_buffers_never_reallocate() {
        let mut send_queue = UdpGsoQueue::new();
        let segment = [0u8; MAX_SEGMENT_SIZE];

        for _ in 0..100 {
            send_queue.enqueue(None, DST_1, &segment, Ecn::NonEct);
        }

        for datagram in send_queue.datagrams() {
            assert_eq!(datagram.packet.capacity(), GSO_BUFFER_SIZE);
        }
    }

    #[test]
    fn committing_a_reservation_keeps_the_datagram() {
        let mut send_queue = UdpGsoQueue::new();

        {
            let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"foobar");
            reservation.commit();
        }

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(&datagrams[0].packet[..], b"foobar");
    }

    #[test]
    fn dropping_a_reservation_without_committing_rolls_it_back() {
        let mut send_queue = UdpGsoQueue::new();

        send_queue.enqueue(None, DST_1, b"foobar", Ecn::NonEct);

        // Reserve a second segment in the same batch but drop it without committing.
        {
            let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"barbaz");
        }

        // Only the committed datagram remains; the reserved bytes were rolled back.
        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(&datagrams[0].packet[..], b"foobar");
        assert_eq!(datagrams[0].segment_size, 6);
    }

    #[test]
    fn dropping_the_only_reservation_leaves_the_queue_empty() {
        let mut send_queue = UdpGsoQueue::new();

        {
            let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"barbaz");
        }

        // Rolling back the last segment drops the empty batch.
        assert_eq!(send_queue.datagrams().count(), 0);
    }

    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
}
