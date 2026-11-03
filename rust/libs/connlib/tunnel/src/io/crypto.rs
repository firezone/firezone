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

use super::UdpGsoTrain;
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{PendingDatagrams, Sockets};
use prefetch::IteratorExt as _;
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
    workers: Vec<mpsc::Sender<Job>>,
    next_worker: usize,
    packet_counter: Counter<u64>,
    /// The open train to each destination of the current [`EncryptJobs`], kept for its capacity.
    open_trains: Vec<EncryptJob>,
}

enum Job {
    Encrypt(EncryptJob, oneshot::Sender<DatagramOut>),
    Decrypt(DecryptJob, oneshot::Sender<DecryptedIpPackets>),
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
            workers: spawn_workers(num_workers, packet_counter.clone()),
            next_worker: 0,
            packet_counter,
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
            crypto: self,
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
            crypto: self,
            decrypting,
            remaining: num_packets,
            job: DecryptJob::new(),
        }
    }

    /// Sends `job` to the worker after the one picked last, removing the workers that stopped.
    ///
    /// Without any workers left, `job` runs inline.
    fn send(&mut self, mut job: Job) {
        while !self.workers.is_empty() {
            let index = self.next_worker % self.workers.len();
            self.next_worker = self.next_worker.wrapping_add(1);

            match self.workers[index].send(job) {
                Ok(()) => return,
                Err(mpsc::SendError(unsent)) => {
                    tracing::debug!("Crypto worker stopped");

                    self.workers.remove(index);
                    job = unsent;
                }
            }
        }

        run(job, &self.packet_counter);
    }
}

/// Packets to encrypt, sent to the UDP sockets when dropped.
pub struct EncryptJobs<'a> {
    crypto: &'a mut CryptoWorkers,
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

        loop {
            let first = &packets[0];
            let index = self.train_for(src, dst, first.ecn(), encapsulation.datagram_len(first));
            let job = &mut self.crypto.open_trains[index];

            let full_at = packets[1..]
                .iter()
                .position(|p| {
                    !job.train
                        .try_append(src, dst, p.ecn(), encapsulation.datagram_len(p))
                })
                .and_then(|i| NonZeroUsize::new(i + 1));
            let rest = full_at.map(|at| {
                let encapsulation = encapsulation
                    .split_off(at)
                    .expect("one counter is reserved per packet");

                (encapsulation, packets.split_off(at.get()))
            });

            self.remaining = self.remaining.saturating_sub(packets.len());
            job.batches.push((encapsulation, packets));

            let Some(rest) = rest else {
                return;
            };
            (encapsulation, packets) = rest;
        }
    }

    /// Returns the index of the open train to `dst`, after appending a datagram of `len` bytes.
    ///
    /// Joins the train already open to `dst` if the datagram fits it, handing that train to a
    /// worker otherwise.
    fn train_for(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        ecn: Ecn,
        len: usize,
    ) -> usize {
        let open_trains = &mut self.crypto.open_trains;

        match open_trains
            .iter()
            .position(|open| open.train.is_between(src, dst))
        {
            Some(index) if open_trains[index].train.try_append(src, dst, ecn, len) => index,
            Some(index) => {
                let new = EncryptJob::new(UdpGsoTrain::new(src, dst, ecn, len));
                let closed = mem::replace(&mut open_trains[index], new);
                self.dispatch(closed);

                index
            }
            None => {
                open_trains.push(EncryptJob::new(UdpGsoTrain::new(src, dst, ecn, len)));

                open_trains.len() - 1
            }
        }
    }

    fn dispatch(&mut self, job: EncryptJob) {
        let (tx, rx) = oneshot::channel();
        let pending = match job.train.dst() {
            SocketAddr::V4(_) => &mut self.pending_v4,
            SocketAddr::V6(_) => &mut self.pending_v6,
        };
        // Every train still open and every packet still to come may need a receiver.
        let max_trains = self.crypto.open_trains.len() + self.remaining + 1;
        pending
            .get_or_insert_with(|| Vec::with_capacity(max_trains))
            .push(rx);

        // A stopped worker drops the sender, so the socket skips the train.
        self.crypto.send(Job::Encrypt(job, tx));
    }
}

impl Drop for EncryptJobs<'_> {
    fn drop(&mut self) {
        // In the order they were opened, so a flow whose destination changed mid-batch stays in order.
        self.crypto.open_trains.reverse();
        while let Some(open) = self.crypto.open_trains.pop() {
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

/// Batches of packets to encrypt into one [`UdpGsoTrain`].
struct EncryptJob {
    train: UdpGsoTrain,
    batches: Vec<(PendingEncapsulate, Vec<IpPacket>)>,
}

impl EncryptJob {
    fn new(train: UdpGsoTrain) -> Self {
        Self {
            train,
            batches: Vec::new(),
        }
    }
}

/// Received buffers to decrypt, handed to the workers when dropped.
pub struct DecryptJobs<'a> {
    crypto: &'a mut CryptoWorkers,
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

        if self.job.buffers.is_empty() {
            let max_messages = DECRYPT_BATCH_SIZE.min(self.remaining);
            self.job.buffers.reserve(max_messages);
            self.job.messages.reserve(max_messages);
        }
        self.remaining = self.remaining.saturating_sub(datagram.num_segments());

        let index = self.job.buffers.len();
        let num_messages = self.job.messages.len();
        self.job.buffers.push(datagram);

        DatagramToDecrypt {
            jobs: self,
            index,
            num_messages,
        }
    }

    fn submit(&mut self) {
        let job = mem::replace(&mut self.job, DecryptJob::new());

        // A stopped worker drops the sender, so `Decrypting::poll_job` skips the job.
        let tx = self.decrypting.add_job();
        self.crypto.send(Job::Decrypt(job, tx));
    }
}

impl Drop for DecryptJobs<'_> {
    fn drop(&mut self) {
        if !self.job.messages.is_empty() {
            self.submit();
        }
    }
}

/// A datagram of a [`DecryptJobs`], kept in its job only if a segment of it is to be decrypted.
pub struct DatagramToDecrypt<'b, 'a> {
    jobs: &'b mut DecryptJobs<'a>,
    index: usize,
    num_messages: usize,
}

impl DatagramToDecrypt<'_, '_> {
    /// Marks `segments`, those of `decapsulation` in order, for decryption.
    pub fn decrypt(&mut self, segments: Vec<Segment>, decapsulation: PendingDecapsulate) {
        self.jobs.job.len += segments.len();
        self.jobs.job.messages.push(Message {
            buffer: self.index,
            segments,
            decapsulation,
        });
    }
}

impl Deref for DatagramToDecrypt<'_, '_> {
    type Target = DatagramIn;

    fn deref(&self) -> &DatagramIn {
        &self.jobs.job.buffers[self.index]
    }
}

impl Drop for DatagramToDecrypt<'_, '_> {
    fn drop(&mut self) {
        let job = &mut self.jobs.job;

        if job.messages.len() == self.num_messages {
            job.buffers.pop();
        }

        if job.len >= DECRYPT_BATCH_SIZE {
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

/// Receive buffers and the data messages within them to decrypt.
///
/// Each buffer holds at least one of the messages.
struct DecryptJob {
    buffers: Vec<DatagramIn>,
    messages: Vec<Message>,
    /// How many segments the messages hold in total.
    len: usize,
}

/// The data messages of one [`PendingDecapsulate`]: segments of one buffer.
struct Message {
    buffer: usize,
    segments: Vec<Segment>,
    decapsulation: PendingDecapsulate,
}

impl DecryptJob {
    fn new() -> Self {
        Self {
            buffers: Vec::new(),
            messages: Vec::new(),
            len: 0,
        }
    }
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
            let name = format!("wg-crypto-{i}");

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
    EncryptJob { train, mut batches }: EncryptJob,
    encrypted: oneshot::Sender<DatagramOut>,
    packet_counter: &Counter<u64>,
) {
    let Some(datagram) = train.encrypt(batches.drain(..)) else {
        return;
    };

    let mut transmitted = UdpPacketCounts::transmit(packet_counter);

    for segment in datagram.packet.chunks(datagram.segment_size) {
        transmitted.record(segment);
    }

    // The socket thread stopped if the receiver is gone.
    let _ = encrypted.send(datagram);
}

fn decrypt(job: DecryptJob, decrypted: oneshot::Sender<DecryptedIpPackets>) {
    let DecryptJob {
        buffers,
        messages,
        len: _,
    } = job;

    let packets = messages
        .into_iter()
        .map(|message| (&buffers[message.buffer], message))
        .prefetching_with(|(buffer, message)| match message.segments.first() {
            Some(segment) => &buffer[*segment],
            None => &[],
        })
        .map(|(buffer, message)| DecryptedBatch {
            local: buffer.local(),
            from: buffer.from(),
            ecn: buffer.ecn(),
            packets: message
                .decapsulation
                .decrypt(message.segments.iter().map(|segment| &buffer[*segment])),
        })
        .collect();

    // We stopped if the receiver is gone; the channel for the next job is closed too.
    let _ = decrypted.send(DecryptedIpPackets(packets));
}
