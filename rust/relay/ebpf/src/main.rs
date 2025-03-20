#![no_std]
#![no_main]

use crate::error::Error;
use aya_ebpf::{
    bindings::xdp_action,
    cty::c_void,
    helpers::{bpf_csum_diff, bpf_xdp_adjust_head, bpf_xdp_load_bytes, bpf_xdp_store_bytes},
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use etherparse::{
    EtherType, Ethernet2Header, Ethernet2HeaderSlice, IpNumber, Ipv4Header, Ipv4HeaderSlice,
    UdpHeader, UdpHeaderSlice,
};
use etherparse_ext::{Ipv4HeaderSliceMut, UdpHeaderSliceMut};
use firezone_relay_ebpf_shared::{ClientAndChannel, PortAndPeer};

mod error;

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[map]
static CHANNELS_TO_UDP: HashMap<ClientAndChannel, PortAndPeer> =
    HashMap::with_max_entries(0x1000, 0);

// #[map]
// static UDP_TO_CHANNEL_DATA: HashMap<(AllocationPort, SocketAddr), (ChannelNumber, SocketAddr)> =
//     HashMap::with_max_entries(1024, 0);

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
        EtherType::IPV4 => {}
        _ => return Ok(xdp_action::XDP_PASS),
    }

    let ipv4hdr_slice = slice_mut_at::<{ Ipv4Header::MIN_LEN }>(ctx, Ethernet2Header::LEN)?;
    let ipv4hdr = parse_ipv4(ipv4hdr_slice)?;

    let src_addr = u32::from_be_bytes(ipv4hdr.source());
    let dst_addr = u32::from_be_bytes(ipv4hdr.destination());
    let tot_len = ipv4hdr.total_len();
    let ipv4hdr_length = ipv4hdr.ihl() * 4;
    let ipv4_checksum = ipv4hdr.header_checksum();

    if usize::from(ipv4hdr_length) != Ipv4Header::MIN_LEN {
        return Ok(xdp_action::XDP_PASS);
    }

    let IpNumber::UDP = ipv4hdr.protocol() else {
        return Ok(xdp_action::XDP_PASS);
    };

    let udphdr_slice = slice_mut_at::<{ UdpHeader::LEN }>(
        ctx,
        Ethernet2Header::LEN + usize::from(ipv4hdr_length),
    )?;
    let udphdr = parse_udp(udphdr_slice)?;

    let src_port = udphdr.source_port();
    let dst_port = udphdr.destination_port();
    let udp_payload_len = udphdr.length();
    let udp_checksum = udphdr.checksum();

    trace!(ctx, "New packet from {:i}:{}", src_addr, src_port);

    if dst_port == 3478 {
        let cdhdr = slice_mut_at::<{ CHANNEL_DATA_HEADER_LEN }>(
            ctx,
            Ethernet2Header::LEN + usize::from(ipv4hdr_length) + UdpHeader::LEN,
        )?;

        if !(64..=79).contains(&cdhdr[0]) {
            return Ok(xdp_action::XDP_PASS);
        }

        let channel_number = u16::from_be_bytes([cdhdr[0], cdhdr[1]]);

        // Untrusted because we read it from the packet.
        let untrusted_channel_data_length = u16::from_be_bytes([cdhdr[2], cdhdr[3]]);

        let channel_data_length = remaining_bytes(
            ctx,
            Ethernet2Header::LEN
                + usize::from(ipv4hdr_length)
                + UdpHeader::LEN
                + CHANNEL_DATA_HEADER_LEN,
        )?;

        // We received less (or more) data than the header said we would.
        if channel_data_length != usize::from(untrusted_channel_data_length) {
            return Ok(xdp_action::XDP_DROP);
        }

        let client_and_channel = ClientAndChannel::new(src_addr, src_port, channel_number);

        let binding = unsafe { CHANNELS_TO_UDP.get(&client_and_channel) };
        let Some(port_and_peer) = binding else {
            debug!(
                ctx,
                "No channel binding from {:x}:{:x} for channel {:x}",
                src_addr,
                src_port,
                channel_number,
            );

            return Ok(xdp_action::XDP_PASS);
        };

        {
            let mut ipv4hdr_mut = parse_ipv4_mut(ipv4hdr_slice)?;

            let new_src_addr = dst_addr; // The IP we received the packet on will be the new source IP.
            let new_dst_addr = port_and_peer.dest_ip();
            let new_tot_len = tot_len - 4;

            ipv4hdr_mut.set_source(new_src_addr.to_be_bytes());
            ipv4hdr_mut.set_destination(new_dst_addr.to_be_bytes());
            ipv4hdr_mut.set_total_length(new_tot_len.to_be_bytes());

            let new_ipv4_checksum = csum_fold_helper(unsafe {
                bpf_csum_diff(
                    [src_addr, dst_addr, u32::from(tot_len)].as_mut_ptr(), // Original components
                    3 * 4,
                    [new_src_addr, new_dst_addr, u32::from(new_tot_len)].as_mut_ptr(), // New components
                    3 * 4,
                    u32::from(!ipv4_checksum),
                ) as u64
            });
            ipv4hdr_mut.set_checksum(new_ipv4_checksum);

            trace!(
                ctx,
                "Updating IP checksum from {:x} to {:x}",
                ipv4_checksum,
                new_ipv4_checksum
            );

            let mut udphdr_mut = parse_udp_mut(udphdr_slice)?;

            let new_src_port = port_and_peer.allocation_port();
            let new_dst_port = port_and_peer.dest_port();
            let new_udp_payload_len = udp_payload_len - 4;

            udphdr_mut.set_source_port(new_src_port);
            udphdr_mut.set_destination_port(new_dst_port);
            udphdr_mut.set_length(new_udp_payload_len);

            let new_udp_checksum = csum_fold_helper(unsafe {
                bpf_csum_diff(
                    [
                        src_addr,
                        dst_addr,
                        u32::from(udp_payload_len),
                        u32::from(src_port),
                        u32::from(dst_port),
                        u32::from_be_bytes([cdhdr[0], cdhdr[1], cdhdr[2], cdhdr[3]]),
                    ]
                    .as_mut_ptr(),
                    6 * 4,
                    [
                        new_src_addr,
                        new_dst_addr,
                        u32::from(new_udp_payload_len),
                        u32::from(new_src_port),
                        u32::from(new_dst_port),
                    ]
                    .as_mut_ptr(),
                    5 * 4,
                    u32::from(!udp_checksum),
                )
            } as u64);
            udphdr_mut.set_checksum(new_udp_checksum);

            trace!(
                ctx,
                "Updating UDP checksum from {:x} to {:x}",
                udp_checksum,
                new_udp_checksum
            );
        }

        let mut headers = [0u8; Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN];

        // TODO: See if we can combine this and avoid the intermediate copy of the headers.
        unsafe {
            bpf_xdp_load_bytes(
                ctx.ctx,
                0,
                headers.as_mut_ptr() as *mut c_void,
                (Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN) as u32,
            );
        }

        unsafe { bpf_xdp_adjust_head(ctx.ctx, 4) };

        unsafe {
            bpf_xdp_store_bytes(
                ctx.ctx,
                0,
                headers.as_mut_ptr() as *mut c_void,
                (Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN) as u32,
            )
        };

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
    } else {
        try_handle_peer(ctx)
    }
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
fn try_handle_peer(_: &XdpContext) -> Result<u32, Error> {
    Err(Error::NotImplemented)
}

// Converts a checksum into u16
#[inline(always)]
pub fn csum_fold_helper(mut csum: u64) -> u16 {
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);

    !(csum as u16)
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
