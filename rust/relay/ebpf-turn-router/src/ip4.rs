use core::net::Ipv4Addr;

use crate::{Error, checksum::ChecksumUpdate, ref_mut_at::ref_mut_at};
use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::debug;
use network_types::{
    eth::EthHdr,
    ip::{IpProto, Ipv4Hdr},
};

/// Represents an IPv4 header within our packet.
pub struct Ip4<'a> {
    ctx: &'a XdpContext,
    inner: &'a mut Ipv4Hdr,
}

impl<'a> Ip4<'a> {
    #[inline(always)]
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        let ip4_hdr = ref_mut_at::<Ipv4Hdr>(ctx, EthHdr::LEN)?;

        // IPv4 packets with options are handled in user-space.
        if usize::from(ip4_hdr.ihl()) * 4 != Ipv4Hdr::LEN {
            return Err(Error::Ipv4PacketWithOptions);
        }

        Ok(Self {
            ctx,
            inner: ip4_hdr,
        })
    }

    pub fn src(&self) -> Ipv4Addr {
        self.inner.src_addr.into()
    }

    pub fn dst(&self) -> Ipv4Addr {
        self.inner.dst_addr.into()
    }

    pub fn protocol(&self) -> IpProto {
        self.inner.proto
    }

    pub fn total_len(&self) -> u16 {
        u16::from_be_bytes(self.inner.tot_len)
    }

    /// Update this packet with a new source, destination, and total length.
    ///
    /// Returns a [`ChecksumUpdate`] representing the checksum-difference of the "IP pseudo-header."
    /// which is used in certain L4 protocols (e.g. UDP).
    #[inline(always)]
    pub fn update(self, new_src: Ipv4Addr, new_dst: Ipv4Addr, new_len: u16) -> ChecksumUpdate {
        let src = self.src();
        let dst = self.dst();
        let total_len = self.total_len();

        self.inner.src_addr = new_src.octets();
        self.inner.dst_addr = new_dst.octets();
        self.inner.tot_len = new_len.to_be_bytes();

        let ip_pseudo_header = ChecksumUpdate::default()
            .remove_u32(src.to_bits())
            .add_u32(new_src.to_bits())
            .remove_u32(dst.to_bits())
            .add_u32(new_dst.to_bits());

        self.inner.check = ChecksumUpdate::new(u16::from_be_bytes(self.inner.check))
            .remove_u32(src.to_bits())
            .add_u32(new_src.to_bits())
            .remove_u32(dst.to_bits())
            .add_u32(new_dst.to_bits())
            .remove_u16(total_len)
            .add_u16(new_len)
            .into_checksum()
            .to_be_bytes();

        debug!(
            self.ctx,
            "IP4 header update: src {:i} -> {:i}; dst {:i} -> {:i}", src, new_src, dst, new_dst,
        );

        ip_pseudo_header
    }
}
