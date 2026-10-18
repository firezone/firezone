use std::{
    collections::VecDeque,
    mem,
    net::SocketAddr,
    pin::Pin,
    sync::mpsc,
    task::{Context, Poll, ready},
};

use bufferpool::{Buffer, VecBuf};
use ip_packet::Ecn;
use snownet::{DecryptJob, DecryptedPacket};
use tokio::sync::oneshot;

use super::{next_worker, spawn_workers};

/// How many received packets go to a decrypt worker in one batch at most.
const DECRYPT_BATCH_SIZE: usize = 64;

/// How many received packets may await decryption before we stop reading from the network.
///
/// Each holds a copy of its datagram, so this bounds their memory like the UDP socket's queue
/// bounds that of the received batches.
const MAX_DECRYPTS_IN_FLIGHT: usize = 4 * DECRYPT_BATCH_SIZE;

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

/// Decrypts WireGuard data messages on worker threads.
///
/// Packets go to the next worker round-robin in batches. The results come back through a `oneshot`
/// channel per batch, which we queue in submission order to accept the decrypted packets in that order.
pub struct Decryptor {
    workers: Vec<mpsc::Sender<Batch>>,
    next_worker: usize,

    staged: Buffer<VecBuf<Received<DecryptJob>>>,
    /// The batches handed to the workers, with how many packets each holds.
    decrypting: VecDeque<(usize, oneshot::Receiver<Decrypted>)>,
    in_flight: usize,
}

type Decrypted = Buffer<VecBuf<Received<DecryptedPacket>>>;

struct Batch {
    jobs: Buffer<VecBuf<Received<DecryptJob>>>,
    decrypted: oneshot::Sender<Decrypted>,
}

impl Decryptor {
    pub fn new(num_workers: usize) -> Self {
        Self {
            workers: spawn_workers("wg-decrypt", num_workers, decrypt),
            next_worker: 0,
            staged: DECRYPT_JOBS.pull(),
            decrypting: VecDeque::new(),
            in_flight: 0,
        }
    }

    /// Stages `job` for decryption.
    pub fn submit(&mut self, job: Received<DecryptJob>) {
        self.staged.push(job);

        if self.staged.len() >= DECRYPT_BATCH_SIZE {
            self.flush();
        }
    }

    /// Whether we may hand more received packets to the workers.
    pub fn has_room(&self) -> bool {
        self.in_flight < MAX_DECRYPTS_IN_FLIGHT
    }

    /// Returns the next batch of decrypted packets, in the order they were received.
    pub fn poll_decrypted(&mut self, cx: &mut Context<'_>) -> Poll<Decrypted> {
        loop {
            let Some((len, decrypted)) = self.decrypting.front_mut() else {
                return Poll::Pending;
            };
            let len = *len;
            let result = ready!(Pin::new(decrypted).poll(cx));

            self.decrypting.pop_front();
            self.in_flight -= len;

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

    /// Drops all staged packets.
    pub fn clear(&mut self) {
        self.staged.clear();
    }

    /// Hands all staged packets to the next worker.
    pub fn flush(&mut self) {
        if self.staged.is_empty() {
            return;
        }

        let jobs = mem::replace(&mut self.staged, DECRYPT_JOBS.pull());
        let len = jobs.len();
        let Some(worker) = next_worker(&self.workers, &mut self.next_worker) else {
            tracing::debug!("No decrypt worker running; dropping packets");
            return;
        };
        let (tx, rx) = oneshot::channel();

        // A stopped worker drops the sender, so `poll_decrypted` skips the batch.
        let _ = worker.send(Batch {
            jobs,
            decrypted: tx,
        });
        self.decrypting.push_back((len, rx));
        self.in_flight += len;
    }
}

fn decrypt(batches: mpsc::Receiver<Batch>) {
    for Batch {
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
