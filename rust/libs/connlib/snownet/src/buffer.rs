use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::LazyLock;

use boringtun::noise::PendingSeal;
use bufferpool::BufferPool;
use ip_packet::{Ecn, IpPacket};

use crate::node::Transmit;

static SEAL_BUFFER_POOL: LazyLock<BufferPool<Vec<u8>>> =
    LazyLock::new(|| BufferPool::new(ip_packet::MAX_FZ_PAYLOAD, "seal"));

/// A WireGuard data message to be sent from `src` to `dst`, not yet sealed.
#[derive(Debug)]
#[must_use = "the data message is lost unless it is sealed"]
pub struct DataMessage {
    pub src: Option<SocketAddr>,
    pub dst: SocketAddr,
    pub ecn: Ecn,
    pub job: SealJob,
}

impl DataMessage {
    /// Returns the datagram ready to be sent, sealing it on the current thread.
    pub fn seal(self) -> Transmit {
        let mut payload = SEAL_BUFFER_POOL.pull();
        payload.resize(self.job.datagram_len(), 0);
        self.job.seal_into(&mut payload);

        Transmit {
            src: self.src,
            dst: self.dst,
            payload,
            ecn: self.ecn,
        }
    }
}

/// The plaintext of a WireGuard data message and the means to seal it.
///
/// Sealing is the only way to get at the bytes, so plaintext never reaches a socket.
#[derive(derive_more::Debug)]
#[must_use = "the data message is lost unless it is sealed"]
pub struct SealJob {
    channel_data_header: Option<[u8; 4]>,
    /// `None` for a keepalive.
    packet: Option<IpPacket>,
    #[debug(skip)]
    seal: PendingSeal,
}

impl SealJob {
    pub fn new(
        channel_data_header: Option<[u8; 4]>,
        packet: Option<IpPacket>,
        seal: PendingSeal,
    ) -> Self {
        Self {
            channel_data_header,
            packet,
            seal,
        }
    }

    /// Returns the length of the sealed datagram.
    pub fn datagram_len(&self) -> usize {
        self.channel_data_header.map_or(0, |header| header.len())
            + self.plaintext().len()
            + ip_packet::WG_OVERHEAD
    }

    /// Whether the datagram is sent through a TURN channel.
    pub fn is_relayed(&self) -> bool {
        self.channel_data_header.is_some()
    }

    /// Writes the sealed datagram to the start of `dst` and returns its length.
    ///
    /// # Panics
    ///
    /// Panics if `dst` is shorter than [`SealJob::datagram_len`].
    pub fn seal_into(self, dst: &mut [u8]) -> usize {
        let Self {
            channel_data_header,
            packet,
            seal,
        } = self;

        let header_len = match channel_data_header {
            Some(header) => {
                dst[..header.len()].copy_from_slice(&header);

                header.len()
            }
            None => 0,
        };
        let plaintext = packet.as_ref().map_or(&[][..], IpPacket::packet);

        header_len + seal.seal_into(plaintext, &mut dst[header_len..])
    }

    fn plaintext(&self) -> &[u8] {
        self.packet.as_ref().map_or(&[], IpPacket::packet)
    }
}

/// A datagram collected by a [`TransmitBuffer`].
pub enum Outgoing {
    /// A control message, e.g. a WireGuard handshake or a STUN/TURN message, final when created.
    Control(Transmit),
    /// A WireGuard data message that still needs to be sealed.
    Data(DataMessage),
}

impl Outgoing {
    /// Returns the datagram ready to be sent, sealing a data message on the current thread.
    pub fn seal(self) -> Transmit {
        match self {
            Outgoing::Control(transmit) => transmit,
            Outgoing::Data(message) => message.seal(),
        }
    }
}

/// Collects datagrams for the network, each as an [`Outgoing`].
#[derive(Default)]
pub struct TransmitBuffer {
    transmits: VecDeque<Outgoing>,
}

impl TransmitBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Collect a control message.
    pub fn push(&mut self, transmit: Transmit) {
        self.transmits.push_back(Outgoing::Control(transmit));
    }

    /// Collect a data message.
    pub fn push_data(&mut self, message: DataMessage) {
        self.transmits.push_back(Outgoing::Data(message));
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
