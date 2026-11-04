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
use snownet::{DecryptedIpPacket, PendingDecapsulate, PendingEncapsulate};
use socket_factory::{DatagramIn, DatagramOut, Segment};
use tokio::sync::oneshot;

use super::{UdpGroTrain, UdpGsoTrain};
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{PendingDatagrams, Sockets};
use prefetch::{IteratorExt as _, Prefetch};
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

/// A datagram from the network with its WireGuard data message decrypted.
pub struct DecryptedDatagram {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub ecn: Ecn,
    pub packet: DecryptedIpPacket,
}

impl Prefetch for DecryptedDatagram {
    fn prefetch(&self) {
        self.packet.prefetch();
    }
}

/// Encrypts and decrypts WireGuard data messages on worker threads.
///
/// Jobs of either kind go to the next worker round-robin.
/// Without any workers, jobs run on the thread that submits them.
pub struct CryptoWorkers {
    workers: Workers,
    /// The open train to each destination of the current [`EncryptJobs`], kept for its capacity.
    open_trains: Vec<UdpGsoTrain>,
}

struct Workers {
    senders: Vec<mpsc::Sender<Job>>,
    next: usize,
    packet_counter: Counter<u64>,
}

enum Job {
    Encrypt(UdpGsoTrain, oneshot::Sender<DatagramOut>),
    Decrypt(DecryptJob, oneshot::Sender<DecryptedIpPackets>),
}

/// Packets decrypted from the jobs of an [`Io::new_decrypt_jobs`](super::Io::new_decrypt_jobs).
#[derive(Default)]
pub struct DecryptedIpPackets(Vec<DecryptedDatagram>);

impl DecryptedIpPackets {
    /// Moves out every decrypted packet, in the order it was received.
    pub fn drain(&mut self) -> impl Iterator<Item = DecryptedDatagram> + '_ {
        self.0.drain(..)
    }
}

/// The decrypt jobs that were done by the time [`Decrypting::poll_next`] looked.
#[derive(Default)]
pub struct DecryptedJobs(SmallVec<[DecryptedIpPackets; MAX_JOBS_IN_FLIGHT]>);

impl DecryptedJobs {
    /// Moves out every decrypted packet, in the order it was received.
    pub fn drain(&mut self) -> impl Iterator<Item = DecryptedDatagram> + '_ {
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
            open_trains: Vec::new(),
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
            trains: &mut self.open_trains,
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
            job: DecryptJob::default(),
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
    trains: &'a mut Vec<UdpGsoTrain>,
    sockets: &'a mut Sockets,
    /// How many of the packets have yet to be encrypted, at most.
    remaining: usize,
    pending_v4: Option<PendingDatagrams>,
    pending_v6: Option<PendingDatagrams>,
}

impl EncryptJobs<'_> {
    /// Adds `packet` to the open train to its destination, handing that train to a worker first if
    /// `packet` starts a new one.
    pub fn encrypt(&mut self, encapsulation: PendingEncapsulate, packet: IpPacket) {
        let (src, dst) = (encapsulation.src(), encapsulation.dst());
        let max_packets = self.remaining;
        self.remaining = self.remaining.saturating_sub(1);

        let (ecn, len) = (packet.ecn(), encapsulation.datagram_len(&packet));
        let index = self.train_for(src, dst);

        if self.trains[index].try_reserve(ecn, len, max_packets) {
            self.trains[index].push(encapsulation, packet);
            return;
        }

        let mut next = UdpGsoTrain::new(src, dst);
        let reserved = next.try_reserve(ecn, len, max_packets);
        debug_assert!(reserved, "An empty train takes any packet");
        next.push(encapsulation, packet);

        let full = mem::replace(&mut self.trains[index], next);
        self.dispatch(full);
    }

    /// Returns the index of the open train from `src` to `dst`, opening one if there is none.
    fn train_for(&mut self, src: Option<SocketAddr>, dst: SocketAddr) -> usize {
        match self
            .trains
            .iter()
            .position(|open| open.is_between(src, dst))
        {
            Some(index) => index,
            None => {
                self.trains.push(UdpGsoTrain::new(src, dst));

                self.trains.len() - 1
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
        let max_trains = self.trains.len() + self.remaining + 1;
        pending
            .get_or_insert_with(|| Vec::with_capacity(max_trains))
            .push(rx);

        // A stopped worker drops the sender, so the socket skips the train.
        self.workers.send(Job::Encrypt(train, tx));
    }
}

impl Drop for EncryptJobs<'_> {
    fn drop(&mut self) {
        // In the order they were opened, so a flow whose destination changed mid-batch stays in order.
        self.trains.reverse();
        while let Some(open) = self.trains.pop() {
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
    job: DecryptJob,
}

impl<'a> DecryptJobs<'a> {
    /// Adds a received datagram, to mark which of its segments to decrypt.
    pub fn add(&mut self, datagram: DatagramIn) -> DatagramToDecrypt<'_, 'a> {
        if self.job.len + datagram.num_segments() > DECRYPT_BATCH_SIZE {
            self.submit();
        }

        if self.job.trains.is_empty() {
            self.job
                .trains
                .reserve(DECRYPT_BATCH_SIZE.min(self.remaining));
        }
        self.remaining = self.remaining.saturating_sub(datagram.num_segments());

        let index = self.job.trains.len();
        self.job.trains.push(UdpGroTrain::new(datagram));

        DatagramToDecrypt { jobs: self, index }
    }

    fn submit(&mut self) {
        let job = mem::take(&mut self.job);

        // A stopped worker drops the sender, so `Decrypting::poll_job` skips the job.
        let tx = self.decrypting.add_job();
        self.workers.send(Job::Decrypt(job, tx));
    }
}

impl Drop for DecryptJobs<'_> {
    fn drop(&mut self) {
        if !self.job.trains.is_empty() {
            self.submit();
        }
    }
}

/// A datagram of a [`DecryptJobs`], kept in its job only if a segment of it is to be decrypted.
pub struct DatagramToDecrypt<'b, 'a> {
    jobs: &'b mut DecryptJobs<'a>,
    index: usize,
}

impl DatagramToDecrypt<'_, '_> {
    pub fn decrypt(&mut self, segment: Segment, decapsulation: PendingDecapsulate) {
        self.jobs.job.trains[self.index].push(segment, decapsulation);
    }
}

impl Deref for DatagramToDecrypt<'_, '_> {
    type Target = DatagramIn;

    fn deref(&self) -> &DatagramIn {
        self.jobs.job.trains[self.index].datagram()
    }
}

impl Drop for DatagramToDecrypt<'_, '_> {
    fn drop(&mut self) {
        let job = &mut self.jobs.job;
        let train = &job.trains[self.index];

        if train.is_empty() {
            job.trains.pop();
        } else {
            job.len += train.len();
        }

        if job.len == DECRYPT_BATCH_SIZE {
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

/// The trains one worker decrypts, each with at least one segment.
#[derive(Default)]
struct DecryptJob {
    trains: Vec<UdpGroTrain>,
    /// How many segments the trains decrypt in total.
    len: usize,
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
        Job::Encrypt(train, encrypted) => encrypt(train, encrypted, packet_counter),
        Job::Decrypt(job, decrypted) => decrypt(job, decrypted),
    }
}

fn encrypt(
    train: UdpGsoTrain,
    encrypted: oneshot::Sender<DatagramOut>,
    packet_counter: &Counter<u64>,
) {
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

fn decrypt(mut job: DecryptJob, decrypted: oneshot::Sender<DecryptedIpPackets>) {
    let mut packets = Vec::with_capacity(job.len);
    for train in job.trains.iter_mut().prefetching_with(|train| &**train) {
        train.decrypt_into(&mut packets);
    }

    // We stopped if the receiver is gone; the channel for the next job is closed too.
    let _ = decrypted.send(DecryptedIpPackets(packets));
}
