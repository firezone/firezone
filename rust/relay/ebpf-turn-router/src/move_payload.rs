//! Helpers for moving the UDP payload forward or backward.
//!
//! ## Overview
//!
//! This module shifts the UDP payload forward or packet in order to add or remove the 4-byte
//! TURN channel data header to or from the front of the UDP payload.
//!
//! How this works:
//!
//!
//! ### Adding Channel Data Header (`extend_and_add_header`)
//!
//! Original packet:
//! ┌─────────┬──────┬───────┬─────────────────┐
//! │ ETH HDR │ IP   │ UDP   │ PAYLOAD         │
//! └─────────┴──────┴───────┴─────────────────┘
//! ↑                          ↑                 ↑
//! data                       payload_offset    data_end
//!
//!
//! Step 1: Extend packet tail by 4 bytes (bpf_xdp_adjust_tail)
//! ┌─────────┬──────┬───────┬─────────────────┬────┐
//! │ ETH HDR │ IP   │ UDP   │ PAYLOAD         │new │
//! └─────────┴──────┴───────┴─────────────────┴────┘
//! ↑                                                ↑
//! data                                             data_end (new)
//!
//!
//! Step 2: Copy payload backward by 4 bytes
//! ┌─────────┬──────┬───────┬────┬─────────────────┐
//! │ ETH HDR │ IP   │ UDP   │????│ PAYLOAD         │
//! └─────────┴──────┴───────┴────┴─────────────────┘
//! ↑                          ────→ copy direction  ↑
//! data                                             data_end
//!
//!
//! Step 3: Write channel data header
//! ┌─────────┬──────┬───────┬────┬─────────────────┐
//! │ ETH HDR │ IP   │ UDP   │CDH │ PAYLOAD         │
//! └─────────┴──────┴───────┴────┴─────────────────┘
//! ↑                                                ↑
//! data                                             data_end
//!
//!
//! ### Removing Channel Data Header (`remove_header_and_shrink`)
//!
//! Original packet:
//! ┌─────────┬──────┬───────┬────┬─────────────────┐
//! │ ETH HDR │ IP   │ UDP   │CDH │ PAYLOAD         │
//! └─────────┴──────┴───────┴────┴─────────────────┘
//! ↑                          ↑                     ↑
//! data                       payload_offset        data_end
//!
//!
//! Step 1: Copy payload forward by 4 bytes (overwriting CDH)
//! ┌─────────┬──────┬───────┬─────────────────┬────┐
//! │ ETH HDR │ IP   │ UDP   │ PAYLOAD         │junk│
//! └─────────┴──────┴───────┴─────────────────┴────┘
//! ↑                          ←──── copy direction  ↑
//! data                                             data_end
//!
//!
//! Step 2: Shrink packet tail by 4 bytes (bpf_xdp_adjust_tail)
//! ┌─────────┬──────┬───────┬─────────────────┐
//! │ ETH HDR │ IP   │ UDP   │ PAYLOAD         │
//! └─────────┴──────┴───────┴─────────────────┘
//! ↑                                           ↑
//! data                                        data_end (new)
//!
//!
//! ## Approach
//!
//! Generally there are two approaches to achieve the above:
//!   1. Head adjustment + shift packet headers (42-62 bytes) + add/remove channel data header
//!   2. Tail adjustment + shift payload (0-1454 bytes) + add/remove channel data header
//!
//! Unfortunately, we can't use the first approach because the `gve` driver on GCP does not support
//! `bpf_xdp_adjust_head`, which is required to shift the packet headers forward.
//!
//! Therefore, we use the second approach.
//!
//! To perform the actual shifting, we avoid the use of `bpf_xdp_load_bytes` and
//! `bpf_xdp_store_bytes` because these helpers can often be slower for large byte copies due to
//! the overhead of kernel function calls. Instead, we do a more efficient manual byte copy using raw
//! pointers, keeping in mind the verifier constraints listed below.
//!
//!
//! ## eBPF Verifier Gotchas
//!
//! The eBPF verifier imposes strict constraints that require consideration when manipulating
//! packet data in this module:
//!
//! 1. **No arithmetic on end pointers**: The verifier doesn't allow arithmetic on `data_end`
//!    pointers, so we can't do `data_end - offset`. Instead, we use tracking variables
//!    (`remaining`, `copied`) to index from the start.
//!
//! 2. **Bounded loops**: The verifier needs to prove loops terminate. We use the `MAX_PAYLOAD`
//!    constant to provide an upper bound, preventing the verifier from tracking too many
//!    states (which would exceed the 1M instruction limit).
//!
//! 3. **Backward copying**: When extending the packet, we must copy from the end to avoid
//!    overwriting data we haven't read yet. We find the payload end by counting up, then
//!    copy backward using the `remaining` counter.
//!
//! 4. **Forward copying**: When shrinking, we copy from the beginning forward, using a
//!    `copied` counter to track progress.
//!
//! 5. **Pointer invalidation**: After `bpf_xdp_adjust_tail`, all cached pointers become
//!    invalid and must be re-fetched from the XDP context.
//!
//! 6. **Inline hints**: Functions marked `#[inline(never)]` prevent excessive inlining that
//!    could blow up the instruction count. Functions marked `#[inline(always)]` ensure
//!    critical paths are optimized.
//!
use crate::{channel_data::CdHdr, error::Error};
use aya_ebpf::{helpers::bpf_xdp_adjust_tail, programs::XdpContext};
use network_types::{
    eth::EthHdr,
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

// Set an upper limit for bounds checks
const MAX_MTU: usize = 1500; // does not include Ethernet header
const MAX_PAYLOAD: usize = MAX_MTU - Ipv4Hdr::LEN - UdpHdr::LEN - CdHdr::LEN;

#[inline(always)]
pub fn add_channel_data_header_ipv4(ctx: &XdpContext, header: CdHdr) -> Result<(), Error> {
    extend_and_add_header::<{ Ipv4Hdr::LEN }>(ctx, &header)
}

#[inline(always)]
pub fn add_channel_data_header_ipv6(ctx: &XdpContext, header: CdHdr) -> Result<(), Error> {
    extend_and_add_header::<{ Ipv6Hdr::LEN }>(ctx, &header)
}

#[inline(always)]
pub fn remove_channel_data_header_ipv4(ctx: &XdpContext) -> Result<(), Error> {
    remove_header_and_shrink::<{ Ipv4Hdr::LEN }>(ctx)
}

#[inline(always)]
pub fn remove_channel_data_header_ipv6(ctx: &XdpContext) -> Result<(), Error> {
    remove_header_and_shrink::<{ Ipv6Hdr::LEN }>(ctx)
}

/// Extend the packet by `CdHdr::LEN` bytes and add the channel data header at the front of the
/// payload.
#[inline(never)]
fn extend_and_add_header<const IP_HEADER_LEN: usize>(
    ctx: &XdpContext,
    header: &CdHdr,
) -> Result<(), Error> {
    let payload_offset = EthHdr::LEN + IP_HEADER_LEN + UdpHdr::LEN;

    // 1. Extend the packet by `CdHdr::LEN` bytes
    let ret = unsafe { bpf_xdp_adjust_tail(ctx.ctx, CdHdr::LEN as i32) };
    if ret < 0 {
        return Err(Error::XdpAdjustTailFailed(ret));
    }

    // 2. Get the new packet pointers as they have changed
    let data_start = ctx.data();
    let data_end = ctx.data_end();

    // 3. Copy the payload back by `CdHdr::LEN` bytes to make space for the header
    copy_bytes_backward(data_start, data_end, payload_offset, CdHdr::LEN);

    // 4. Copy header
    let hdr_dst = data_start + payload_offset;
    let hdr_src = header as *const CdHdr as *const u8;

    for i in 0..CdHdr::LEN {
        if hdr_dst + i < data_end {
            let dst_ptr = (hdr_dst + i) as *mut u8;
            unsafe {
                *dst_ptr = *hdr_src.add(i);
            }
        }
    }

    Ok(())
}

/// Remove the channel data header by shifting the payload forward `CdHdr::LEN` bytes, then
/// shrink the packet by the same amount.
#[inline(never)]
fn remove_header_and_shrink<const IP_HEADER_LEN: usize>(ctx: &XdpContext) -> Result<(), Error> {
    let payload_offset = EthHdr::LEN + IP_HEADER_LEN + UdpHdr::LEN;

    let data_start = ctx.data();
    let data_end = ctx.data_end();

    // 1. Copy the payload forward by `CdHdr::LEN` bytes, overwriting the header
    copy_bytes_forward(data_start, data_end, payload_offset, CdHdr::LEN);

    // 2. Shrink the packet by `CdHdr::LEN` bytes
    let ret = unsafe { bpf_xdp_adjust_tail(ctx.ctx, -(CdHdr::LEN as i32)) };
    if ret < 0 {
        return Err(Error::XdpAdjustTailFailed(ret));
    }

    Ok(())
}

/// Copy bytes forward from src_offset to dst_offset by `delta` bytes.
/// Optimized to copy 4 bytes at a time when possible.
#[inline(never)]
fn copy_bytes_forward(data_start: usize, data_end: usize, offset: usize, delta: usize) {
    let mut src_offset = offset + delta;
    let mut dst_offset = offset;
    let mut copied: usize = 0;

    loop {
        // Bounds check to prevent verifier from exploding
        if copied >= MAX_PAYLOAD {
            break;
        }

        // Try to copy 4 bytes if we have enough remaining
        if copied + 4 <= MAX_PAYLOAD && data_start + src_offset + 3 < data_end {
            let src_ptr = (data_start + src_offset) as *const u8;
            let dst_ptr = (data_start + dst_offset) as *mut u8;

            // SAFETY: We verified we have at least 4 bytes available
            unsafe {
                let value = (src_ptr as *const u32).read_unaligned();
                (dst_ptr as *mut u32).write_unaligned(value);
            }
            src_offset += 4;
            dst_offset += 4;
            copied += 4;
        } else if data_start + src_offset < data_end {
            // Fall back to single byte copy
            let src_ptr = (data_start + src_offset) as *const u8;
            let dst_ptr = (data_start + dst_offset) as *mut u8;

            // SAFETY: We verified the bounds above
            unsafe {
                *dst_ptr = *src_ptr;
            }
            src_offset += 1;
            dst_offset += 1;
            copied += 1;
        } else {
            break;
        }
    }
}

/// Copy bytes backward from src_offset to dst_offset by `delta` bytes.
/// Optimized to copy 4 bytes at a time when possible.
#[inline(never)]
fn copy_bytes_backward(data_start: usize, data_end: usize, offset: usize, delta: usize) {
    let mut remaining: usize = 0;

    // Calculate total bytes to copy
    loop {
        if remaining >= MAX_PAYLOAD {
            break;
        }
        if data_start + offset + delta + remaining >= data_end {
            break;
        }
        remaining += 1;
    }

    // Single loop that handles both 4-byte and 1-byte copies
    while remaining > 0 {
        if remaining >= 4 {
            let src_offset = offset + remaining - 4;
            let dst_offset = src_offset + delta;

            // Check bounds for 4-byte access
            if data_start + src_offset + 3 < data_end && data_start + dst_offset + 3 < data_end {
                let src_ptr = (data_start + src_offset) as *const u8;
                let dst_ptr = (data_start + dst_offset) as *mut u8;

                // SAFETY: We verified we have at least 4 bytes available
                unsafe {
                    let value = (src_ptr as *const u32).read_unaligned();
                    (dst_ptr as *mut u32).write_unaligned(value);
                }
                remaining -= 4;
                continue;
            }
        }

        // Fall back to single byte
        let src_offset = offset + remaining - 1;
        let dst_offset = src_offset + delta;

        if data_start + src_offset >= data_end || data_start + dst_offset >= data_end {
            break;
        }

        let src_ptr = (data_start + src_offset) as *const u8;
        let dst_ptr = (data_start + dst_offset) as *mut u8;
        unsafe {
            *dst_ptr = *src_ptr;
        }
        remaining -= 1;
    }
}
