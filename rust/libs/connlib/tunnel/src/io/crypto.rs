use std::{
    hash::{DefaultHasher, Hash as _, Hasher as _},
    io, iter,
    net::SocketAddr,
    num::NonZeroUsize,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll},
    thread,
};

use anyhow::Context as _;
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

#[derive(thiserror::Error, Debug)]
#[error("Crypto workers unavailable")]
pub struct CryptoWorkersUnavailable;

/// Seals and opens batches of WireGuard data messages on dedicated worker threads.
///
/// Each worker runs its jobs in the order they were submitted. The seals and the opens for one peer
/// address each go to a fixed worker, a different one per direction whenever there are several, so
/// both directions keep their order per peer. Sealed batches go from the worker straight to the
/// socket; opened packets come back over a channel polled by the main thread.
pub struct Crypto<TId> {
    workers: Vec<crossbeam_channel::Sender<Job<TId>>>,
    spawn_error: Option<anyhow::Error>,
    seals_in_flight: Arc<SealsInFlight>,
    opens_in_flight: Arc<AtomicUsize>,
    opened_rx: mpsc::UnboundedReceiver<Opened<TId>>,
}

impl<TId> Crypto<TId>
where
    TId: Send + 'static,
{
    pub fn new() -> Self {
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
            .collect::<io::Result<_>>()
            .context(CryptoWorkersUnavailable);

        let (workers, spawn_error) = match workers {
            Ok(workers) => (workers, None),
            Err(e) => (Vec::new(), Some(e)),
        };

        Self {
            workers,
            spawn_error,
            seals_in_flight,
            opens_in_flight: Arc::default(),
            opened_rx,
        }
    }

    /// Returns the error that prevented the workers from starting, once.
    ///
    /// Without workers, all batches are dropped.
    pub fn take_error(&mut self) -> Option<anyhow::Error> {
        self.spawn_error.take()
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
        let Some(index) = self.worker_index(datagram.datagram().dst, Direction::Seal) else {
            return;
        };
        let worker = &self.workers[index];

        self.seals_in_flight.count.fetch_add(1, Ordering::Relaxed);

        if worker.send(Job::Seal(datagram, socket)).is_err() {
            self.seals_in_flight.release();
        }
    }

    /// Opens `packets`, after all packets previously submitted from the same peer.
    pub fn open(&mut self, packets: Vec<Received<EncryptedPacket<TId>>>) {
        if packets.is_empty() {
            return;
        }

        let batch = Arc::new(BatchInFlight::new(self.opens_in_flight.clone()));
        let mut parts = iter::repeat_with(Vec::new)
            .take(self.workers.len())
            .collect::<Vec<_>>();

        for received in packets {
            let Some(index) = self.worker_index(received.from, Direction::Open) else {
                return;
            };

            parts[index].push(received);
        }

        for (worker, part) in self.workers.iter().zip(parts) {
            if part.is_empty() {
                continue;
            }

            // Fails only once the worker is gone, in which case the packets are dropped.
            let _ = worker.send(Job::Open(part, batch.clone()));
        }
    }

    /// Returns the number of received batches whose opened packets have not been polled yet.
    pub fn opens_in_flight(&self) -> usize {
        self.opens_in_flight.load(Ordering::Relaxed)
    }

    pub fn poll_opened(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Vec<Vec<Received<DecryptedPacket<TId>>>> {
        iter::from_fn(|| {
            let Poll::Ready(Some(Opened(packets, _batch))) = self.opened_rx.poll_recv(cx) else {
                return None;
            };

            Some(packets)
        })
        .collect()
    }

    fn worker_index(&self, peer: SocketAddr, direction: Direction) -> Option<usize> {
        let mut hasher = DefaultHasher::new();
        peer.hash(&mut hasher);

        let num_workers = self.workers.len();
        let index = (hasher.finish() as usize).checked_rem(num_workers)?;

        Some((index + direction as usize) % num_workers)
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
            Job::Open(packets, batch) => {
                if opened.send(Opened(open(packets), batch)).is_err() {
                    return;
                }
            }
        }
    }
}

enum Job<TId> {
    Seal(PendingDatagram, mpsc::Sender<DatagramOut>),
    Open(Vec<Received<EncryptedPacket<TId>>>, Arc<BatchInFlight>),
}

struct Opened<TId>(Vec<Received<DecryptedPacket<TId>>>, Arc<BatchInFlight>);

enum Direction {
    Seal = 0,
    Open = 1,
}

/// Counts a received batch as in flight until the opened packets of all its parts are polled.
struct BatchInFlight(Arc<AtomicUsize>);

impl BatchInFlight {
    fn new(count: Arc<AtomicUsize>) -> Self {
        count.fetch_add(1, Ordering::Relaxed);

        Self(count)
    }
}

impl Drop for BatchInFlight {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

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
        let mut crypto = Crypto::<()>::new();
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
}
