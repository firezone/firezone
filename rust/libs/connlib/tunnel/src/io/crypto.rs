use std::{
    collections::VecDeque,
    net::SocketAddr,
    num::NonZeroUsize,
    task::{Context, Poll},
    thread,
};

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

/// Jobs with fewer packets run on the main thread: handing them off costs more than the AEAD.
const MIN_PACKETS_PER_JOB: usize = 8;

/// How many GSO batches may be sealing or waiting for their turn to be sent.
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
/// Results come back over a channel polled by the main thread and are released in the order the
/// jobs were submitted, separately per direction. Small jobs, and all jobs when there are no
/// workers, run inline but are released through the same order.
pub struct Crypto<TId> {
    jobs: crossbeam_channel::Sender<Job<TId>>,
    completed_rx: mpsc::UnboundedReceiver<Completed<TId>>,
    seals: ReorderBuffer<DatagramOut>,
    opens: ReorderBuffer<Vec<Received<DecryptedPacket<TId>>>>,
}

impl<TId> Crypto<TId>
where
    TId: Send + 'static,
{
    pub fn new() -> Self {
        // Unbounded because the callers bound the jobs in flight per direction.
        let (jobs_tx, jobs_rx) = crossbeam_channel::unbounded();
        let (completed_tx, completed_rx) = mpsc::unbounded_channel();

        let num_workers = thread::available_parallelism()
            .map_or(0, NonZeroUsize::get)
            .saturating_sub(RESERVED_CORES)
            .min(MAX_WORKERS);

        for i in 0..num_workers {
            let jobs = jobs_rx.clone();
            let completed = completed_tx.clone();

            if let Err(e) = thread::Builder::new()
                .name(format!("Crypto {i}"))
                .spawn(move || work(jobs, completed))
            {
                tracing::warn!("Failed to spawn crypto worker: {e}");
            }
        }

        Self {
            jobs: jobs_tx,
            completed_rx,
            seals: ReorderBuffer::default(),
            opens: ReorderBuffer::default(),
        }
    }

    pub fn can_seal(&self) -> bool {
        self.seals.len() < MAX_SEALS_IN_FLIGHT
    }

    pub fn seal(&mut self, datagram: PendingDatagram) {
        let seq = self.seals.push();

        if datagram.num_seals() < MIN_PACKETS_PER_JOB {
            self.seals.complete(seq, datagram.seal());
            return;
        }

        self.submit(Job::Seal(seq, datagram));
    }

    pub fn open(&mut self, packets: Vec<Received<EncryptedPacket<TId>>>) {
        if packets.is_empty() {
            return;
        }

        let seq = self.opens.push();

        if packets.len() < MIN_PACKETS_PER_JOB {
            self.opens.complete(seq, open(packets));
            return;
        }

        self.submit(Job::Open(seq, packets));
    }

    pub fn opens_in_flight(&self) -> usize {
        self.opens.len()
    }

    pub fn poll_completed(&mut self, cx: &mut Context<'_>) {
        while let Poll::Ready(Some(completed)) = self.completed_rx.poll_recv(cx) {
            self.complete(completed);
        }
    }

    pub fn pop_sealed(&mut self) -> Option<DatagramOut> {
        self.seals.pop()
    }

    pub fn pop_opened(&mut self) -> Option<Vec<Received<DecryptedPacket<TId>>>> {
        self.opens.pop()
    }

    fn submit(&mut self, job: Job<TId>) {
        // Without any worker left, the job runs inline.
        if let Err(crossbeam_channel::SendError(job)) = self.jobs.send(job) {
            self.complete(job.run());
        }
    }

    fn complete(&mut self, completed: Completed<TId>) {
        match completed {
            Completed::Sealed(seq, datagram) => self.seals.complete(seq, datagram),
            Completed::Opened(seq, packets) => self.opens.complete(seq, packets),
        }
    }
}

fn work<TId>(
    jobs: crossbeam_channel::Receiver<Job<TId>>,
    completed: mpsc::UnboundedSender<Completed<TId>>,
) {
    for job in jobs {
        if completed.send(job.run()).is_err() {
            return;
        }
    }
}

enum Job<TId> {
    Seal(u64, PendingDatagram),
    Open(u64, Vec<Received<EncryptedPacket<TId>>>),
}

enum Completed<TId> {
    Sealed(u64, DatagramOut),
    Opened(u64, Vec<Received<DecryptedPacket<TId>>>),
}

impl<TId> Job<TId> {
    fn run(self) -> Completed<TId> {
        match self {
            Job::Seal(seq, datagram) => Completed::Sealed(seq, datagram.seal()),
            Job::Open(seq, packets) => Completed::Opened(seq, open(packets)),
        }
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
    use std::{future::poll_fn, time::Instant};

    use snownet::{BufferProvider as _, Reservation as _, SealJob};

    use super::super::{UdpGsoQueue, udp_gso_queue::tests::*};
    use super::*;

    #[tokio::test]
    async fn offloaded_seals_are_released_in_submission_order() {
        let now = Instant::now();
        let (mut alice, mut bob) = connected_tunnels(now);
        let mut queue = UdpGsoQueue::new();
        let mut crypto = Crypto::<()>::new();
        // A longer segment cannot join the previous batch, so every length starts a new one.
        let packets = [100, 200, 300, 400]
            .into_iter()
            .flat_map(|len| [len; MIN_PACKETS_PER_JOB])
            .map(|len| ip_packet::make::udp_packet(SRC_IP, DST_IP, 1, 2, &vec![0; len]).unwrap())
            .collect::<Vec<_>>();

        for packet in &packets {
            let mut reservation =
                queue.reserve(None, DST_1, Ecn::NonEct, packet.packet().len() + 32);
            let seal = alice
                .encapsulate_data_deferred_at(packet.packet(), reservation.buffer(), now)
                .unwrap();
            reservation.commit_sealed(SealJob::new(0, seal));
        }
        while let Some(datagram) = queue.pop() {
            crypto.seal(datagram);
        }
        let mut released = Vec::new();
        while released.len() < 4 {
            let datagram = poll_fn(|cx| {
                crypto.poll_completed(cx);

                crypto.pop_sealed().map_or(Poll::Pending, Poll::Ready)
            })
            .await;
            released.push(datagram);
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
