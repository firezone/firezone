//! Linux `virtio_net_hdr` encoding around the platform-neutral packet coalescer.

use ip_packet::{IpNumber, IpPacket, IpVersion};

use crate::coalesce::{CoalescedPacket, PacketCoalescer};

use super::virtio::*;

const ZEROED_VNET_HDR: [u8; VNET_HDR_LEN] = [0; VNET_HDR_LEN];

/// Coalesces IP packets and formats coalesced outputs as Linux GSO writes.
pub struct TunGsoQueue(PacketCoalescer);

impl TunGsoQueue {
    pub fn new() -> Self {
        Self(PacketCoalescer::gso(VNET_HDR_LEN))
    }

    pub fn enqueue(&mut self, packet: IpPacket) {
        self.0.enqueue(packet);
    }

    pub fn drain(&mut self) -> impl Iterator<Item = Outgoing> + '_ {
        self.0.drain().map(|mut packet| {
            if let Some(offload) = packet.offload() {
                let gso_type = match (offload.protocol, offload.version) {
                    (IpNumber::TCP, IpVersion::V4) => VIRTIO_NET_HDR_GSO_TCPV4,
                    (IpNumber::TCP, IpVersion::V6) => VIRTIO_NET_HDR_GSO_TCPV6,
                    (IpNumber::UDP, _) => VIRTIO_NET_HDR_GSO_UDP_L4,
                    _ => unreachable!("only TCP and UDP packets are coalesced"),
                };
                let csum_offset = match offload.protocol {
                    IpNumber::TCP => 16,
                    IpNumber::UDP => 6,
                    _ => unreachable!("only TCP and UDP packets are coalesced"),
                };

                VirtioNetHdr {
                    flags: VIRTIO_NET_HDR_F_NEEDS_CSUM,
                    gso_type,
                    hdr_len: (offload.ip_hdr_len + offload.l4_hdr_len) as u16,
                    gso_size: offload.seg_size as u16,
                    csum_start: offload.ip_hdr_len as u16,
                    csum_offset,
                }
                .write_to(packet.headroom_mut());
            }

            Outgoing(packet)
        })
    }
}

/// A pending Linux TUN write.
pub struct Outgoing(CoalescedPacket);

impl Outgoing {
    pub fn num_segments(&self) -> usize {
        self.0.num_segments()
    }

    /// The `virtio_net_hdr` and IP packet bytes, ready for `writev`.
    pub fn bufs(&self) -> [&[u8]; 2] {
        if self.0.offload().is_some() {
            [self.0.headroom(), self.0.packet()]
        } else {
            [ZEROED_VNET_HDR.as_slice(), self.0.packet()]
        }
    }
}

impl From<IpPacket> for Outgoing {
    fn from(packet: IpPacket) -> Self {
        Self(CoalescedPacket::from(packet))
    }
}
