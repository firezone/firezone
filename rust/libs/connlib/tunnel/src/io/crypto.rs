use std::{
    hash::BuildHasher as _,
    mem,
    net::SocketAddr,
    num::NonZeroUsize,
    task::{Context, Poll, ready},
    thread,
};

use bufferpool::{Buffer, VecBuf};
use fast_random_state::FastRandomState;
use ip_packet::{Ecn, IpPacket};
use opentelemetry::metrics::Counter;
use snownet::{DecryptJob, DecryptedPacket, EncryptJob, Encryptor};
use tokio::sync::mpsc;
use tokio_util::sync::PollSender;

use super::UdpGsoQueue;
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{Sockets, UdpSenders};

/// How many encrypt and decrypt workers to spawn.
///
/// Crypto takes up to half of the cores, split evenly between both directions.
fn num_workers() -> (usize, usize) {
    let cores = thread::available_parallelism().map_or(1, NonZeroUsize::get);
    let total = (cores / 2).max(2);
    let encrypt = total / 2;

    (encrypt, total - encrypt)
}

/// How many batches may queue for an encrypt worker on top of the one it is encrypting.
const ENCRYPT_QUEUE_CAPACITY: usize = 2;

/// How many received packets go to a decrypt worker in one batch at most.
const DECRYPT_BATCH_SIZE: usize = 64;

/// How many received packets may await decryption before we stop reading from the network.
///
/// Each holds a copy of its datagram, so this bounds their memory like the UDP socket's queue
/// bounds that of the received batches.
const MAX_DECRYPTS_IN_FLIGHT: usize = 4 * DECRYPT_BATCH_SIZE;

bufferpool::buffer_pool!(
    static ENCRYPT_JOBS: VecBuf<EncryptJob> = (tun::MAX_BATCH_SIZE, "encrypt-jobs"),
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
/// Packets are handed to the workers in batches. The packets of one flow always go to the same
/// encrypt worker, which sends them to the UDP socket. The packets of one peer always go to the
/// same decrypt worker, which returns them to us in order.
///
/// WireGuard counters are reserved in order on the main thread, so packets of different flows to
/// the same peer may leave out of counter order. The peer's replay window accepts counters up to
/// 8192 behind the newest one, so a worker would have to fall that far behind before any of its
/// packets are dropped.
pub struct CryptoWorkers {
    encrypt: Vec<EncryptWorker>,
    decrypt: Vec<DecryptWorker>,
    decrypted: mpsc::UnboundedReceiver<Buffer<VecBuf<Received<DecryptedPacket>>>>,
    decrypts_in_flight: usize,
    hasher: FastRandomState,
}

struct EncryptWorker {
    batches: PollSender<EncryptBatch>,
    staged: Buffer<VecBuf<EncryptJob>>,
}

struct DecryptWorker {
    batches: mpsc::UnboundedSender<Buffer<VecBuf<Received<DecryptJob>>>>,
    staged: Buffer<VecBuf<Received<DecryptJob>>>,
}

struct EncryptBatch {
    jobs: Buffer<VecBuf<EncryptJob>>,
    sockets: UdpSenders,
}

impl CryptoWorkers {
    pub fn new(packet_counter: Counter<u64>) -> Self {
        let (num_encrypt, num_decrypt) = num_workers();
        let (decrypted_tx, decrypted_rx) = mpsc::unbounded_channel();

        let encrypt = (0..num_encrypt)
            .filter_map(|i| {
                let (tx, rx) = mpsc::channel(ENCRYPT_QUEUE_CAPACITY);
                let packet_counter = packet_counter.clone();

                spawn(format!("wg-encrypt-{i}"), move || {
                    encrypt(rx, packet_counter)
                })?;

                Some(EncryptWorker {
                    batches: PollSender::new(tx),
                    staged: ENCRYPT_JOBS.pull(),
                })
            })
            .collect();
        let decrypt = (0..num_decrypt)
            .filter_map(|i| {
                let (tx, rx) = mpsc::unbounded_channel();
                let decrypted_tx = decrypted_tx.clone();

                spawn(format!("wg-decrypt-{i}"), move || decrypt(rx, decrypted_tx))?;

                Some(DecryptWorker {
                    batches: tx,
                    staged: DECRYPT_JOBS.pull(),
                })
            })
            .collect();

        Self {
            encrypt,
            decrypt,
            decrypted: decrypted_rx,
            decrypts_in_flight: 0,
            hasher: FastRandomState::default(),
        }
    }

    /// Stages `job` for decryption by the worker of its peer.
    pub fn decrypt(&mut self, job: Received<DecryptJob>) {
        let Some(index) = worker_index(&self.decrypt, self.hasher.hash_one(job.packet.tunnel_id()))
        else {
            tracing::debug!("No decrypt worker running; dropping packet");
            return;
        };
        let worker = &mut self.decrypt[index];

        worker.staged.push(job);

        if worker.staged.len() >= DECRYPT_BATCH_SIZE {
            self.decrypts_in_flight += worker.submit();
        }
    }

    /// Whether we may hand more received packets to the decrypt workers.
    pub fn can_decrypt(&self) -> bool {
        self.decrypts_in_flight < MAX_DECRYPTS_IN_FLIGHT
    }

    /// Returns the next batch of decrypted packets, in the order they were received per peer.
    pub fn poll_decrypted(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Buffer<VecBuf<Received<DecryptedPacket>>>> {
        // `None` means no worker is running and none will ever return a packet.
        let Some(decrypted) = ready!(self.decrypted.poll_recv(cx)) else {
            return Poll::Pending;
        };
        self.decrypts_in_flight -= decrypted.len();

        Poll::Ready(decrypted)
    }

    /// Hands all staged packets to their workers, sending encrypted packets to `sockets`.
    ///
    /// Pending while an encrypt worker has no room for another batch.
    pub fn poll_flush(&mut self, sockets: &Sockets, cx: &mut Context<'_>) -> Poll<()> {
        for worker in &mut self.decrypt {
            if worker.staged.is_empty() {
                continue;
            }

            self.decrypts_in_flight += worker.submit();
        }

        for worker in &mut self.encrypt {
            if worker.staged.is_empty() {
                continue;
            }

            if ready!(worker.batches.poll_reserve(cx)).is_err() {
                tracing::debug!(
                    num_packets = worker.staged.len(),
                    "Encrypt worker stopped; dropping packets"
                );
                worker.staged.clear();
                continue;
            }

            let jobs = mem::replace(&mut worker.staged, ENCRYPT_JOBS.pull());
            let _ = worker.batches.send_item(EncryptBatch {
                jobs,
                sockets: sockets.senders(),
            });
        }

        Poll::Ready(())
    }

    /// Drops all staged packets.
    pub fn clear(&mut self) {
        for worker in &mut self.encrypt {
            worker.staged.clear();
        }

        for worker in &mut self.decrypt {
            worker.staged.clear();
        }
    }
}

impl Encryptor for CryptoWorkers {
    fn encrypt(&mut self, job: EncryptJob) {
        let Some(index) = worker_index(&self.encrypt, self.hasher.hash_one(flow(job.packet())))
        else {
            tracing::debug!("No encrypt worker running; dropping packet");
            return;
        };

        self.encrypt[index].staged.push(job);
    }
}

impl DecryptWorker {
    /// Hands the staged packets to the worker, returning how many it accepted.
    fn submit(&mut self) -> usize {
        let jobs = mem::replace(&mut self.staged, DECRYPT_JOBS.pull());
        let len = jobs.len();

        if self.batches.send(jobs).is_err() {
            tracing::debug!(
                num_packets = len,
                "Decrypt worker stopped; dropping packets"
            );
            return 0;
        }

        len
    }
}

/// The fields identifying the flow of `packet`.
fn flow(packet: &IpPacket) -> impl std::hash::Hash {
    (
        packet.source(),
        packet.destination(),
        packet.source_protocol().ok(),
        packet.destination_protocol().ok(),
    )
}

fn worker_index<T>(workers: &[T], hash: u64) -> Option<usize> {
    (hash as usize).checked_rem(workers.len())
}

fn spawn(name: String, work: impl FnOnce() + Send + 'static) -> Option<()> {
    thread::Builder::new()
        .name(name.clone())
        .spawn(work)
        .inspect_err(|e| tracing::warn!(%name, "Failed to spawn crypto worker: {e}"))
        .ok()?;

    Some(())
}

fn encrypt(mut batches: mpsc::Receiver<EncryptBatch>, packet_counter: Counter<u64>) {
    let mut gso_queue = UdpGsoQueue::new();

    while let Some(EncryptBatch { mut jobs, sockets }) = batches.blocking_recv() {
        for job in jobs.drain(..) {
            gso_queue.encrypt(job);
        }

        let mut transmitted = UdpPacketCounts::transmit(&packet_counter);

        for datagram in gso_queue.datagrams() {
            for segment in datagram.packet.chunks(datagram.segment_size) {
                transmitted.record(segment);
            }

            if let Err(e) = sockets.blocking_send(datagram) {
                tracing::debug!("{e:#}");
            }
        }
    }
}

fn decrypt(
    mut batches: mpsc::UnboundedReceiver<Buffer<VecBuf<Received<DecryptJob>>>>,
    decrypted: mpsc::UnboundedSender<Buffer<VecBuf<Received<DecryptedPacket>>>>,
) {
    while let Some(mut jobs) = batches.blocking_recv() {
        let mut packets = DECRYPTED.pull();
        packets.extend(jobs.drain(..).map(|job| Received {
            local: job.local,
            from: job.from,
            ecn: job.ecn,
            packet: job.packet.decrypt(),
        }));

        if decrypted.send(packets).is_err() {
            return;
        }
    }
}
