use std::{
    collections::VecDeque,
    net::SocketAddr,
    sync::mpsc,
    task::{Context, Poll, ready},
};

use anyhow::Result;
use bufferpool::{Buffer, VecBuf};
use ip_packet::IpVersion;
use opentelemetry::metrics::Counter;
use snownet::EncryptJob;
use socket_factory::{DatagramOut, MAX_GSO_SEGMENTS};
use tokio::sync::oneshot;

use super::{UdpGsoTrain, next_worker, spawn_workers};
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::Sockets;

bufferpool::buffer_pool!(
    static ENCRYPT_JOBS: VecBuf<EncryptJob> = (MAX_GSO_SEGMENTS, "encrypt-jobs"),
    batch: 4
);

/// Encrypts WireGuard data messages on worker threads, one [`UdpGsoTrain`] per job.
///
/// A train goes to the next worker round-robin as soon as the next packet would start a new train,
/// or when we flush. The result comes back through a `oneshot` channel, which we queue on the UDP
/// socket thread in submission order, so it sends the datagrams in that order.
pub struct Encryptor {
    workers: Vec<mpsc::Sender<(Train, oneshot::Sender<DatagramOut>)>>,
    next_worker: usize,

    open: Option<Train>,
    /// Closed trains waiting for room in their UDP socket's queue.
    unsent: VecDeque<Train>,
}

struct Train {
    train: UdpGsoTrain,
    jobs: Buffer<VecBuf<EncryptJob>>,
}

impl Encryptor {
    pub fn new(num_workers: usize, packet_counter: Counter<u64>) -> Self {
        Self {
            workers: spawn_workers("wg-encrypt", num_workers, move |trains| {
                encrypt(trains, packet_counter.clone())
            }),
            next_worker: 0,
            open: None,
            unsent: VecDeque::new(),
        }
    }

    /// Adds `job` to the open train, sending that train to a worker first if `job` starts a new train.
    pub fn submit(&mut self, job: EncryptJob, sockets: &mut Sockets) {
        let (src, dst, ecn, len) = (job.src(), job.dst(), job.ecn(), job.datagram_len());

        if let Some(open) = self.open.as_mut()
            && open.train.try_append(src, dst, ecn, len)
        {
            open.jobs.push(job);
            return;
        }

        let mut jobs = ENCRYPT_JOBS.pull();
        jobs.push(job);
        let next = Train {
            train: UdpGsoTrain::new(src, dst, ecn, len),
            jobs,
        };

        let Some(train) = self.open.replace(next) else {
            return;
        };

        self.unsent.push_back(train);
        self.try_flush(sockets);
    }

    /// Hands all trains to the workers and queues the encrypted datagrams on `sockets`.
    ///
    /// Pending while a UDP socket has no room for another datagram.
    pub fn poll_flush(&mut self, sockets: &mut Sockets, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.unsent.extend(self.open.take());

        while let Some(train) = self.unsent.front() {
            let version = train.version();

            if let Err(e) = ready!(sockets.poll_send_ready_for(version, cx)) {
                self.unsent.clear();
                return Poll::Ready(Err(e));
            }

            let Some(train) = self.unsent.pop_front() else {
                break;
            };
            let (tx, rx) = oneshot::channel();
            sockets.send_encrypting(version, rx)?;

            self.dispatch(train, tx);
        }

        Poll::Ready(Ok(()))
    }

    /// Drops all trains not yet handed to a worker.
    pub fn clear(&mut self) {
        self.open = None;
        self.unsent.clear();
    }

    /// Hands queued trains to the workers while their socket's queue has room.
    fn try_flush(&mut self, sockets: &mut Sockets) {
        while let Some(train) = self.unsent.front() {
            let (tx, rx) = oneshot::channel();

            if !sockets.try_send_encrypting(train.version(), rx) {
                return;
            }

            let Some(train) = self.unsent.pop_front() else {
                return;
            };
            self.dispatch(train, tx);
        }
    }

    fn dispatch(&mut self, train: Train, encrypted: oneshot::Sender<DatagramOut>) {
        let Some(worker) = next_worker(&self.workers, &mut self.next_worker) else {
            tracing::debug!("No encrypt worker running; dropping packets");
            return;
        };

        // A stopped worker drops the sender, so the socket skips the train.
        let _ = worker.send((train, encrypted));
    }
}

impl Train {
    fn version(&self) -> IpVersion {
        match self.train.dst() {
            SocketAddr::V4(_) => IpVersion::V4,
            SocketAddr::V6(_) => IpVersion::V6,
        }
    }
}

fn encrypt(
    trains: mpsc::Receiver<(Train, oneshot::Sender<DatagramOut>)>,
    packet_counter: Counter<u64>,
) {
    for (Train { train, mut jobs }, encrypted) in trains {
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
