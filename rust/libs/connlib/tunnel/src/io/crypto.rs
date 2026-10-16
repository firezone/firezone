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
use snownet::{DecryptJob, DecryptedPacket, EncryptJob, Encryptor};
use tokio::sync::oneshot;

use super::UdpGsoQueue;
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{Encrypted, Sockets};

/// How many encrypt and decrypt workers to spawn.
///
/// Crypto takes up to half of the cores, split evenly between both directions.
fn num_workers() -> (usize, usize) {
    let cores = thread::available_parallelism().map_or(1, NonZeroUsize::get);
    let total = (cores / 2).max(2);
    let encrypt = total / 2;

    (encrypt, total - encrypt)
}

/// How many packets go to an encrypt worker in one batch at most.
///
/// Small enough for a batch to one connection to fit into a single GSO send.
const ENCRYPT_BATCH_SIZE: usize = 32;

/// How many received packets go to a decrypt worker in one batch at most.
const DECRYPT_BATCH_SIZE: usize = 64;

/// How many received packets may await decryption before we stop reading from the network.
///
/// Each holds a copy of its datagram, so this bounds their memory like the UDP socket's queue
/// bounds that of the received batches.
const MAX_DECRYPTS_IN_FLIGHT: usize = 4 * DECRYPT_BATCH_SIZE;

bufferpool::buffer_pool!(
    static ENCRYPT_JOBS: VecBuf<EncryptJob> = (ENCRYPT_BATCH_SIZE, "encrypt-jobs"),
    batch: 4
);
bufferpool::buffer_pool!(
    static ENCRYPTED: VecBuf<socket_factory::DatagramOut> = (4, "encrypted"),
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
pub struct CryptoWorkers {
    encrypt: Vec<mpsc::Sender<EncryptBatch>>,
    decrypt: Vec<mpsc::Sender<DecryptBatch>>,
    next_encrypt: usize,
    next_decrypt: usize,

    staged_encrypts: VecDeque<Buffer<VecBuf<EncryptJob>>>,
    staged_decrypts: Buffer<VecBuf<Received<DecryptJob>>>,

    /// The batches handed to the decrypt workers, with how many packets each holds.
    decrypting: VecDeque<(
        usize,
        oneshot::Receiver<Buffer<VecBuf<Received<DecryptedPacket>>>>,
    )>,
    decrypts_in_flight: usize,
}

struct EncryptBatch {
    jobs: Buffer<VecBuf<EncryptJob>>,
    v4: Option<oneshot::Sender<Encrypted>>,
    v6: Option<oneshot::Sender<Encrypted>>,
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
            staged_encrypts: VecDeque::new(),
            staged_decrypts: DECRYPT_JOBS.pull(),
            decrypting: VecDeque::new(),
            decrypts_in_flight: 0,
        }
    }

    /// Stages `job` for decryption.
    pub fn decrypt(&mut self, job: Received<DecryptJob>) {
        self.staged_decrypts.push(job);

        if self.staged_decrypts.len() >= DECRYPT_BATCH_SIZE {
            self.submit_decrypts();
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
        self.submit_decrypts();

        while let Some(jobs) = self.staged_encrypts.front() {
            let v4 = jobs.iter().any(|job| job.dst().is_ipv4());
            let v6 = jobs.iter().any(|job| job.dst().is_ipv6());

            if let Err(e) = ready!(poll_send_ready(sockets, v4, v6, cx)) {
                self.staged_encrypts.clear();
                return Poll::Ready(Err(e));
            }

            let Some(jobs) = self.staged_encrypts.pop_front() else {
                break;
            };
            let batch = EncryptBatch {
                jobs,
                v4: v4
                    .then(|| send_encrypting(sockets, IpVersion::V4))
                    .transpose()?,
                v6: v6
                    .then(|| send_encrypting(sockets, IpVersion::V6))
                    .transpose()?,
            };
            let Some(worker) = next(&self.encrypt, &mut self.next_encrypt) else {
                tracing::debug!("No encrypt worker running; dropping packets");
                continue;
            };

            // A stopped worker drops the senders, so the socket skips the batch.
            let _ = worker.send(batch);
        }

        Poll::Ready(Ok(()))
    }

    /// Drops all staged packets.
    pub fn clear(&mut self) {
        self.staged_encrypts.clear();
        self.staged_decrypts.clear();
    }

    fn submit_decrypts(&mut self) {
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

impl Encryptor for CryptoWorkers {
    fn encrypt(&mut self, job: EncryptJob) {
        match self.staged_encrypts.back_mut() {
            Some(jobs) if jobs.len() < ENCRYPT_BATCH_SIZE => jobs.push(job),
            Some(_) | None => {
                let mut jobs = ENCRYPT_JOBS.pull();
                jobs.push(job);
                self.staged_encrypts.push_back(jobs);
            }
        }
    }
}

fn poll_send_ready(
    sockets: &mut Sockets,
    v4: bool,
    v6: bool,
    cx: &mut Context<'_>,
) -> Poll<Result<()>> {
    if v4 {
        ready!(sockets.poll_send_ready_for(IpVersion::V4, cx))?;
    }

    if v6 {
        ready!(sockets.poll_send_ready_for(IpVersion::V6, cx))?;
    }

    Poll::Ready(Ok(()))
}

fn send_encrypting(
    sockets: &mut Sockets,
    version: IpVersion,
) -> Result<oneshot::Sender<Encrypted>> {
    let (tx, rx) = oneshot::channel();
    sockets.send_encrypting(version, rx)?;

    Ok(tx)
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

fn encrypt(batches: mpsc::Receiver<EncryptBatch>, packet_counter: Counter<u64>) {
    let mut gso_queue = UdpGsoQueue::new();

    for EncryptBatch { mut jobs, v4, v6 } in batches {
        for job in jobs.drain(..) {
            gso_queue.encrypt(job);
        }

        let mut encrypted_v4 = ENCRYPTED.pull();
        let mut encrypted_v6 = ENCRYPTED.pull();
        let mut transmitted = UdpPacketCounts::transmit(&packet_counter);

        for datagram in gso_queue.datagrams() {
            for segment in datagram.packet.chunks(datagram.segment_size) {
                transmitted.record(segment);
            }

            match datagram.dst {
                SocketAddr::V4(_) => encrypted_v4.push(datagram),
                SocketAddr::V6(_) => encrypted_v6.push(datagram),
            }
        }

        // The socket thread stopped if the receiver is gone.
        if let Some(v4) = v4 {
            let _ = v4.send(encrypted_v4);
        }
        if let Some(v6) = v6 {
            let _ = v6.send(encrypted_v6);
        }
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
