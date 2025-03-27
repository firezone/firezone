use aya_ebpf::programs::XdpContext;

use crate::error::Error;

/// Helper function to get a mutable slice of `LEN` bytes at `offset` from the packet data.
#[inline(always)]
pub fn slice_mut_at<const LEN: usize>(ctx: &XdpContext, offset: usize) -> Result<&mut [u8], Error> {
    let start = ctx.data();
    let end = ctx.data_end();

    // Ensure our access is not out-of-bounds.
    if start + offset + LEN > end {
        return Err(Error::PacketTooShort);
    }

    Ok(unsafe { core::slice::from_raw_parts_mut((start + offset) as *mut u8, LEN) })
}
