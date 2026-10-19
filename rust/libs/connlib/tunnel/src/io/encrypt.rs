use std::{net::SocketAddr, sync::mpsc};

use bufferpool::{Buffer, VecBuf};
use ip_packet::IpVersion;
use opentelemetry::metrics::Counter;
use snownet::EncryptJob;
use socket_factory::{DatagramOut, MAX_GSO_SEGMENTS};
use tokio::sync::oneshot;

use super::{UdpGsoTrain, Work, next_worker};
use crate::packet_counts::UdpPacketCounts;
use crate::sockets::{Encrypting, Sockets};

bufferpool::buffer_pool!(
    static ENCRYPT_JOBS: VecBuf<EncryptJob> = (MAX_GSO_SEGMENTS, "encrypt-jobs"),
    batch: 4
);
bufferpool::buffer_pool!(
    static ENCRYPTING: VecBuf<oneshot::Receiver<DatagramOut>> = (tun::MAX_BATCH_SIZE, "encrypting"),
    batch: 4
);

/// Encrypts WireGuard data messages on worker threads, one [`UdpGsoTrain`] per job.
///
/// Push packets in the order the state encapsulated them, i.e. reserved their counters, and their
/// datagrams go out in that order: batches borrow the [`Encryptor`] mutably, so they never
/// interleave. Within a batch, trains close in push order and queue their receivers in that order.
/// When the batch ends, the receivers of each IP version go to its UDP socket thread as one item.
/// A socket thread sends its items and their receivers front to back, and a flow has one
/// destination, so all of its datagrams go through one socket thread.
pub struct Encryptor {
    workers: Vec<mpsc::Sender<Work>>,
    next_worker: usize,
}

impl Encryptor {
    pub fn new(workers: Vec<mpsc::Sender<Work>>) -> Self {
        Self {
            workers,
            next_worker: 0,
        }
    }

    /// Starts a batch whose datagrams are queued on `sockets` when it is dropped.
    ///
    /// Each UDP socket must have room for one more item.
    pub fn batch<'a>(&'a mut self, sockets: &'a mut Sockets) -> EncryptBatch<'a> {
        EncryptBatch {
            encryptor: self,
            sockets,
            open: None,
            encrypting_v4: None,
            encrypting_v6: None,
        }
    }
}

/// Packets to encrypt, sent to the UDP sockets when dropped.
pub struct EncryptBatch<'a> {
    encryptor: &'a mut Encryptor,
    sockets: &'a mut Sockets,
    open: Option<Train>,
    encrypting_v4: Option<Encrypting>,
    encrypting_v6: Option<Encrypting>,
}

impl EncryptBatch<'_> {
    /// Adds `job` to the open train, handing that train to a worker first if `job` starts a new one.
    pub fn push(&mut self, job: EncryptJob) {
        if let Some(open) = self.open.as_mut()
            && open
                .train
                .try_append(job.src(), job.dst(), job.ecn(), job.datagram_len())
        {
            open.jobs.push(job);
            return;
        }

        if let Some(closed) = self.open.replace(Train::new(job)) {
            self.dispatch(closed);
        }
    }

    fn dispatch(&mut self, train: Train) {
        let (tx, rx) = oneshot::channel();
        let encrypting = match train.train.dst() {
            SocketAddr::V4(_) => &mut self.encrypting_v4,
            SocketAddr::V6(_) => &mut self.encrypting_v6,
        };
        encrypting.get_or_insert_with(|| ENCRYPTING.pull()).push(rx);

        let Some(worker) = next_worker(&self.encryptor.workers, &mut self.encryptor.next_worker)
        else {
            tracing::debug!("No encrypt worker running; dropping packets");
            return;
        };

        // A stopped worker drops the sender, so the socket skips the train.
        let _ = worker.send(Work::Encrypt(train, tx));
    }
}

impl Extend<EncryptJob> for EncryptBatch<'_> {
    fn extend<T: IntoIterator<Item = EncryptJob>>(&mut self, jobs: T) {
        for job in jobs {
            self.push(job);
        }
    }
}

impl Drop for EncryptBatch<'_> {
    fn drop(&mut self) {
        if let Some(open) = self.open.take() {
            self.dispatch(open);
        }

        if let Some(encrypting) = self.encrypting_v4.take() {
            self.sockets.send_encrypting(IpVersion::V4, encrypting);
        }

        if let Some(encrypting) = self.encrypting_v6.take() {
            self.sockets.send_encrypting(IpVersion::V6, encrypting);
        }
    }
}

pub(super) struct Train {
    train: UdpGsoTrain,
    jobs: Buffer<VecBuf<EncryptJob>>,
}

impl Train {
    fn new(job: EncryptJob) -> Self {
        let train = UdpGsoTrain::new(job.src(), job.dst(), job.ecn(), job.datagram_len());
        let mut jobs = ENCRYPT_JOBS.pull();
        jobs.push(job);

        Self { train, jobs }
    }
}

pub(super) fn encrypt(
    Train { train, mut jobs }: Train,
    encrypted: oneshot::Sender<DatagramOut>,
    packet_counter: &Counter<u64>,
) {
    let Some(datagram) = train.encrypt(jobs.drain(..)) else {
        return;
    };

    let mut transmitted = UdpPacketCounts::transmit(packet_counter);

    for segment in datagram.packet.chunks(datagram.segment_size) {
        transmitted.record(segment);
    }

    // The socket thread stopped if the receiver is gone.
    let _ = encrypted.send(datagram);
}
