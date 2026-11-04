use prefetch::IteratorExt as _;
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

    /// Appends `segments`, a run of the datagram in order, to decrypt with `decapsulation`.
    pub fn push(&mut self, decapsulation: PendingDecapsulate, segments: Vec<Segment>) {
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

    /// Decrypts the batches, in order, into `decrypted`.
    pub fn decrypt_into(&mut self, decrypted: &mut Vec<DecryptedBatch>) {
        let datagram = &self.datagram;

        decrypted.extend(self.batches.drain(..).map(|(segments, decapsulation)| {
            DecryptedBatch {
                local: datagram.local(),
                from: datagram.from(),
                ecn: datagram.ecn(),
                packets: decapsulation.decrypt(
                    segments
                        .iter()
                        .map(|segment| &datagram[*segment])
                        .prefetching_with(|segment| *segment),
                ),
            }
        }));
    }
}
