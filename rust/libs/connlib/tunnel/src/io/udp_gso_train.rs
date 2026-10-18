use std::net::SocketAddr;

use bufferpool::Buffer;
use ip_packet::Ecn;
use snownet::EncryptJob;
use socket_factory::DatagramOut;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// The size every buffer in [`GSO_BUFFERS`] is allocated with.
///
/// An IP packet - and therefore the payload of one GSO send - can never exceed 65535 bytes.
/// A [`UdpGsoTrain`] is capped at one GSO send's worth of segments (see [`DatagramOut::max_len`]), which
/// is always below this capacity, so a pooled buffer never grows and never reallocates.
///
/// The buffer occupies this much memory regardless of how many segments it actually carries; every
/// in-flight [`DatagramOut`] pins one, which is why the outbound socket queue's depth directly bounds
/// the send path's memory footprint.
pub(crate) const GSO_BUFFER_SIZE: usize = u16::MAX as usize;

bufferpool::buffer_pool!(static GSO_BUFFERS: Vec<u8> = (GSO_BUFFER_SIZE, "gso-queue"), batch: 2);

/// Datagrams to one connection that one GSO send can carry: all of the same size, except for a
/// shorter last one.
#[derive(Debug, Clone, Copy)]
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
