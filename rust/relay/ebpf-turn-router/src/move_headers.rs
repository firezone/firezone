use aya_ebpf::{
    cty::c_void,
    helpers::{bpf_xdp_adjust_head, bpf_xdp_load_bytes, bpf_xdp_store_bytes},
    programs::XdpContext,
};
use etherparse::{Ethernet2Header, Ipv4Header, Ipv6Header, UdpHeader};

use crate::CHANNEL_DATA_HEADER_LEN;

pub fn remove_channel_data_header_ipv4(ctx: &XdpContext) {
    move_headers::<{ CHANNEL_DATA_HEADER_LEN as i32 }, { Ipv4Header::MIN_LEN }>(ctx)
}

#[expect(dead_code, reason = "Will be used in the future.")]
pub fn add_channel_data_header_ipv4(ctx: &XdpContext, mut header: [u8; 4]) {
    move_headers::<{ -(CHANNEL_DATA_HEADER_LEN as i32) }, { Ipv4Header::MIN_LEN }>(ctx);
    let offset = (Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN) as u32;

    unsafe {
        bpf_xdp_store_bytes(
            ctx.ctx,
            offset,
            header.as_mut_ptr() as *mut c_void,
            CHANNEL_DATA_HEADER_LEN as u32,
        )
    };
}

fn move_headers<const DELTA: i32, const IP_HEADER_LEN: usize>(ctx: &XdpContext) {
    // Scratch space for our headers.
    // IPv6 headers are always 40 bytes long.
    // IPv4 headers are between 20 and 60 bytes long.
    // We restrict the eBPF program to only handle 20 byte long IPv4 headers.
    // Therefore, we only need to reserver space for IPv6 headers.
    //
    // Ideally, we would just use the const-generic argument here but that is not yet supported ...
    let mut headers = [0u8; Ethernet2Header::LEN + Ipv6Header::LEN + UdpHeader::LEN];

    // Copy headers into buffer.
    unsafe {
        bpf_xdp_load_bytes(
            ctx.ctx,
            0,
            headers.as_mut_ptr() as *mut c_void,
            (Ethernet2Header::LEN + IP_HEADER_LEN + UdpHeader::LEN) as u32,
        );
    }

    // Move the head for the packet by `DELTA`.
    unsafe { bpf_xdp_adjust_head(ctx.ctx, DELTA) };

    // Copy the headers back.
    unsafe {
        bpf_xdp_store_bytes(
            ctx.ctx,
            0,
            headers.as_mut_ptr() as *mut c_void,
            (Ethernet2Header::LEN + IP_HEADER_LEN + UdpHeader::LEN) as u32,
        )
    };
}
