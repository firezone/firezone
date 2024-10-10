use std::collections::VecDeque;

use ip_packet::{IpPacket, IpPacketBuf};

/// An adapter struct between our managed TUN device and [`smoltcp`].
pub(crate) struct SmolDeviceAdapter {
    /// Packets that we have received on the TUN device and selected to be processed by [`smoltcp`].
    pub(crate) inbound_packets: VecDeque<IpPacket>,
    pub(crate) outbound_packets: VecDeque<IpPacket>,
}

impl smoltcp::phy::Device for SmolDeviceAdapter {
    type RxToken<'a> = SmolRxToken;
    type TxToken<'a> = SmolTxToken<'a>;

    fn receive(
        &mut self,
        _timestamp: smoltcp::time::Instant,
    ) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let rx_token = SmolRxToken {
            packet: self.inbound_packets.pop_front()?,
        };
        let tx_token = SmolTxToken {
            outbound_packets: &mut self.outbound_packets,
        };

        Some((rx_token, tx_token))
    }

    fn transmit(&mut self, _timestamp: smoltcp::time::Instant) -> Option<Self::TxToken<'_>> {
        Some(SmolTxToken {
            outbound_packets: &mut self.outbound_packets,
        })
    }

    fn capabilities(&self) -> smoltcp::phy::DeviceCapabilities {
        let mut caps = smoltcp::phy::DeviceCapabilities::default();
        caps.medium = smoltcp::phy::Medium::Ip;
        caps.max_transmission_unit = ip_packet::PACKET_SIZE;

        caps
    }
}

pub(crate) struct SmolTxToken<'a> {
    outbound_packets: &'a mut VecDeque<IpPacket>,
}

impl<'a> smoltcp::phy::TxToken for SmolTxToken<'a> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut ip_packet_buf = IpPacketBuf::new();
        let result = f(ip_packet_buf.buf());

        let mut ip_packet = IpPacket::new(ip_packet_buf, len).unwrap();
        ip_packet.update_checksum();
        self.outbound_packets.push_back(ip_packet);

        result
    }
}

pub(crate) struct SmolRxToken {
    packet: IpPacket,
}

impl smoltcp::phy::RxToken for SmolRxToken {
    fn consume<R, F>(mut self, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        f(self.packet.packet_mut())
    }
}
