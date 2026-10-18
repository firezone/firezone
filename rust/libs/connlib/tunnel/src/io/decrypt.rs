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

/// How many received packets go to a decrypt worker in one job at most.
const DECRYPT_BATCH_SIZE: usize = 64;

/// How many jobs may await decryption before we stop reading from the network.
///
/// Each packet holds a copy of its datagram, so this bounds their memory like the UDP socket's queue
/// bounds that of the received batches.
const MAX_JOBS_IN_FLIGHT: usize = 4;

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
/// Packets go to the next worker round-robin in jobs of up to [`DECRYPT_BATCH_SIZE`]. The results
/// come back through a `oneshot` channel per job, which we queue in submission order to accept the
/// decrypted packets in that order.
pub struct Decryptor {
    workers: Vec<mpsc::Sender<(Jobs, oneshot::Sender<Decrypted>)>>,
    next_worker: usize,

    /// The jobs handed to the workers.
    decrypting: VecDeque<oneshot::Receiver<Decrypted>>,
}

type Jobs = Buffer<VecBuf<Received<DecryptJob>>>;
type Decrypted = Buffer<VecBuf<Received<DecryptedPacket>>>;

impl Decryptor {
    pub fn new(num_workers: usize) -> Self {
        Self {
            workers: spawn_workers("wg-decrypt", num_workers, decrypt),
            next_worker: 0,
            decrypting: VecDeque::new(),
        }
    }

    /// Starts a batch of packets to decrypt, handed to the workers when it is dropped.
    pub fn batch(&mut self) -> DecryptBatch<'_> {
        DecryptBatch {
            decryptor: self,
            jobs: DECRYPT_JOBS.pull(),
        }
    }

    /// Whether we may hand more received packets to the workers.
    pub fn has_room(&self) -> bool {
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

    fn submit(&mut self, jobs: Jobs) {
        let Some(worker) = next_worker(&self.workers, &mut self.next_worker) else {
            tracing::debug!("No decrypt worker running; dropping packets");
            return;
        };
        let (tx, rx) = oneshot::channel();

        // A stopped worker drops the sender, so `poll_decrypted` skips the job.
        let _ = worker.send((jobs, tx));
        self.decrypting.push_back(rx);
    }
}

/// Packets to decrypt, handed to the workers when dropped.
pub struct DecryptBatch<'a> {
    decryptor: &'a mut Decryptor,
    jobs: Jobs,
}

impl DecryptBatch<'_> {
    pub fn push(&mut self, job: Received<DecryptJob>) {
        self.jobs.push(job);

        if self.jobs.len() == DECRYPT_BATCH_SIZE {
            self.submit();
        }
    }

    fn submit(&mut self) {
        let jobs = mem::replace(&mut self.jobs, DECRYPT_JOBS.pull());
        self.decryptor.submit(jobs);
    }
}

impl Drop for DecryptBatch<'_> {
    fn drop(&mut self) {
        if !self.jobs.is_empty() {
            self.submit();
        }
    }
}

fn decrypt(jobs: mpsc::Receiver<(Jobs, oneshot::Sender<Decrypted>)>) {
    for (mut jobs, decrypted) in jobs {
        let mut packets = DECRYPTED.pull();
        packets.extend(jobs.drain(..).map(|job| Received {
            local: job.local,
            from: job.from,
            ecn: job.ecn,
            packet: job.packet.decrypt(),
        }));

        // We stopped if the receiver is gone; the channel for the next job is closed too.
        let _ = decrypted.send(packets);
    }
}
