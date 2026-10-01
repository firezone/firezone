use std::{
    collections::VecDeque,
    hash::{DefaultHasher, Hash as _, Hasher as _},
    io,
    net::SocketAddr,
    num::NonZeroUsize,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll},
    thread,
};

use futures::task::AtomicWaker;
use ip_packet::Ecn;
use snownet::{DecryptedPacket, EncryptedPacket};
use socket_factory::DatagramOut;
use tokio::sync::mpsc;

use super::udp_gso_queue::PendingDatagram;

/// The most crypto worker threads we start.
///
/// The main thread's per-packet work outside of the AEAD caps a tunnel's throughput long before
/// four workers run out of capacity, so more would only add wake-ups.
const MAX_WORKERS: usize = 4;

/// Cores left to the main thread and the busiest IO thread feeding it.
const RESERVED_CORES: usize = 2;

/// How many GSO batches may be sealing or waiting to be handed to their socket.
///
/// Two per worker keep each one busy while the main thread fills the next batch.
const MAX_SEALS_IN_FLIGHT: usize = 2 * MAX_WORKERS;

/// A packet received from the network.
pub struct Received<P> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub ecn: Ecn,
    pub packet: P,
}

/// Seals and opens batches of WireGuard data messages on dedicated worker threads.
///
/// Each connection is pinned to one worker, which hands its sealed batches straight to the socket,
/// so they leave in the order they were submitted. Opened batches come back over a channel polled
/// by the main thread and are released in the order they were submitted.
pub struct Crypto<TId> {
    workers: Vec<crossbeam_channel::Sender<Job<TId>>>,
    seals_in_flight: Arc<SealsInFlight>,
    next_open_worker: usize,
    opened_rx: mpsc::UnboundedReceiver<Opened<TId>>,
    opens: ReorderBuffer<Vec<Received<DecryptedPacket<TId>>>>,
}

impl<TId> Crypto<TId>
where
    TId: Send + 'static,
{
    pub fn new() -> io::Result<Self> {
        let (opened_tx, opened_rx) = mpsc::unbounded_channel();
        let seals_in_flight = Arc::new(SealsInFlight::default());

        let num_workers = thread::available_parallelism()
            .map_or(0, NonZeroUsize::get)
            .saturating_sub(RESERVED_CORES)
            .clamp(1, MAX_WORKERS);

        let workers = (0..num_workers)
            .map(|i| {
                // Unbounded because the callers bound the jobs in flight per direction.
                let (jobs_tx, jobs_rx) = crossbeam_channel::unbounded();
                let opened_tx = opened_tx.clone();
                let seals_in_flight = seals_in_flight.clone();

                thread::Builder::new()
                    .name(format!("connlib-crypto-{i}"))
                    .spawn(move || work(jobs_rx, opened_tx, seals_in_flight))?;

                Ok(jobs_tx)
            })
            .collect::<io::Result<_>>()?;

        Ok(Self {
            workers,
            seals_in_flight,
            next_open_worker: 0,
            opened_rx,
            opens: ReorderBuffer::default(),
        })
    }

    pub fn poll_seal_ready(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        if self.seals_in_flight.has_capacity() {
            return Poll::Ready(());
        }

        self.seals_in_flight.waker.register(cx.waker());

        if self.seals_in_flight.has_capacity() {
            return Poll::Ready(());
        }

        Poll::Pending
    }

    /// Seals `datagram` and sends it to `socket`, after all batches previously submitted to the
    /// same peer.
    pub fn seal(&mut self, datagram: PendingDatagram, socket: mpsc::Sender<DatagramOut>) {
        let DatagramOut { src, dst, .. } = datagram.datagram();
        let mut hasher = DefaultHasher::new();
        (src, dst).hash(&mut hasher);
        let worker = self.worker(hasher.finish() as usize);

        self.seals_in_flight.count.fetch_add(1, Ordering::Relaxed);

        if worker.send(Job::Seal(datagram, socket)).is_err() {
            self.seals_in_flight.release();
        }
    }

    pub fn open(&mut self, packets: Vec<Received<EncryptedPacket<TId>>>) {
        if packets.is_empty() {
            return;
        }

        let seq = self.opens.push();
        self.next_open_worker = self.next_open_worker.wrapping_add(1);

        if self
            .worker(self.next_open_worker)
            .send(Job::Open(seq, packets))
            .is_err()
        {
            self.opens.complete(seq, Vec::new());
        }
    }

    pub fn opens_in_flight(&self) -> usize {
        self.opens.len()
    }

    pub fn poll_opened(&mut self, cx: &mut Context<'_>) {
        while let Poll::Ready(Some(Opened(seq, packets))) = self.opened_rx.poll_recv(cx) {
            self.opens.complete(seq, packets);
        }
    }

    pub fn pop_opened(&mut self) -> Option<Vec<Received<DecryptedPacket<TId>>>> {
        self.opens.pop()
    }

    fn worker(&self, key: usize) -> &crossbeam_channel::Sender<Job<TId>> {
        &self.workers[key % self.workers.len()]
    }
}

fn work<TId>(
    jobs: crossbeam_channel::Receiver<Job<TId>>,
    opened: mpsc::UnboundedSender<Opened<TId>>,
    seals_in_flight: Arc<SealsInFlight>,
) {
    for job in jobs {
        match job {
            Job::Seal(datagram, socket) => {
                // Fails only once the socket is gone, in which case the datagram is dropped.
                let _ = socket.blocking_send(datagram.seal());
                seals_in_flight.release();
            }
            Job::Open(seq, packets) => {
                if opened.send(Opened(seq, open(packets))).is_err() {
                    return;
                }
            }
        }
    }
}

enum Job<TId> {
    Seal(PendingDatagram, mpsc::Sender<DatagramOut>),
    Open(u64, Vec<Received<EncryptedPacket<TId>>>),
}

struct Opened<TId>(u64, Vec<Received<DecryptedPacket<TId>>>);

#[derive(Default)]
struct SealsInFlight {
    count: AtomicUsize,
    waker: AtomicWaker,
}

impl SealsInFlight {
    fn has_capacity(&self) -> bool {
        self.count.load(Ordering::Relaxed) < MAX_SEALS_IN_FLIGHT
    }

    fn release(&self) {
        self.count.fetch_sub(1, Ordering::Relaxed);
        self.waker.wake();
    }
}

fn open<TId>(packets: Vec<Received<EncryptedPacket<TId>>>) -> Vec<Received<DecryptedPacket<TId>>> {
    packets
        .into_iter()
        .map(|received| Received {
            local: received.local,
            from: received.from,
            ecn: received.ecn,
            packet: received.packet.decrypt(),
        })
        .collect()
}

/// Releases the results of jobs in the order they were pushed, however they complete.
struct ReorderBuffer<T> {
    /// The sequence number of the oldest job not yet released.
    head: u64,
    results: VecDeque<Option<T>>,
}

impl<T> Default for ReorderBuffer<T> {
    fn default() -> Self {
        Self {
            head: 0,
            results: VecDeque::new(),
        }
    }
}

impl<T> ReorderBuffer<T> {
    /// Returns the sequence number of a new job.
    fn push(&mut self) -> u64 {
        self.results.push_back(None);

        self.head + self.results.len() as u64 - 1
    }

    fn complete(&mut self, seq: u64, result: T) {
        let index = usize::try_from(seq - self.head).expect("in-flight jobs are bounded");

        self.results[index] = Some(result);
    }

    fn pop(&mut self) -> Option<T> {
        let result = self.results.pop_front_if(|r| r.is_some())??;
        self.head += 1;

        Some(result)
    }

    /// Returns the number of jobs not yet released.
    fn len(&self) -> usize {
        self.results.len()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::super::{UdpGsoQueue, udp_gso_queue::tests::*};
    use super::*;

    #[tokio::test]
    async fn seals_of_one_peer_leave_in_submission_order() {
        let now = Instant::now();
        let (mut alice, mut bob) = connected_tunnels(now);
        let mut queue = UdpGsoQueue::new();
        let mut crypto = Crypto::<()>::new().unwrap();
        let (socket, mut sent) = mpsc::channel(MAX_SEALS_IN_FLIGHT);
        // A longer segment cannot join the previous batch, so every length starts a new one.
        let packets = [100, 200, 300, 400]
            .into_iter()
            .flat_map(|len| [len; 8])
            .map(|len| ip_packet::make::udp_packet(SRC_IP, DST_IP, 1, 2, &vec![0; len]).unwrap())
            .collect::<Vec<_>>();

        for packet in &packets {
            enqueue(&mut queue, &mut alice, DST_1, packet.packet(), now);
        }
        while let Some(datagram) = queue.pop() {
            crypto.seal(datagram, socket.clone());
        }
        let mut released = Vec::new();
        while released.len() < 4 {
            released.push(sent.recv().await.unwrap());
        }

        let received = released
            .iter()
            .flat_map(|d| d.packet.chunks(d.segment_size))
            .map(|segment| decapsulate(&mut bob, segment, now))
            .collect::<Vec<_>>();
        let expected = packets
            .iter()
            .map(|p| p.packet().to_vec())
            .collect::<Vec<_>>();
        assert_eq!(received, expected);
    }

    #[test]
    fn releases_results_in_push_order() {
        let mut buffer = ReorderBuffer::default();
        let first = buffer.push();
        let second = buffer.push();

        buffer.complete(second, "second");
        let before_first = buffer.pop();
        buffer.complete(first, "first");

        assert_eq!(before_first, None);
        assert_eq!(buffer.pop(), Some("first"));
        assert_eq!(buffer.pop(), Some("second"));
        assert_eq!(buffer.len(), 0);
    }
}
