use std::net::SocketAddr;

use ip_packet::{Ecn, IpPacket};
use sanstun::PendingEncapsulate;

use crate::node::Transmit;

/// Encrypts the data messages produced by [`Node::encapsulate`](crate::Node::encapsulate).
///
/// Implementations may encrypt right away or hand the job to another thread.
pub trait Encryptor {
    fn encrypt(&mut self, job: EncryptJob);
}

/// An IP packet to encrypt into a WireGuard data message whose counter is already reserved.
///
/// Encrypting needs no access to the [`Node`](crate::Node), so it can happen on any thread.
pub struct EncryptJob {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    channel: Option<u16>,
    pending: PendingEncapsulate,
    packet: IpPacket,
}

impl EncryptJob {
    pub(crate) fn new(
        src: Option<SocketAddr>,
        dst: SocketAddr,
        channel: Option<u16>,
        pending: PendingEncapsulate,
        packet: IpPacket,
    ) -> Self {
        Self {
            src,
            dst,
            channel,
            pending,
            packet,
        }
    }

    pub fn src(&self) -> Option<SocketAddr> {
        self.src
    }

    pub fn dst(&self) -> SocketAddr {
        self.dst
    }

    pub fn ecn(&self) -> Ecn {
        self.packet.ecn()
    }

    /// Returns the IP packet to be encrypted.
    pub fn packet(&self) -> &IpPacket {
        &self.packet
    }

    /// Returns the length of the datagram written by [`EncryptJob::encrypt_into`].
    pub fn datagram_len(&self) -> usize {
        let channel_data_overhead = match self.channel {
            Some(_) => ip_packet::DATA_CHANNEL_OVERHEAD,
            None => 0,
        };

        channel_data_overhead
            + self.packet.packet().len().next_multiple_of(16)
            + ip_packet::WG_OVERHEAD
    }

    /// Encrypts the packet into `dst`, which must be [`EncryptJob::datagram_len`] bytes long.
    pub fn encrypt_into(self, dst: &mut [u8]) -> Result<(), sanstun::Error> {
        let message = match self.channel {
            Some(channel) => {
                let (header, message) = dst.split_at_mut(ip_packet::DATA_CHANNEL_OVERHEAD);
                crate::channel_data::encode_header_to_slice(header, channel, message.len());

                message
            }
            None => dst,
        };

        self.pending.encrypt(self.packet.packet(), message)?;

        Ok(())
    }

    /// Encrypts the packet into a standalone [`Transmit`].
    pub fn encrypt(self) -> Result<Transmit, sanstun::Error> {
        let src = self.src;
        let dst = self.dst;
        let ecn = self.ecn();

        let mut payload = crate::DATAGRAMS.pull();
        payload.resize(self.datagram_len(), 0);
        self.encrypt_into(&mut payload)?;

        Ok(Transmit {
            src,
            dst,
            payload,
            ecn,
        })
    }
}
