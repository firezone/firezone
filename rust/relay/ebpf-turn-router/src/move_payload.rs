use aya_ebpf::{helpers::bpf_xdp_adjust_tail, programs::XdpContext};
use network_types::{
    eth::EthHdr,
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

use crate::{channel_data::CdHdr, error::Error};

// Set an upper limit for bounds checks
const MAX_MTU: usize = 1500;
const MAX_PAYLOAD: usize = MAX_MTU - EthHdr::LEN - Ipv4Hdr::LEN - UdpHdr::LEN - CdHdr::LEN;

#[inline(always)]
pub fn add_channel_data_header_ipv4(ctx: &XdpContext, header: CdHdr) -> Result<(), Error> {
    extend_and_shift_backward::<{ Ipv4Hdr::LEN }>(ctx, &header)
}

#[inline(always)]
pub fn add_channel_data_header_ipv6(ctx: &XdpContext, header: CdHdr) -> Result<(), Error> {
    extend_and_shift_backward::<{ Ipv6Hdr::LEN }>(ctx, &header)
}

#[inline(always)]
pub fn remove_channel_data_header_ipv4(ctx: &XdpContext) -> Result<(), Error> {
    shift_forward_and_shrink::<{ Ipv4Hdr::LEN }>(ctx)
}

#[inline(always)]
pub fn remove_channel_data_header_ipv6(ctx: &XdpContext) -> Result<(), Error> {
    shift_forward_and_shrink::<{ Ipv6Hdr::LEN }>(ctx)
}

/// Extend tail by `CdHdr::LEN` and write `CdHdr` at the front of the payload.
#[inline(never)]
fn extend_and_shift_backward<const IP_HEADER_LEN: usize>(
    ctx: &XdpContext,
    header: &CdHdr,
) -> Result<(), Error> {
    let off = payload_offset::<IP_HEADER_LEN>();

    // Bounds check for verifier
    if ctx.data() + off > ctx.data_end() {
        return Err(Error::PacketTooShort);
    }

    // Extend tail
    let ret = unsafe { bpf_xdp_adjust_tail(ctx.ctx, CdHdr::LEN as i32) };
    if ret < 0 {
        return Err(Error::XdpAdjustTailFailed(ret));
    }

    let data_size = ctx.data_end() - ctx.data();

    // Copy payload
    let original_data_size = data_size - CdHdr::LEN;
    let payload_size = original_data_size - off;
    let src_off = off as i32;
    let dst_off = (off + CdHdr::LEN) as i32;

    copy_payload(ctx, src_off, dst_off, payload_size)?;

    // Write header
    let data_start = ctx.data();
    let data_end = ctx.data_end();

    // Verify the header write location is within bounds
    if data_start + off + CdHdr::LEN > data_end {
        return Err(Error::PacketTooShort);
    }

    let src_ptr = header as *const CdHdr;
    let dst_ptr = data_start + off;
    unsafe {
        core::ptr::copy_nonoverlapping(src_ptr as *const u8, dst_ptr as *mut u8, CdHdr::LEN);
    }

    Ok(())
}

/// Slide payload toward head by `CdHdr::LEN` and shrink tail by `CdHdr::LEN`.
#[inline(never)]
fn shift_forward_and_shrink<const IP_HEADER_LEN: usize>(ctx: &XdpContext) -> Result<(), Error> {
    let off = payload_offset::<IP_HEADER_LEN>();

    if ctx.data() + off > ctx.data_end() {
        return Err(Error::PacketTooShort);
    }

    let data_size = ctx.data_end() - ctx.data();

    // Copy payload
    let remaining = data_size - off - CdHdr::LEN;
    let src_off = (off + CdHdr::LEN) as i32;
    let dst_off = off as i32;

    copy_payload(ctx, src_off, dst_off, remaining)?;

    // Trim the now-unused bytes from the tail
    let ret = unsafe { bpf_xdp_adjust_tail(ctx.ctx, -(CdHdr::LEN as i32)) };
    if ret < 0 {
        return Err(Error::XdpAdjustTailFailed(ret));
    }

    Ok(())
}

#[inline(always)]
fn payload_offset<const IP_HEADER_LEN: usize>() -> usize {
    EthHdr::LEN + IP_HEADER_LEN + UdpHdr::LEN
}

/// Copy payload by `n` bytes with direction determined by src/dst relationship.
/// When dst > src, we copy forward (ascending) to avoid overlaps.
/// When dst < src, we copy backward (descending) to avoid overlaps.
///
/// This is performed in a single pass using binary decomposition from 1024 down to 1 byte.
/// This done because the verifier doesn't like non compile-time guarantees that pointers
/// are within bounds, and the variable length payload can cause an issue.
#[inline(never)]
fn copy_payload(
    ctx: &XdpContext,
    mut src_off: i32,
    mut dst_off: i32,
    n: usize,
) -> Result<(), Error> {
    if n > MAX_PAYLOAD {
        return Err(Error::PacketTooLong);
    }

    // Get data pointers once at the start
    let data_start = ctx.data() as *const u8;
    let data_end = ctx.data_end() as *const u8;

    // Determine direction: -1 for backward (when dst > src), 1 for forward
    let dir: i32 = if dst_off > src_off { -1 } else { 1 };

    // If copying backward, start from the end
    if dir < 0 {
        src_off += n as i32;
        dst_off += n as i32;
    }

    let m = n;
    if (m & 1024) != 0 {
        let step = 1024 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<1024>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 512) != 0 {
        let step = 512 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<512>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 256) != 0 {
        let step = 256 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<256>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 128) != 0 {
        let step = 128 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<128>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 64) != 0 {
        let step = 64 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<64>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 32) != 0 {
        let step = 32 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<32>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 16) != 0 {
        let step = 16 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<16>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 8) != 0 {
        let step = 8 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<8>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 4) != 0 {
        let step = 4 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<4>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 2) != 0 {
        let step = 2 * dir;
        src_off += step;
        dst_off += step;
        copy_n::<2>(data_start, data_end, src_off, dst_off)?;
    }
    if (m & 1) != 0 {
        let step = dir;
        src_off += step;
        dst_off += step;
        copy_n::<1>(data_start, data_end, src_off, dst_off)?;
    }

    Ok(())
}

/// Copy N bytes within the packet (memmove-like).
#[inline(always)]
fn copy_n<const N: usize>(
    data_start: *const u8,
    data_end: *const u8,
    src_off: i32,
    dst_off: i32,
) -> Result<(), Error> {
    // Appeases the verifier 🤷🏻‍♂️
    let bounded_src_off = (src_off as usize) & 0x7ff;
    let bounded_dst_off = (dst_off as usize) & 0x7ff;

    // Maximum bounds check to help the verifier
    if bounded_src_off > MAX_PAYLOAD || bounded_dst_off > MAX_PAYLOAD {
        return Err(Error::PacketTooShort);
    }

    // SAFETY: These are simply offset calculations that are more verifier-friendly.
    let src = unsafe { data_start.add(bounded_src_off) };
    let dst = unsafe { data_start.add(bounded_dst_off) as *mut u8 };
    let src_end = unsafe { src.add(N) };
    let dst_end = unsafe { dst.add(N) };

    if src_end > data_end || (dst_end as *const u8) > data_end {
        return Err(Error::PacketTooShort);
    }

    // Overlap-safe copy (memmove-like)
    unsafe {
        core::ptr::copy(src, dst, N);
    }

    Ok(())
}
