use crate::{Error, slice_mut_at::slice_mut_at, udp::UdpHdr};
use aya_ebpf::programs::XdpContext;
use network_types::eth::EthHdr;

/// Represents a channel-data header within our packet.
pub struct ChannelData<'a> {
    inner: &'a mut CdHdr,

    _ctx: &'a XdpContext,
}

impl<'a> ChannelData<'a> {
    #[inline(always)]
    pub fn parse(ctx: &'a XdpContext, ip_header_length: usize) -> Result<Self, Error> {
        let hdr = slice_mut_at::<CdHdr>(ctx, EthHdr::LEN + ip_header_length + UdpHdr::LEN)?;

        if !(0x4000..0x4FFF).contains(&u16::from_be_bytes(hdr.number)) {
            return Err(Error::NotAChannelDataMessage);
        }

        // The eBPF verifier doesn't allow you to use data read from the packet to index into the packet.
        // Hence, we cannot read the length of the channel-data message and use it on the packet.
        // So what we do instead is, we check how many bytes we have left in the packet and compare it to the length we read.
        let length = remaining_bytes(
            ctx,
            EthHdr::LEN + ip_header_length + UdpHdr::LEN + CdHdr::LEN,
        )?;

        // We received less (or more) data than the header said we would.
        if length != usize::from(u16::from_be_bytes(hdr.length)) {
            return Err(Error::BadChannelDataLength);
        }

        // After we have verified the length, we don't need it anymore.

        Ok(Self {
            inner: hdr,
            _ctx: ctx,
        })
    }

    pub fn number(&self) -> u16 {
        u16::from_be_bytes(self.inner.number)
    }

    pub fn length(&self) -> u16 {
        u16::from_be_bytes(self.inner.length)
    }
}

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct CdHdr {
    pub number: [u8; 2],
    pub length: [u8; 2],
}

impl CdHdr {
    pub const LEN: usize = core::mem::size_of::<Self>();
}

/// Computes how many more bytes we have in the packet after a given offset.
#[inline(always)]
fn remaining_bytes(ctx: &XdpContext, offset: usize) -> Result<usize, Error> {
    let start = ctx.data() + offset;
    let end = ctx.data_end();

    if start > end {
        return Err(Error::PacketTooShort);
    }

    let len = end - start;

    Ok(len)
}
