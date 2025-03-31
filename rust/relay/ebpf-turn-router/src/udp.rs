use crate::{Error, checksum::ChecksumUpdate, slice_mut_at::slice_mut_at};
use aya_ebpf::programs::XdpContext;
use aya_log_ebpf::debug;
use network_types::eth::EthHdr;

/// Represents a UDP header within our packet.
pub struct Udp<'a> {
    inner: &'a mut UdpHdr,
    ctx: &'a XdpContext,
}

impl<'a> Udp<'a> {
    #[inline(always)]
    pub fn parse(ctx: &'a XdpContext, ip_header_length: usize) -> Result<Self, Error> {
        Ok(Self {
            ctx,
            inner: slice_mut_at::<UdpHdr>(ctx, EthHdr::LEN + ip_header_length)?,
        })
    }

    pub fn src(&self) -> u16 {
        u16::from_be_bytes(self.inner.source)
    }

    pub fn dst(&self) -> u16 {
        u16::from_be_bytes(self.inner.dest)
    }

    pub fn len(&self) -> u16 {
        u16::from_be_bytes(self.inner.len)
    }

    /// Update this packet with a new source, destination, and length.
    #[inline(always)]
    pub fn update(
        self,
        ip_pseudo_header: ChecksumUpdate,
        new_src: u16,
        new_dst: u16,
        new_len: u16,
    ) {
        let src = self.src();
        let dst = self.dst();
        let len = self.len();

        self.inner.source = new_src.to_be_bytes();
        self.inner.dest = new_dst.to_be_bytes();
        self.inner.len = new_len.to_be_bytes();

        let ip_pseudo_header = ip_pseudo_header.remove_u16(len).add_u16(new_len);

        if crate::config::udp_checksum_enabled() {
            self.inner.check = ChecksumUpdate::new(u16::from_be_bytes(self.inner.check))
                .add_update(ip_pseudo_header)
                .remove_u16(len)
                .add_u16(new_len)
                .remove_u16(src)
                .add_u16(new_src)
                .remove_u16(dst)
                .add_u16(new_dst)
                .into_checksum()
                .to_be_bytes()
        } else {
            self.inner.check = [0, 0];
        }

        debug!(
            self.ctx,
            "UDP header update: src {} -> {}; dst {} -> {}; len {} -> {}",
            src,
            new_src,
            dst,
            new_dst,
            len,
            new_len,
        );
    }
}

// Copied from `network-types` but uses byte-arrays instead of `u32` and `u16`
// See <https://github.com/vadorovsky/network-types/issues/32>.
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct UdpHdr {
    pub source: [u8; 2],
    pub dest: [u8; 2],
    pub len: [u8; 2],
    pub check: [u8; 2],
}

impl UdpHdr {
    pub const LEN: usize = core::mem::size_of::<Self>();
}
