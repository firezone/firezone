use smallvec::SmallVec;
use snownet::PendingDecapsulate;
use socket_factory::{DatagramIn, Segment};

/// The receive-side twin of [`UdpGsoTrain`](super::UdpGsoTrain): the datagrams of one GRO receive.
///
/// Its batches are runs of its segments, each decrypted with the [`PendingDecapsulate`] of its peer.
pub struct UdpGroTrain {
    datagram: DatagramIn,
    /// How many segments the batches hold in total.
    len: usize,
    batches: SmallVec<[(Vec<Segment>, PendingDecapsulate); 1]>,
}

impl UdpGroTrain {
    pub fn new(datagram: DatagramIn) -> Self {
        Self {
            datagram,
            len: 0,
            batches: SmallVec::new(),
        }
    }

    pub fn datagram(&self) -> &DatagramIn {
        &self.datagram
    }

    /// Appends `segments`, those of `decapsulation` in order, as a batch to decrypt.
    pub fn push(&mut self, segments: Vec<Segment>, decapsulation: PendingDecapsulate) {
        self.len += segments.len();
        self.batches.push((segments, decapsulation));
    }

    /// How many segments are to be decrypted.
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.batches.is_empty()
    }

    pub fn num_batches(&self) -> usize {
        self.batches.len()
    }

    /// Moves out the batches of the train, in order, each with the datagram it is in.
    pub fn drain(
        &mut self,
    ) -> impl Iterator<Item = (&DatagramIn, Vec<Segment>, PendingDecapsulate)> + '_ {
        let Self {
            datagram, batches, ..
        } = self;
        let datagram = &*datagram;

        batches
            .drain(..)
            .map(move |(segments, decapsulation)| (datagram, segments, decapsulation))
    }
}
