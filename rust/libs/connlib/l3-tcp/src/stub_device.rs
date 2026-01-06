use std::collections::VecDeque;

use ip_packet::{IpPacket, IpPacketBuf};

/// A in-memory device for [`smoltcp`] that is entirely backed by buffers.
#[derive(Debug, Default)]
pub struct InMemoryDevice {
    inbound_packets: VecDeque<IpPacket>,
    outbound_packets: VecDeque<IpPacket>,
}

impl InMemoryDevice {
    pub fn receive(&mut self, packet: IpPacket) {
        self.inbound_packets.push_back(packet);
    }

    pub fn next_send(&mut self) -> Option<IpPacket> {
        self.outbound_packets.pop_front()
    }
}

impl smoltcp::phy::Device for InMemoryDevice {
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
        caps.max_transmission_unit = ip_packet::MAX_IP_SIZE;

        caps
    }
}

pub struct SmolTxToken<'a> {
    outbound_packets: &'a mut VecDeque<IpPacket>,
}

impl smoltcp::phy::TxToken for SmolTxToken<'_> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let max_len = ip_packet::MAX_IP_SIZE;

        if len > max_len {
            tracing::warn!("Packets larger than {max_len} are not supported; len={len}");

            let mut buf = Vec::with_capacity(len);
            return f(&mut buf);
        }

        let mut ip_packet_buf = IpPacketBuf::new();
        let result = f(ip_packet_buf.buf());

        let mut ip_packet = match IpPacket::new(ip_packet_buf, len) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!("Received invalid IP packet: {e:#}");
                return result;
            }
        };

        ip_packet.update_checksum();
        self.outbound_packets.push_back(ip_packet);

        result
    }
}

pub struct SmolRxToken {
    packet: IpPacket,
}

impl smoltcp::phy::RxToken for SmolRxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(self.packet.packet())
    }
}
