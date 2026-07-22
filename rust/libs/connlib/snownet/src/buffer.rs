use std::collections::VecDeque;
use std::net::SocketAddr;

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

    /// Collect an already-formed [`Transmit`].
    ///
    /// Used for datagrams that were produced elsewhere as a standalone [`Transmit`] (e.g. a
    /// handshake that cannot be encrypted in place because there is no session yet). The default
    /// implementation copies the payload into a fresh reservation; implementers that can take
    /// ownership of the buffer should override it.
    fn push(&mut self, transmit: Transmit) {
        let mut reservation = self.reserve(
            transmit.src,
            transmit.dst,
            transmit.ecn,
            transmit.payload.len(),
        );
        reservation.buffer().copy_from_slice(&transmit.payload);
        reservation.commit();
    }
}

/// A reserved region within a [`BufferProvider`].
///
/// Dropping the reservation without [committing](Self::commit) it rolls the reservation back.
pub trait Reservation {
    /// The writable bytes reserved for the datagram.
    fn buffer(&mut self) -> &mut [u8];

    /// Keep the bytes written into [`buffer`](Self::buffer); without this the reservation is rolled
    /// back on drop.
    fn commit(self);
}

/// Collects datagrams as standalone [`Transmit`]s.
pub struct TransmitBuffer {
    buffer_pool: BufferPool<Vec<u8>>,
    transmits: VecDeque<Transmit>,
}

impl TransmitBuffer {
    pub fn new() -> Self {
        Self {
            buffer_pool: BufferPool::new(ip_packet::MAX_FZ_PAYLOAD, "transmit-buffer"),
            transmits: VecDeque::default(),
        }
    }

    /// Returns the next collected [`Transmit`], if any.
    pub fn poll_transmit(&mut self) -> Option<Transmit> {
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
        self.transmits.extend(iter);
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

        self.transmits.push_back(Transmit {
            src,
            dst,
            payload,
            ecn,
        });

        TransmitReservation {
            inner: self,
            committed: false,
        }
    }

    fn push(&mut self, transmit: Transmit) {
        self.transmits.push_back(transmit);
    }
}

/// A [`Reservation`] into a [`TransmitBuffer`], backed by a freshly pushed [`Transmit`].
pub struct TransmitReservation<'a> {
    inner: &'a mut TransmitBuffer,
    committed: bool,
}

impl Reservation for TransmitReservation<'_> {
    fn buffer(&mut self) -> &mut [u8] {
        &mut self
            .inner
            .transmits
            .back_mut()
            .expect("a transmit to have been reserved")
            .payload[..]
    }

    fn commit(mut self) {
        self.committed = true;
    }
}

impl Drop for TransmitReservation<'_> {
    fn drop(&mut self) {
        if !self.committed {
            self.inner.transmits.pop_back();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    const DST: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1111));

    #[test]
    fn committing_a_reservation_yields_the_transmit() {
        let mut transmits = TransmitBuffer::new();

        {
            let mut reservation = transmits.reserve(None, DST, Ecn::NonEct, 6);
            reservation.buffer().copy_from_slice(b"foobar");
            reservation.commit();
        }

        let transmit = transmits.poll_transmit().expect("a committed transmit");
        assert_eq!(transmit.dst, DST);
        assert_eq!(&transmit.payload[..], b"foobar");
        assert!(transmits.poll_transmit().is_none());
    }

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
