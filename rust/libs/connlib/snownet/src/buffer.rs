use std::collections::VecDeque;
use std::net::SocketAddr;

use boringtun::noise::PendingSeal;
use bufferpool::BufferPool;
use ip_packet::Ecn;

use crate::node::Transmit;

/// Provides destination buffers for [`Node::encapsulate`](crate::Node::encapsulate).
///
/// Implementers hand out a writable slice into which the encrypted packet is written directly,
/// avoiding an intermediate copy.
pub trait BufferProvider {
    type Reservation<'a>: Reservation
    where
        Self: 'a;

    /// Reserve `len` writable bytes for a datagram from `src` to `dst` with the given `ecn`.
    ///
    /// The returned [`Reservation`] is rolled back when dropped unless it is
    /// [committed](Reservation::commit).
    fn reserve(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        ecn: Ecn,
        len: usize,
    ) -> Self::Reservation<'_>;
}

/// A reserved region within a [`BufferProvider`].
///
/// Dropping the reservation without [committing](Self::commit) it rolls the reservation back.
pub trait Reservation {
    /// The writable bytes reserved for the datagram.
    fn buffer(&mut self) -> &mut [u8];

    /// Keep the data message written into [`buffer`](Self::buffer); without this the reservation
    /// is rolled back on drop.
    ///
    /// The datagram is only complete once `seal` has run, which the provider must ensure before it
    /// is sent.
    fn commit(self, seal: SealJob);
}

/// The deferred encryption of the WireGuard data message inside a [`Reservation`].
#[must_use = "the datagram is not encrypted until the job runs"]
pub struct SealJob {
    offset: usize,
    seal: PendingSeal,
}

impl SealJob {
    pub fn new(offset: usize, seal: PendingSeal) -> Self {
        Self { offset, seal }
    }

    /// Encrypts the data message within `datagram`, the bytes of the [`Reservation`] it belongs to.
    pub fn run(self, datagram: &mut [u8]) {
        self.seal.seal(&mut datagram[self.offset..]);
    }
}

/// A datagram collected by a [`TransmitBuffer`].
pub enum Outgoing {
    /// A control message, e.g. a WireGuard handshake or a STUN/TURN message, final when created.
    Control(Transmit),
    /// A WireGuard data message that still needs to be sealed.
    Data(PendingTransmit),
}

impl Outgoing {
    /// Returns the datagram ready to be sent, sealing a data message on the current thread.
    pub fn seal(self) -> Transmit {
        match self {
            Outgoing::Control(transmit) => transmit,
            Outgoing::Data(PendingTransmit { mut transmit, seal }) => {
                seal.run(&mut transmit.payload);

                transmit
            }
        }
    }
}

/// A WireGuard data message whose payload still holds the plaintext.
#[must_use = "the data message is lost unless it is sealed"]
pub struct PendingTransmit {
    transmit: Transmit,
    seal: SealJob,
}

impl PendingTransmit {
    /// Moves the data message into `provider`, which seals it.
    pub fn write_into(self, provider: &mut impl BufferProvider) {
        let Transmit {
            src,
            dst,
            payload,
            ecn,
        } = self.transmit;

        let mut reservation = provider.reserve(src, dst, ecn, payload.len());
        reservation.buffer().copy_from_slice(&payload);
        reservation.commit(self.seal);
    }
}

/// Collects datagrams for the network, each as an [`Outgoing`].
pub struct TransmitBuffer {
    buffer_pool: BufferPool<Vec<u8>>,
    transmits: VecDeque<Outgoing>,
}

impl TransmitBuffer {
    pub fn new() -> Self {
        Self {
            buffer_pool: BufferPool::new(ip_packet::MAX_FZ_PAYLOAD, "transmit-buffer"),
            transmits: VecDeque::default(),
        }
    }

    /// Collect a control message.
    pub fn push(&mut self, transmit: Transmit) {
        self.transmits.push_back(Outgoing::Control(transmit));
    }

    /// Returns the next collected datagram, if any.
    pub fn poll_transmit(&mut self) -> Option<Outgoing> {
        self.transmits.pop_front()
    }

    pub fn is_empty(&self) -> bool {
        self.transmits.is_empty()
    }

    pub fn clear(&mut self) {
        self.transmits.clear();
    }
}

impl Extend<Transmit> for TransmitBuffer {
    fn extend<T: IntoIterator<Item = Transmit>>(&mut self, iter: T) {
        self.transmits
            .extend(iter.into_iter().map(Outgoing::Control));
    }
}

impl Default for TransmitBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl BufferProvider for TransmitBuffer {
    type Reservation<'a> = TransmitReservation<'a>;

    fn reserve(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        ecn: Ecn,
        len: usize,
    ) -> TransmitReservation<'_> {
        let mut payload = self.buffer_pool.pull();
        payload.resize(len, 0);

        TransmitReservation {
            transmit: Transmit {
                src,
                dst,
                payload,
                ecn,
            },
            transmits: &mut self.transmits,
        }
    }
}

/// A [`Reservation`] into a [`TransmitBuffer`], collected once committed.
pub struct TransmitReservation<'a> {
    transmit: Transmit,
    transmits: &'a mut VecDeque<Outgoing>,
}

impl Reservation for TransmitReservation<'_> {
    fn buffer(&mut self) -> &mut [u8] {
        &mut self.transmit.payload
    }

    fn commit(self, seal: SealJob) {
        self.transmits.push_back(Outgoing::Data(PendingTransmit {
            transmit: self.transmit,
            seal,
        }));
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    const DST: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));

    #[test]
    fn dropping_a_reservation_without_committing_yields_nothing() {
        let mut transmits = TransmitBuffer::new();

        {
            let mut reservation = transmits.reserve(None, DST, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"foobar");
            // Dropped without committing.
        }

        assert!(transmits.poll_transmit().is_none());
    }
}
