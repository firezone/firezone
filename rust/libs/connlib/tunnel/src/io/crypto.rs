use std::{
    mem,
    net::SocketAddr,
    num::NonZeroUsize,
    ops::Deref,
    sync::mpsc,
    task::{Context, Poll, ready},
    thread,
};

use futures::{StreamExt as _, stream::FuturesOrdered};
use ip_packet::{Ecn, IpPacket, IpVersion};
use opentelemetry::metrics::Counter;
use snownet::{PendingDecapsulate, PendingEncapsulate};
use socket_factory::{DatagramIn, DatagramOut, Segment};
use tokio::sync::oneshot;

use super::{UdpGroTrain, UdpGsoTrain};
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{PendingDatagrams, Sockets};
use smallvec::SmallVec;

/// How many received packets go to a worker in one decrypt job at most.
///
/// A receive buffer holds at most this many datagrams, so every buffer fits into a single job.
const DECRYPT_BATCH_SIZE: usize = 64;

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
/// A job holds at most one receive buffer per data message.
pub(crate) const MAX_DECRYPT_BACKLOG_MEMORY: usize =
    (MAX_JOBS_IN_FLIGHT - 1) * DECRYPT_BATCH_SIZE * socket_factory::MAX_RECV_BUFFER_MEMORY;

/// A batch of WireGuard data messages from one datagram of the network, decrypted.
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

/// Packets decrypted from the jobs of an [`Io::new_decrypt_jobs`](super::Io::new_decrypt_jobs).
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

    /// Creates the jobs that encrypt `num_packets` packets, whose datagrams go to `sockets`.
    pub fn new_encrypt_jobs<'a>(
        &'a mut self,
        sockets: &'a mut Sockets,
        num_packets: usize,
    ) -> EncryptJobs<'a> {
        EncryptJobs {
            workers: &mut self.workers,
            gso_trains: &mut self.open_gso_trains,
            sockets,
            remaining: num_packets,
            pending_v4: None,
            pending_v6: None,
        }
    }

    /// Creates the jobs that decrypt received buffers, which go to the workers when dropped.
    ///
    /// The results of its jobs are queued in `decrypting`.
    pub fn new_decrypt_jobs<'a>(
        &'a mut self,
        decrypting: &'a mut Decrypting,
        num_packets: usize,
    ) -> DecryptJobs<'a> {
        DecryptJobs {
            workers: &mut self.workers,
            decrypting,
            remaining: num_packets,
            gro_trains: Vec::new(),
            len: 0,
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
    /// How many of the packets have yet to be encrypted, at most.
    remaining: usize,
    pending_v4: Option<PendingDatagrams>,
    pending_v6: Option<PendingDatagrams>,
}

impl EncryptJobs<'_> {
    /// Adds the `packets` of `encapsulation` to the train to its destination, continuing on a new
    /// train where one is full.
    pub fn add(&mut self, mut encapsulation: PendingEncapsulate, mut packets: Vec<IpPacket>) {
        let (src, dst) = (encapsulation.src(), encapsulation.dst());
        let index = self.train_for(src, dst);

        loop {
            let num_packets = packets.len();
            let rest = self.gso_trains[index].extend(encapsulation, packets);

            let num_rest = rest.as_ref().map_or(0, |(_, rest)| rest.len());
            self.remaining = self.remaining.saturating_sub(num_packets - num_rest);

            let Some(rest) = rest else {
                return;
            };
            let full = mem::replace(&mut self.gso_trains[index], UdpGsoTrain::new(src, dst));
            self.dispatch(full);

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

    fn dispatch(&mut self, train: UdpGsoTrain) {
        let (tx, rx) = oneshot::channel();
        let pending = match train.dst() {
            SocketAddr::V4(_) => &mut self.pending_v4,
            SocketAddr::V6(_) => &mut self.pending_v6,
        };
        // Every train still open and every packet still to come may need a receiver.
        let max_trains = self.gso_trains.len() + self.remaining + 1;
        pending
            .get_or_insert_with(|| Vec::with_capacity(max_trains))
            .push(rx);

        // A stopped worker drops the sender, so the socket skips the train.
        self.workers.send(Job::Encrypt(EncryptJob {
            train,
            encrypted: tx,
        }));
    }
}

impl Drop for EncryptJobs<'_> {
    fn drop(&mut self) {
        // In the order they were opened, so a flow whose destination changed mid-batch stays in order.
        self.gso_trains.reverse();
        while let Some(open) = self.gso_trains.pop() {
            self.dispatch(open);
        }

        if let Some(pending) = self.pending_v4.take() {
            self.sockets.send_pending(IpVersion::V4, pending);
        }

        if let Some(pending) = self.pending_v6.take() {
            self.sockets.send_pending(IpVersion::V6, pending);
        }
    }
}

/// Received buffers to decrypt, handed to the workers when dropped.
pub struct DecryptJobs<'a> {
    workers: &'a mut Workers,
    decrypting: &'a mut Decrypting,
    /// How many of the packets have yet to be added, at most.
    remaining: usize,
    /// The trains of the job not yet handed to a worker.
    gro_trains: Vec<UdpGroTrain>,
    /// How many segments the trains decrypt in total.
    len: usize,
}

impl<'a> DecryptJobs<'a> {
    /// Opens a train for a received datagram, to add the runs of its segments to decrypt.
    pub fn open(&mut self, datagram: DatagramIn) -> OpenGroTrain<'_, 'a> {
        if self.len + datagram.num_segments() > DECRYPT_BATCH_SIZE {
            self.submit();
        }

        if self.gro_trains.is_empty() {
            // Assumes that the datagrams to come are coalesced like this one.
            let max_trains = DECRYPT_BATCH_SIZE
                .min(self.remaining)
                .div_ceil(datagram.num_segments());
            self.gro_trains.reserve(max_trains);
        }
        self.remaining = self.remaining.saturating_sub(datagram.num_segments());

        let index = self.gro_trains.len();
        self.gro_trains.push(UdpGroTrain::new(datagram));

        OpenGroTrain { jobs: self, index }
    }

    fn submit(&mut self) {
        self.len = 0;

        // A stopped worker drops the sender, so `Decrypting::poll_job` skips the job.
        let job = DecryptJob {
            trains: mem::take(&mut self.gro_trains),
            decrypted: self.decrypting.add_job(),
        };
        self.workers.send(Job::Decrypt(job));
    }
}

impl Drop for DecryptJobs<'_> {
    fn drop(&mut self) {
        if !self.gro_trains.is_empty() {
            self.submit();
        }
    }
}

/// A [`UdpGroTrain`] of a [`DecryptJobs`], kept in its job only if a run of segments is added to it.
pub struct OpenGroTrain<'b, 'a> {
    jobs: &'b mut DecryptJobs<'a>,
    index: usize,
}

impl OpenGroTrain<'_, '_> {
    /// Adds `segments`, a run of the datagram in order, to be decrypted with `decapsulation`.
    pub fn add(&mut self, decapsulation: PendingDecapsulate, segments: Vec<Segment>) {
        self.jobs.gro_trains[self.index].push(decapsulation, segments);
    }
}

impl Deref for OpenGroTrain<'_, '_> {
    type Target = DatagramIn;

    fn deref(&self) -> &DatagramIn {
        self.jobs.gro_trains[self.index].datagram()
    }
}

impl Drop for OpenGroTrain<'_, '_> {
    fn drop(&mut self) {
        let jobs = &mut *self.jobs;
        let train = &jobs.gro_trains[self.index];

        if train.is_empty() {
            jobs.gro_trains.pop();
        } else {
            jobs.len += train.len();
        }

        if jobs.len >= DECRYPT_BATCH_SIZE {
            self.jobs.submit();
        }
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

/// The trains one worker decrypts, each with at least one batch, and where to hand the packets.
struct DecryptJob {
    trains: Vec<UdpGroTrain>,
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

fn decrypt(
    DecryptJob {
        mut trains,
        decrypted,
    }: DecryptJob,
) {
    let mut packets = Vec::with_capacity(trains.iter().map(UdpGroTrain::num_batches).sum());
    for train in &mut trains {
        train.decrypt_into(&mut packets);
    }

    // We stopped if the receiver is gone; the channel for the next job is closed too.
    let _ = decrypted.send(DecryptedIpPackets(packets));
}
