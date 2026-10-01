use std::{collections::VecDeque, net::SocketAddr};

use bufferpool::{Buffer, BufferPool};
use ip_packet::Ecn;
use snownet::{DataMessage, SealJob};
use socket_factory::DatagramOut;

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

/// Holds the WireGuard data messages that we need to send, grouped into GSO batches per connection.
///
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

    pub fn push(&mut self, message: DataMessage) {
        let DataMessage { src, dst, ecn, job } = message;
        let len = job.datagram_len();
        debug_assert!(len <= MAX_SEGMENT_SIZE, "MAX_SEGMENT_SIZE is miscalculated");

        let connection = Connection { src, dst, ecn };

        // A datagram may only extend the most recent batch of its connection;
        // extending anything older would reorder the flow.
        let existing = self
            .batches
            .iter_mut()
            .rev()
            .find(|batch| batch.connection == connection)
            .filter(|batch| batch.can_append(len));

        if let Some(batch) = existing {
            batch.len += len;
            batch.jobs.push(job);

            return;
        }

        let max_len = DatagramOut::max_len(dst, len);
        debug_assert!(
            max_len <= GSO_BUFFER_SIZE,
            "GSO_BUFFER_SIZE is miscalculated"
        );

        self.batches.push_back(Batch {
            connection,
            segment_size: len,
            max_len,
            len,
            jobs: vec![job],
        });
    }

    /// Returns the destination of the batch [`UdpGsoQueue::pop`] returns next.
    pub fn front_dst(&self) -> Option<SocketAddr> {
        self.batches.front().map(|batch| batch.connection.dst)
    }

    /// Removes the oldest batch from the queue.
    pub fn pop(&mut self) -> Option<PendingDatagram> {
        let Batch {
            connection,
            segment_size,
            len,
            jobs,
            ..
        } = self.batches.pop_front()?;

        Some(PendingDatagram {
            connection,
            segment_size,
            len,
            jobs,
            buffer: self.buffer_pool.pull(),
        })
    }

    pub fn clear(&mut self) {
        self.batches.clear()
    }
}

/// A batch of WireGuard data messages that are yet to be sealed.
///
/// [`PendingDatagram::seal`] is the only way to get the [`DatagramOut`], so plaintext never reaches
/// a socket.
pub struct PendingDatagram {
    connection: Connection,
    segment_size: usize,
    len: usize,
    /// One per segment.
    jobs: Vec<SealJob>,
    buffer: Buffer<Vec<u8>>,
}

impl PendingDatagram {
    pub fn dst(&self) -> SocketAddr {
        self.connection.dst
    }

    pub fn jobs(&self) -> &[SealJob] {
        &self.jobs
    }

    /// Writes and encrypts all data messages of the batch, which is then ready to be sent.
    pub fn seal(self) -> DatagramOut {
        let mut packet = self.buffer;
        // Every byte is overwritten below, so this only zero-fills beyond the buffer's previous length.
        packet.resize(self.len, 0);

        let mut offset = 0;
        for job in self.jobs {
            offset += job.seal_into(&mut packet[offset..]);
        }
        debug_assert_eq!(offset, self.len);

        DatagramOut {
            src: self.connection.src,
            dst: self.connection.dst,
            packet,
            segment_size: self.segment_size,
            ecn: self.connection.ecn,
        }
    }
}

/// One or more equal-size datagrams to a single [`Connection`], laid out back-to-back once sealed.
struct Batch {
    connection: Connection,
    /// The GSO segment size: the length of the first datagram in the batch.
    segment_size: usize,
    /// The batch's size limit: as many whole segments as one GSO send can carry to this destination.
    max_len: usize,
    /// The total length of all datagrams in the batch.
    len: usize,
    /// One per segment.
    jobs: Vec<SealJob>,
}

impl Batch {
    /// Whether another datagram of `len` bytes may be appended.
    fn can_append(&self, len: usize) -> bool {
        // A batch is "ongoing" as long as every segment so far has been full-size;
        // a shorter, final segment seals it.
        let is_ongoing = self.len.is_multiple_of(self.segment_size);

        // Only equal-size segments plus at most one shorter, final one form a valid GSO batch.
        let fits_segment = len <= self.segment_size;

        // A batch never grows past what one GSO send can carry.
        let fits_send = self.len + len <= self.max_len;

        is_ongoing && fits_segment && fits_send
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
struct Connection {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    ecn: Ecn,
}

#[cfg(test)]
pub(super) mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};
    use std::time::{Duration, Instant};

    use boringtun::noise::{Index, Tunn, TunnResult};
    use boringtun::x25519::{PublicKey, StaticSecret};
    use ip_packet::{IpPacket, WG_OVERHEAD};

    use super::*;

    #[test]
    fn appends_items_of_same_batch() {
        let mut send_queue = SendQueue::new();

        send_queue.enqueue(DST_1, b"foobar");
        send_queue.enqueue(DST_1, b"barbaz");
        send_queue.enqueue(DST_1, b"foobaz");
        send_queue.enqueue(DST_1, b"foo");

        assert_eq!(
            send_queue.batches(),
            [(
                DST_1,
                vec![b"foobar".as_slice(), b"barbaz", b"foobaz", b"foo"]
            )]
        );
    }

    #[test]
    fn starts_new_batch_for_new_dst() {
        let mut send_queue = SendQueue::new();

        send_queue.enqueue(DST_1, b"foobar");
        send_queue.enqueue(DST_1, b"barbaz");

        send_queue.enqueue(DST_2, b"barbarba");
        send_queue.enqueue(DST_2, b"foofoo");

        assert_eq!(
            send_queue.batches(),
            [
                (DST_1, vec![b"foobar".as_slice(), b"barbaz"]),
                (DST_2, vec![b"barbarba".as_slice(), b"foofoo"]),
            ]
        );
    }

    #[test]
    fn continues_batch_for_old_dst() {
        let mut send_queue = SendQueue::new();

        send_queue.enqueue(DST_1, b"foobar");
        send_queue.enqueue(DST_1, b"barbaz");

        send_queue.enqueue(DST_2, b"barbarba");
        send_queue.enqueue(DST_2, b"foofoo");

        send_queue.enqueue(DST_1, b"foobaz");
        send_queue.enqueue(DST_1, b"bazfoo");

        assert_eq!(
            send_queue.batches(),
            [
                (
                    DST_1,
                    vec![b"foobar".as_slice(), b"barbaz", b"foobaz", b"bazfoo"]
                ),
                (DST_2, vec![b"barbarba".as_slice(), b"foofoo"]),
            ]
        );
    }

    #[test]
    fn starts_new_batch_after_single_item_less_than_segment_length() {
        let mut send_queue = SendQueue::new();

        send_queue.enqueue(DST_1, b"foobar");
        send_queue.enqueue(DST_1, b"barbaz");
        send_queue.enqueue(DST_1, b"bar");

        send_queue.enqueue(DST_1, b"barbaz");

        assert_eq!(
            send_queue.batches(),
            [
                (DST_1, vec![b"foobar".as_slice(), b"barbaz", b"bar"]),
                (DST_1, vec![b"barbaz".as_slice()]),
            ]
        );
    }

    #[test]
    fn does_not_append_to_older_batch_of_same_connection() {
        let mut send_queue = SendQueue::new();

        send_queue.enqueue(DST_1, b"aaaa");
        send_queue.enqueue(DST_1, b"bbbbbb"); // Does not fit the first batch's segment size.
        send_queue.enqueue(DST_1, b"ccc"); // Short tail: seals the second batch.

        // The most recent batch is sealed, so this must open a new one;
        // appending to the first batch would overtake the second one.
        send_queue.enqueue(DST_1, b"dd");

        assert_eq!(
            send_queue.batches(),
            [
                (DST_1, vec![b"aaaa".as_slice()]),
                (DST_1, vec![b"bbbbbb".as_slice(), b"ccc"]),
                (DST_1, vec![b"dd".as_slice()]),
            ]
        );
    }

    #[test]
    fn seals_full_size_batch_at_one_gso_send() {
        let mut send_queue = SendQueue::new();
        let payload = [0u8; ip_packet::MAX_UDP_PAYLOAD as usize];

        // Full-size segments are byte-bound: 51 of them fill one GSO send to an IPv4 destination.
        let segment_len = UDP_HEADERS + payload.len() + WG_OVERHEAD;
        let segments_per_send = 51;
        assert_eq!(
            DatagramOut::max_len(DST_1, segment_len),
            segments_per_send * segment_len
        );

        for _ in 0..(segments_per_send + 1) {
            send_queue.enqueue(DST_1, &payload);
        }

        let batches = send_queue.batches();

        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].1.len(), segments_per_send);
        assert_eq!(batches[1].1.len(), 1);
    }

    #[test]
    fn seals_small_segment_batch_at_segment_limit() {
        let mut send_queue = SendQueue::new();
        let payload = [0u8; 100];

        // Small segments are count-bound: one GSO send carries at most the kernel's segment limit.
        let segment_len = UDP_HEADERS + payload.len() + WG_OVERHEAD;
        let segments_per_send = DatagramOut::max_len(DST_1, segment_len) / segment_len;
        assert_eq!(segments_per_send, 64);

        for _ in 0..(segments_per_send + 1) {
            send_queue.enqueue(DST_1, &payload);
        }

        let batches = send_queue.batches();

        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].1.len(), segments_per_send);
        assert_eq!(batches[1].1.len(), 1);
    }

    #[test]
    fn batch_buffers_never_reallocate() {
        let mut send_queue = SendQueue::new();
        let payload = [0u8; ip_packet::MAX_UDP_PAYLOAD as usize];

        for _ in 0..100 {
            send_queue.enqueue(DST_1, &payload);
        }

        for datagram in send_queue.queue.datagrams() {
            assert_eq!(datagram.packet.capacity(), GSO_BUFFER_SIZE);
        }
    }

    #[test]
    fn sealing_encrypts_all_datagrams_of_a_batch() {
        let now = Instant::now();
        let (mut alice, mut bob) = connected_tunnels(now);
        let mut send_queue = UdpGsoQueue::new();
        let packets = (0..20u8)
            .map(|i| ip_packet::make::udp_packet(SRC_IP, DST_IP, 1, 2, &[i; 100]).unwrap())
            .collect::<Vec<_>>();

        for (i, packet) in packets.iter().enumerate() {
            let dst = if i % 2 == 0 { DST_1 } else { DST_2 };
            enqueue(&mut send_queue, &mut alice, dst, packet.clone(), now);
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

    /// A [`UdpGsoQueue`] fed by a connected [`Tunn`].
    struct SendQueue {
        queue: UdpGsoQueue,
        alice: Tunn,
        bob: Tunn,
        now: Instant,
        popped: Vec<(SocketAddr, Vec<Vec<u8>>)>,
    }

    impl SendQueue {
        fn new() -> Self {
            let now = Instant::now();
            let (alice, bob) = connected_tunnels(now);

            Self {
                queue: UdpGsoQueue::new(),
                alice,
                bob,
                now,
                popped: Vec::new(),
            }
        }

        fn enqueue(&mut self, dst: SocketAddr, payload: &[u8]) {
            let packet = ip_packet::make::udp_packet(SRC_IP, DST_IP, 1, 2, payload).unwrap();

            enqueue(&mut self.queue, &mut self.alice, dst, packet, self.now);
        }

        /// Pops all batches, with the UDP payload of each of their data messages.
        fn batches(&mut self) -> Vec<(SocketAddr, Vec<&[u8]>)> {
            self.popped = std::iter::from_fn(|| self.queue.pop())
                .map(|datagram| {
                    let datagram = datagram.seal();
                    let payloads = datagram
                        .packet
                        .chunks(datagram.segment_size)
                        .map(|message| {
                            decapsulate(&mut self.bob, message, self.now)[UDP_HEADERS..].to_vec()
                        })
                        .collect();

                    (datagram.dst, payloads)
                })
                .collect();

            self.popped
                .iter()
                .map(|(dst, payloads)| (*dst, payloads.iter().map(Vec::as_slice).collect()))
                .collect()
        }
    }

    pub(crate) fn enqueue(
        queue: &mut UdpGsoQueue,
        tunn: &mut Tunn,
        dst: SocketAddr,
        packet: IpPacket,
        now: Instant,
    ) {
        let seal = tunn
            .encapsulate_data_deferred_at(packet.packet().len(), now)
            .unwrap();

        queue.push(DataMessage {
            src: None,
            dst,
            ecn: Ecn::NonEct,
            job: SealJob::new(None, Some(packet), seal),
        });
    }

    pub(crate) fn connected_tunnels(now: Instant) -> (Tunn, Tunn) {
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
        let TunnResult::KeepaliveDue = alice.decapsulate_at(None, &response, &mut buf, now) else {
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

    pub(crate) fn decapsulate(tunn: &mut Tunn, datagram: &[u8], now: Instant) -> Vec<u8> {
        let mut buf = [0u8; 2048];

        let TunnResult::WriteToTunnelV4(packet, _) =
            tunn.decapsulate_at(None, datagram, &mut buf, now)
        else {
            panic!("expected an IPv4 packet")
        };

        packet.to_vec()
    }

    impl UdpGsoQueue {
        fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut> + '_ {
            std::iter::from_fn(|| self.pop().map(PendingDatagram::seal))
        }
    }

    /// The IPv4 and UDP headers of a packet built by [`ip_packet::make::udp_packet`].
    const UDP_HEADERS: usize = 28;
    pub(crate) const SRC_IP: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);
    pub(crate) const DST_IP: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 2);
    pub(crate) const DST_1: SocketAddr =
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
}
