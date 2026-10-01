use std::{
    collections::VecDeque,
    hash::{DefaultHasher, Hash as _, Hasher as _},
    io, iter,
    net::SocketAddr,
    num::NonZeroUsize,
    task::{Context, Poll, ready},
    thread,
};

use ip_packet::Ecn;
use snownet::{DecryptedPacket, EncryptedPacket};
use socket_factory::{DatagramBatch, DatagramLocation, DatagramOut};
use tokio::sync::mpsc;
use tokio_util::sync::PollSender;

use super::udp_gso_queue::PendingDatagram;

/// The most worker threads we start per direction.
///
/// The main thread's per-packet work outside of the AEAD caps a tunnel's throughput long before
/// four workers run out of capacity, so more would only add wake-ups.
const MAX_WORKERS: usize = 4;

/// Cores left to the main thread and the busiest IO thread feeding it.
///
/// Both pools are sized against the same remaining cores because a tunnel's load is dominated by
/// one direction at a time.
const RESERVED_CORES: usize = 2;

/// How many GSO batches may queue for each seal worker on top of the one it is sealing.
const SEAL_QUEUE_CAPACITY: usize = 2;

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
/// Seals and opens run on separate pools of workers. All seals for one peer address go to the
/// same worker, which runs them in submission order and sends the sealed batches straight to the
/// socket. Received batches go to the open workers in turn and their opened packets are released
/// in the order the batches were submitted.
pub struct Crypto<TId> {
    sealers: Vec<PollSender<Seal>>,
    openers: Vec<crossbeam_channel::Sender<Open<TId>>>,
    next_opener: usize,
    opened_rx: mpsc::UnboundedReceiver<Opened<TId>>,
    opened: ReorderBuffer<Vec<Received<DecryptedPacket<TId>>>>,
}

impl<TId> Crypto<TId>
where
    TId: Send + 'static,
{
    pub fn new() -> Self {
        let (opened_tx, opened_rx) = mpsc::unbounded_channel();

        let num_workers = thread::available_parallelism()
            .map_or(0, NonZeroUsize::get)
            .saturating_sub(RESERVED_CORES)
            .clamp(1, MAX_WORKERS);

        let (sealers, openers) = spawn_workers(num_workers, opened_tx)
            .inspect_err(|e| tracing::debug!("Failed to spawn crypto workers: {e}"))
            .unwrap_or_default();

        Self {
            sealers,
            openers,
            next_opener: 0,
            opened_rx,
            opened: ReorderBuffer::default(),
        }
    }

    /// Waits until the seal worker for `dst` has room for another batch.
    pub fn poll_seal_ready(
        &mut self,
        dst: SocketAddr,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), CryptoWorkersUnavailable>> {
        let index = worker_index(dst, self.sealers.len())?;

        // Fails only once the worker is gone, in which case `seal` drops the datagram.
        let _ = ready!(self.sealers[index].poll_reserve(cx));

        Poll::Ready(Ok(()))
    }

    /// Seals `datagram` and sends it to `socket`, after all batches previously submitted to the
    /// same peer.
    ///
    /// Call [`Crypto::poll_seal_ready`] for the datagram's destination first, otherwise the
    /// datagram is dropped.
    pub fn seal(
        &mut self,
        datagram: PendingDatagram,
        socket: mpsc::Sender<DatagramOut>,
    ) -> Result<(), CryptoWorkersUnavailable> {
        let index = worker_index(datagram.dst(), self.sealers.len())?;

        let _ = self.sealers[index].send_item(Seal(datagram, socket));

        Ok(())
    }

    /// Opens `packets`, received in `batch`, on the next open worker.
    ///
    /// [`Crypto::poll_opened`] releases the opened packets after those of all previously
    /// submitted batches.
    pub fn open(
        &mut self,
        batch: DatagramBatch,
        packets: Vec<(DatagramLocation, Received<EncryptedPacket<TId>>)>,
    ) -> Result<(), CryptoWorkersUnavailable> {
        if packets.is_empty() {
            return Ok(());
        }

        let index = self
            .next_opener
            .checked_rem(self.openers.len())
            .ok_or(CryptoWorkersUnavailable)?;
        self.next_opener = index + 1;

        let seq = self.opened.push();

        if self.openers[index].send(Open(seq, batch, packets)).is_err() {
            self.opened.complete(seq, Vec::new());
        }

        Ok(())
    }

    /// Returns the number of received batches whose opened packets have not been released yet.
    pub fn opens_in_flight(&self) -> usize {
        self.opened.len()
    }

    /// Returns the opened packets of each batch that is done, in submission order.
    pub fn poll_opened(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Vec<Vec<Received<DecryptedPacket<TId>>>> {
        while let Poll::Ready(Some(Opened(seq, packets))) = self.opened_rx.poll_recv(cx) {
            self.opened.complete(seq, packets);
        }

        iter::from_fn(|| self.opened.pop()).collect()
    }
}

/// Spawns `n` workers per direction.
fn spawn_workers<TId>(
    n: usize,
    opened: mpsc::UnboundedSender<Opened<TId>>,
) -> io::Result<(
    Vec<PollSender<Seal>>,
    Vec<crossbeam_channel::Sender<Open<TId>>>,
)>
where
    TId: Send + 'static,
{
    let sealers = (0..n)
        .map(|i| {
            let (jobs_tx, jobs_rx) = mpsc::channel(SEAL_QUEUE_CAPACITY);

            thread::Builder::new()
                .name(format!("connlib-seal-{i}"))
                .spawn(move || seal_work(jobs_rx))?;

            Ok(PollSender::new(jobs_tx))
        })
        .collect::<io::Result<_>>()?;

    let openers = (0..n)
        .map(|i| {
            // Unbounded because the receive budget bounds the opens in flight.
            let (jobs_tx, jobs_rx) = crossbeam_channel::unbounded();
            let opened = opened.clone();

            thread::Builder::new()
                .name(format!("connlib-open-{i}"))
                .spawn(move || open_work(jobs_rx, opened))?;

            Ok(jobs_tx)
        })
        .collect::<io::Result<_>>()?;

    Ok((sealers, openers))
}

fn worker_index(peer: SocketAddr, num_workers: usize) -> Result<usize, CryptoWorkersUnavailable> {
    let mut hasher = DefaultHasher::new();
    peer.hash(&mut hasher);

    let index = (hasher.finish() as usize)
        .checked_rem(num_workers)
        .ok_or(CryptoWorkersUnavailable)?;

    Ok(index)
}

fn seal_work(mut jobs: mpsc::Receiver<Seal>) {
    while let Some(Seal(datagram, socket)) = jobs.blocking_recv() {
        // Fails only once the socket is gone, in which case the datagram is dropped.
        let _ = socket.blocking_send(datagram.seal());
    }
}

fn open_work<TId>(
    jobs: crossbeam_channel::Receiver<Open<TId>>,
    opened: mpsc::UnboundedSender<Opened<TId>>,
) {
    for Open(seq, batch, packets) in jobs {
        if opened.send(Opened(seq, open(&batch, packets))).is_err() {
            return;
        }
    }
}

struct Seal(PendingDatagram, mpsc::Sender<DatagramOut>);

struct Open<TId>(
    u64,
    DatagramBatch,
    Vec<(DatagramLocation, Received<EncryptedPacket<TId>>)>,
);

struct Opened<TId>(u64, Vec<Received<DecryptedPacket<TId>>>);

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

fn open<TId>(
    batch: &DatagramBatch,
    packets: Vec<(DatagramLocation, Received<EncryptedPacket<TId>>)>,
) -> Vec<Received<DecryptedPacket<TId>>> {
    packets
        .into_iter()
        .map(|(location, received)| Received {
            local: received.local,
            from: received.from,
            ecn: received.ecn,
            packet: received.packet.decrypt(batch.get(location)),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::{future::poll_fn, time::Instant};

    use super::super::{UdpGsoQueue, udp_gso_queue::tests::*};
    use super::*;

    #[tokio::test]
    async fn seals_of_one_peer_leave_in_submission_order() {
        let now = Instant::now();
        let (mut alice, mut bob) = connected_tunnels(now);
        let mut queue = UdpGsoQueue::new();
        let mut crypto = Crypto::<()>::new();
        let (socket, mut sent) = mpsc::channel(4);
        // A longer segment cannot join the previous batch, so every length starts a new one.
        let packets = [100, 200, 300, 400]
            .into_iter()
            .flat_map(|len| [len; 8])
            .map(|len| ip_packet::make::udp_packet(SRC_IP, DST_IP, 1, 2, &vec![0; len]).unwrap())
            .collect::<Vec<_>>();

        for packet in &packets {
            enqueue(&mut queue, &mut alice, DST_1, packet.clone(), now);
        }
        while let Some(datagram) = queue.pop() {
            let dst = datagram.dst();
            poll_fn(|cx| crypto.poll_seal_ready(dst, cx)).await.unwrap();
            crypto.seal(datagram, socket.clone()).unwrap();
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
