use std::{
    collections::VecDeque,
    mem,
    net::SocketAddr,
    ops::Range,
    pin::Pin,
    sync::mpsc,
    task::{Context, Poll, ready},
};

use bufferpool::{Buffer, VecBuf};
use ip_packet::Ecn;
use snownet::{Decapsulation, DecryptedPacket};
use socket_factory::{DatagramIn, RecvBuffer};
use tokio::sync::oneshot;

use super::{next_worker, spawn_workers};

/// How many received packets go to a decrypt worker in one job at most.
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
    static DECRYPT_BUFFERS: VecBuf<RecvBuffer> = (DECRYPT_BATCH_SIZE, "decrypt-buffers"),
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

/// Decrypts WireGuard data messages on worker threads.
///
/// Received buffers go to the next worker round-robin in jobs of up to [`DECRYPT_BATCH_SIZE`] data
/// messages. The results come back through a `oneshot` channel per job, which we queue in
/// submission order to accept the decrypted packets in that order.
pub struct Decryptor {
    workers: Vec<mpsc::Sender<(Job, oneshot::Sender<Decrypted>)>>,
    next_worker: usize,

    /// The jobs handed to the workers.
    decrypting: VecDeque<oneshot::Receiver<Decrypted>>,
}

type Decrypted = Buffer<VecBuf<Received<DecryptedPacket>>>;

/// Receive buffers and the data messages within them to decrypt.
///
/// Each buffer holds at least one of the messages.
struct Job {
    buffers: Buffer<VecBuf<RecvBuffer>>,
    messages: Buffer<VecBuf<Message>>,
}

struct Message {
    buffer: usize,
    datagram: Range<usize>,
    decapsulation: Decapsulation,
}

impl Job {
    fn new() -> Self {
        Self {
            buffers: DECRYPT_BUFFERS.pull(),
            messages: DECRYPT_MESSAGES.pull(),
        }
    }
}

impl Decryptor {
    pub fn new(num_workers: usize) -> Self {
        Self {
            workers: spawn_workers("wg-decrypt", num_workers, decrypt),
            next_worker: 0,
            decrypting: VecDeque::new(),
        }
    }

    /// Starts a batch of received buffers to decrypt, handed to the workers when it is dropped.
    pub fn batch(&mut self) -> DecryptBatch<'_> {
        DecryptBatch {
            decryptor: self,
            job: Job::new(),
        }
    }

    /// Whether we may hand more received buffers to the workers.
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

    fn submit(&mut self, job: Job) {
        let Some(worker) = next_worker(&self.workers, &mut self.next_worker) else {
            tracing::debug!("No decrypt worker running; dropping packets");
            return;
        };
        let (tx, rx) = oneshot::channel();

        // A stopped worker drops the sender, so `poll_decrypted` skips the job.
        let _ = worker.send((job, tx));
        self.decrypting.push_back(rx);
    }
}

/// Received buffers to decrypt, handed to the workers when dropped.
pub struct DecryptBatch<'a> {
    decryptor: &'a mut Decryptor,
    job: Job,
}

impl DecryptBatch<'_> {
    /// Passes each datagram in `buffer` to `decapsulate` and moves the buffer into a job if any of
    /// them is a data message to decrypt.
    pub fn push(
        &mut self,
        buffer: RecvBuffer,
        mut decapsulate: impl FnMut(DatagramIn<'_>) -> Option<Decapsulation>,
    ) {
        if self.job.messages.len() + buffer.num_datagrams() > DECRYPT_BATCH_SIZE {
            self.submit();
        }

        let index = self.job.buffers.len();
        let num_messages = self.job.messages.len();

        self.job
            .messages
            .extend(buffer.datagrams().filter_map(|datagram| {
                let range = datagram.range.clone();

                Some(Message {
                    buffer: index,
                    datagram: range,
                    decapsulation: decapsulate(datagram)?,
                })
            }));

        if self.job.messages.len() > num_messages {
            self.job.buffers.push(buffer);
        }

        if self.job.messages.len() == DECRYPT_BATCH_SIZE {
            self.submit();
        }
    }

    fn submit(&mut self) {
        let job = mem::replace(&mut self.job, Job::new());
        self.decryptor.submit(job);
    }
}

impl Drop for DecryptBatch<'_> {
    fn drop(&mut self) {
        if !self.job.messages.is_empty() {
            self.submit();
        }
    }
}

fn decrypt(jobs: mpsc::Receiver<(Job, oneshot::Sender<Decrypted>)>) {
    for (mut job, decrypted) in jobs {
        let mut packets = DECRYPTED.pull();
        packets.extend(job.messages.drain(..).map(|message| {
            let buffer = &job.buffers[message.buffer];

            Received {
                local: buffer.local(),
                from: buffer.from(),
                ecn: buffer.ecn(),
                packet: message.decapsulation.decrypt(&buffer[message.datagram]),
            }
        }));

        // We stopped if the receiver is gone; the channel for the next job is closed too.
        let _ = decrypted.send(packets);
    }
}
