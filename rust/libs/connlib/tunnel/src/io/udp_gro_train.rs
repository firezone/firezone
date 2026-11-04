use smallvec::SmallVec;
use snownet::PendingDecapsulate;
use socket_factory::{DatagramIn, Segment};

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
            datagram,
            segments: SmallVec::new(),
        }
    }

    pub fn datagram(&self) -> &DatagramIn {
        &self.datagram
    }

    /// Appends `segment` to decrypt with `decapsulation`.
    pub fn push(&mut self, segment: Segment, decapsulation: PendingDecapsulate) {
        self.segments.push((segment, decapsulation));
    }

    /// How many segments are to be decrypted.
    pub fn len(&self) -> usize {
        self.segments.len()
    }

    pub fn is_empty(&self) -> bool {
        self.segments.is_empty()
    }

    /// Moves out the segments to decrypt, in order, along with their datagram.
    pub fn drain(
        &mut self,
    ) -> impl Iterator<Item = (&DatagramIn, Segment, PendingDecapsulate)> + '_ {
        let Self { datagram, segments } = self;
        let datagram = &*datagram;

        segments
            .drain(..)
            .map(move |(segment, decapsulation)| (datagram, segment, decapsulation))
    }
}
