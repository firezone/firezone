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

use super::UdpGsoTrain;
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{PendingDatagrams, Sockets};
use prefetch::{IteratorExt as _, Prefetch};

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
    workers: Vec<mpsc::Sender<Job>>,
    next_worker: usize,
    packet_counter: Counter<u64>,
    /// The open train to each destination of the current [`EncryptBatch`], kept for its capacity.
    open_trains: Vec<EncryptJob>,
}

enum Job {
    Encrypt(EncryptJob, oneshot::Sender<DatagramOut>),
    Decrypt(DecryptJob, oneshot::Sender<DecryptedIpPackets>),
}

/// Packets decrypted from the jobs of an [`Io::start_decrypt_batch`](super::Io::start_decrypt_batch).
pub struct DecryptedIpPackets(Vec<DecryptedDatagram>);

impl DecryptedIpPackets {
    /// Moves out every decrypted packet, in the order it was received.
    pub fn drain(&mut self) -> impl Iterator<Item = DecryptedDatagram> + '_ {
        self.0.drain(..)
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

    /// Starts a batch of packets to encrypt, whose datagrams go to `sockets` when it is dropped.
    pub fn start_encrypt_batch<'a>(
        &'a mut self,
        sockets: &'a mut Sockets,
        num_packets: usize,
    ) -> EncryptBatch<'a> {
        EncryptBatch {
            crypto: self,
            sockets,
            remaining: num_packets,
            pending_v4: None,
            pending_v6: None,
        }
    }

    /// Starts a batch of received buffers to decrypt, handed to the workers when it is dropped.
    ///
    /// The results of its jobs are queued in `decrypting`.
    pub fn start_decrypt_batch<'a>(
        &'a mut self,
        decrypting: &'a mut Decrypting,
        num_packets: usize,
    ) -> DecryptBatch<'a> {
        DecryptBatch {
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
pub struct EncryptBatch<'a> {
    crypto: &'a mut CryptoWorkers,
    sockets: &'a mut Sockets,
    /// How many of the batch's packets have yet to be encrypted, at most.
    remaining: usize,
    pending_v4: Option<PendingDatagrams>,
    pending_v6: Option<PendingDatagrams>,
}

impl EncryptBatch<'_> {
    /// Adds `packet` to the open train to its destination, handing that train to a worker first if
    /// `packet` starts a new one.
    pub fn encrypt(&mut self, encapsulation: PendingEncapsulate, packet: IpPacket) {
        let src = encapsulation.src();
        let dst = encapsulation.dst();
        let remaining = self.remaining;
        self.remaining = remaining.saturating_sub(1);

        let Some(open) = self
            .crypto
            .open_trains
            .iter_mut()
            .find(|open| open.train.is_between(src, dst))
        else {
            self.crypto
                .open_trains
                .push(EncryptJob::new(encapsulation, packet, remaining));
            return;
        };

        if open
            .train
            .try_append(src, dst, packet.ecn(), encapsulation.datagram_len(&packet))
        {
            open.packets.push((encapsulation, packet));
            return;
        }

        let closed = mem::replace(open, EncryptJob::new(encapsulation, packet, remaining));
        self.dispatch(closed);
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

impl Drop for EncryptBatch<'_> {
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

/// Packets to encrypt into one [`UdpGsoTrain`].
struct EncryptJob {
    train: UdpGsoTrain,
    packets: Vec<(PendingEncapsulate, IpPacket)>,
}

impl EncryptJob {
    /// Starts a train with `packet`, sized for at most `max_packets`.
    fn new(encapsulation: PendingEncapsulate, packet: IpPacket, max_packets: usize) -> Self {
        let train = UdpGsoTrain::new(
            encapsulation.src(),
            encapsulation.dst(),
            packet.ecn(),
            encapsulation.datagram_len(&packet),
        );
        let mut packets = Vec::with_capacity(train.max_segments().min(max_packets));
        packets.push((encapsulation, packet));

        Self { train, packets }
    }
}

/// Received buffers to decrypt, handed to the workers when dropped.
pub struct DecryptBatch<'a> {
    crypto: &'a mut CryptoWorkers,
    decrypting: &'a mut Decrypting,
    /// How many of the batch's packets have yet to be added, at most.
    remaining: usize,
    job: DecryptJob,
}

impl<'a> DecryptBatch<'a> {
    /// Adds a received datagram, to mark which of its segments to decrypt.
    pub fn add(&mut self, datagram: DatagramIn) -> DatagramToDecrypt<'_, 'a> {
        if self.job.messages.len() + datagram.num_segments() > DECRYPT_BATCH_SIZE {
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
            batch: self,
            index,
            num_messages,
        }
    }

    fn submit(&mut self) {
        let job = mem::replace(&mut self.job, DecryptJob::new());

        let (tx, rx) = oneshot::channel();

        // A stopped worker drops the sender, so `Decrypting::poll_next` skips the job.
        self.crypto.send(Job::Decrypt(job, tx));
        self.decrypting.jobs.push_back(rx);
    }
}

impl Drop for DecryptBatch<'_> {
    fn drop(&mut self) {
        if !self.job.messages.is_empty() {
            self.submit();
        }
    }
}

/// A datagram of a [`DecryptBatch`], kept in its job only if a segment of it is to be decrypted.
pub struct DatagramToDecrypt<'b, 'a> {
    batch: &'b mut DecryptBatch<'a>,
    index: usize,
    num_messages: usize,
}

impl DatagramToDecrypt<'_, '_> {
    pub fn decrypt(&mut self, segment: Segment, decapsulation: PendingDecapsulate) {
        self.batch.job.messages.push(Message {
            buffer: self.index,
            segment,
            decapsulation,
        });
    }
}

impl Deref for DatagramToDecrypt<'_, '_> {
    type Target = DatagramIn;

    fn deref(&self) -> &DatagramIn {
        &self.batch.job.buffers[self.index]
    }
}

impl Drop for DatagramToDecrypt<'_, '_> {
    fn drop(&mut self) {
        let job = &mut self.batch.job;

        if job.messages.len() == self.num_messages {
            job.buffers.pop();
        }

        if job.messages.len() == DECRYPT_BATCH_SIZE {
            self.batch.submit();
        }
    }
}

/// The decrypt jobs handed to the workers, in submission order.
#[derive(Default)]
pub struct Decrypting {
    jobs: FuturesOrdered<oneshot::Receiver<DecryptedIpPackets>>,
}

impl Decrypting {
    /// Whether we may hand more received buffers to the workers.
    pub fn has_room(&self) -> bool {
        self.jobs.len() < MAX_JOBS_IN_FLIGHT
    }

    /// Returns the next batch of decrypted packets, in the order they were received.
    pub fn poll_next(&mut self, cx: &mut Context<'_>) -> Poll<DecryptedIpPackets> {
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
}

struct Message {
    buffer: usize,
    segment: Segment,
    decapsulation: PendingDecapsulate,
}

impl DecryptJob {
    fn new() -> Self {
        Self {
            buffers: Vec::new(),
            messages: Vec::new(),
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
    EncryptJob { train, mut packets }: EncryptJob,
    encrypted: oneshot::Sender<DatagramOut>,
    packet_counter: &Counter<u64>,
) {
    let Some(datagram) = train.encrypt(packets.drain(..).prefetching_with(|(_, packet)| packet))
    else {
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
    let DecryptJob { buffers, messages } = job;

    let packets = messages
        .into_iter()
        .map(|message| {
            let buffer = &buffers[message.buffer];

            (message.decapsulation, buffer, &buffer[message.segment])
        })
        .prefetching_with(|(_, _, ciphertext)| *ciphertext)
        .map(|(decapsulation, buffer, ciphertext)| DecryptedDatagram {
            local: buffer.local(),
            from: buffer.from(),
            ecn: buffer.ecn(),
            packet: decapsulation.decrypt(ciphertext),
        })
        .collect();

    // We stopped if the receiver is gone; the channel for the next job is closed too.
    let _ = decrypted.send(DecryptedIpPackets(packets));
}
