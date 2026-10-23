use std::net::SocketAddr;
use std::num::NonZeroUsize;
use std::time::Instant;

use anyhow::Result;
use bufferpool::Bytes;
use ip_packet::IpPacket;

use crate::node::Transmit;

/// A batch of outgoing packets to one connection, with the [`Node`](crate::Node) borrowed until
/// [`EncapsulateBatch::finish`] reserves their WireGuard counters.
#[must_use = "no counters are reserved until the batch is finished"]
pub struct EncapsulateBatch<'n> {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    channel: Option<u16>,
    batch: sanstun::EncapsulateBatch<'n>,
}

impl<'n> EncapsulateBatch<'n> {
    pub(crate) fn new(
        src: Option<SocketAddr>,
        dst: SocketAddr,
        channel: Option<u16>,
        batch: sanstun::EncapsulateBatch<'n>,
    ) -> Self {
        Self {
            src,
            dst,
            channel,
            batch,
        }
    }

    pub fn src(&self) -> Option<SocketAddr> {
        self.src
    }

    pub fn dst(&self) -> SocketAddr {
        self.dst
    }

    /// Returns the length of the datagram `packet` encrypts to.
    pub fn datagram_len(&self, packet: &IpPacket) -> usize {
        datagram_len(self.channel, packet)
    }

    /// Reserves `len` consecutive counters and releases the [`Node`](crate::Node).
    pub fn finish(self, len: NonZeroUsize) -> Result<PendingEncapsulate, sanstun::Error> {
        let pending = self.batch.finish(len)?;

        Ok(PendingEncapsulate {
            src: self.src,
            dst: self.dst,
            channel: self.channel,
            pending,
        })
    }
}

/// Where to send a batch of outgoing packets, with their WireGuard counters reserved.
///
/// Encrypting needs no access to the [`Node`](crate::Node), so it can happen on any thread.
#[derive(Debug)]
pub struct PendingEncapsulate {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    channel: Option<u16>,
    pending: sanstun::PendingEncapsulate,
}

#[expect(clippy::len_without_is_empty, reason = "a batch is never empty")]
impl PendingEncapsulate {
    pub fn src(&self) -> Option<SocketAddr> {
        self.src
    }

    pub fn dst(&self) -> SocketAddr {
        self.dst
    }

    /// Returns the number of reserved counters.
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// Returns the length of the datagram written for `packet` by [`PendingEncapsulate::encrypt_into`].
    pub fn datagram_len(&self, packet: &IpPacket) -> usize {
        datagram_len(self.channel, packet)
    }

    /// Encrypts `packets`, those of the batch in order, each into a `dst` of
    /// [`PendingEncapsulate::datagram_len`] bytes, as the iterator is pulled.
    pub fn encrypt_into<'a, I>(
        self,
        packets: I,
    ) -> impl Iterator<Item = Result<(), sanstun::Error>> + 'a
    where
        I: IntoIterator<Item = (&'a IpPacket, &'a mut [u8])>,
        I::IntoIter: 'a,
    {
        let channel = self.channel;
        let messages = packets.into_iter().map(move |(packet, dst)| {
            let message = match channel {
                Some(channel) => {
                    let (header, message) = dst.split_at_mut(ip_packet::DATA_CHANNEL_OVERHEAD);
                    crate::channel_data::encode_header_to_slice(header, channel, message.len());

                    message
                }
                None => dst,
            };

            (packet.packet(), message)
        });

        self.pending
            .encrypt(messages)
            .map(|result| result.map(drop))
    }

    /// Encrypts `packet`, the only one of the batch, into a standalone [`Transmit`].
    pub fn encrypt(self, packet: &IpPacket) -> Result<Transmit, sanstun::Error> {
        debug_assert_eq!(self.len(), 1, "a standalone transmit holds one packet");

        let src = self.src;
        let dst = self.dst;

        let len = self.datagram_len(packet);
        let mut payload = Bytes::fitting(len);
        let result = self
            .encrypt_into([(packet, payload.expose(len))])
            .next()
            .unwrap_or(Err(sanstun::Error::EmptyPlaintext));
        result?;

        Ok(Transmit {
            src,
            dst,
            payload,
            ecn: packet.ecn(),
        })
    }
}

fn datagram_len(channel: Option<u16>, packet: &IpPacket) -> usize {
    let channel_data_overhead = match channel {
        Some(_) => ip_packet::DATA_CHANNEL_OVERHEAD,
        None => 0,
    };

    channel_data_overhead + packet.packet().len().next_multiple_of(16) + ip_packet::WG_OVERHEAD
}

/// The WireGuard data messages of one received datagram that passed the replay check, with the
/// [`Node`](crate::Node) borrowed until [`DecapsulateBatch::finish`].
#[must_use = "the data messages are not decrypted until the batch is finished"]
pub struct DecapsulateBatch<'n> {
    interface: &'n mut sanstun::Interface,
    tunnel: sanstun::TunnelId,
    src: SocketAddr,
    dst: SocketAddr,
    /// Where the WireGuard message starts in each segment; it takes up the rest of it.
    offset: usize,
    channel: Option<u16>,
    batch: sanstun::DecapsulateBatch<'n>,
}

impl<'n> DecapsulateBatch<'n> {
    pub(crate) fn new(
        interface: &'n mut sanstun::Interface,
        tunnel: sanstun::TunnelId,
        src: SocketAddr,
        dst: SocketAddr,
        offset: usize,
        channel: Option<u16>,
        batch: sanstun::DecapsulateBatch<'n>,
    ) -> Self {
        Self {
            interface,
            tunnel,
            src,
            dst,
            offset,
            channel,
            batch,
        }
    }

    /// Adds `segment`, a further segment of the same datagram, if it is a data message of the
    /// same session on the same path.
    ///
    /// Returns `false` without changing the batch otherwise; finish the batch and pass the
    /// segment to [`Node::begin_decapsulate`](crate::Node::begin_decapsulate) then.
    pub fn increment(&mut self, segment: &[u8], now: Instant) -> bool {
        if let Some(channel) = self.channel
            && !crate::channel_data::decode(segment).is_ok_and(|cd| cd.channel() == channel)
        {
            return false;
        }

        let message = &segment[self.offset.min(segment.len())..];

        // Parsing anything but a data message has side effects, such as rate limiting.
        if message.first() != Some(&4) {
            return false;
        }

        let Ok(sanstun::Received::Message(sanstun::ReceivedMessage::TransportData(data))) =
            self.interface.receive(self.src, message, now)
        else {
            return false;
        };

        if data.tunnel_id() != self.tunnel {
            return false;
        }

        self.batch.increment(data).is_ok()
    }

    /// Releases the [`Node`](crate::Node).
    pub fn finish(self) -> PendingDecapsulate {
        PendingDecapsulate {
            tunnel: self.tunnel,
            src: self.src,
            dst: self.dst,
            offset: self.offset,
            pending: self.batch.finish(),
        }
    }
}

/// The WireGuard data messages of one received datagram that passed the replay check and await
/// decryption.
///
/// Decrypting needs no access to the [`Node`](crate::Node), so it can happen on any thread.
pub struct PendingDecapsulate {
    tunnel: sanstun::TunnelId,
    src: SocketAddr,
    dst: SocketAddr,
    /// Where the WireGuard message starts in each segment; it takes up the rest of it.
    offset: usize,
    pending: sanstun::PendingDecapsulate,
}

#[expect(clippy::len_without_is_empty, reason = "a batch is never empty")]
impl PendingDecapsulate {
    /// Returns the number of data messages in the batch.
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// Decrypts the messages from `segments`, those passed to
    /// [`Node::begin_decapsulate`](crate::Node::begin_decapsulate) and
    /// [`DecapsulateBatch::increment`] in order.
    ///
    /// Commit each result with [`Node::commit_decrypted`](crate::Node::commit_decrypted).
    pub fn decrypt<'a>(self, segments: impl IntoIterator<Item = &'a [u8]>) -> DecryptedBatch {
        let offset = self.offset;
        let messages = segments.into_iter().map(|segment| {
            (
                segment.get(offset..).unwrap_or_default(),
                ip_packet::packet_buffer(),
            )
        });

        DecryptedBatch {
            tunnel: self.tunnel,
            src: self.src,
            dst: self.dst,
            decrypted: self.pending.decrypt(messages),
        }
    }
}

/// The outcome of a [`PendingDecapsulate`], yielding one [`DecryptedIpPacket`] per message.
pub struct DecryptedBatch {
    tunnel: sanstun::TunnelId,
    src: SocketAddr,
    dst: SocketAddr,
    decrypted: sanstun::DecryptedBatch<bufferpool::Bytes>,
}

impl Iterator for DecryptedBatch {
    type Item = DecryptedIpPacket;

    fn next(&mut self) -> Option<Self::Item> {
        let decrypted = self.decrypted.next()?;

        Some(DecryptedIpPacket {
            tunnel: self.tunnel,
            src: self.src,
            dst: self.dst,
            decrypted: decrypted.map(IpPacket::new),
        })
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.decrypted.size_hint()
    }
}

impl ExactSizeIterator for DecryptedBatch {}

/// One decrypted message of a [`DecryptedBatch`].
pub struct DecryptedIpPacket {
    pub(crate) tunnel: sanstun::TunnelId,
    pub(crate) src: SocketAddr,
    pub(crate) dst: SocketAddr,
    pub(crate) decrypted: sanstun::Decrypted<Result<IpPacket>>,
}

impl prefetch::Prefetch for DecryptedIpPacket {
    fn prefetch(&self) {
        if let Some(Ok(packet)) = self.decrypted.plaintext() {
            packet.prefetch();
        }
    }
}
