use aya_ebpf::{
    cty::c_void,
    helpers::{bpf_xdp_adjust_head, bpf_xdp_load_bytes, bpf_xdp_store_bytes},
    programs::XdpContext,
};
use network_types::{
    eth::EthHdr,
    ip::{Ipv4Hdr, Ipv6Hdr},
    udp::UdpHdr,
};

use crate::channel_data::CdHdr;

pub fn remove_channel_data_header_ipv4(ctx: &XdpContext) {
    move_headers::<{ CdHdr::LEN as i32 }, { Ipv4Hdr::LEN }>(ctx)
}

pub fn add_channel_data_header_ipv4(ctx: &XdpContext, mut header: [u8; 4]) {
    move_headers::<{ -(CdHdr::LEN as i32) }, { Ipv4Hdr::LEN }>(ctx);
    let offset = (EthHdr::LEN + Ipv4Hdr::LEN + UdpHdr::LEN) as u32;

    let header_ptr = &mut header as *mut _ as *mut c_void;
    let header_len = CdHdr::LEN as u32;

    unsafe { bpf_xdp_store_bytes(ctx.ctx, offset, header_ptr, header_len) };
}

fn move_headers<const DELTA: i32, const IP_HEADER_LEN: usize>(ctx: &XdpContext) {
    // Scratch space for our headers.
    // IPv6 headers are always 40 bytes long.
    // IPv4 headers are between 20 and 60 bytes long.
    // We restrict the eBPF program to only handle 20 byte long IPv4 headers.
    // Therefore, we only need to reserver space for IPv6 headers.
    //
    // Ideally, we would just use the const-generic argument here but that is not yet supported ...
    let mut headers = [0u8; EthHdr::LEN + Ipv6Hdr::LEN + UdpHdr::LEN];

    let headers_ptr = headers.as_mut_ptr() as *mut c_void;
    let headers_len = (EthHdr::LEN + IP_HEADER_LEN + UdpHdr::LEN) as u32;

    // Copy headers into buffer.
    unsafe { bpf_xdp_load_bytes(ctx.ctx, 0, headers_ptr, headers_len) };

    // Move the head for the packet by `DELTA`.
    unsafe { bpf_xdp_adjust_head(ctx.ctx, DELTA) };

    // if ctx.data() + EthHdr::LEN + IP_HEADER_LEN + UdpHdr::LEN + 6 > ctx.data_end() {
    //     return Err(Error::PacketTooShort);
    // }

    // Copy the headers back.
    unsafe { bpf_xdp_store_bytes(ctx.ctx, 0, headers_ptr, headers_len) };
}
