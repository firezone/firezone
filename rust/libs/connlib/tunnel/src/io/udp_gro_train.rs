use prefetch::Prefetch;
use smallvec::SmallVec;
use snownet::PendingDecapsulate;
use socket_factory::{DatagramIn, Segment};

use super::DecryptedBatch;

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

    /// Decrypts the batches of the train, in order.
    pub fn decrypt(self) -> impl Iterator<Item = DecryptedBatch> {
        let Self {
            datagram, batches, ..
        } = self;
        let mut batches = batches.into_iter().peekable();

        std::iter::from_fn(move || {
            let (segments, decapsulation) = batches.next()?;

            if let Some(next) = batches.peek().and_then(|(segments, _)| segments.first()) {
                datagram[*next].prefetch();
            }

            Some(DecryptedBatch {
                local: datagram.local(),
                from: datagram.from(),
                ecn: datagram.ecn(),
                packets: decapsulation.decrypt(segments.iter().map(|segment| &datagram[*segment])),
            })
        })
    }
}

impl Prefetch for UdpGroTrain {
    fn prefetch(&self) {
        if let Some(first) = self
            .batches
            .first()
            .and_then(|(segments, _)| segments.first())
        {
            self.datagram[*first].prefetch();
        }
    }
}
