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
    /// Reserve `len` writable bytes for a datagram from `src` to `dst` with the given `ecn`.
    fn reserve(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        ecn: Ecn,
        len: usize,
    ) -> &mut [u8];

    /// Undo the most recent [`BufferProvider::reserve`] for `(src, dst, ecn)`.
    ///
    /// Called when we end up not writing a valid datagram into the reserved slice.
    fn rollback(&mut self, src: Option<SocketAddr>, dst: SocketAddr, ecn: Ecn, len: usize);

    /// Collect an already-formed [`Transmit`].
    ///
    /// Used for datagrams that were produced elsewhere as a standalone [`Transmit`] (e.g. a
    /// handshake that cannot be encrypted in place because there is no session yet). The default
    /// implementation copies the payload via [`BufferProvider::reserve`]; implementers that can take
    /// ownership of the buffer should override it.
    fn push(&mut self, transmit: Transmit) {
        self.reserve(
            transmit.src,
            transmit.dst,
            transmit.ecn,
            transmit.payload.len(),
        )
        .copy_from_slice(&transmit.payload);
    }
}

/// Collects datagrams as standalone [`Transmit`]s.
///
/// Datagrams are either encapsulated in place via the [`BufferProvider`] impl or pushed in
/// fully-formed via [`BufferProvider::push`]. Used wherever packets must be surfaced as individual
/// transmits rather than written into a shared destination buffer (e.g. control traffic, handshakes
/// or the test harness).
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
    fn reserve(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        ecn: Ecn,
        len: usize,
    ) -> &mut [u8] {
        let mut payload = self.buffer_pool.pull();
        payload.resize(len, 0);

        self.transmits.push_back(Transmit {
            src,
            dst,
            payload,
            ecn,
        });

        let last = self.transmits.back_mut().expect("just pushed an element");

        &mut last.payload[..]
    }

    fn rollback(&mut self, _: Option<SocketAddr>, _: SocketAddr, _: Ecn, _: usize) {
        self.transmits.pop_back();
    }

    fn push(&mut self, transmit: Transmit) {
        self.transmits.push_back(transmit);
    }
}
