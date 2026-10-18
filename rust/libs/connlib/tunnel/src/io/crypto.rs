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

use anyhow::Result;
use bufferpool::{Buffer, VecBuf};
use ip_packet::{Ecn, IpVersion};
use opentelemetry::metrics::Counter;
use snownet::{DecryptJob, DecryptedPacket, EncryptJob};
use socket_factory::{DatagramOut, MAX_GSO_SEGMENTS};
use tokio::sync::oneshot;

use super::UdpGsoTrain;
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::Sockets;

/// How many encrypt and decrypt workers to spawn.
///
/// Crypto takes up to half of the cores, split evenly between both directions.
fn num_workers() -> (usize, usize) {
    let cores = thread::available_parallelism().map_or(1, NonZeroUsize::get);
    let total = (cores / 2).max(2);
    let encrypt = total / 2;

    (encrypt, total - encrypt)
}

/// How many received packets go to a decrypt worker in one batch at most.
const DECRYPT_BATCH_SIZE: usize = 64;

/// How many received packets may await decryption before we stop reading from the network.
///
/// Each holds a copy of its datagram, so this bounds their memory like the UDP socket's queue
/// bounds that of the received batches.
const MAX_DECRYPTS_IN_FLIGHT: usize = 4 * DECRYPT_BATCH_SIZE;

bufferpool::buffer_pool!(
    static ENCRYPT_JOBS: VecBuf<EncryptJob> = (MAX_GSO_SEGMENTS, "encrypt-jobs"),
    batch: 4
);
bufferpool::buffer_pool!(
    static DECRYPT_JOBS: VecBuf<Received<DecryptJob>> = (DECRYPT_BATCH_SIZE, "decrypt-jobs"),
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

/// Encrypts and decrypts WireGuard data messages on two pools of worker threads.
///
/// Packets go to the workers of each pool in batches, round-robin. The results come back
/// through a `oneshot` channel per batch, which we queue in submission order: the UDP socket
/// threads send the encrypted batches in that order and we accept the decrypted ones in that order.
///
/// An encrypt batch is one [`UdpGsoTrain`]. It goes to a worker as soon as the next packet would
/// start a new train, or when we flush.
pub struct CryptoWorkers {
    encrypt: Vec<mpsc::Sender<(EncryptBatch, oneshot::Sender<DatagramOut>)>>,
    decrypt: Vec<mpsc::Sender<DecryptBatch>>,
    next_encrypt: usize,
    next_decrypt: usize,

    open_encrypt: Option<EncryptBatch>,
    /// Batches that found their UDP socket's queue full, sent by [`CryptoWorkers::poll_flush`].
    unsent_encrypts: VecDeque<EncryptBatch>,
    staged_decrypts: Buffer<VecBuf<Received<DecryptJob>>>,

    /// The batches handed to the decrypt workers, with how many packets each holds.
    decrypting: VecDeque<(
        usize,
        oneshot::Receiver<Buffer<VecBuf<Received<DecryptedPacket>>>>,
    )>,
    decrypts_in_flight: usize,
}

struct EncryptBatch {
    train: UdpGsoTrain,
    jobs: Buffer<VecBuf<EncryptJob>>,
}

struct DecryptBatch {
    jobs: Buffer<VecBuf<Received<DecryptJob>>>,
    decrypted: oneshot::Sender<Buffer<VecBuf<Received<DecryptedPacket>>>>,
}

impl CryptoWorkers {
    pub fn new(packet_counter: Counter<u64>) -> Self {
        let (num_encrypt, num_decrypt) = num_workers();

        let encrypt = (0..num_encrypt)
            .filter_map(|i| {
                let (tx, rx) = mpsc::channel();
                let packet_counter = packet_counter.clone();

                spawn(format!("wg-encrypt-{i}"), move || {
                    encrypt(rx, packet_counter)
                })?;

                Some(tx)
            })
            .collect();
        let decrypt = (0..num_decrypt)
            .filter_map(|i| {
                let (tx, rx) = mpsc::channel();

                spawn(format!("wg-decrypt-{i}"), move || decrypt(rx))?;

                Some(tx)
            })
            .collect();

        Self {
            encrypt,
            decrypt,
            next_encrypt: 0,
            next_decrypt: 0,
            open_encrypt: None,
            unsent_encrypts: VecDeque::new(),
            staged_decrypts: DECRYPT_JOBS.pull(),
            decrypting: VecDeque::new(),
            decrypts_in_flight: 0,
        }
    }

    /// Adds `job` to the open batch, sending that batch to a worker first if `job` starts a new train.
    pub fn submit_encrypt(&mut self, job: EncryptJob, sockets: &mut Sockets) {
        let (src, dst, ecn, len) = (job.src(), job.dst(), job.ecn(), job.datagram_len());

        if let Some(open) = self.open_encrypt.as_mut()
            && open.train.try_append(src, dst, ecn, len)
        {
            open.jobs.push(job);
            return;
        }

        let mut jobs = ENCRYPT_JOBS.pull();
        jobs.push(job);
        let next = EncryptBatch {
            train: UdpGsoTrain::new(src, dst, ecn, len),
            jobs,
        };

        let Some(batch) = self.open_encrypt.replace(next) else {
            return;
        };

        if self.unsent_encrypts.is_empty() {
            let (tx, rx) = oneshot::channel();

            if sockets.try_send_encrypting(batch.version(), rx) {
                self.dispatch_encrypt(batch, tx);
                return;
            }
        }

        self.unsent_encrypts.push_back(batch);
    }

    /// Stages `job` for decryption.
    pub fn submit_decrypt(&mut self, job: Received<DecryptJob>) {
        self.staged_decrypts.push(job);

        if self.staged_decrypts.len() >= DECRYPT_BATCH_SIZE {
            self.flush_decrypts();
        }
    }

    /// Whether we may hand more received packets to the decrypt workers.
    pub fn can_decrypt(&self) -> bool {
        self.decrypts_in_flight < MAX_DECRYPTS_IN_FLIGHT
    }

    /// Returns the next batch of decrypted packets, in the order they were received.
    pub fn poll_decrypted(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Buffer<VecBuf<Received<DecryptedPacket>>>> {
        loop {
            let Some((len, decrypted)) = self.decrypting.front_mut() else {
                return Poll::Pending;
            };
            let len = *len;
            let result = ready!(Pin::new(decrypted).poll(cx));

            self.decrypting.pop_front();
            self.decrypts_in_flight -= len;

            match result {
                Ok(decrypted) => return Poll::Ready(decrypted),
                Err(_) => {
                    tracing::debug!(
                        num_packets = len,
                        "Decrypt worker stopped; dropping packets"
                    );
                }
            }
        }
    }

    /// Hands all staged packets to the workers and queues the encrypted batches on `sockets`.
    ///
    /// Pending while a UDP socket has no room for another batch.
    pub fn poll_flush(&mut self, sockets: &mut Sockets, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.flush_decrypts();
        self.unsent_encrypts.extend(self.open_encrypt.take());

        while let Some(batch) = self.unsent_encrypts.front() {
            let version = batch.version();

            if let Err(e) = ready!(sockets.poll_send_ready_for(version, cx)) {
                self.unsent_encrypts.clear();
                return Poll::Ready(Err(e));
            }

            let Some(batch) = self.unsent_encrypts.pop_front() else {
                break;
            };
            let (tx, rx) = oneshot::channel();
            sockets.send_encrypting(version, rx)?;

            self.dispatch_encrypt(batch, tx);
        }

        Poll::Ready(Ok(()))
    }

    /// Drops all staged packets.
    pub fn clear(&mut self) {
        self.open_encrypt = None;
        self.unsent_encrypts.clear();
        self.staged_decrypts.clear();
    }

    fn dispatch_encrypt(&mut self, batch: EncryptBatch, encrypted: oneshot::Sender<DatagramOut>) {
        let Some(worker) = next(&self.encrypt, &mut self.next_encrypt) else {
            tracing::debug!("No encrypt worker running; dropping packets");
            return;
        };

        // A stopped worker drops the sender, so the socket skips the batch.
        let _ = worker.send((batch, encrypted));
    }

    fn flush_decrypts(&mut self) {
        if self.staged_decrypts.is_empty() {
            return;
        }

        let jobs = mem::replace(&mut self.staged_decrypts, DECRYPT_JOBS.pull());
        let len = jobs.len();
        let Some(worker) = next(&self.decrypt, &mut self.next_decrypt) else {
            tracing::debug!("No decrypt worker running; dropping packets");
            return;
        };
        let (tx, rx) = oneshot::channel();

        // A stopped worker drops the sender, so `poll_decrypted` skips the batch.
        let _ = worker.send(DecryptBatch {
            jobs,
            decrypted: tx,
        });
        self.decrypting.push_back((len, rx));
        self.decrypts_in_flight += len;
    }
}

impl EncryptBatch {
    fn version(&self) -> IpVersion {
        match self.train.dst() {
            SocketAddr::V4(_) => IpVersion::V4,
            SocketAddr::V6(_) => IpVersion::V6,
        }
    }
}

/// Returns the worker after the one picked last.
fn next<'a, T>(workers: &'a [T], next: &mut usize) -> Option<&'a T> {
    let worker = workers.get(*next % workers.len().max(1))?;
    *next = next.wrapping_add(1);

    Some(worker)
}

fn spawn(name: String, work: impl FnOnce() + Send + 'static) -> Option<()> {
    thread::Builder::new()
        .name(name.clone())
        .spawn(work)
        .inspect_err(|e| tracing::warn!(%name, "Failed to spawn crypto worker: {e}"))
        .ok()?;

    Some(())
}

fn encrypt(
    batches: mpsc::Receiver<(EncryptBatch, oneshot::Sender<DatagramOut>)>,
    packet_counter: Counter<u64>,
) {
    for (EncryptBatch { train, mut jobs }, encrypted) in batches {
        let Some(datagram) = train.encrypt(jobs.drain(..)) else {
            continue;
        };

        let mut transmitted = UdpPacketCounts::transmit(&packet_counter);

        for segment in datagram.packet.chunks(datagram.segment_size) {
            transmitted.record(segment);
        }

        // The socket thread stopped if the receiver is gone.
        let _ = encrypted.send(datagram);
    }
}

fn decrypt(batches: mpsc::Receiver<DecryptBatch>) {
    for DecryptBatch {
        mut jobs,
        decrypted,
    } in batches
    {
        let mut packets = DECRYPTED.pull();
        packets.extend(jobs.drain(..).map(|job| Received {
            local: job.local,
            from: job.from,
            ecn: job.ecn,
            packet: job.packet.decrypt(),
        }));

        // We stopped if the receiver is gone; the channel for the next batch is closed too.
        let _ = decrypted.send(packets);
    }
}
