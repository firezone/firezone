use std::{net::SocketAddr, ops::Deref};

use prefetch::IteratorExt as _;
use smallvec::SmallVec;
use snownet::PendingDecapsulate;
use socket_factory::DatagramIn;

use super::DecryptedBatch;

/// How many segments go to a worker in one decrypt job at most, counted over its datagrams.
///
/// A receive buffer holds at most this many segments, so every buffer fits into a single job.
pub const MAX_TRAIN_SEGMENTS: usize = 64;

/// One decrypt job: consecutive datagrams of one receive with at most [`MAX_TRAIN_SEGMENTS`]
/// segments, and the batches of data messages among them.
///
/// A datagram can hold segments of several batches, such as the channel data of several peers
/// from one relay, and a batch can span several datagrams, so every batch that shares a datagram
/// has to go to the same job. Trains are therefore cut between datagrams before any segment is
/// batched, and a batch ends where its train does, even if the next datagram would continue it.
pub struct UdpGroTrain {
    datagrams: SmallVec<[DatagramIn; 1]>,
    num_segments: usize,
    /// Each batch with the index of its first segment in the train.
    batches: Vec<(PendingDecapsulate, usize)>,
}

/// A segment of a [`UdpGroTrain`], i.e. one datagram as its remote sent it.
pub struct ReceivedSegment<'a> {
    datagram: &'a DatagramIn,
    segment: &'a [u8],
    index: SegmentIndex,
}

/// Where a [`ReceivedSegment`] lies among the trains of one receive.
#[derive(Debug, Clone, Copy)]
pub struct SegmentIndex {
    train: usize,
    segment: usize,
}

impl UdpGroTrain {
    pub fn new(datagram: DatagramIn) -> Self {
        Self {
            num_segments: datagram.num_segments(),
            datagrams: SmallVec::from_buf([datagram]),
            batches: Vec::new(),
        }
    }

    /// Whether `datagram` fits into the train.
    pub fn accepts(&self, datagram: &DatagramIn) -> bool {
        self.num_segments + datagram.num_segments() <= MAX_TRAIN_SEGMENTS
    }

    pub fn push(&mut self, datagram: DatagramIn) {
        self.num_segments += datagram.num_segments();
        self.datagrams.push(datagram);
    }

    /// Iterates over the segments of the datagrams, in order.
    ///
    /// `index` is the train's position among the trains of its receive.
    pub fn segments(&self, index: usize) -> impl Iterator<Item = ReceivedSegment<'_>> {
        segments(&self.datagrams)
            .enumerate()
            .map(move |(segment, (datagram, bytes))| ReceivedSegment {
                datagram,
                segment: bytes,
                index: SegmentIndex {
                    train: index,
                    segment,
                },
            })
    }

    /// Adds the batch decrypted with `decapsulation` that begins with the segment at `first`.
    pub fn add_batch(&mut self, decapsulation: PendingDecapsulate, first: SegmentIndex) {
        self.batches.push((decapsulation, first.segment));
    }

    pub fn has_batches(&self) -> bool {
        !self.batches.is_empty()
    }

    /// Decrypts the batches, in order.
    pub fn decrypt(self) -> Vec<DecryptedBatch> {
        let segments = segments(&self.datagrams).collect::<SmallVec<[_; MAX_TRAIN_SEGMENTS]>>();

        self.batches
            .into_iter()
            .map(|(decapsulation, start)| {
                let batch = &segments[start..][..decapsulation.len()];
                let (datagram, _) = batch[0];

                DecryptedBatch {
                    local: datagram.local(),
                    from: datagram.from(),
                    ecn: datagram.ecn(),
                    packets: decapsulation.decrypt(
                        batch
                            .iter()
                            .map(|(_, segment)| *segment)
                            .prefetching_with(|segment| *segment),
                    ),
                }
            })
            .collect()
    }
}

impl ReceivedSegment<'_> {
    pub fn local(&self) -> SocketAddr {
        self.datagram.local()
    }

    pub fn from(&self) -> SocketAddr {
        self.datagram.from()
    }

    pub(super) fn index(&self) -> SegmentIndex {
        self.index
    }

    /// Whether this segment may join a batch that begins with `first`: it arrived on the same path
    /// with the same ECN, in the same train.
    pub fn may_join(&self, first: &Self) -> bool {
        let path = |s: &Self| (s.datagram.local(), s.datagram.from(), s.datagram.ecn());

        self.index.train == first.index.train
            && (std::ptr::eq(self.datagram, first.datagram) || path(self) == path(first))
    }
}

impl SegmentIndex {
    /// The index of the segment's train.
    pub fn train(&self) -> usize {
        self.train
    }
}

impl Deref for ReceivedSegment<'_> {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        self.segment
    }
}

fn segments(datagrams: &[DatagramIn]) -> impl Iterator<Item = (&DatagramIn, &[u8])> {
    datagrams.iter().flat_map(|datagram| {
        datagram
            .segments()
            .map(move |segment| (datagram, &datagram[segment]))
    })
}
