use std::{net::SocketAddr, ops::Deref};

use prefetch::IteratorExt as _;
use smallvec::SmallVec;
use snownet::PendingDecapsulate;
use socket_factory::DatagramIn;

use super::DecryptedBatch;

/// How many segments go to a worker in one decrypt job at most, counted over its datagrams.
///
/// A receive buffer holds at most this many segments, so every buffer fits into a single job.
pub const DECRYPT_BATCH_SIZE: usize = 64;

/// The datagrams of one receive, split into the [`UdpGroTrain`]s of their decrypt jobs.
pub struct Received {
    trains: Vec<UdpGroTrain>,
}

/// One decrypt job: consecutive datagrams of one receive with at most [`DECRYPT_BATCH_SIZE`]
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

/// A segment of a [`Received`], i.e. one datagram as its remote sent it.
pub struct ReceivedSegment<'a> {
    datagram: &'a DatagramIn,
    segment: &'a [u8],
    index: SegmentIndex,
}

/// Where a [`ReceivedSegment`] lies within its [`Received`].
#[derive(Debug, Clone, Copy)]
pub struct SegmentIndex {
    train: usize,
    segment: usize,
}

impl Received {
    pub fn new(datagrams: impl Iterator<Item = DatagramIn>) -> Self {
        let mut trains = Vec::<UdpGroTrain>::new();

        for datagram in datagrams {
            let num_segments = datagram.num_segments();

            match trains.last_mut() {
                Some(train) if train.num_segments + num_segments <= DECRYPT_BATCH_SIZE => {
                    train.num_segments += num_segments;
                    train.datagrams.push(datagram);
                }
                Some(_) | None => trains.push(UdpGroTrain {
                    datagrams: SmallVec::from_buf([datagram]),
                    num_segments,
                    batches: Vec::new(),
                }),
            }
        }

        Self { trains }
    }

    /// Iterates over the segments of the datagrams, in order.
    pub fn segments(&self) -> impl Iterator<Item = ReceivedSegment<'_>> {
        self.trains.iter().enumerate().flat_map(|(train, t)| {
            segments(&t.datagrams)
                .enumerate()
                .map(move |(segment, (datagram, bytes))| ReceivedSegment {
                    datagram,
                    segment: bytes,
                    index: SegmentIndex { train, segment },
                })
        })
    }

    /// Adds each of `batches` to the train of the segment it begins with, returning the trains
    /// that have any.
    pub fn into_trains(
        mut self,
        batches: Vec<(PendingDecapsulate, SegmentIndex)>,
    ) -> impl Iterator<Item = UdpGroTrain> {
        for (decapsulation, index) in batches {
            self.trains[index.train]
                .batches
                .push((decapsulation, index.segment));
        }

        self.trains
            .into_iter()
            .filter(|train| !train.batches.is_empty())
    }
}

impl UdpGroTrain {
    /// Decrypts the batches, in order.
    pub fn decrypt(self) -> Vec<DecryptedBatch> {
        let mut segments = segments(&self.datagrams).peekable();
        let mut position = 0;

        self.batches
            .into_iter()
            .map(|(decapsulation, start)| {
                for _ in segments.by_ref().take(start - position) {}
                let len = decapsulation.len();
                position = start + len;

                let (datagram, _) = *segments
                    .peek()
                    .expect("a batch begins with a segment of its train");

                DecryptedBatch {
                    local: datagram.local(),
                    from: datagram.from(),
                    ecn: datagram.ecn(),
                    packets: decapsulation.decrypt(
                        segments
                            .by_ref()
                            .take(len)
                            .map(|(_, segment)| segment)
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

    pub fn index(&self) -> SegmentIndex {
        self.index
    }

    /// Whether `next` may join a batch that begins with this segment: it arrived on the same path
    /// with the same ECN, in the same train.
    pub fn may_batch_with(&self, next: &Self) -> bool {
        let path = |s: &Self| (s.datagram.local(), s.datagram.from(), s.datagram.ecn());

        self.index.train == next.index.train
            && (std::ptr::eq(self.datagram, next.datagram) || path(self) == path(next))
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
