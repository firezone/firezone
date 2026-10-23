use std::net::SocketAddr;

use bufferpool::Bytes;
use ip_packet::{Ecn, IpPacket};
use snownet::PendingEncapsulate;
use socket_factory::DatagramOut;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

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

        let max_len = DatagramOut::max_len(dst, len);

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
    ) -> Option<DatagramOut> {
        let mut buffer = Bytes::fitting(self.len);
        let datagram = buffer.expose(self.len);
        let mut len = 0;

        for (encapsulation, packet) in packets {
            let end = len + encapsulation.datagram_len(&packet);

            match encapsulation
                .encrypt_into([(&packet, &mut datagram[len..end])])
                .next()
            {
                Some(Ok(())) => len = end,
                Some(Err(e)) => tracing::debug!("Failed to encrypt packet: {e}"),
                None => {}
            }
        }
        buffer.truncate(len);

        if buffer.is_empty() {
            return None;
        }

        Some(self.into_datagram(buffer))
    }

    fn into_datagram(self, packet: Bytes) -> DatagramOut {
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
