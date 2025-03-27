use crate::{CHANNEL_DATA_HEADER_LEN, Error, slice_mut_at::slice_mut_at};
use aya_ebpf::programs::XdpContext;
use etherparse::{Ethernet2Header, Ipv4Header, UdpHeader};

/// Represents a channel-data header within our packet.
pub struct ChannelData<'a> {
    number: u16,

    _ctx: &'a XdpContext,
}

impl<'a> ChannelData<'a> {
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        let cdhdr = slice_mut_at::<{ CHANNEL_DATA_HEADER_LEN }>(
            ctx,
            Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN,
        )?;

        if !(64..=79).contains(&cdhdr[0]) {
            return Err(Error::NotAChannelDataMessage);
        }

        let number = u16::from_be_bytes([cdhdr[0], cdhdr[1]]);

        // Untrusted because we read it from the packet.
        let untrusted_channel_data_length = u16::from_be_bytes([cdhdr[2], cdhdr[3]]);

        // The eBPF verifier doesn't allow you to use data read from the packet to index into the packet.
        // Hence, we cannot read the length of the channel-data message and use it on the packet.
        // So what we do instead is, we check how many bytes we have left in the packet and compare it to the length we read.
        let length = remaining_bytes(
            ctx,
            Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN + CHANNEL_DATA_HEADER_LEN,
        )?;

        // We received less (or more) data than the header said we would.
        if length != usize::from(untrusted_channel_data_length) {
            return Err(Error::BadChannelDataLength);
        }

        // After we have verified the length, we don't need it anymore.

        Ok(Self { number, _ctx: ctx })
    }

    pub fn number(&self) -> u16 {
        self.number
    }
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
