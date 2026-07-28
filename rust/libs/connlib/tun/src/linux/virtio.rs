//! The `virtio_net_hdr` exchanged with the kernel on every read / write of a TUN fd
//! that has `IFF_VNET_HDR` set.
//!
//! See `include/uapi/linux/virtio_net.h` and `include/linux/virtio_net.h` in the kernel sources.

use ip_packet::{IpNumber, IpVersion};
use packet_coalescer::CoalescedPacket;

/// `virtio_net_hdr` is 10 bytes; the TUN driver defaults to this size for `IFF_VNET_HDR`
/// unless changed via `TUNSETVNETHDRSZ`.
pub const VNET_HDR_LEN: usize = 10;

/// The checksum starting at [`VirtioNetHdr::csum_start`] must be completed by the receiver.
///
/// The field at `csum_start + csum_offset` holds the (folded, uncomplemented) pseudo-header
/// checksum; the payload checksum still needs to be summed into it.
pub const VIRTIO_NET_HDR_F_NEEDS_CSUM: u8 = 1;

pub const VIRTIO_NET_HDR_GSO_NONE: u8 = 0;
pub const VIRTIO_NET_HDR_GSO_TCPV4: u8 = 1;
pub const VIRTIO_NET_HDR_GSO_TCPV6: u8 = 4;
pub const VIRTIO_NET_HDR_GSO_UDP_L4: u8 = 5;

/// The TUN driver interprets the multi-byte fields as `__virtio16`,
/// which is native endian for the "legacy" virtio interface the driver defaults to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VirtioNetHdr {
    pub flags: u8,
    pub gso_type: u8,
    pub hdr_len: u16,
    pub gso_size: u16,
    pub csum_start: u16,
    pub csum_offset: u16,
}

impl VirtioNetHdr {
    pub fn parse(buf: &[u8]) -> Option<(Self, &[u8])> {
        let (hdr, packet) = buf.split_at_checked(VNET_HDR_LEN)?;

        Some((
            Self {
                flags: hdr[0],
                gso_type: hdr[1],
                hdr_len: u16::from_ne_bytes([hdr[2], hdr[3]]),
                gso_size: u16::from_ne_bytes([hdr[4], hdr[5]]),
                csum_start: u16::from_ne_bytes([hdr[6], hdr[7]]),
                csum_offset: u16::from_ne_bytes([hdr[8], hdr[9]]),
            },
            packet,
        ))
    }

    pub fn write_to(&self, buf: &mut [u8]) {
        buf[0] = self.flags;
        buf[1] = self.gso_type;
        buf[2..4].copy_from_slice(&self.hdr_len.to_ne_bytes());
        buf[4..6].copy_from_slice(&self.gso_size.to_ne_bytes());
        buf[6..8].copy_from_slice(&self.csum_start.to_ne_bytes());
        buf[8..10].copy_from_slice(&self.csum_offset.to_ne_bytes());
    }

    pub fn to_bytes(self) -> [u8; VNET_HDR_LEN] {
        let mut buf = [0u8; VNET_HDR_LEN];
        self.write_to(&mut buf);

        buf
    }
}

pub fn header_for(packet: &CoalescedPacket) -> [u8; VNET_HDR_LEN] {
    let Some(offload) = packet.offload() else {
        return [0; VNET_HDR_LEN];
    };

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
    .to_bytes()
}
