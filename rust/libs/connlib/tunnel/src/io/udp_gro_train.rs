use std::{net::SocketAddr, ops::Index};

use ip_packet::Ecn;
use prefetch::IteratorExt as _;
use smallvec::SmallVec;
use snownet::PendingDecapsulate;
use socket_factory::{DatagramIn, Segment};

use super::DecryptedBatch;

/// The receive-side twin of [`UdpGsoTrain`](super::UdpGsoTrain): consecutive datagrams of one
/// receive from the same remote, as GRO coalesces them.
///
/// Its batches are runs of its segments, each decrypted with the [`PendingDecapsulate`] of its peer.
pub struct UdpGroTrain {
    datagrams: SmallVec<[DatagramIn; 1]>,
    num_segments: usize,
    /// How many segments the batches hold in total.
    len: usize,
    batches: SmallVec<[(Vec<TrainSegment>, PendingDecapsulate); 1]>,
}

/// Where a segment lies within its [`UdpGroTrain`].
#[derive(Debug, Clone, Copy)]
pub struct TrainSegment {
    datagram: usize,
    segment: Segment,
}

impl UdpGroTrain {
    pub fn new(datagram: DatagramIn) -> Self {
        Self {
            num_segments: datagram.num_segments(),
            datagrams: SmallVec::from_buf([datagram]),
            len: 0,
            batches: SmallVec::new(),
        }
    }

    /// Whether `datagram` comes from the same remote with the same ECN as the train.
    pub fn continues_with(&self, datagram: &DatagramIn) -> bool {
        (datagram.local(), datagram.from(), datagram.ecn())
            == (self.local(), self.from(), self.ecn())
    }

    /// Appends `datagram`, which the train [continues with](Self::continues_with).
    pub fn append(&mut self, datagram: DatagramIn) {
        self.num_segments += datagram.num_segments();
        self.datagrams.push(datagram);
    }

    pub fn local(&self) -> SocketAddr {
        self.datagrams[0].local()
    }

    pub fn from(&self) -> SocketAddr {
        self.datagrams[0].from()
    }

    pub fn ecn(&self) -> Ecn {
        self.datagrams[0].ecn()
    }

    /// How many segments the datagrams hold.
    pub fn num_segments(&self) -> usize {
        self.num_segments
    }

    /// Iterates over the segments of the datagrams, in order.
    pub fn segments(&self) -> impl Iterator<Item = TrainSegment> + use<> {
        let segments = self
            .datagrams
            .iter()
            .map(DatagramIn::segments)
            .collect::<SmallVec<[_; 1]>>();

        segments
            .into_iter()
            .enumerate()
            .flat_map(|(datagram, segments)| {
                segments.map(move |segment| TrainSegment { datagram, segment })
            })
    }

    /// Appends `segments`, a run of the train in order, to decrypt with `decapsulation`.
    pub fn push(&mut self, decapsulation: PendingDecapsulate, segments: Vec<TrainSegment>) {
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
        let (local, from, ecn) = (self.local(), self.from(), self.ecn());
        let datagrams = &self.datagrams;

        decrypted.extend(self.batches.drain(..).map(|(segments, decapsulation)| {
            DecryptedBatch {
                local,
                from,
                ecn,
                packets: decapsulation.decrypt(
                    segments
                        .iter()
                        .map(|s| &datagrams[s.datagram][s.segment])
                        .prefetching_with(|segment| *segment),
                ),
            }
        }));
    }
}

impl Index<TrainSegment> for UdpGroTrain {
    type Output = [u8];

    fn index(&self, segment: TrainSegment) -> &[u8] {
        &self.datagrams[segment.datagram][segment.segment]
    }
}
