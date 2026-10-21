use std::net::SocketAddr;

use bufferpool::{Buffer, BufferPool, Pool};
use ip_packet::{Ecn, IpPacket};
use snownet::PendingEncapsulate;
use socket_factory::{DatagramOut, max_datagram_len};

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

bufferpool::buffer_pool!(static GSO_BUFFERS_2K = (2 * 1024, "gso-train-2k"), batch: 2, pool: GsoBuffers::K2);
bufferpool::buffer_pool!(static GSO_BUFFERS_4K = (4 * 1024, "gso-train-4k"), batch: 2, pool: GsoBuffers::K4);
bufferpool::buffer_pool!(static GSO_BUFFERS_8K = (8 * 1024, "gso-train-8k"), batch: 2, pool: GsoBuffers::K8);
bufferpool::buffer_pool!(static GSO_BUFFERS_16K = (16 * 1024, "gso-train-16k"), batch: 2, pool: GsoBuffers::K16);
bufferpool::buffer_pool!(static GSO_BUFFERS_32K = (32 * 1024, "gso-train-32k"), batch: 2, pool: GsoBuffers::K32);
bufferpool::buffer_pool!(static GSO_BUFFERS_64K = (64 * 1024, "gso-train-64k"), batch: 2, pool: GsoBuffers::K64);

/// The pools of GSO train buffers, one per size class.
#[derive(Clone, Copy)]
pub(crate) enum GsoBuffers {
    K2,
    K4,
    K8,
    K16,
    K32,
    K64,
}

impl Pool for GsoBuffers {
    type Buf = Vec<u8>;

    fn pool(self) -> &'static BufferPool<Self> {
        match self {
            GsoBuffers::K2 => &GSO_BUFFERS_2K,
            GsoBuffers::K4 => &GSO_BUFFERS_4K,
            GsoBuffers::K8 => &GSO_BUFFERS_8K,
            GsoBuffers::K16 => &GSO_BUFFERS_16K,
            GsoBuffers::K32 => &GSO_BUFFERS_32K,
            GsoBuffers::K64 => &GSO_BUFFERS_64K,
        }
    }
}

/// The pool of the smallest buffers that fit `len` bytes: at most 2 KiB or twice `len`.
///
/// One GSO send never exceeds 64 KiB, so neither does a [`UdpGsoTrain`].
fn gso_buffers(len: usize) -> GsoBuffers {
    match len {
        0..=2_048 => GsoBuffers::K2,
        2_049..=4_096 => GsoBuffers::K4,
        4_097..=8_192 => GsoBuffers::K8,
        8_193..=16_384 => GsoBuffers::K16,
        16_385..=32_768 => GsoBuffers::K32,
        _ => GsoBuffers::K64,
    }
}

/// Datagrams to one connection that one GSO send can carry: all of the same size, except for a
/// shorter last one.
pub struct UdpGsoTrain {
    connection: Connection,
    /// The GSO segment size: the length of the first datagram.
    segment_size: usize,
    /// As many whole segments as one GSO send can carry to this destination.
    max_len: usize,
    len: usize,
}

impl UdpGsoTrain {
    /// Starts a train with a datagram of `len` bytes.
    pub fn new(src: Option<SocketAddr>, dst: SocketAddr, ecn: Ecn, len: usize) -> Self {
        debug_assert!(len <= MAX_SEGMENT_SIZE, "MAX_SEGMENT_SIZE is miscalculated");

        let max_len = max_datagram_len(dst, len);

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

    /// The most datagrams the train can hold.
    pub fn max_segments(&self) -> usize {
        self.max_len / self.segment_size
    }

    /// Whether the train goes from `src` to `dst`.
    pub fn is_between(&self, src: Option<SocketAddr>, dst: SocketAddr) -> bool {
        self.connection.src == src && self.connection.dst == dst
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

    /// Encrypts `packets`, the ones this train was built from, back-to-back into one datagram.
    ///
    /// Packets that fail to encrypt are skipped; returns `None` if none are left.
    pub fn encrypt(
        self,
        packets: impl Iterator<Item = (PendingEncapsulate, IpPacket)>,
    ) -> Option<DatagramOut<GsoBuffers>> {
        let mut buffer = gso_buffers(self.len).pool().pull();
        buffer.clear();

        for (encapsulation, packet) in packets {
            let offset = buffer.len();
            buffer.resize(offset + encapsulation.datagram_len(&packet), 0);

            if let Err(e) = encapsulation.encrypt_into(&packet, &mut buffer[offset..]) {
                tracing::debug!("Failed to encrypt packet: {e}");
                buffer.truncate(offset);
            }
        }

        if buffer.is_empty() {
            return None;
        }

        Some(self.into_datagram(buffer))
    }

    fn into_datagram(self, packet: Buffer<GsoBuffers>) -> DatagramOut<GsoBuffers> {
        DatagramOut {
            src: self.connection.src,
            dst: self.connection.dst,
            // Skipped packets may leave only the shorter last segment.
            segment_size: self.segment_size.min(packet.len()),
            packet,
            ecn: self.connection.ecn,
        }
    }
}

#[derive(PartialEq, Eq)]
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
    fn shorter_segment_seals_train() {
        let mut train = UdpGsoTrain::new(None, DST_1, Ecn::NonEct, 6);

        assert!(train.try_append(None, DST_1, Ecn::NonEct, 6));
        assert!(train.try_append(None, DST_1, Ecn::NonEct, 3));
        assert!(!train.try_append(None, DST_1, Ecn::NonEct, 3));
    }

    #[test]
    fn rejects_other_connection_and_longer_segment() {
        let mut train = UdpGsoTrain::new(None, DST_1, Ecn::NonEct, 6);

        assert!(!train.try_append(None, DST_2, Ecn::NonEct, 6));
        assert!(!train.try_append(None, DST_1, Ecn::Ect0, 6));
        assert!(!train.try_append(None, DST_1, Ecn::NonEct, 7));
    }

    #[test]
    fn full_size_segments_fill_one_gso_send() {
        assert_segments_per_send(MAX_SEGMENT_SIZE, 49);
    }

    #[test]
    fn small_segments_hit_kernel_segment_limit() {
        assert_segments_per_send(100, socket_factory::MAX_GSO_SEGMENTS);
    }

    #[test]
    fn train_takes_smallest_fitting_buffer() {
        for (len, capacity) in [
            (1, 2 * 1024),
            (2 * 1024, 2 * 1024),
            (2 * 1024 + 1, 4 * 1024),
            (32 * 1024 + 1, 64 * 1024),
            (max_datagram_len(DST_1, MAX_SEGMENT_SIZE), 64 * 1024),
        ] {
            assert_eq!(gso_buffers(len).pool().pull().capacity(), capacity);
        }
    }

    fn assert_segments_per_send(segment_size: usize, segments_per_send: usize) {
        let mut train = UdpGsoTrain::new(None, DST_1, Ecn::NonEct, segment_size);

        for _ in 1..segments_per_send {
            assert!(train.try_append(None, DST_1, Ecn::NonEct, segment_size));
        }
        assert!(!train.try_append(None, DST_1, Ecn::NonEct, segment_size));
    }

    const DST_1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
    const DST_2: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 2222));
}
