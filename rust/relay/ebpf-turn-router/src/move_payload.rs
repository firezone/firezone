use crate::{channel_data::CdHdr, error::Error};
use aya_ebpf::{helpers::bpf_xdp_adjust_tail, programs::XdpContext};
use network_types::{
    eth::EthHdr,
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

// Set an upper limit for bounds checks
const MAX_MTU: usize = 1500;
const MAX_PAYLOAD: usize = MAX_MTU - EthHdr::LEN - Ipv4Hdr::LEN - UdpHdr::LEN - CdHdr::LEN;

#[inline(always)]
pub fn add_channel_data_header_ipv4(ctx: &XdpContext, header: CdHdr) -> Result<(), Error> {
    adjust_header::<{ Ipv4Hdr::LEN }>(ctx, Some(&header))
}

#[inline(always)]
pub fn add_channel_data_header_ipv6(ctx: &XdpContext, header: CdHdr) -> Result<(), Error> {
    adjust_header::<{ Ipv6Hdr::LEN }>(ctx, Some(&header))
}

#[inline(always)]
pub fn remove_channel_data_header_ipv4(ctx: &XdpContext) -> Result<(), Error> {
    adjust_header::<{ Ipv4Hdr::LEN }>(ctx, None)
}

#[inline(always)]
pub fn remove_channel_data_header_ipv6(ctx: &XdpContext) -> Result<(), Error> {
    adjust_header::<{ Ipv6Hdr::LEN }>(ctx, None)
}

/// Add or remove channel data header
#[inline(never)]
fn adjust_header<const IP_HEADER_LEN: usize>(
    ctx: &XdpContext,
    header: Option<&CdHdr>,
) -> Result<(), Error> {
    let offset = EthHdr::LEN + IP_HEADER_LEN + UdpHdr::LEN;

    if let Some(hdr) = header {
        // Adding header - extend first, then copy
        let ret = unsafe { bpf_xdp_adjust_tail(ctx.ctx, CdHdr::LEN as i32) };
        if ret < 0 {
            return Err(Error::XdpAdjustTailFailed(ret));
        }

        let data_start = ctx.data();
        let data_end = ctx.data_end();

        // Copy payload backward starting at end
        copy_bytes(
            data_start, data_end, offset, true, // backward
        );

        // Write header byte by byte
        let hdr_dst = data_start + offset;
        let hdr_src = hdr as *const CdHdr as *const u8;

        // Copy 4 bytes of CdHdr
        for i in 0..4 {
            if hdr_dst + i < data_end {
                let dst_ptr = (hdr_dst + i) as *mut u8;
                unsafe {
                    let src_byte = *hdr_src.add(i);
                    *dst_ptr = src_byte;
                }
            }
        }
    } else {
        // Removing header - copy first, then shrink
        let data_start = ctx.data();
        let data_end = ctx.data_end();

        // Copy payload forward
        copy_bytes(
            data_start, data_end, offset, false, // forward
        );

        // Now shrink
        let ret = unsafe { bpf_xdp_adjust_tail(ctx.ctx, -(CdHdr::LEN as i32)) };
        if ret < 0 {
            return Err(Error::XdpAdjustTailFailed(ret));
        }
    }

    Ok(())
}

/// Copy bytes from src_offset to dst_offset being mindful of overlap.
/// Bounds are checked often to appease the verifier. This implementation
/// is used over core::ptr::copy because it avoids LLVM from unrolling the
/// loop which can create large code that the verifier struggles with.
#[inline(always)]
fn copy_bytes(data_start: usize, data_end: usize, offset: usize, backward: bool) {
    if backward {
        // First we need to walk the data to determine the location of the destination offset
        let mut dst_offset = offset + CdHdr::LEN - 1;
        loop {
            if data_start + dst_offset >= data_end {
                break; // Prevent writing out of bounds
            }

            dst_offset += 1;
        }

        // From there, we know the src offset
        let mut src_offset = dst_offset - CdHdr::LEN;

        loop {
            // Now copy bytes from src to dst
            let src_ptr = (data_start + src_offset) as *const u8;
            let dst_ptr = (data_start + dst_offset) as *mut u8;

            if data_start + dst_offset >= data_end {
                return; // Prevent writing out of bounds
            }

            unsafe {
                *dst_ptr = *src_ptr;
            }

            src_offset -= 1;
            dst_offset -= 1;
        }
    } else {
        // Copy forward
        let mut src_offset = offset + CdHdr::LEN;
        let mut dst_offset = offset;

        loop {
            // Quick sanity check to avoid verifier issues
            if src_offset >= MAX_PAYLOAD {
                return;
            }

            // Now copy bytes from src to dst
            let src_ptr = (data_start + src_offset) as *const u8;
            let dst_ptr = (data_start + dst_offset) as *mut u8;

            if data_start + src_offset >= data_end {
                return; // Prevent writing out of bounds
            }

            unsafe {
                *dst_ptr = *src_ptr;
            }

            src_offset += 1;
            dst_offset += 1;
        }
    }
}
