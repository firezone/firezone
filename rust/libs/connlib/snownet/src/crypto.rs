use std::net::SocketAddr;

use anyhow::Result;
use ip_packet::{IpPacket, IpPacketBuf};

use crate::node::Transmit;

/// Where to send an outgoing packet, with its WireGuard counter reserved.
///
/// Encrypting needs no access to the [`Node`](crate::Node), so it can happen on any thread.
#[derive(Debug)]
pub struct PendingEncapsulate {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    channel: Option<u16>,
    pending: sanstun::PendingEncapsulate,
}

impl PendingEncapsulate {
    pub(crate) fn new(
        src: Option<SocketAddr>,
        dst: SocketAddr,
        channel: Option<u16>,
        pending: sanstun::PendingEncapsulate,
    ) -> Self {
        Self {
            src,
            dst,
            channel,
            pending,
        }
    }

    pub fn src(&self) -> Option<SocketAddr> {
        self.src
    }

    pub fn dst(&self) -> SocketAddr {
        self.dst
    }

    /// Returns the length of the datagram written by [`PendingEncapsulate::encrypt_into`].
    pub fn datagram_len(&self, packet: &IpPacket) -> usize {
        let channel_data_overhead = match self.channel {
            Some(_) => ip_packet::DATA_CHANNEL_OVERHEAD,
            None => 0,
        };

        channel_data_overhead + packet.packet().len().next_multiple_of(16) + ip_packet::WG_OVERHEAD
    }

    /// Encrypts `packet`, the one passed to [`Node::encapsulate`](crate::Node::encapsulate), into
    /// `dst`, which must be [`PendingEncapsulate::datagram_len`] bytes long.
    pub fn encrypt_into(self, packet: &IpPacket, dst: &mut [u8]) -> Result<(), sanstun::Error> {
        let message = match self.channel {
            Some(channel) => {
                let (header, message) = dst.split_at_mut(ip_packet::DATA_CHANNEL_OVERHEAD);
                crate::channel_data::encode_header_to_slice(header, channel, message.len());

                message
            }
            None => dst,
        };

        self.pending.encrypt(packet.packet(), message)?;

        Ok(())
    }

    /// Encrypts `packet` into a standalone [`Transmit`].
    pub fn encrypt(self, packet: &IpPacket) -> Result<Transmit, sanstun::Error> {
        let src = self.src;
        let dst = self.dst;

        let mut payload = crate::DATAGRAMS.pull();
        payload.resize(self.datagram_len(packet), 0);
        self.encrypt_into(packet, &mut payload)?;

        Ok(Transmit {
            src,
            dst,
            payload,
            ecn: packet.ecn(),
        })
    }
}

/// A WireGuard data message that passed the replay check and awaits decryption.
///
/// Decrypting needs no access to the [`Node`](crate::Node), so it can happen on any thread.
pub struct PendingDecapsulate {
    tunnel: sanstun::TunnelId,
    src: SocketAddr,
    dst: SocketAddr,
    /// Where the WireGuard message starts in the datagram; it takes up the rest of it.
    offset: usize,
    pending: sanstun::PendingDecapsulate,
}

impl PendingDecapsulate {
    pub(crate) fn new(
        tunnel: sanstun::TunnelId,
        src: SocketAddr,
        dst: SocketAddr,
        offset: usize,
        pending: sanstun::PendingDecapsulate,
    ) -> Self {
        Self {
            tunnel,
            src,
            dst,
            offset,
            pending,
        }
    }

    /// Decrypts the message from `datagram`, the one passed to [`Node::begin_decapsulate`](crate::Node::begin_decapsulate).
    ///
    /// Commit the result with [`Node::commit_decrypted`](crate::Node::commit_decrypted).
    pub fn decrypt(self, datagram: &[u8]) -> DecryptedIpPacket {
        let message = datagram.get(self.offset..).unwrap_or_default();

        DecryptedIpPacket {
            tunnel: self.tunnel,
            src: self.src,
            dst: self.dst,
            decrypted: self
                .pending
                .decrypt(message, IpPacketBuf::new())
                .map(IpPacket::new),
        }
    }
}

/// The outcome of a [`PendingDecapsulate`].
pub struct DecryptedIpPacket {
    pub(crate) tunnel: sanstun::TunnelId,
    pub(crate) src: SocketAddr,
    pub(crate) dst: SocketAddr,
    pub(crate) decrypted: sanstun::Decrypted<Result<IpPacket>>,
}
