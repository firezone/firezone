use core::net::Ipv6Addr;

use crate::{Error, checksum::ChecksumUpdate, ref_mut_at::ref_mut_at};
use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::debug;
use network_types::{
    eth::EthHdr,
    ip::{IpProto, Ipv6Hdr},
};

/// Represents an IPv6 header within our packet.
pub struct Ip6<'a> {
    ctx: &'a XdpContext,
    inner: &'a mut Ipv6Hdr,
}

impl<'a> Ip6<'a> {
    #[inline(always)]
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        Ok(Self {
            ctx,
            inner: ref_mut_at::<Ipv6Hdr>(ctx, EthHdr::LEN)?,
        })
    }

    pub fn src(&self) -> Ipv6Addr {
        self.inner.src_addr.into()
    }

    pub fn dst(&self) -> Ipv6Addr {
        self.inner.dst_addr.into()
    }

    pub fn protocol(&self) -> IpProto {
        self.inner.next_hdr
    }

    pub fn payload_len(&self) -> u16 {
        u16::from_be_bytes(self.inner.payload_len)
    }

    /// Update this packet with a new source, destination, and total length.
    ///
    /// Returns a [`ChecksumUpdate`] representing the checksum-difference of the "IP pseudo-header."
    /// which is used in certain L4 protocols (e.g. UDP).
    #[inline(always)]
    pub fn update(self, new_src: Ipv6Addr, new_dst: Ipv6Addr, new_len: u16) -> ChecksumUpdate {
        let src = self.src();
        let dst = self.dst();

        self.inner.src_addr = new_src.octets();
        self.inner.dst_addr = new_dst.octets();
        self.inner.payload_len = new_len.to_be_bytes();

        let ip_pseudo_header = ChecksumUpdate::default()
            .remove_u128(src.to_bits())
            .add_u128(new_src.to_bits())
            .remove_u128(dst.to_bits())
            .add_u128(new_dst.to_bits());

        debug!(
            self.ctx,
            "IP6 header update: src {:i} -> {:i}; dst {:i} -> {:i}", src, new_src, dst, new_dst,
        );

        ip_pseudo_header
    }
}
