use std::{collections::VecDeque, mem, net::SocketAddr, ops::Range};

use bufferpool::{Buffer, BufferPool};
use ip_packet::Ecn;
use snownet::{BufferProvider, Reservation, SealJob};
use socket_factory::DatagramOut;

use super::parallel;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// The size every buffer in the [`UdpGsoQueue`]'s pool is allocated with.
///
/// An IP packet - and therefore the payload of one GSO send - can never exceed 65535 bytes.
/// Batches are capped at one GSO send's worth of segments (see [`DatagramOut::max_len`]), which is
/// always below this capacity, so a pooled buffer never grows and never reallocates.
///
/// The buffer occupies this much memory regardless of how many segments it actually carries; every
/// in-flight [`DatagramOut`] pins one, which is why the outbound socket queue's depth directly bounds
/// the send path's memory footprint.
pub(crate) const GSO_BUFFER_SIZE: usize = u16::MAX as usize;

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
    /// Datagrams whose encryption is deferred until the queue is drained, in commit order.
    ///
    /// Batches are only ever popped after all seals ran, so the batch indices stay valid.
    pending_seals: Vec<DeferredSeal>,
    buffer_pool: BufferPool<Vec<u8>>,
}

impl UdpGsoQueue {
    pub fn new() -> Self {
        Self {
            batches: VecDeque::new(),
            pending_seals: Vec::new(),
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

    pub fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut> + '_ {
        self.run_pending_seals();

        DrainDatagramsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.batches.clear();
        self.pending_seals.clear();
    }

    /// Encrypts all datagrams committed with a [`SealJob`], in parallel if there are enough.
    fn run_pending_seals(&mut self) {
        if self.pending_seals.is_empty() {
            return;
        }

        self.pending_seals
            .sort_unstable_by_key(|seal| (seal.batch, seal.range.start));

        let mut pending_seals = self.pending_seals.drain(..).peekable();
        let mut jobs = Vec::with_capacity(pending_seals.len());

        for (index, batch) in self.batches.iter_mut().enumerate() {
            let mut rest = &mut batch.buffer[..];
            let mut rest_start = 0;

            while let Some(seal) = pending_seals.next_if(|seal| seal.batch == index) {
                let (_, tail) = mem::take(&mut rest).split_at_mut(seal.range.start - rest_start);
                let (datagram, tail) = tail.split_at_mut(seal.range.len());

                rest = tail;
                rest_start = seal.range.end;
                jobs.push((datagram, seal.job));
            }
        }
        debug_assert!(pending_seals.next().is_none(), "Seal for unknown batch");

        parallel::for_each(jobs, |(datagram, job)| job.run(datagram));
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
                // A rolled-back reservation may have left the batch empty; it starts over with our segment size.
                if batch.buffer.is_empty() {
                    batch.segment_size = len;
                    batch.max_len = DatagramOut::max_len(dst, len);
                }

                let new_len = batch.buffer.len() + len;
                batch.buffer.resize(new_len, 0);

                index
            }
            None => {
                let max_len = DatagramOut::max_len(dst, len);
                debug_assert!(
                    max_len <= GSO_BUFFER_SIZE,
                    "GSO_BUFFER_SIZE is miscalculated"
                );

                let mut buffer = self.buffer_pool.pull();
                buffer.clear();
                buffer.resize(len, 0);

                self.batches.push_back(Batch {
                    connection,
                    segment_size: len,
                    max_len,
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

/// A datagram within a [`Batch`] that still needs to be encrypted.
struct DeferredSeal {
    batch: usize,
    range: Range<usize>,
    job: SealJob,
}

/// A [`Reservation`] into a [`UdpGsoQueue`], pointing at the tail of one of its batches.
pub struct GsoReservation<'a> {
    queue: &'a mut UdpGsoQueue,
    index: usize,
    len: usize,
    committed: bool,
}

impl GsoReservation<'_> {
    fn range(&self) -> Range<usize> {
        let end = self.queue.batches[self.index].buffer.len();

        end - self.len..end
    }
}

impl Reservation for GsoReservation<'_> {
    fn buffer(&mut self) -> &mut [u8] {
        let range = self.range();

        &mut self.queue.batches[self.index].buffer[range]
    }

    fn commit(mut self) {
        self.committed = true;
    }

    fn commit_sealed(mut self, job: SealJob) {
        self.queue.pending_seals.push(DeferredSeal {
            batch: self.index,
            range: self.range(),
            job,
        });
        self.committed = true;
    }
}

impl Drop for GsoReservation<'_> {
    fn drop(&mut self) {
        if !self.committed {
            let batch = &mut self.queue.batches[self.index];
            let new_len = batch.buffer.len().saturating_sub(self.len);
            batch.buffer.truncate(new_len);
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
        loop {
            let Batch {
                connection,
                segment_size,
                buffer,
                ..
            } = self.queue.batches.pop_front()?;

            // A rolled-back reservation may leave an empty batch behind; there is nothing to send for it.
            if buffer.is_empty() {
                continue;
            }

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
    use std::time::{Duration, Instant};

    use boringtun::noise::{Index, Tunn, TunnResult};
    use boringtun::x25519::{PublicKey, StaticSecret};

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

    #[test]
    fn rolled_back_batch_restarts_with_new_segment_size() {
        let mut send_queue = UdpGsoQueue::new();

        {
            let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"barbaz");
        }

        send_queue.enqueue(None, DST_1, b"foo", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(&datagrams[0].packet[..], b"foo");
        assert_eq!(datagrams[0].segment_size, 3);
    }

    #[test]
    fn sealed_reservations_are_encrypted_before_draining() {
        let now = Instant::now();
        let (mut alice, mut bob) = connected_tunnels(now);
        let mut send_queue = UdpGsoQueue::new();
        let packets = (0..20u8)
            .map(|i| ip_packet::make::udp_packet(SRC_IP, DST_IP, 1, 2, &[i; 100]).unwrap())
            .collect::<Vec<_>>();

        for (i, packet) in packets.iter().enumerate() {
            let dst = if i % 2 == 0 { DST_1 } else { DST_2 };
            let mut reservation =
                send_queue.reserve(None, dst, Ecn::NonEct, packet.packet().len() + 32);
            let seal = alice
                .encapsulate_data_deferred_at(packet.packet(), reservation.buffer(), now)
                .unwrap();
            reservation.commit_sealed(SealJob::new(0, seal));
        }
        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        let received = datagrams
            .iter()
            .flat_map(|d| d.packet.chunks(d.segment_size))
            .map(|segment| decapsulate(&mut bob, segment, now))
            .collect::<Vec<_>>();
        let expected = packets
            .iter()
            .step_by(2)
            .chain(packets.iter().skip(1).step_by(2))
            .map(|p| p.packet().to_vec())
            .collect::<Vec<_>>();
        assert_eq!(datagrams.len(), 2);
        assert_eq!(received, expected);
    }

    #[test]
    fn clearing_the_queue_discards_pending_seals() {
        let now = Instant::now();
        let (mut alice, _) = connected_tunnels(now);
        let mut send_queue = UdpGsoQueue::new();

        let mut reservation = send_queue.reserve(None, DST_1, Ecn::NonEct, 32);
        let seal = alice
            .encapsulate_data_deferred_at(&[], reservation.buffer(), now)
            .unwrap();
        reservation.commit_sealed(SealJob::new(0, seal));
        send_queue.clear();
        send_queue.enqueue(None, DST_2, b"foobar", Ecn::NonEct);

        let datagrams = send_queue.datagrams().collect::<Vec<_>>();

        assert_eq!(datagrams.len(), 1);
        assert_eq!(&datagrams[0].packet[..], b"foobar");
    }

    fn connected_tunnels(now: Instant) -> (Tunn, Tunn) {
        let alice_key = StaticSecret::from([1; 32]);
        let bob_key = StaticSecret::from([2; 32]);
        let mut alice = tunnel(alice_key.clone(), PublicKey::from(&bob_key), 1, now);
        let mut bob = tunnel(bob_key, PublicKey::from(&alice_key), 2, now);
        let mut buf = [0u8; 256];

        let TunnResult::WriteToNetwork(init) =
            alice.format_handshake_initiation_at(&mut buf, false, now)
        else {
            panic!("expected a handshake initiation")
        };
        let init = init.to_vec();
        let TunnResult::WriteToNetwork(response) = bob.decapsulate_at(None, &init, &mut buf, now)
        else {
            panic!("expected a handshake response")
        };
        let response = response.to_vec();
        let TunnResult::WriteToNetwork(_keepalive) =
            alice.decapsulate_at(None, &response, &mut buf, now)
        else {
            panic!("expected a keepalive")
        };

        (alice, bob)
    }

    fn tunnel(key: StaticSecret, peer: PublicKey, index: u32, now: Instant) -> Tunn {
        Tunn::new_at(
            key,
            peer,
            None,
            None,
            Index::new_local(index),
            None,
            0,
            now,
            now,
            Duration::ZERO,
        )
    }

    fn decapsulate(tunn: &mut Tunn, datagram: &[u8], now: Instant) -> Vec<u8> {
        let mut buf = [0u8; 2048];

        let TunnResult::WriteToTunnelV4(packet, _) =
            tunn.decapsulate_at(None, datagram, &mut buf, now)
        else {
            panic!("expected an IPv4 packet")
        };

        packet.to_vec()
    }

    const SRC_IP: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);
    const DST_IP: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 2);
    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
}
