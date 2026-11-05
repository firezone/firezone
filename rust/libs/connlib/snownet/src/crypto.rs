use std::fmt;
use std::net::SocketAddr;
use std::num::NonZeroUsize;
use std::time::Instant;

use anyhow::Result;
use bufferpool::Bytes;
use frostlink::Probe;
use ip_packet::IpPacket;
use prefetch::{IteratorExt as _, Prefetching};

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

    /// Encrypts `packet` as the only one of the batch into a standalone [`Transmit`].
    pub fn encrypt_single(self, packet: &IpPacket) -> Result<Transmit, sanstun::Error> {
        self.finish(NonZeroUsize::MIN)?.encrypt(packet)
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

    /// Splits off the counters from `at` onwards into a new pending encapsulation.
    ///
    /// Returns [`None`] and keeps all counters if `at` is not less than [`len`](Self::len).
    pub fn split_off(&mut self, at: NonZeroUsize) -> Option<PendingEncapsulate> {
        Some(PendingEncapsulate {
            src: self.src,
            dst: self.dst,
            channel: self.channel,
            pending: self.pending.split_off(at)?,
        })
    }

    /// Returns the length of the datagram written for `packet` by [`PendingEncapsulate::encrypt_into`].
    pub fn datagram_len(&self, packet: &IpPacket) -> usize {
        datagram_len(self.channel, packet)
    }

    /// Encrypts `packets`, those of the batch in order, back-to-back into `dst` as the iterator
    /// is pulled, yielding the length of each datagram.
    ///
    /// `dst` must hold the [`PendingEncapsulate::datagram_len`] of every packet. A packet that
    /// fails to encrypt still takes up its datagram's space, so stop at the first error.
    pub fn encrypt_into<'a>(
        self,
        packets: impl IntoIterator<Item = &'a IpPacket> + 'a,
        mut dst: &'a mut [u8],
    ) -> impl Iterator<Item = Result<usize, sanstun::Error>> + 'a {
        let channel = self.channel;
        let messages = packets.into_iter().map(move |packet| {
            let (datagram, rest) =
                std::mem::take(&mut dst).split_at_mut(datagram_len(channel, packet));
            dst = rest;

            let message = match channel {
                Some(channel) => {
                    let (header, message) = datagram.split_at_mut(ip_packet::DATA_CHANNEL_OVERHEAD);
                    crate::channel_data::encode_header_to_slice(header, channel, message.len());

                    message
                }
                None => datagram,
            };

            (packet.packet(), message)
        });
        let channel_data_overhead = channel_data_overhead(channel);

        self.pending
            .encrypt(messages)
            .map(move |result| result.map(|message| channel_data_overhead + message.len()))
    }

    /// Encrypts `packet`, the only one of the batch, into a standalone [`Transmit`].
    pub fn encrypt(self, packet: &IpPacket) -> Result<Transmit, sanstun::Error> {
        debug_assert_eq!(self.len(), 1, "a standalone transmit holds one packet");

        let src = self.src;
        let dst = self.dst;

        let len = self.datagram_len(packet);
        let mut payload = Bytes::fitting(len);
        let result = self
            .encrypt_into(std::iter::once(packet), payload.expose(len))
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
    channel_data_overhead(channel)
        + packet.packet().len().next_multiple_of(16)
        + ip_packet::WG_OVERHEAD
}

fn channel_data_overhead(channel: Option<u16>) -> usize {
    match channel {
        Some(_) => ip_packet::DATA_CHANNEL_OVERHEAD,
        None => 0,
    }
}

/// The WireGuard data messages of one session, received on the same path, that passed the replay
/// check, with the [`Node`](crate::Node) borrowed until [`DecapsulateBatch::finish`].
#[must_use = "the data messages are not decrypted until the batch is finished"]
pub struct DecapsulateBatch<'n> {
    interface: &'n mut sanstun::Interface,
    tunnel: sanstun::TunnelId,
    src: SocketAddr,
    dst: SocketAddr,
    /// The TURN channel the segments are relayed through, if any.
    channel: Option<u16>,
    batch: sanstun::DecapsulateBatch<'n>,
}

impl<'n> DecapsulateBatch<'n> {
    pub(crate) fn new(
        interface: &'n mut sanstun::Interface,
        tunnel: sanstun::TunnelId,
        src: SocketAddr,
        dst: SocketAddr,
        channel: Option<u16>,
        batch: sanstun::DecapsulateBatch<'n>,
    ) -> Self {
        Self {
            interface,
            tunnel,
            src,
            dst,
            channel,
            batch,
        }
    }

    /// Adds `segment`, received on the same path, if it is a data message of the same session.
    ///
    /// Returns `false` without changing the batch otherwise; finish the batch and pass the
    /// segment to [`Node::begin_decapsulate`](crate::Node::begin_decapsulate) then.
    pub fn push(&mut self, segment: &[u8], now: Instant) -> bool {
        let message = match self.channel {
            Some(channel) => match crate::channel_data::decode(segment) {
                Ok(cd) if cd.channel() == channel => cd.payload(),
                _ => return false,
            },
            None => segment,
        };

        // Parsing anything but a data message has side effects, such as rate limiting.
        if message.first() != Some(&4) {
            return false;
        }

        let Ok(sanstun::Received::Message(sanstun::ReceivedMessage::TransportData(data))) =
            self.interface.receive(self.src, message, now)
        else {
            return false;
        };

        self.batch.push(data).is_ok()
    }

    /// Releases the [`Node`](crate::Node).
    pub fn finish(self) -> PendingDecapsulate {
        PendingDecapsulate {
            tunnel: self.tunnel,
            src: self.src,
            dst: self.dst,
            channel: self.channel,
            pending: self.batch.finish(),
        }
    }
}

/// The WireGuard data messages of one session, received on the same path, that passed the replay
/// check and await decryption.
///
/// Decrypting needs no access to the [`Node`](crate::Node), so it can happen on any thread.
pub struct PendingDecapsulate {
    tunnel: sanstun::TunnelId,
    src: SocketAddr,
    dst: SocketAddr,
    /// The TURN channel the segments are relayed through, if any.
    channel: Option<u16>,
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
    /// [`DecapsulateBatch::push`] in order.
    ///
    /// Commit the result with [`Node::commit_decrypted`](crate::Node::commit_decrypted).
    pub fn decrypt<'a>(self, segments: impl IntoIterator<Item = &'a [u8]>) -> DecryptedBatch {
        let header_len = channel_data_overhead(self.channel);
        // Each relayed segment was decoded as channel data before it joined the batch.
        let messages = segments.into_iter().map(|segment| {
            (
                segment.get(header_len..).unwrap_or_default(),
                ip_packet::packet_buffer(),
            )
        });

        let mut data = self.pending.decrypt(messages).map(IpPacket::new);
        let probes = data.extract_map(|packet| packet.as_ref().ok().and_then(Probe::try_parse));

        DecryptedBatch {
            tunnel: self.tunnel,
            src: self.src,
            dst: self.dst,
            data,
            probes,
        }
    }
}

/// The outcome of a [`PendingDecapsulate`], awaiting
/// [`Node::commit_decrypted`](crate::Node::commit_decrypted).
pub struct DecryptedBatch {
    pub(crate) tunnel: sanstun::TunnelId,
    pub(crate) src: SocketAddr,
    pub(crate) dst: SocketAddr,
    pub(crate) data: sanstun::DecryptedBatch<Result<IpPacket>>,
    /// The path agent's probes, which never reach the TUN device.
    pub(crate) probes: sanstun::DecryptedBatch<Probe>,
}

type CommittedPacket = std::result::Result<sanstun::Committed<Result<IpPacket>>, sanstun::Error>;

/// The packets of a [`DecryptedBatch`] committed to their connection, in order.
///
/// Yields `Ok(None)` for a packet that was handled internally, for example, a keepalive.
pub struct CommittedBatch<TId> {
    cid: TId,
    packets: Prefetching<sanstun::CommittedBatch<Result<IpPacket>>, fn(&CommittedPacket) -> &[u8]>,
}

impl<TId: Copy> CommittedBatch<TId> {
    /// Returns the connection the packets were received on.
    pub fn cid(&self) -> TId {
        self.cid
    }

    pub(crate) fn new(cid: TId, packets: sanstun::CommittedBatch<Result<IpPacket>>) -> Self {
        // The worker thread wrote the packets, so fetch the next one while handling this one.
        Self {
            cid,
            packets: packets.prefetching_with(packet_bytes),
        }
    }
}

impl<TId: fmt::Display> Iterator for CommittedBatch<TId> {
    type Item = Result<Option<IpPacket>>;

    fn next(&mut self) -> Option<Self::Item> {
        let packet = match self.packets.next()? {
            Ok(sanstun::Committed::Data {
                buffer: Ok(packet), ..
            }) => Ok(Some(packet)),
            Ok(sanstun::Committed::Data { buffer: Err(e), .. }) => Err(e
                .context("Failed to parse IP packet")
                .context(format!("cid={}", self.cid))),
            Ok(sanstun::Committed::Keepalive) => Ok(None),
            Err(e) => Err(anyhow::Error::new(e)
                .context("Failed to commit data packet")
                .context(format!("cid={}", self.cid))),
        };

        Some(packet)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.packets.size_hint()
    }
}

impl<TId: fmt::Display> ExactSizeIterator for CommittedBatch<TId> {}

fn packet_bytes(committed: &CommittedPacket) -> &[u8] {
    match committed {
        Ok(sanstun::Committed::Data {
            buffer: Ok(packet), ..
        }) => packet.packet(),
        _ => &[],
    }
}
