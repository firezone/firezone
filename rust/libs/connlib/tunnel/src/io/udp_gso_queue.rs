use std::{collections::VecDeque, iter, net::SocketAddr};

use bufferpool::Buffer;
use ip_packet::Ecn;
use snownet::EncryptJob;
use socket_factory::DatagramOut;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// The size every buffer in [`GSO_BUFFERS`] is allocated with.
///
/// An IP packet - and therefore the payload of one GSO send - can never exceed 65535 bytes.
/// A [`Train`] is capped at one GSO send's worth of segments (see [`DatagramOut::max_len`]), which
/// is always below this capacity, so a pooled buffer never grows and never reallocates.
///
/// The buffer occupies this much memory regardless of how many segments it actually carries; every
/// in-flight [`DatagramOut`] pins one, which is why the outbound socket queue's depth directly bounds
/// the send path's memory footprint.
pub(crate) const GSO_BUFFER_SIZE: usize = u16::MAX as usize;

bufferpool::buffer_pool!(static GSO_BUFFERS: Vec<u8> = (GSO_BUFFER_SIZE, "gso-queue"), batch: 2);

/// Holds UDP datagrams that we need to send, grouped into one [`Train`] per GSO send.
///
/// Calling [`Io::send_network`](super::Io::send_network) copies the provided payload into this queue.
pub struct UdpGsoQueue {
    /// Queued batches, in write order.
    ///
    /// A datagram may only be appended to the most recent batch of its connection,
    /// so per-connection ordering is preserved by construction.
    batches: VecDeque<Batch>,
}

impl UdpGsoQueue {
    pub fn new() -> Self {
        Self {
            batches: VecDeque::new(),
        }
    }

    /// Copies a datagram into the queue.
    pub fn enqueue(&mut self, src: Option<SocketAddr>, dst: SocketAddr, payload: &[u8], ecn: Ecn) {
        let connection = Connection { src, dst, ecn };

        // Extending anything but the most recent batch of a connection would reorder the flow.
        if let Some(batch) = self
            .batches
            .iter_mut()
            .rev()
            .find(|batch| batch.train.connection == connection)
            && batch.train.try_append(src, dst, ecn, payload.len())
        {
            batch.buffer.extend_from_slice(payload);
            return;
        }

        let mut buffer = GSO_BUFFERS.pull();
        buffer.clear();
        buffer.extend_from_slice(payload);

        self.batches.push_back(Batch {
            train: Train::new(src, dst, ecn, payload.len()),
            buffer,
        });
    }

    /// Drains the queued datagrams; the ones not consumed stay queued.
    pub fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut> + '_ {
        iter::from_fn(|| {
            let Batch { train, buffer } = self.batches.pop_front()?;

            Some(train.into_datagram(buffer))
        })
    }

    pub fn clear(&mut self) {
        self.batches.clear()
    }
}

/// Datagrams to one connection that one GSO send can carry: all of the same size, except for a
/// shorter last one.
#[derive(Debug, Clone, Copy)]
pub struct Train {
    connection: Connection,
    /// The GSO segment size: the length of the first datagram.
    segment_size: usize,
    /// As many whole segments as one GSO send can carry to this destination.
    max_len: usize,
    len: usize,
}

impl Train {
    /// Starts a train with a datagram of `len` bytes.
    pub fn new(src: Option<SocketAddr>, dst: SocketAddr, ecn: Ecn, len: usize) -> Self {
        debug_assert!(len <= MAX_SEGMENT_SIZE, "MAX_SEGMENT_SIZE is miscalculated");

        let max_len = DatagramOut::max_len(dst, len);
        debug_assert!(
            max_len <= GSO_BUFFER_SIZE,
            "GSO_BUFFER_SIZE is miscalculated"
        );

        Self {
            connection: Connection { src, dst, ecn },
            segment_size: len,
            max_len,
            len,
        }
    }

    pub fn dst(&self) -> SocketAddr {
        self.connection.dst
    }

    /// Appends a datagram of `len` bytes, unless it has to start a new train.
    pub fn try_append(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        ecn: Ecn,
        len: usize,
    ) -> bool {
        let same_connection = self.connection == Connection { src, dst, ecn };

        // A shorter segment seals the train.
        let is_ongoing = self.len.is_multiple_of(self.segment_size);
        let fits_segment = len <= self.segment_size;
        let fits_send = self.len + len <= self.max_len;

        if !(same_connection && is_ongoing && fits_segment && fits_send) {
            return false;
        }

        self.len += len;

        true
    }

    /// Encrypts `jobs` back-to-back into one datagram.
    ///
    /// Jobs that fail to encrypt are skipped; returns `None` if none are left.
    pub fn encrypt(self, jobs: impl Iterator<Item = EncryptJob>) -> Option<DatagramOut> {
        let mut buffer = GSO_BUFFERS.pull();
        buffer.clear();

        for job in jobs {
            let offset = buffer.len();
            buffer.resize(offset + job.datagram_len(), 0);

            if let Err(e) = job.encrypt_into(&mut buffer[offset..]) {
                tracing::debug!("Failed to encrypt packet: {e}");
                buffer.truncate(offset);
            }
        }

        if buffer.is_empty() {
            return None;
        }

        Some(self.into_datagram(buffer))
    }

    fn into_datagram(self, packet: Buffer<Vec<u8>>) -> DatagramOut {
        DatagramOut {
            src: self.connection.src,
            dst: self.connection.dst,
            // Skipped jobs may leave only the shorter last segment.
            segment_size: self.segment_size.min(packet.len()),
            packet,
            ecn: self.connection.ecn,
        }
    }
}

struct Batch {
    train: Train,
    buffer: Buffer<Vec<u8>>,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
struct Connection {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    ecn: Ecn,
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
            DatagramOut::max_len(DST_1, MAX_SEGMENT_SIZE),
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

        // Small segments are count-bound: one GSO send carries at most the kernel's segment limit.
        let segments_per_send = DatagramOut::max_len(DST_1, segment.len()) / segment.len();
        assert_eq!(segments_per_send, 64);

        for _ in 0..(segments_per_send + 1) {
            send_queue.enqueue(None, DST_1, &segment, Ecn::NonEct);
        }

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 2);
        assert_eq!(datagrams[0].packet.len(), segments_per_send * segment.len());
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

    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
}
