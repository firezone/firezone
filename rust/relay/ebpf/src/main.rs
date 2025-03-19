#![no_std]
#![no_main]

use crate::error::Error;
use aya_ebpf::{
    bindings::xdp_action,
    macros::{map, xdp},
    maps::HashMap,
    programs::XdpContext,
};
use aya_log_ebpf::*;
use etherparse::{
    checksum, EtherType, Ethernet2Header, Ethernet2HeaderSlice, IpNumber, Ipv4Header,
    Ipv4HeaderSlice, UdpHeader, UdpHeaderSlice,
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

            xdp_action::XDP_ABORTED
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

    let source_addr = u32::from_be_bytes(ipv4hdr.source());
    let tot_len = ipv4hdr.total_len();
    // let ipv4hdr_length = usize::from(ipv4hdr.ihl() * 4);
    let ipv4hdr_length = Ipv4Header::MIN_LEN;

    let IpNumber::UDP = ipv4hdr.protocol() else {
        return Ok(xdp_action::XDP_PASS);
    };

    let udphdr_slice =
        slice_mut_at::<{ UdpHeader::LEN }>(ctx, Ethernet2Header::LEN + ipv4hdr_length)?;
    let udphdr = parse_udp(udphdr_slice)?;

    let source_port = udphdr.source_port();
    let dest_port = udphdr.destination_port();
    let udp_payload_len = udphdr.length();

    trace!(ctx, "New packet from {:i}:{}", source_addr, source_port);

    if dest_port == 3478 {
        // Handle channel data messages

        let cdhdr = slice_mut_at::<{ CHANNEL_DATA_HEADER_LEN }>(
            ctx,
            Ethernet2Header::LEN + ipv4hdr_length + UdpHeader::LEN,
        )?;

        if !(64..=79).contains(&cdhdr[0]) {
            return Ok(xdp_action::XDP_PASS);
        }

        let channel_number = u16::from_be_bytes([cdhdr[0], cdhdr[1]]);
        let channel_data_length = usize::from(u16::from_be_bytes([cdhdr[2], cdhdr[3]]));

        if channel_data_length > usize::from(u16::MAX) {
            return Ok(xdp_action::XDP_DROP);
        }

        let channel_data_payload = remaining_bytes(
            ctx,
            Ethernet2Header::LEN + ipv4hdr_length + UdpHeader::LEN + CHANNEL_DATA_HEADER_LEN,
        )?;

        // if channel_data_payload.len() != channel_data_length {
        //     return Ok(xdp_action::XDP_DROP);
        // }

        let client_and_channel = ClientAndChannel::new(source_addr, source_port, channel_number);

        let binding = unsafe { CHANNELS_TO_UDP.get(&client_and_channel) };
        let Some(port_and_peer) = binding else {
            debug!(
                ctx,
                "No channel binding from {:x}:{:x} for channel {:x}",
                source_addr,
                source_port,
                channel_number,
            );

            return Ok(xdp_action::XDP_PASS);
        };

        let ipv4_dst = ipv4hdr.destination();

        {
            let mut ipv4hdr_mut = parse_ipv4_mut(ipv4hdr_slice)?;

            ipv4hdr_mut.set_source(ipv4_dst); // The IP we received the packet on will be the new source IP.
            ipv4hdr_mut.set_destination(port_and_peer.dest_ip().to_be_bytes());
            ipv4hdr_mut.set_total_length((tot_len - 4).to_be_bytes());
        }

        {
            let mut udphdr_mut = parse_udp_mut(udphdr_slice)?;

            udphdr_mut.set_source_port(port_and_peer.allocation_port());
            udphdr_mut.set_destination_port(port_and_peer.dest_port());
            udphdr_mut.set_length(udp_payload_len - 4);
        }

        {
            let ipv4_header = parse_ipv4(ipv4hdr_slice)?;

            let udp_checksum = parse_udp(udphdr_slice)?
                .to_header()
                .calc_checksum_ipv4_raw(
                    ipv4_header.source(),
                    ipv4_header.destination(),
                    channel_data_payload,
                )
                .map_err(|_| Error::UdpChecksum)?;
            let ipv4_checksum = calc_ipv4_checksum(&ipv4_header);

            parse_udp_mut(udphdr_slice)?.set_checksum(udp_checksum);
            parse_ipv4_mut(ipv4hdr_slice)?.set_checksum(ipv4_checksum);
        }

        unsafe {
            aya_ebpf::memmove(
                cdhdr.as_mut_ptr(),
                channel_data_payload.as_mut_ptr(),
                channel_data_length,
            );
        }

        info!(
            ctx,
            "Redirecting message from {:i}:{} on channel {} to {:i}:{} on port {}",
            source_addr,
            source_port,
            channel_number,
            port_and_peer.dest_ip(),
            port_and_peer.dest_port(),
            port_and_peer.allocation_port()
        );

        Ok(xdp_action::XDP_REDIRECT)
    } else {
        try_handle_peer(ctx)
    }
}

#[inline(always)]
fn calc_ipv4_checksum(ipv4_header: &Ipv4HeaderSlice) -> u16 {
    checksum::Sum16BitWords::new()
        .add_2bytes([
            (4 << 4) | ipv4_header.ihl(),
            (ipv4_header.dcp().value() << 2) | ipv4_header.ecn().value(),
        ])
        .add_2bytes(ipv4_header.total_len().to_be_bytes())
        .add_2bytes(ipv4_header.identification().to_be_bytes())
        .add_2bytes({
            let frag_off_be = ipv4_header.fragments_offset().value().to_be_bytes();
            let flags = {
                let mut result = 0;
                if ipv4_header.dont_fragment() {
                    result |= 64;
                }
                if ipv4_header.more_fragments() {
                    result |= 32;
                }
                result
            };
            [flags | (frag_off_be[0] & 0x1f), frag_off_be[1]]
        })
        .add_2bytes([ipv4_header.ttl(), ipv4_header.protocol().0])
        .add_4bytes(ipv4_header.source())
        .add_4bytes(ipv4_header.destination())
        .add_slice(ipv4_header.options())
        .ones_complement()
        .to_be()
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
fn remaining_bytes(ctx: &XdpContext, offset: usize) -> Result<&mut [u8], Error> {
    let start = ctx.data() + offset;
    let end = ctx.data_end();

    if start > end {
        return Err(Error::PacketTooShort);
    }

    let len = end - start;

    Ok(unsafe { core::slice::from_raw_parts_mut(start as *mut u8, len) })
}
