use prefetch::Prefetch;
use smallvec::SmallVec;
use snownet::PendingDecapsulate;
use socket_factory::{DatagramIn, Segment};

use super::crypto::DecryptedDatagram;

/// The receive-side twin of [`UdpGsoTrain`](super::UdpGsoTrain): the datagrams of one GRO receive.
///
/// Each of its segments to decrypt goes with the [`PendingDecapsulate`] of its peer.
pub struct UdpGroTrain {
    datagram: DatagramIn,
    segments: SmallVec<[(Segment, PendingDecapsulate); 1]>,
}

impl UdpGroTrain {
    pub fn new(datagram: DatagramIn) -> Self {
        Self {
            segments: SmallVec::with_capacity(datagram.num_segments()),
            datagram,
        }
    }

    pub fn datagram(&self) -> &DatagramIn {
        &self.datagram
    }

    /// Appends `segment` to decrypt with `decapsulation`.
    pub fn push(&mut self, decapsulation: PendingDecapsulate, segment: Segment) {
        self.segments.push((segment, decapsulation));
    }

    /// How many segments are to be decrypted.
    pub fn len(&self) -> usize {
        self.segments.len()
    }

    pub fn is_empty(&self) -> bool {
        self.segments.is_empty()
    }

    /// Decrypts the segments, in order, into `decrypted`.
    pub fn decrypt_into(&mut self, decrypted: &mut Vec<DecryptedDatagram>) {
        let datagram = &self.datagram;

        decrypted.extend(self.segments.drain(..).map(|(segment, decapsulation)| {
            DecryptedDatagram {
                local: datagram.local(),
                from: datagram.from(),
                ecn: datagram.ecn(),
                packet: decapsulation.decrypt(&datagram[segment]),
            }
        }));
    }
}

impl Prefetch for UdpGroTrain {
    fn prefetch(&self) {
        let Some((segment, _)) = self.segments.first() else {
            return;
        };

        self.datagram[*segment].prefetch();
    }
}
