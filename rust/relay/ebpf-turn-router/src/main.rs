#![cfg_attr(not(test), no_std)]
#![cfg_attr(not(test), no_main)]

use crate::error::Error;
use crate::slice_mut_at::slice_mut_at;
use aya_ebpf::{
    bindings::xdp_action,
    cty::c_void,
    helpers::{bpf_xdp_adjust_head, bpf_xdp_load_bytes, bpf_xdp_store_bytes},
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use ebpf_shared::{ClientAndChannelV4, PortAndPeerV4};
use etherparse::{
    EtherType, Ethernet2Header, Ethernet2HeaderSlice, IpNumber, Ipv4Header, Ipv6Header, UdpHeader,
};
use ipv4::Ipv4;
use udp::Udp;

mod checksum;
mod error;
mod ipv4;
mod slice_mut_at;
mod udp;

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

/// Channel mappings from an IPv4 socket + channel number to an IPv4 socket + port.
#[map]
static CHAN_TO_UDP_44: HashMap<ClientAndChannelV4, PortAndPeerV4> =
    HashMap::with_max_entries(0x100000, 0);

#[xdp]
pub fn handle_turn(ctx: XdpContext) -> u32 {
    match try_handle_turn(&ctx) {
        Ok(ret) => ret,
        Err(e) => {
            debug!(&ctx, "Failed to handle packet {}", e);

            xdp_action::XDP_PASS // Re-consider this.
        }
    }
}

const CHANNEL_DATA_HEADER_LEN: usize = 4;

#[inline(always)]
fn try_handle_turn(ctx: &XdpContext) -> Result<u32, Error> {
    let ethhdr_slice = slice_mut_at::<{ Ethernet2Header::LEN }>(ctx, 0)?;
    let ethhdr = parse_eth(ethhdr_slice)?;

    match ethhdr.ether_type() {
        EtherType::IPV4 => try_handle_turn_ipv4(ctx),
        EtherType::IPV6 => try_handle_turn_ipv6(ctx),
        _ => Ok(xdp_action::XDP_PASS),
    }
}

#[inline(always)]
fn try_handle_turn_ipv4(ctx: &XdpContext) -> Result<u32, Error> {
    let ipv4 = Ipv4::parse(ctx)?;

    if ipv4.protocol() != IpNumber::UDP {
        return Ok(xdp_action::XDP_PASS);
    }

    let udp = Udp::parse(ctx)?; // TODO: Change the API so we parse the UDP header _from_ the ipv4 struct?

    trace!(ctx, "New packet from {:i}:{}", ipv4.src(), udp.src());

    if udp.dst() == 3478 {
        try_handle_ipv4_channel_data_to_udp(ctx, ipv4, udp)
    } else {
        try_handle_ipv4_udp_to_channel_data(ctx)
    }
}

fn try_handle_ipv4_channel_data_to_udp(
    ctx: &XdpContext,
    ipv4: Ipv4,
    udp: Udp,
) -> Result<u32, Error> {
    let cdhdr = slice_mut_at::<{ CHANNEL_DATA_HEADER_LEN }>(
        ctx,
        Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN,
    )?;

    if !(64..=79).contains(&cdhdr[0]) {
        return Ok(xdp_action::XDP_PASS);
    }

    let channel_number = u16::from_be_bytes([cdhdr[0], cdhdr[1]]);

    // Untrusted because we read it from the packet.
    let untrusted_channel_data_length = u16::from_be_bytes([cdhdr[2], cdhdr[3]]);

    let channel_data_length = remaining_bytes(
        ctx,
        Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN + CHANNEL_DATA_HEADER_LEN,
    )?;

    // We received less (or more) data than the header said we would.
    if channel_data_length != usize::from(untrusted_channel_data_length) {
        return Ok(xdp_action::XDP_DROP);
    }

    let client_and_channel = ClientAndChannelV4::new(ipv4.src(), udp.src(), channel_number);

    let binding = unsafe { CHAN_TO_UDP_44.get(&client_and_channel) };
    let Some(port_and_peer) = binding else {
        debug!(
            ctx,
            "No channel binding from {:i}:{} for channel {}",
            ipv4.src(),
            udp.src(),
            channel_number,
        );

        return Ok(xdp_action::XDP_PASS);
    };

    let new_src = ipv4.dst(); // The IP we received the packet on will be the new source IP.
    let new_ipv4_total_len = ipv4.total_len() - CHANNEL_DATA_HEADER_LEN as u16;
    let pseudo_header = ipv4.update(new_src, port_and_peer.dest_ip(), new_ipv4_total_len);

    let new_udp_len = udp.len() - CHANNEL_DATA_HEADER_LEN as u16;
    udp.update(
        pseudo_header,
        port_and_peer.allocation_port(),
        port_and_peer.dest_port(),
        new_udp_len,
    );

    remove_channel_data_header_ipv4(ctx);

    Ok(xdp_action::XDP_TX)
}

fn try_handle_turn_ipv6(ctx: &XdpContext) -> Result<u32, Error> {
    Ok(xdp_action::XDP_PASS)
}

fn remove_channel_data_header_ipv4(ctx: &XdpContext) {
    move_headers::<{ CHANNEL_DATA_HEADER_LEN as i32 }, { Ipv4Header::MIN_LEN }>(ctx)
}

fn add_channel_data_header_ipv4(ctx: &XdpContext) {
    move_headers::<{ -(CHANNEL_DATA_HEADER_LEN as i32) }, { Ipv4Header::MIN_LEN }>(ctx)
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

    // Copy the headers back (because we )
    unsafe {
        bpf_xdp_store_bytes(
            ctx.ctx,
            0,
            headers.as_mut_ptr() as *mut c_void,
            (Ethernet2Header::LEN + IP_HEADER_LEN + UdpHeader::LEN) as u32,
        )
    };
}

#[inline(always)]
fn parse_eth(slice: &mut [u8]) -> Result<Ethernet2HeaderSlice<'_>, Error> {
    Ethernet2HeaderSlice::from_slice(slice).map_err(|_| Error::Ethernet2Header)
}

#[inline(always)]
fn try_handle_ipv4_udp_to_channel_data(_: &XdpContext) -> Result<u32, Error> {
    Err(Error::NotImplemented)
}

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
