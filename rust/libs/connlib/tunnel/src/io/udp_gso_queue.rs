use std::{collections::VecDeque, net::SocketAddr};

use bufferpool::{Buffer, BufferPool};
use ip_packet::{Ecn, Ipv4Header, Ipv6Header, UdpHeader};
use snownet::{BufferProvider, Reservation};
use socket_factory::DatagramOut;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// The size every buffer in the [`UdpGsoQueue`]'s pool is allocated with.
///
/// An IP packet - and therefore the payload of one GSO send - can never exceed 65535 bytes.
/// Batches are capped at one GSO send's worth of segments (see [`max_gso_send_len`]), which is
/// always below this capacity, so a pooled buffer never grows and never reallocates.
///
/// The buffer occupies this much memory regardless of how many segments it actually carries; every
/// in-flight [`DatagramOut`] pins one, which is why the outbound socket queue's depth directly bounds
/// the send path's memory footprint.
pub(crate) const GSO_BUFFER_SIZE: usize = u16::MAX as usize;

/// The most segments one GSO send may carry (`UDP_MAX_SEGMENTS` in `linux/udp.h`; `quinn-udp` enforces the same).
const MAX_GSO_SEGMENTS: usize = 64;

/// Holds UDP datagrams that we need to send, grouped into GSO batches per connection.
///
/// Calling [`Io::send_network`](super::Io::send_network) copies the provided payload into this queue.
/// Batches are capped at what a single GSO send can carry, so each one is flushed with one syscall
/// while GSO is available.
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
        let existing = self
            .batches
            .iter_mut()
            .enumerate()
            .rev()
            .find(|(_, batch)| batch.connection == connection)
            .filter(|(_, batch)| batch.can_append(len));

        let index = match existing {
            Some((index, batch)) => {
                let new_len = batch.buffer.len() + len;
                batch.buffer.resize(new_len, 0);

                index
            }
            None => {
                let mut buffer = self.buffer_pool.pull();
                buffer.clear();
                buffer.resize(len, 0);

                self.batches.push_back(Batch {
                    connection,
                    segment_size: len,
                    max_len: max_gso_send_len(dst, len),
                    buffer,
                });

                self.batches.len() - 1
            }
        };

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
    /// The batch's size limit: as many whole segments as one GSO send can carry to this destination.
    max_len: usize,
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

        // A batch never grows past what one GSO send can carry.
        let fits_send = self.buffer.len() + len <= self.max_len;

        is_ongoing && fits_segment && fits_send
    }
}

/// How many bytes one GSO send can carry to `dst`, in whole segments of `segment_size`.
///
/// Mirrors the UDP send path's chunking (see `PerfUdpSocket::calculate_chunk_size`): a send's
/// payload is bounded by the maximum IP packet size less IP/UDP header overhead, and by the
/// kernel's segment limit. Capping batches at this size makes one batch equal one syscall;
/// it also keeps every batch below the pooled buffer's capacity, so buffers never reallocate.
fn max_gso_send_len(dst: SocketAddr, segment_size: usize) -> usize {
    let header_overhead = match dst {
        SocketAddr::V4(_) => Ipv4Header::MAX_LEN + UdpHeader::LEN,
        SocketAddr::V6(_) => Ipv6Header::LEN + UdpHeader::LEN,
    };

    let max_segments_by_size = (u16::MAX as usize - header_overhead) / segment_size.max(1);
    let max_segments = std::cmp::min(MAX_GSO_SEGMENTS, max_segments_by_size).max(1);

    let max_len = segment_size * max_segments;

    debug_assert!(
        max_len <= GSO_BUFFER_SIZE,
        "GSO_BUFFER_SIZE is miscalculated"
    );

    max_len
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
            ..
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
    fn does_not_append_to_older_batch_of_same_connection() {
        let mut send_queue = UdpGsoQueue::new();

        send_queue.enqueue(None, DST_1, b"aaaa", Ecn::NonEct);
        send_queue.enqueue(None, DST_1, b"bbbbbb", Ecn::NonEct); // Does not fit the first batch's segment size.
        send_queue.enqueue(None, DST_1, b"ccc", Ecn::NonEct); // Short tail: seals the second batch.

        // The most recent batch is sealed, so this must open a new one;
        // appending to the first batch would overtake the second one.
        send_queue.enqueue(None, DST_1, b"dd", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 3);
        assert_eq!(&datagrams[0].packet[..], b"aaaa");
        assert_eq!(&datagrams[1].packet[..], b"bbbbbbccc");
        assert_eq!(&datagrams[2].packet[..], b"dd");
    }

    #[test]
    fn seals_full_size_batch_at_one_gso_send() {
        let mut send_queue = UdpGsoQueue::new();
        let segment = [0u8; MAX_SEGMENT_SIZE];

        // Full-size segments are byte-bound: 49 of them fill one GSO send to an IPv4 destination.
        let segments_per_send = 49;
        assert_eq!(
            max_gso_send_len(DST_1, MAX_SEGMENT_SIZE),
            segments_per_send * MAX_SEGMENT_SIZE
        );

        for _ in 0..(segments_per_send + 1) {
            send_queue.enqueue(None, DST_1, &segment, Ecn::NonEct);
        }

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(
            datagrams[0].packet.len(),
            segments_per_send * MAX_SEGMENT_SIZE
        );
        assert_eq!(datagrams[1].packet.len(), MAX_SEGMENT_SIZE);
    }

    #[test]
    fn seals_small_segment_batch_at_segment_limit() {
        let mut send_queue = UdpGsoQueue::new();
        let segment = [0u8; 100];

        // Small segments are count-bound: one GSO send carries at most `MAX_GSO_SEGMENTS`.
        for _ in 0..(MAX_GSO_SEGMENTS + 1) {
            send_queue.enqueue(None, DST_1, &segment, Ecn::NonEct);
        }

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(datagrams[0].packet.len(), MAX_GSO_SEGMENTS * segment.len());
        assert_eq!(datagrams[1].packet.len(), segment.len());
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
