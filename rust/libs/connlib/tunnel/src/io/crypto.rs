use std::{
    collections::VecDeque,
    mem,
    net::SocketAddr,
    num::NonZeroUsize,
    pin::Pin,
    sync::mpsc,
    task::{Context, Poll, ready},
    thread,
};

use bufferpool::{Buffer, VecBuf};
use ip_packet::{Ecn, IpVersion};
use opentelemetry::metrics::Counter;
use snownet::{Decapsulation, DecryptedPacket, EncryptJob};
use socket_factory::{DatagramIn, DatagramOut, MAX_GSO_SEGMENTS, Segment};
use tokio::sync::oneshot;

use super::{Queued, UdpGsoTrain};
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::Encrypting;

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
    static ENCRYPT_JOBS: VecBuf<EncryptJob> = (MAX_GSO_SEGMENTS, "encrypt-jobs"),
    batch: 4
);
bufferpool::buffer_pool!(
    static ENCRYPTING: VecBuf<oneshot::Receiver<DatagramOut>> = (tun::MAX_BATCH_SIZE, "encrypting"),
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
    static DECRYPTED: VecBuf<Received<DecryptedPacket>> = (DECRYPT_BATCH_SIZE, "decrypted"),
    batch: 4
);

/// A packet received from the network.
pub struct Received<P> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub ecn: Ecn,
    pub packet: P,
}

/// Encrypts and decrypts WireGuard data messages on worker threads.
///
/// Jobs of either kind go to the next worker round-robin.
///
/// To encrypt, push packets in the order the state encapsulated them, i.e. reserved their
/// counters, and their datagrams go out in that order: batches borrow the [`CryptoWorkers`]
/// mutably, so they never interleave. Each job is one [`UdpGsoTrain`]. Within a batch, trains close
/// in push order and queue their receivers in that order. When the batch ends, the receivers of
/// each IP version go to its UDP socket thread as one item. A socket thread sends its items and
/// their receivers front to back, and a flow has one destination, so all of its datagrams go
/// through one socket thread.
///
/// To decrypt, received buffers go to the workers in jobs of up to [`DECRYPT_BATCH_SIZE`] data
/// messages. The results come back through a `oneshot` channel per job, which we queue in
/// submission order to accept the decrypted packets in that order.
pub struct CryptoWorkers {
    workers: Vec<mpsc::Sender<Work>>,
    next_worker: usize,

    /// The decrypt jobs handed to the workers.
    decrypting: VecDeque<oneshot::Receiver<Decrypted>>,
}

/// A job for a crypto worker.
///
/// Every worker takes both kinds, so traffic in one direction can use all of them.
enum Work {
    Encrypt(EncryptTrain, oneshot::Sender<DatagramOut>),
    Decrypt(DecryptJob, oneshot::Sender<Decrypted>),
}

type Decrypted = Buffer<VecBuf<Received<DecryptedPacket>>>;

impl CryptoWorkers {
    pub fn new(packet_counter: Counter<u64>) -> Self {
        Self {
            workers: spawn_workers(num_crypto_workers(), packet_counter),
            next_worker: 0,
            decrypting: VecDeque::new(),
        }
    }

    /// Starts a batch of packets to encrypt, whose datagrams are queued in `outbound` when it is
    /// dropped.
    pub fn encrypt_batch<'a>(&'a mut self, outbound: &'a mut VecDeque<Queued>) -> EncryptBatch<'a> {
        EncryptBatch {
            crypto: self,
            outbound,
            open: None,
            encrypting_v4: None,
            encrypting_v6: None,
        }
    }

    /// Starts a batch of received buffers to decrypt, handed to the workers when it is dropped.
    pub fn decrypt_batch(&mut self) -> DecryptBatch<'_> {
        DecryptBatch {
            crypto: self,
            job: DecryptJob::new(),
        }
    }

    /// Whether we may hand more received buffers to the workers.
    pub fn has_room_to_decrypt(&self) -> bool {
        self.decrypting.len() < MAX_JOBS_IN_FLIGHT
    }

    /// Returns the next batch of decrypted packets, in the order they were received.
    pub fn poll_decrypted(&mut self, cx: &mut Context<'_>) -> Poll<Decrypted> {
        loop {
            let Some(decrypted) = self.decrypting.front_mut() else {
                return Poll::Pending;
            };
            let result = ready!(Pin::new(decrypted).poll(cx));

            self.decrypting.pop_front();

            match result {
                Ok(decrypted) => return Poll::Ready(decrypted),
                Err(_) => tracing::debug!("Decrypt worker stopped; dropping packets"),
            }
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

/// Packets to encrypt, queued for the UDP sockets when dropped.
pub struct EncryptBatch<'a> {
    crypto: &'a mut CryptoWorkers,
    outbound: &'a mut VecDeque<Queued>,
    open: Option<EncryptTrain>,
    encrypting_v4: Option<Encrypting>,
    encrypting_v6: Option<Encrypting>,
}

impl EncryptBatch<'_> {
    /// Adds `job` to the open train, handing that train to a worker first if `job` starts a new one.
    pub fn push(&mut self, job: EncryptJob) {
        if let Some(open) = self.open.as_mut()
            && open
                .train
                .try_append(job.src(), job.dst(), job.ecn(), job.datagram_len())
        {
            open.jobs.push(job);
            return;
        }

        if let Some(closed) = self.open.replace(EncryptTrain::new(job)) {
            self.dispatch(closed);
        }
    }

    fn dispatch(&mut self, train: EncryptTrain) {
        let (tx, rx) = oneshot::channel();
        let encrypting = match train.train.dst() {
            SocketAddr::V4(_) => &mut self.encrypting_v4,
            SocketAddr::V6(_) => &mut self.encrypting_v6,
        };
        encrypting.get_or_insert_with(|| ENCRYPTING.pull()).push(rx);

        let Some(worker) = self.crypto.next_worker() else {
            tracing::debug!("No encrypt worker running; dropping packets");
            return;
        };

        // A stopped worker drops the sender, so the socket skips the train.
        let _ = worker.send(Work::Encrypt(train, tx));
    }
}

impl Extend<EncryptJob> for EncryptBatch<'_> {
    fn extend<T: IntoIterator<Item = EncryptJob>>(&mut self, jobs: T) {
        for job in jobs {
            self.push(job);
        }
    }
}

impl Drop for EncryptBatch<'_> {
    fn drop(&mut self) {
        if let Some(open) = self.open.take() {
            self.dispatch(open);
        }

        if let Some(encrypting) = self.encrypting_v4.take() {
            self.outbound
                .push_back(Queued::Encrypting(IpVersion::V4, encrypting));
        }

        if let Some(encrypting) = self.encrypting_v6.take() {
            self.outbound
                .push_back(Queued::Encrypting(IpVersion::V6, encrypting));
        }
    }
}

/// Jobs to encrypt into one [`UdpGsoTrain`].
struct EncryptTrain {
    train: UdpGsoTrain,
    jobs: Buffer<VecBuf<EncryptJob>>,
}

impl EncryptTrain {
    fn new(job: EncryptJob) -> Self {
        let train = UdpGsoTrain::new(job.src(), job.dst(), job.ecn(), job.datagram_len());
        let mut jobs = ENCRYPT_JOBS.pull();
        jobs.push(job);

        Self { train, jobs }
    }
}

/// Received buffers to decrypt, handed to the workers when dropped.
pub struct DecryptBatch<'a> {
    crypto: &'a mut CryptoWorkers,
    job: DecryptJob,
}

impl DecryptBatch<'_> {
    /// Passes each segment of `datagram` to `decapsulate` and moves the datagram into a job if any
    /// of them is a data message to decrypt.
    pub fn push(
        &mut self,
        datagram: DatagramIn,
        mut decapsulate: impl FnMut(&DatagramIn, &[u8]) -> Option<Decapsulation>,
    ) {
        if self.job.messages.len() + datagram.num_segments() > DECRYPT_BATCH_SIZE {
            self.submit();
        }

        let index = self.job.buffers.len();
        let num_messages = self.job.messages.len();

        self.job
            .messages
            .extend(datagram.segments().filter_map(|segment| {
                Some(Message {
                    buffer: index,
                    segment,
                    decapsulation: decapsulate(&datagram, &datagram[segment])?,
                })
            }));

        if self.job.messages.len() > num_messages {
            self.job.buffers.push(datagram);
        }

        if self.job.messages.len() == DECRYPT_BATCH_SIZE {
            self.submit();
        }
    }

    fn submit(&mut self) {
        let job = mem::replace(&mut self.job, DecryptJob::new());

        let Some(worker) = self.crypto.next_worker() else {
            tracing::debug!("No decrypt worker running; dropping packets");
            return;
        };
        let (tx, rx) = oneshot::channel();

        // A stopped worker drops the sender, so `poll_decrypted` skips the job.
        let _ = worker.send(Work::Decrypt(job, tx));
        self.crypto.decrypting.push_back(rx);
    }
}

impl Drop for DecryptBatch<'_> {
    fn drop(&mut self) {
        if !self.job.messages.is_empty() {
            self.submit();
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
    decapsulation: Decapsulation,
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
    EncryptTrain { train, mut jobs }: EncryptTrain,
    encrypted: oneshot::Sender<DatagramOut>,
    packet_counter: &Counter<u64>,
) {
    let Some(datagram) = train.encrypt(jobs.drain(..)) else {
        return;
    };

    let mut transmitted = UdpPacketCounts::transmit(packet_counter);

    for segment in datagram.packet.chunks(datagram.segment_size) {
        transmitted.record(segment);
    }

    // The socket thread stopped if the receiver is gone.
    let _ = encrypted.send(datagram);
}

fn decrypt(mut job: DecryptJob, decrypted: oneshot::Sender<Decrypted>) {
    let mut packets = DECRYPTED.pull();
    packets.extend(job.messages.drain(..).map(|message| {
        let buffer = &job.buffers[message.buffer];

        Received {
            local: buffer.local(),
            from: buffer.from(),
            ecn: buffer.ecn(),
            packet: message.decapsulation.decrypt(&buffer[message.segment]),
        }
    }));

    // We stopped if the receiver is gone; the channel for the next job is closed too.
    let _ = decrypted.send(packets);
}
