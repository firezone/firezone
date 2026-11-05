use std::{
    mem,
    net::SocketAddr,
    num::NonZeroUsize,
    sync::mpsc,
    task::{Context, Poll, ready},
    thread,
};

use futures::{StreamExt as _, stream::FuturesOrdered};
use ip_packet::{Ecn, IpPacket, IpVersion};
use opentelemetry::metrics::Counter;
use snownet::{PendingDecapsulate, PendingEncapsulate};
use socket_factory::DatagramOut;
use tokio::sync::oneshot;

use super::udp_gro_train::{DECRYPT_BATCH_SIZE, ReceivedSegment, SegmentIndex, UdpGroTrain};
use super::udp_gso_train::UdpGsoTrain;
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{PendingDatagrams, ReceivedDatagrams, Sockets};
use smallvec::SmallVec;

/// How many jobs may await decryption before we stop reading from the network.
///
/// Every job pins its receive buffers. Android's are sized for a full GRO batch and its memory
/// budget leaves no room for the jobs of an earlier read, so it reads again only once those are done.
const MAX_JOBS_IN_FLIGHT: usize = cfg_select! {
    target_os = "android" => { 1 }
    _ => { 4 }
};

/// Worst-case memory pinned by the jobs still awaiting decryption when we read from the network.
///
/// A job holds at most one receive buffer per segment.
pub(crate) const MAX_DECRYPT_BACKLOG_MEMORY: usize =
    (MAX_JOBS_IN_FLIGHT - 1) * DECRYPT_BATCH_SIZE * socket_factory::MAX_RECV_BUFFER_MEMORY;

/// A batch of WireGuard data messages from one [`UdpGroTrain`], decrypted.
pub struct DecryptedBatch {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub ecn: Ecn,
    pub packets: snownet::DecryptedBatch,
}

/// Encrypts and decrypts WireGuard data messages on worker threads.
///
/// Jobs of either kind go to the next worker round-robin.
/// Without any workers, jobs run on the thread that submits them.
pub struct CryptoWorkers {
    workers: Workers,
    /// The open train to each destination of the current [`EncryptJobs`], kept for its capacity.
    open_gso_trains: Vec<UdpGsoTrain>,
}

struct Workers {
    senders: Vec<mpsc::Sender<Job>>,
    next: usize,
    packet_counter: Counter<u64>,
}

enum Job {
    Encrypt(EncryptJob),
    Decrypt(DecryptJob),
}

/// Packets decrypted by one decrypt job.
#[derive(Default)]
pub struct DecryptedIpPackets(Vec<DecryptedBatch>);

impl DecryptedIpPackets {
    /// Moves out every decrypted packet, in the order it was received.
    pub fn drain(&mut self) -> impl Iterator<Item = DecryptedBatch> + '_ {
        self.0.drain(..)
    }
}

/// The decrypt jobs that were done by the time [`Decrypting::poll_next`] looked.
#[derive(Default)]
pub struct DecryptedJobs(SmallVec<[DecryptedIpPackets; MAX_JOBS_IN_FLIGHT]>);

impl DecryptedJobs {
    /// Moves out every decrypted packet, in the order it was received.
    pub fn drain(&mut self) -> impl Iterator<Item = DecryptedBatch> + '_ {
        self.0.iter_mut().flat_map(DecryptedIpPackets::drain)
    }
}

impl Default for CryptoWorkers {
    fn default() -> Self {
        Self::with_num_workers(num_crypto_workers())
    }
}

impl CryptoWorkers {
    pub fn with_num_workers(num_workers: usize) -> Self {
        let packet_counter = otel_instruments::network_packets();

        Self {
            workers: Workers {
                senders: spawn_workers(num_workers, packet_counter.clone()),
                next: 0,
                packet_counter,
            },
            open_gso_trains: Vec::new(),
        }
    }

    /// Creates the jobs that encrypt packets, whose datagrams go to `sockets`.
    pub fn new_encrypt_jobs<'a>(&'a mut self, sockets: &'a mut Sockets) -> EncryptJobs<'a> {
        EncryptJobs {
            workers: &mut self.workers,
            gso_trains: &mut self.open_gso_trains,
            sockets,
            pending_v4: None,
            pending_v6: None,
        }
    }

    /// Creates the jobs that decrypt the batches of `received`, queueing their results in
    /// `decrypting`.
    pub fn new_decrypt_jobs<'a>(
        &'a mut self,
        decrypting: &'a mut Decrypting,
        mut received: ReceivedDatagrams,
    ) -> DecryptJobs<'a> {
        let mut trains = Vec::<UdpGroTrain>::new();

        for datagram in received.drain() {
            match trains.last_mut() {
                Some(train) if train.accepts(&datagram) => train.push(datagram),
                Some(_) | None => trains.push(UdpGroTrain::new(datagram)),
            }
        }

        DecryptJobs {
            workers: &mut self.workers,
            decrypting,
            trains,
            batches: Vec::new(),
        }
    }
}

impl Workers {
    /// Sends `job` to the worker after the one picked last, removing the workers that stopped.
    ///
    /// Without any workers left, `job` runs inline.
    fn send(&mut self, mut job: Job) {
        while !self.senders.is_empty() {
            let index = self.next % self.senders.len();
            self.next = self.next.wrapping_add(1);

            match self.senders[index].send(job) {
                Ok(()) => return,
                Err(mpsc::SendError(unsent)) => {
                    tracing::debug!("Crypto worker stopped");

                    self.senders.remove(index);
                    job = unsent;
                }
            }
        }

        run(job, &self.packet_counter);
    }
}

/// Packets to encrypt, sent to the UDP sockets when dropped.
pub struct EncryptJobs<'a> {
    workers: &'a mut Workers,
    /// The open train to each destination.
    gso_trains: &'a mut Vec<UdpGsoTrain>,
    sockets: &'a mut Sockets,
    pending_v4: Option<PendingDatagrams>,
    pending_v6: Option<PendingDatagrams>,
}

impl EncryptJobs<'_> {
    /// Adds the `packets` of `encapsulation` to the train to its destination, continuing on a new
    /// train where one is full.
    pub fn add(&mut self, mut encapsulation: PendingEncapsulate, mut packets: Vec<IpPacket>) {
        let (src, dst) = (encapsulation.src(), encapsulation.dst());
        let index = self.train_for(src, dst);

        while let Some(rest) = self.gso_trains[index].extend(encapsulation, packets) {
            let full = mem::replace(&mut self.gso_trains[index], UdpGsoTrain::new(src, dst));
            dispatch(
                self.workers,
                &mut self.pending_v4,
                &mut self.pending_v6,
                full,
            );

            (encapsulation, packets) = rest;
        }
    }

    /// Returns the index of the open train from `src` to `dst`, opening one if there is none.
    fn train_for(&mut self, src: Option<SocketAddr>, dst: SocketAddr) -> usize {
        match self
            .gso_trains
            .iter()
            .position(|open| open.is_between(src, dst))
        {
            Some(index) => index,
            None => {
                self.gso_trains.push(UdpGsoTrain::new(src, dst));

                self.gso_trains.len() - 1
            }
        }
    }
}

/// Hands `train` to a worker, queueing its datagram to be sent after the ones before it.
fn dispatch(
    workers: &mut Workers,
    pending_v4: &mut Option<PendingDatagrams>,
    pending_v6: &mut Option<PendingDatagrams>,
    train: UdpGsoTrain,
) {
    let (tx, rx) = oneshot::channel();
    let pending = match train.dst() {
        SocketAddr::V4(_) => pending_v4,
        SocketAddr::V6(_) => pending_v6,
    };
    pending.get_or_insert_default().push(rx);

    // A stopped worker drops the sender, so the socket skips the train.
    workers.send(Job::Encrypt(EncryptJob {
        train,
        encrypted: tx,
    }));
}

impl Drop for EncryptJobs<'_> {
    fn drop(&mut self) {
        for open in self.gso_trains.drain(..) {
            dispatch(
                self.workers,
                &mut self.pending_v4,
                &mut self.pending_v6,
                open,
            );
        }

        if let Some(pending) = self.pending_v4.take() {
            self.sockets.send_pending(IpVersion::V4, pending);
        }

        if let Some(pending) = self.pending_v6.take() {
            self.sockets.send_pending(IpVersion::V6, pending);
        }
    }
}

/// The trains of one receive and the batches of their segments to decrypt, handed to the workers
/// when dropped.
pub struct DecryptJobs<'a> {
    workers: &'a mut Workers,
    decrypting: &'a mut Decrypting,
    trains: Vec<UdpGroTrain>,
    /// Each batch with the index of the segment it begins with.
    batches: Vec<(PendingDecapsulate, SegmentIndex)>,
}

impl DecryptJobs<'_> {
    /// Returns where to add the batches and the received segments to make them of, in order.
    pub fn split(
        &mut self,
    ) -> (
        DecryptBatches<'_>,
        impl Iterator<Item = ReceivedSegment<'_>>,
    ) {
        let segments = self
            .trains
            .iter()
            .enumerate()
            .flat_map(|(index, train)| train.segments(index));

        (DecryptBatches(&mut self.batches), segments)
    }
}

impl Drop for DecryptJobs<'_> {
    fn drop(&mut self) {
        for (decapsulation, first) in self.batches.drain(..) {
            self.trains[first.train()].add_batch(decapsulation, first);
        }

        for train in self.trains.drain(..).filter(UdpGroTrain::has_batches) {
            // A stopped worker drops the sender, so `Decrypting::poll_job` skips the job.
            self.workers.send(Job::Decrypt(DecryptJob {
                train,
                decrypted: self.decrypting.add_job(),
            }));
        }
    }
}

/// Where to add the batches of a [`DecryptJobs`].
pub struct DecryptBatches<'a>(&'a mut Vec<(PendingDecapsulate, SegmentIndex)>);

impl DecryptBatches<'_> {
    /// Adds the batch decrypted with `decapsulation` that begins with `first`.
    pub fn add(&mut self, decapsulation: PendingDecapsulate, first: &ReceivedSegment<'_>) {
        self.0.push((decapsulation, first.index()));
    }
}

/// The decrypt jobs handed to the workers, in submission order.
#[derive(Default)]
pub struct Decrypting {
    jobs: FuturesOrdered<oneshot::Receiver<DecryptedIpPackets>>,
}

impl Decrypting {
    /// Queues a job that completes once the returned sender sends its packets.
    pub(crate) fn add_job(&mut self) -> oneshot::Sender<DecryptedIpPackets> {
        let (tx, rx) = oneshot::channel();
        self.jobs.push_back(rx);

        tx
    }

    /// Whether we may hand more received buffers to the workers.
    pub fn has_room(&self) -> bool {
        self.jobs.len() < MAX_JOBS_IN_FLIGHT
    }

    /// Returns the packets of every job decrypted so far, in the order they were received.
    ///
    /// Handing them over together lets the event loop pass them to the TUN device in one go,
    /// which wakes its writer once rather than once per job.
    pub fn poll_next(&mut self, cx: &mut Context<'_>) -> Poll<DecryptedJobs> {
        let mut decrypted = DecryptedJobs::default();
        decrypted.0.push(ready!(self.poll_job(cx)));

        while let Poll::Ready(next) = self.poll_job(cx) {
            decrypted.0.push(next);
        }

        Poll::Ready(decrypted)
    }

    fn poll_job(&mut self, cx: &mut Context<'_>) -> Poll<DecryptedIpPackets> {
        loop {
            let Some(result) = ready!(self.jobs.poll_next_unpin(cx)) else {
                return Poll::Pending;
            };

            match result {
                Ok(decrypted) => return Poll::Ready(decrypted),
                Err(_) => tracing::debug!("Decrypt worker stopped; dropping packets"),
            }
        }
    }
}

/// The batches of one GSO send, and where to hand the encrypted datagram.
struct EncryptJob {
    train: UdpGsoTrain,
    encrypted: oneshot::Sender<DatagramOut>,
}

/// The batches of one train, and where to hand the decrypted packets.
struct DecryptJob {
    train: UdpGroTrain,
    decrypted: oneshot::Sender<DecryptedIpPackets>,
}

/// How many crypto workers to spawn: up to half of the cores.
fn num_crypto_workers() -> usize {
    let cores = thread::available_parallelism().map_or(1, NonZeroUsize::get);

    (cores / 2).max(2)
}

fn spawn_workers(num_workers: usize, packet_counter: Counter<u64>) -> Vec<mpsc::Sender<Job>> {
    (0..num_workers)
        .filter_map(|i| {
            let (tx, rx) = mpsc::channel();
            let packet_counter = packet_counter.clone();
            let name = format!("fz-crypto-{i}");

            thread::Builder::new()
                .name(name.clone())
                .spawn(move || {
                    for job in rx {
                        run(job, &packet_counter);
                    }
                })
                .inspect_err(|e| tracing::warn!(%name, "Failed to spawn crypto worker: {e}"))
                .ok()?;

            Some(tx)
        })
        .collect()
}

fn run(job: Job, packet_counter: &Counter<u64>) {
    match job {
        Job::Encrypt(job) => encrypt(job, packet_counter),
        Job::Decrypt(job) => decrypt(job),
    }
}

fn encrypt(EncryptJob { train, encrypted }: EncryptJob, packet_counter: &Counter<u64>) {
    let Some(datagram) = train.encrypt() else {
        return;
    };

    let mut transmitted = UdpPacketCounts::transmit(packet_counter);

    for segment in datagram.packet.chunks(datagram.segment_size) {
        transmitted.record(segment);
    }

    // The socket thread stopped if the receiver is gone.
    let _ = encrypted.send(datagram);
}

fn decrypt(DecryptJob { train, decrypted }: DecryptJob) {
    // We stopped if the receiver is gone; the channel for the next job is closed too.
    let _ = decrypted.send(DecryptedIpPackets(train.decrypt()));
}
