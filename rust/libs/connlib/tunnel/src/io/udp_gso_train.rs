use std::{mem, net::SocketAddr, num::NonZeroUsize};

use bufferpool::Bytes;
use ip_packet::{Ecn, IpPacket};
use prefetch::IteratorExt as _;
use snownet::PendingEncapsulate;
use socket_factory::DatagramOut;

const MAX_SEGMENT_SIZE: usize =
    ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD + ip_packet::DATA_CHANNEL_OVERHEAD;

/// One encrypt job: the datagrams of one GSO send.
///
/// They go to one destination and are all of the same size, except for a shorter last one.
pub struct UdpGsoTrain {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    ecn: Ecn,
    /// The GSO segment size: the length of the first datagram.
    segment_size: usize,
    /// As many whole segments as one GSO send can carry to this destination.
    max_len: usize,
    len: usize,
    batches: Vec<(PendingEncapsulate, Vec<IpPacket>)>,
}

impl UdpGsoTrain {
    /// Starts an empty train from `src` to `dst`, which takes its shape from its first datagram.
    pub fn new(src: Option<SocketAddr>, dst: SocketAddr) -> Self {
        Self {
            src,
            dst,
            ecn: Ecn::NonEct,
            segment_size: 0,
            max_len: 0,
            len: 0,
            batches: Vec::new(),
        }
    }

    pub fn dst(&self) -> SocketAddr {
        self.dst
    }

    /// Whether the train goes from `src` to `dst`.
    pub fn is_between(&self, src: Option<SocketAddr>, dst: SocketAddr) -> bool {
        self.src == src && self.dst == dst
    }

    /// Appends as many of the `packets` of `encapsulation` as fit, returning the rest.
    ///
    /// An empty train takes at least one packet.
    pub fn extend(
        &mut self,
        mut encapsulation: PendingEncapsulate,
        mut packets: Vec<IpPacket>,
    ) -> Option<(PendingEncapsulate, Vec<IpPacket>)> {
        debug_assert!(self.is_between(encapsulation.src(), encapsulation.dst()));

        let Some(full_at) = packets
            .iter()
            .position(|p| !self.try_append(p.ecn(), encapsulation.datagram_len(p)))
        else {
            self.batches.push((encapsulation, packets));

            return None;
        };
        let Some(full_at) = NonZeroUsize::new(full_at) else {
            return Some((encapsulation, packets));
        };

        #[expect(
            clippy::unwrap_in_result,
            reason = "`None` means that every packet fit"
        )]
        let rest = encapsulation
            .split_off(full_at)
            .expect("one counter is reserved per packet");
        let rest = (rest, packets.split_off(full_at.get()));
        self.batches.push((encapsulation, packets));

        Some(rest)
    }

    /// Encrypts the packets of the train back-to-back into one datagram.
    ///
    /// Encryption stops at the first packet that fails; returns `None` if none made it.
    pub fn encrypt(mut self) -> Option<DatagramOut> {
        let mut buffer = Bytes::fitting(self.len);
        let datagram = buffer.expose(self.len);
        let mut len = 0;

        'batches: for (encapsulation, packets) in mem::take(&mut self.batches) {
            for result in encapsulation.encrypt_into(
                packets.iter().prefetching_with(|packet| *packet),
                &mut datagram[len..],
            ) {
                match result {
                    Ok(datagram_len) => len += datagram_len,
                    Err(e) => {
                        tracing::debug!("Failed to encrypt packet: {e}");

                        break 'batches;
                    }
                }
            }
        }
        buffer.truncate(len);

        if buffer.is_empty() {
            return None;
        }

        Some(self.into_datagram(buffer))
    }

    /// Appends a datagram of `len` bytes, unless it has to go on a new train.
    fn try_append(&mut self, ecn: Ecn, len: usize) -> bool {
        if self.len == 0 {
            debug_assert!(len <= MAX_SEGMENT_SIZE, "MAX_SEGMENT_SIZE is miscalculated");

            self.ecn = ecn;
            self.segment_size = len;
            self.max_len = DatagramOut::max_len(self.dst, len);
            self.len = len;

            return true;
        }

        // A shorter segment seals the train.
        let is_ongoing = self.len.is_multiple_of(self.segment_size);
        let fits_segment = len <= self.segment_size;
        let fits_send = self.len + len <= self.max_len;

        if !(ecn == self.ecn && is_ongoing && fits_segment && fits_send) {
            return false;
        }

        self.len += len;

        true
    }

    fn into_datagram(self, packet: Bytes) -> DatagramOut {
        DatagramOut {
            src: self.src,
            dst: self.dst,
            segment_size: self.segment_size,
            packet,
            ecn: self.ecn,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    #[test]
    fn shorter_segment_seals_train() {
        let mut train = UdpGsoTrain::new(None, DST);

        assert!(train.try_append(Ecn::NonEct, 6));
        assert!(train.try_append(Ecn::NonEct, 6));
        assert!(train.try_append(Ecn::NonEct, 3));
        assert!(!train.try_append(Ecn::NonEct, 3));
    }

    #[test]
    fn rejects_other_ecn_and_longer_segment() {
        let mut train = UdpGsoTrain::new(None, DST);

        assert!(train.try_append(Ecn::NonEct, 6));
        assert!(!train.try_append(Ecn::Ect0, 6));
        assert!(!train.try_append(Ecn::NonEct, 7));
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
        let mut train = UdpGsoTrain::new(None, DST);

        for _ in 0..segments_per_send {
            assert!(train.try_append(Ecn::NonEct, segment_size));
        }
        assert!(!train.try_append(Ecn::NonEct, segment_size));
    }

    const DST: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));
}
