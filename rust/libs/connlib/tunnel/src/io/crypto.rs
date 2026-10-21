use std::{
    mem,
    net::SocketAddr,
    num::NonZeroUsize,
    ops::Deref,
    sync::mpsc,
    task::{Context, Poll, ready},
    thread,
};

use bufferpool::{Buffer, VecBuf};
use futures::{StreamExt as _, stream::FuturesOrdered};
use ip_packet::{Ecn, IpPacket, IpVersion};
use opentelemetry::metrics::Counter;
use snownet::{DecryptedIpPacket, PendingDecapsulate, PendingEncapsulate};
use socket_factory::{DatagramIn, DatagramOut, MAX_GSO_SEGMENTS, Segment};
use tokio::sync::oneshot;

use super::UdpGsoTrain;
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{PendingDatagrams, Sockets};

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

bufferpool::buffer_pool!(
    static ENCRYPT_PACKETS: VecBuf<(PendingEncapsulate, IpPacket)> = (MAX_GSO_SEGMENTS, "encrypt-packets"),
    batch: 4
);
bufferpool::buffer_pool!(
    static OPEN_TRAINS: VecBuf<EncryptJob> = (8, "open-trains"),
    batch: 4
);
bufferpool::buffer_pool!(
    static PENDING_DATAGRAMS: VecBuf<oneshot::Receiver<DatagramOut>> = (tun::MAX_BATCH_SIZE, "pending-datagrams"),
    batch: 4
);
bufferpool::buffer_pool!(
    static DECRYPT_BUFFERS: VecBuf<DatagramIn> = (DECRYPT_BATCH_SIZE, "decrypt-buffers"),
    batch: 4
);
bufferpool::buffer_pool!(
    static DECRYPT_MESSAGES: VecBuf<Message> = (DECRYPT_BATCH_SIZE, "decrypt-messages"),
    batch: 4
);
bufferpool::buffer_pool!(
    static DECRYPTED: VecBuf<DecryptedDatagram> = (DECRYPT_BATCH_SIZE, "decrypted"),
    batch: 4
);

/// A datagram from the network with its WireGuard data message decrypted.
pub struct DecryptedDatagram {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub ecn: Ecn,
    pub packet: DecryptedIpPacket,
}

/// Encrypts and decrypts WireGuard data messages on worker threads.
///
/// Jobs of either kind go to the next worker round-robin.
///
/// To encrypt, pass packets to [`EncryptBatch::encrypt`] in the order the state encapsulated them,
/// i.e. reserved their counters, and their datagrams go out in that order: batches borrow the
/// [`CryptoWorkers`] mutably, so they never interleave. Each job is one [`UdpGsoTrain`]. Within a
/// batch, trains close in the order of their packets and queue their receivers in that order. When the batch ends, the receivers of
/// each IP version go to its UDP socket thread as one item. A socket thread sends its items and
/// their receivers front to back, and a flow has one destination, so all of its datagrams go
/// through one socket thread.
///
/// To decrypt, received buffers go to the workers in jobs of up to [`DECRYPT_BATCH_SIZE`] data
/// messages. The results come back through a `oneshot` channel per job, which [`Decrypting`]
/// queues in submission order to accept the decrypted packets in that order.
pub struct CryptoWorkers {
    workers: Vec<mpsc::Sender<Work>>,
    next_worker: usize,
}

/// A job for a crypto worker.
///
/// Every worker takes both kinds, so traffic in one direction can use all of them.
enum Work {
    Encrypt(EncryptJob, oneshot::Sender<DatagramOut>),
    Decrypt(DecryptJob, oneshot::Sender<DecryptedIpPackets>),
}

/// Packets decrypted from the jobs of an [`Io::start_decrypt_batch`](super::Io::start_decrypt_batch).
pub struct DecryptedIpPackets(Buffer<VecBuf<DecryptedDatagram>>);

impl DecryptedIpPackets {
    /// Moves out every decrypted packet, in the order it was received.
    pub fn drain(&mut self) -> impl Iterator<Item = DecryptedDatagram> + '_ {
        self.0.drain(..)
    }
}

impl CryptoWorkers {
    pub fn new() -> Self {
        Self {
            workers: spawn_workers(num_crypto_workers(), otel_instruments::network_packets()),
            next_worker: 0,
        }
    }

    /// Starts a batch of packets to encrypt, whose datagrams go to `sockets` when it is dropped.
    pub fn start_encrypt_batch<'a>(&'a mut self, sockets: &'a mut Sockets) -> EncryptBatch<'a> {
        EncryptBatch {
            crypto: self,
            sockets,
            open: OPEN_TRAINS.pull(),
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
    ) -> DecryptBatch<'a> {
        DecryptBatch {
            crypto: self,
            decrypting,
            job: DecryptJob::new(),
        }
    }

    /// Returns the worker after the one picked last.
    fn next_worker(&mut self) -> Option<&mpsc::Sender<Work>> {
        let worker = self
            .workers
            .get(self.next_worker % self.workers.len().max(1))?;
        self.next_worker = self.next_worker.wrapping_add(1);

        Some(worker)
    }
}

/// Packets to encrypt, sent to the UDP sockets when dropped.
pub struct EncryptBatch<'a> {
    crypto: &'a mut CryptoWorkers,
    sockets: &'a mut Sockets,
    /// The open train to each destination.
    open: Buffer<VecBuf<EncryptJob>>,
    pending_v4: Option<PendingDatagrams>,
    pending_v6: Option<PendingDatagrams>,
}

impl EncryptBatch<'_> {
    /// Adds `packet` to the open train to its destination, handing that train to a worker first if
    /// `packet` starts a new one.
    pub fn encrypt(&mut self, encapsulation: PendingEncapsulate, packet: IpPacket) {
        let src = encapsulation.src();
        let dst = encapsulation.dst();

        let Some(open) = self
            .open
            .iter_mut()
            .find(|open| open.train.is_between(src, dst))
        else {
            self.open.push(EncryptJob::new(encapsulation, packet));
            return;
        };

        if open
            .train
            .try_append(src, dst, packet.ecn(), encapsulation.datagram_len(&packet))
        {
            open.packets.push((encapsulation, packet));
            return;
        }

        let closed = mem::replace(open, EncryptJob::new(encapsulation, packet));
        self.dispatch(closed);
    }

    fn dispatch(&mut self, job: EncryptJob) {
        let (tx, rx) = oneshot::channel();
        let pending = match job.train.dst() {
            SocketAddr::V4(_) => &mut self.pending_v4,
            SocketAddr::V6(_) => &mut self.pending_v6,
        };
        pending
            .get_or_insert_with(|| PENDING_DATAGRAMS.pull())
            .push(rx);

        let Some(worker) = self.crypto.next_worker() else {
            tracing::debug!("No encrypt worker running; dropping packets");
            return;
        };

        // A stopped worker drops the sender, so the socket skips the train.
        let _ = worker.send(Work::Encrypt(job, tx));
    }
}

impl Drop for EncryptBatch<'_> {
    fn drop(&mut self) {
        // Each destination has one open train, so their order does not matter.
        while let Some(open) = self.open.pop() {
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
    packets: Buffer<VecBuf<(PendingEncapsulate, IpPacket)>>,
}

impl EncryptJob {
    fn new(encapsulation: PendingEncapsulate, packet: IpPacket) -> Self {
        let train = UdpGsoTrain::new(
            encapsulation.src(),
            encapsulation.dst(),
            packet.ecn(),
            encapsulation.datagram_len(&packet),
        );
        let mut packets = ENCRYPT_PACKETS.pull();
        packets.push((encapsulation, packet));

        Self { train, packets }
    }
}

/// Received buffers to decrypt, handed to the workers when dropped.
pub struct DecryptBatch<'a> {
    crypto: &'a mut CryptoWorkers,
    decrypting: &'a mut Decrypting,
    job: DecryptJob,
}

impl<'a> DecryptBatch<'a> {
    /// Adds a received datagram, to mark which of its segments to decrypt.
    pub fn add(&mut self, datagram: DatagramIn) -> DatagramToDecrypt<'_, 'a> {
        if self.job.messages.len() + datagram.num_segments() > DECRYPT_BATCH_SIZE {
            self.submit();
        }

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

        let Some(worker) = self.crypto.next_worker() else {
            tracing::debug!("No decrypt worker running; dropping packets");
            return;
        };
        let (tx, rx) = oneshot::channel();

        // A stopped worker drops the sender, so `Decrypting::poll_next` skips the job.
        let _ = worker.send(Work::Decrypt(job, tx));
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
    buffers: Buffer<VecBuf<DatagramIn>>,
    messages: Buffer<VecBuf<Message>>,
}

struct Message {
    buffer: usize,
    segment: Segment,
    decapsulation: PendingDecapsulate,
}

impl DecryptJob {
    fn new() -> Self {
        Self {
            buffers: DECRYPT_BUFFERS.pull(),
            messages: DECRYPT_MESSAGES.pull(),
        }
    }
}

/// How many crypto workers to spawn: up to half of the cores.
fn num_crypto_workers() -> usize {
    let cores = thread::available_parallelism().map_or(1, NonZeroUsize::get);

    (cores / 2).max(2)
}

fn spawn_workers(num_workers: usize, packet_counter: Counter<u64>) -> Vec<mpsc::Sender<Work>> {
    (0..num_workers)
        .filter_map(|i| {
            let (tx, rx) = mpsc::channel();
            let packet_counter = packet_counter.clone();
            let name = format!("wg-crypto-{i}");

            thread::Builder::new()
                .name(name.clone())
                .spawn(move || {
                    for work in rx {
                        match work {
                            Work::Encrypt(train, encrypted) => {
                                encrypt(train, encrypted, &packet_counter)
                            }
                            Work::Decrypt(job, decrypted) => decrypt(job, decrypted),
                        }
                    }
                })
                .inspect_err(|e| tracing::warn!(%name, "Failed to spawn crypto worker: {e}"))
                .ok()?;

            Some(tx)
        })
        .collect()
}

fn encrypt(
    EncryptJob { train, mut packets }: EncryptJob,
    encrypted: oneshot::Sender<DatagramOut>,
    packet_counter: &Counter<u64>,
) {
    let Some(datagram) = train.encrypt(packets.drain(..)) else {
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
    let mut packets = DECRYPTED.pull();
    packets.extend(job.messages.drain(..).map(|message| {
        let buffer = &job.buffers[message.buffer];

        DecryptedDatagram {
            local: buffer.local(),
            from: buffer.from(),
            ecn: buffer.ecn(),
            packet: message.decapsulation.decrypt(&buffer[message.segment]),
        }
    }));

    // We stopped if the receiver is gone; the channel for the next job is closed too.
    let _ = decrypted.send(DecryptedIpPackets(packets));
}
