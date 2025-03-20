#![cfg_attr(not(test), no_std)]
#![cfg_attr(not(test), no_main)]

use crate::error::Error;
use aya_ebpf::{
    bindings::xdp_action,
    cty::c_void,
    helpers::{bpf_xdp_adjust_head, bpf_xdp_load_bytes, bpf_xdp_store_bytes},
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use checksum::ChecksumUpdate;
use ebpf_shared::{ClientAndChannelV4, PortAndPeerV4};
use etherparse::{
    EtherType, Ethernet2Header, Ethernet2HeaderSlice, IpNumber, Ipv4Header, Ipv4HeaderSlice,
    Ipv6Header, UdpHeader, UdpHeaderSlice,
};
use etherparse_ext::{Ipv4HeaderSliceMut, UdpHeaderSliceMut};

mod checksum;
mod error;

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
    let ipv4_slice = slice_mut_at::<{ Ipv4Header::MIN_LEN }>(ctx, Ethernet2Header::LEN)?;
    let ipv4 = parse_ipv4(ipv4_slice)?;

    // IPv4 packets with options are handled in user-space.
    if usize::from(ipv4.ihl() * 4) != Ipv4Header::MIN_LEN {
        return Ok(xdp_action::XDP_PASS);
    }

    // We only handle UDP packets.
    let IpNumber::UDP = ipv4.protocol() else {
        return Ok(xdp_action::XDP_PASS);
    };

    let udp_slice =
        slice_mut_at::<{ UdpHeader::LEN }>(ctx, Ethernet2Header::LEN + Ipv4Header::MIN_LEN)?;
    let udp = parse_udp(udp_slice)?;

    trace!(
        ctx,
        "New packet from {:i}:{}",
        ipv4.source(),
        udp.source_port()
    );

    if udp.destination_port() == 3478 {
        try_handle_ipv4_channel_data_to_udp(ctx, ipv4_slice, udp_slice)
    } else {
        try_handle_ipv4_udp_to_channel_data(ctx)
    }
}

fn try_handle_ipv4_channel_data_to_udp(
    ctx: &XdpContext,
    ipv4_slice: &mut [u8],
    udp_slice: &mut [u8],
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

    let ipv4 = parse_ipv4(ipv4_slice)?;
    let udp = parse_udp(udp_slice)?;

    let ipv4_checksum = ipv4.header_checksum();

    let dst_port = udp.destination_port();
    let udp_payload_len = udp.length();
    let udp_checksum = udp.checksum();

    let client_and_channel =
        ClientAndChannelV4::new(ipv4.source(), udp.source_port(), channel_number);

    let binding = unsafe { CHAN_TO_UDP_44.get(&client_and_channel) };
    let Some(port_and_peer) = binding else {
        debug!(
            ctx,
            "No channel binding from {:i}:{} for channel {}",
            ipv4.source(),
            udp.source_port(),
            channel_number,
        );

        return Ok(xdp_action::XDP_PASS);
    };

    let src_addr = ipv4.source();
    let src_port = udp.source_port();

    {
        let dst_addr = ipv4.destination();
        let tot_len = ipv4.total_len();

        let new_src_addr = dst_addr; // The IP we received the packet on will be the new source IP.
        let new_tot_len = tot_len - CHANNEL_DATA_HEADER_LEN as u16;

        let mut ipv4_mut = parse_ipv4_mut(ipv4_slice)?;

        ipv4_mut.set_source(new_src_addr);
        ipv4_mut.set_destination(port_and_peer.dest_ip());
        ipv4_mut.set_total_length(new_tot_len.to_be_bytes());

        let new_ipv4_checksum = ChecksumUpdate::new(ipv4_checksum)
            .remove_addr(src_addr)
            .add_addr(new_src_addr)
            .remove_addr(dst_addr)
            .add_addr(port_and_peer.dest_ip())
            .remove_u16(tot_len)
            .add_u16(new_tot_len)
            .into_checksum();

        ipv4_mut.set_checksum(new_ipv4_checksum);

        trace!(
            ctx,
            "Updating IP checksum from {:x} to {:x}",
            ipv4_checksum,
            new_ipv4_checksum
        );

        // Parts of the UDP checksum come from a pseudo header.
        let ip_pseudo_header = ChecksumUpdate::new(udp_checksum)
            .remove_addr(src_addr)
            .add_addr(new_src_addr)
            .remove_addr(dst_addr)
            .add_addr(port_and_peer.dest_ip())
            .remove_u16(udp_payload_len)
            .add_u16(udp_payload_len);

        let new_src_port = port_and_peer.allocation_port();
        let new_dst_port = port_and_peer.dest_port();
        let new_udp_payload_len = udp_payload_len - CHANNEL_DATA_HEADER_LEN as u16;

        let mut udp_mut = parse_udp_mut(udp_slice)?;

        udp_mut.set_source_port(new_src_port);
        udp_mut.set_destination_port(new_dst_port);
        udp_mut.set_length(new_udp_payload_len);

        let new_udp_checksum = ip_pseudo_header
            .remove_u16(src_port)
            .add_u16(new_src_port)
            .remove_u16(dst_port)
            .add_u16(new_dst_port)
            .remove_u16(udp_payload_len)
            .add_u16(udp_payload_len)
            .remove_u16(channel_number)
            .remove_u16(untrusted_channel_data_length)
            .into_checksum();

        udp_mut.set_checksum(new_udp_checksum);

        trace!(
            ctx,
            "Updating UDP checksum from {:x} to {:x}",
            udp_checksum,
            new_udp_checksum
        );
    }

    remove_channel_data_header_ipv4(ctx);

    info!(
        ctx,
        "Redirecting message from {:i}:{} on channel {} to {:i}:{} on port {}",
        src_addr,
        src_port,
        channel_number,
        port_and_peer.dest_ip(),
        port_and_peer.dest_port(),
        port_and_peer.allocation_port()
    );

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
fn parse_udp(slice: &mut [u8]) -> Result<UdpHeaderSlice<'_>, Error> {
    UdpHeaderSlice::from_slice(slice).map_err(|_| Error::UdpHeader)
}

#[inline(always)]
fn parse_udp_mut(slice: &mut [u8]) -> Result<UdpHeaderSliceMut<'_>, Error> {
    UdpHeaderSliceMut::from_slice(slice).map_err(|_| Error::UdpHeader)
}

#[inline(always)]
fn parse_ipv4(slice: &mut [u8]) -> Result<Ipv4HeaderSlice<'_>, Error> {
    Ipv4HeaderSlice::from_slice(slice).map_err(|_| Error::Ipv4Header)
}

#[inline(always)]
fn parse_ipv4_mut(slice: &mut [u8]) -> Result<Ipv4HeaderSliceMut<'_>, Error> {
    Ipv4HeaderSliceMut::from_slice(slice).map_err(|_| Error::Ipv4Header)
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
fn slice_mut_at<const LEN: usize>(ctx: &XdpContext, offset: usize) -> Result<&mut [u8], Error> {
    let start = ctx.data();
    let end = ctx.data_end();

    if start + offset + LEN > end {
        return Err(Error::PacketTooShort);
    }

    Ok(unsafe { core::slice::from_raw_parts_mut((start + offset) as *mut u8, LEN) })
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
